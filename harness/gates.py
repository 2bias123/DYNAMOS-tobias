#!/usr/bin/env python3
import argparse
import csv
import datetime
import hashlib
import json
import os
import pathlib
import socket
import sys

import checks
import cluster
import pins
import reset
from cluster import Failed, NOT_ON_KIND, STEWARDS, Void, kjson

LEASE_END = "2026-11-22T17:34:00Z"
STOP_DATE = "2026-11-17T19:00:00Z"
FREE_BYTES = 20 * 10**9
DEADLINE = "HARNESS_DEADLINE_US"
COUNTED = "HARNESS_COUNTED"
NOT_COUNTED = ("no (kind mode)", "no (pilot)", "no (smoke)")
STATE_CLASS = "gateway-state"
PROVISIONER = "rancher.io/local-path"
ANY_NODE = "DEFAULT_PATH_FOR_NON_LISTED_NODES"
COLUMNS = ("when", "clock", "at_us", "gate", "subject", "expected", "observed", "result")
SAVED = "not asked: a saved listing"
IMAGES = "chain images on the node"
CHAIN_IMAGES = ("vfl-train-model-demo", "anonymize-test", "vfl-train-demo", "differential-p-test", "sidecar",
                "policy-checkpoint-gateway")
PULL_S = 900


def utc_us(text):
    return int(datetime.datetime.fromisoformat(text.replace("Z", "+00:00")).timestamp()) * 1_000_000


def row(gate, subject, expected, observed, ok):
    result = ok if isinstance(ok, str) else "pass" if ok else "fail"
    return {"gate": gate, "subject": subject, "expected": str(expected), "observed": str(observed), "result": result}


def nodes():
    return [row("node Ready", name, "Ready", "Ready" if info["ready"] else "NotReady", info["ready"])
            for name, info in cluster.nodes().items()]


def free_bytes(where, path):
    argv = ["df", "-B1", "--output=target,avail", path]
    if where is None:
        command = argv
    elif where.startswith("node:"):
        command = ["docker", "exec", where.removeprefix("node:"), *argv]
    else:
        command = cluster.on(where, argv)
    lines = cluster.run(command, timeout=30).splitlines()
    found = lines[1].rsplit(None, 1) if len(lines) == 2 else []
    if len(found) != 2 or not checks.whole(found[1]):
        raise Failed(f"df {path} answered {' | '.join(lines)!r}")
    return int(found[1]), found[0]


def claim_paths():
    found = kjson("get", "storageclass", STATE_CLASS)
    if found.get("provisioner") != PROVISIONER or found.get("parameters"):
        raise Failed(f"storage class {STATE_CLASS}: provisioner {found.get('provisioner')!r}, parameters "
                     f"{found.get('parameters')!r}; its node paths are read only for {PROVISIONER} without parameters")
    config = json.loads(kjson("-n", "local-path-storage", "get", "configmap", "local-path-config")["data"]["config.json"])
    classed = (config.get("storageClassConfigs") or {}).get(STATE_CLASS)
    entries = (classed or config).get("nodePathMap") or []
    paths = {entry["node"]: entry.get("paths") or [] for entry in entries}
    if not any(paths.values()):
        raise Failed(f"local-path-config gives no node path for {STATE_CLASS}")
    return paths


def disk(mode, out):
    rows, wanted = [], f">= {FREE_BYTES} bytes"
    folder = str(pathlib.Path(out).resolve())
    listed = cluster.nodes()
    if mode == "kind":
        roots = [("laptop", None)]
    else:
        roots = [("control", None), *((name, info["ip"]) for name, info in listed.items() if name != "control")]
    checked = [("disk free on /", name, where, "/") for name, where in roots]
    checked.append(("disk free for archives", f"{'laptop' if mode == 'kind' else 'control'}:{folder} (the run folder)",
                    None, folder))
    try:
        paths = claim_paths()
    except Failed as error:
        paths = None
        rows.append(row("disk free for state claims", f"{STATE_CLASS} node paths", wanted, error, False))
    for steward in STEWARDS if paths is not None else ():
        node = next(iter(listed)) if mode == "kind" else steward
        if node not in listed:
            rows.append(row("disk free for state claims", steward, wanted, "no such node", False))
            continue
        where = f"node:{node}" if mode == "kind" else listed[node]["ip"]
        for path in paths.get(node) or paths.get(ANY_NODE) or []:
            checked.append(("disk free for state claims", f"{steward} {node}:{path}", where, path))
    for gate, subject, where, path in checked:
        try:
            free, mount = free_bytes(where, path)
        except Void:
            raise
        except Failed as error:
            rows.append(row(gate, subject, wanted, error, False))
            continue
        rows.append(row(gate, subject, wanted, f"{free} on {mount}", free >= FREE_BYTES))
    return rows


def lease():
    given = os.environ.get(DEADLINE, "")
    counted = os.environ.get(COUNTED, "")
    if not checks.whole(given):
        unset = f"{DEADLINE} unset or not a number"
        return [row("lease", "the unit's watchdog deadline", f"before {LEASE_END}", unset, False),
                row("stop date", "the unit's watchdog deadline", f"before {STOP_DATE}", unset, False)]
    shown = datetime.datetime.fromtimestamp(int(given) / 1e6, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    rows = [row("lease", "the unit's watchdog deadline", f"before {LEASE_END}", shown, int(given) < utc_us(LEASE_END))]
    if counted in NOT_COUNTED:
        rows.append(row("stop date", "the unit's watchdog deadline", f"before {STOP_DATE} for a counted unit",
                        f"{shown}; counted: {counted}", "not a counted unit"))
    else:
        rows.append(row("stop date", "the unit's watchdog deadline", f"before {STOP_DATE} for a counted unit",
                        f"{shown}; counted: {counted or 'unset, taken as yes'}", int(given) < utc_us(STOP_DATE)))
    return rows


def ours(reference):
    return cluster.parse_image(reference)[0] in cluster.ACCOUNTS


def digests(mode, pinned, pods, ask=True):
    if mode == "kind":
        return [row("digest", "every container under the three accounts", "its pins.csv digest", "kind mode",
                    NOT_ON_KIND)]
    rows, seen = [], set()
    for pod in pods:
        subject = f"{pod['metadata']['namespace']}/{pod['metadata']['name']}"
        statuses = {entry["name"]: entry for key in ("initContainerStatuses", "containerStatuses")
                    for entry in pod["status"].get(key) or []}
        for container in [*(pod["spec"].get("initContainers") or []), *pod["spec"]["containers"]]:
            identity = statuses.get(container["name"], {}).get("imageID", "")
            if not (ours(container["image"]) or (identity and ours(identity))):
                continue
            if not identity:
                rows.append(row("digest", f"{subject} {container['name']}", "a started container",
                                f"{container['image']}, no image ID", False))
                continue
            expected, observed, ok = checks.judge_image(identity, pinned, container["image"])
            seen.add(cluster.parse_image(container["image"])[1])
            rows.append(row("digest", f"{subject} {container['name']}", expected, observed, ok))
    for name, pin in pinned.items():
        if name in seen:
            continue
        subject = f"{pin['repository']}:{pin['tag']} (no running container)"
        if not ask:
            rows.append(row("digest at the registry", subject, pin["digest"], "", SAVED))
            continue
        try:
            found = pins.registry_digest(pin["repository"], pin["tag"])
        except Exception as error:
            found = f"{type(error).__name__}: {error}"
        rows.append(row("digest at the registry", subject, pin["digest"], found or "(no such tag)",
                        found == pin["digest"]))
    return rows


def write(path, rows, when):
    fresh = not path.exists()
    at = reset.micros()
    with open(path, "a", newline="") as f:
        writer = csv.DictWriter(f, COLUMNS, lineterminator="\n")
        if fresh:
            writer.writeheader()
        writer.writerows({"when": when, "clock": f"host@{socket.gethostname()}", "at_us": at, **entry} for entry in rows)


def failing(rows):
    return [f"{entry['gate']} {entry['subject']}: expected {entry['expected']}, observed {entry['observed']}"
            for entry in rows if entry["result"] == "fail"]


def run(mode, out, when):
    rows = [*nodes(), *disk(mode, out), *lease(), *chain_images(mode, out),
            *digests(mode, cluster.pinned(), kjson("get", "pods", "-A", timeout=120)["items"])]
    (pathlib.Path(out) / "env").mkdir(parents=True, exist_ok=True)
    write(pathlib.Path(out) / "env" / "gates.csv", rows, when)
    wrong = failing(rows)
    if wrong:
        raise Failed(f"gates {when}: {wrong[0]}" + (f" ({len(wrong)} rows fail, in env/gates.csv)" if len(wrong) > 1 else ""))


def listing(path, sha256, out, pinned):
    source = pathlib.Path(path).expanduser()
    data = source.read_bytes()
    if sha256 and hashlib.sha256(data).hexdigest() != sha256:
        raise Failed(f"{source} has sha256 {hashlib.sha256(data).hexdigest()}, not {sha256}")
    pods = json.loads(data)["items"]
    out.mkdir(parents=True, exist_ok=True)
    gated = digests("fabric", pinned, pods, ask=False)
    write(out / "gates.csv", gated, f"saved listing {source.name}")
    taken = int(source.stat().st_mtime * 1e6)
    with open(out / "pods.csv", "w", newline="") as f:
        writer = csv.DictWriter(f, checks.POD_COLUMNS, lineterminator="\n")
        writer.writeheader()
        writer.writerows({**checks.pod_row(pod), "first_seen_us": taken, "last_seen_us": taken}
                         for pod in pods if pod["metadata"]["namespace"] in checks.NAMESPACES)
    judged = checks.verdict(out, "fabric", pinned)
    return failing(gated), judged, gated


def held(item):
    return {name.removeprefix("docker.io/") for name in item.get("names") or []}


def pull(mode, out, steward, reference):
    began = reset.micros()
    try:
        said = " ".join(cluster.run(cluster.on(cluster.host(mode, steward), ["sudo", "crictl", "pull", reference]),
                                    timeout=PULL_S).split())
        result = "pulled"
    except Void:
        raise
    except Failed as error:
        said, result = str(error), "pull failed"
    with open(pathlib.Path(out) / "env" / "pulls.log", "a") as f:
        f.write(f"{began} host@{socket.gethostname()} {steward} {reference} {result} after "
                f"{(reset.micros() - began) // 1000} ms: {said}\n")
    return result, said


def chain_images(mode, out, tag=cluster.KIND_TAG):
    (pathlib.Path(out) / "env").mkdir(parents=True, exist_ok=True)
    pinned = cluster.pinned()
    listed = {item["metadata"]["name"]: [held(entry) for entry in item["status"].get("images") or []]
              for item in kjson("get", "nodes")["items"]}
    rows = []
    for steward in STEWARDS:
        node = steward if mode == "fabric" else next(iter(listed))
        for name in CHAIN_IMAGES:
            pin = pinned[name]
            wanted = (f"{cluster.KIND_ACCOUNT}/{name}:{tag}" if mode == "kind"
                      else f"{pin['repository']}@{pin['digest']}")
            subject = f"{steward} {name}"
            if any(wanted in names for names in listed.get(node, [])):
                rows.append(row(IMAGES, subject, wanted, f"on node {node}", True))
            elif mode == "kind":
                rows.append(row(IMAGES, subject, wanted, f"chain image missing on node {node}; kind never pulls", False))
            else:
                result, said = pull(mode, out, steward, wanted)
                rows.append(row(IMAGES, subject, wanted, f"not listed on node {node}; {result}: {said}",
                                result == "pulled"))
    return rows


def images(mode, out, when, tag=cluster.KIND_TAG):
    rows = chain_images(mode, out, tag)
    write(pathlib.Path(out) / "env" / "gates.csv", rows, when)
    wrong = failing(rows)
    if wrong:
        raise Failed(f"chain image missing: {wrong[0]}" + (f" ({len(wrong)} rows fail)" if len(wrong) > 1 else ""))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["listing", "images"])
    parser.add_argument("path", nargs="?")
    parser.add_argument("--sha256")
    parser.add_argument("--pins", default=str(pins.DEFAULT))
    parser.add_argument("--mode", choices=["kind", "fabric"])
    parser.add_argument("--kind-tag", default=cluster.KIND_TAG)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    if args.command == "images":
        if args.mode is None or args.path:
            parser.error("images takes --mode and no path")
        if args.mode == "fabric" and args.kind_tag != cluster.KIND_TAG:
            parser.error("--kind-tag goes with --mode kind only")
        try:
            cluster.guard(args.mode)
            images(args.mode, pathlib.Path(args.out), "check", args.kind_tag)
        except Failed as error:
            print(f"images: {error}", file=sys.stderr)
            return 3 if isinstance(error, Void) else 1
        print(f"images: every chain image on each steward's node ({args.out}/env/gates.csv)")
        return 0
    if not args.path:
        parser.error("listing needs a path")
    try:
        wrong, judged, gated = listing(args.path, args.sha256, pathlib.Path(args.out), cluster.pinned(args.pins))
    except (Failed, OSError, ValueError, KeyError) as error:
        print(f"listing not judged: {type(error).__name__}: {error}", file=sys.stderr)
        return 1
    for line in wrong + judged:
        print(line)
    if wrong or judged:
        print(f"listing fails: digest gate {len(wrong)} and verdict {len(judged)} failing rows; first: "
              f"{(wrong + judged)[0]}", file=sys.stderr)
        return 1
    stage1 = sum(entry["gate"] == "digest" for entry in gated)
    print(f"listing passes: {stage1} containers on their pins, every pod in a class and on its node "
          f"({args.out}/verdict.csv)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
