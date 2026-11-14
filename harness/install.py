#!/usr/bin/env python3
import argparse
import csv
import functools
import hashlib
import json
import os
import pathlib
import sys
import time

import cluster
import reset
from cluster import Failed, NOT_ON_KIND, STEWARDS, kjson, kubectl

RELEASES = (("orchestrator", "orchestrator"), ("agents", "agents"), ("surf", "thirdparty"), ("api-gateway", "api-gateway"))
REQUIRED = ("orchestrator", "agents", "api-gateway")
LAUNCH = ("microservices.json", "requestType.json", "archetype.json", "agreements.json", "datasets.json",
          "optional_microservices.json")
JOB_TAGS = ("VFL-TRAIN-MODEL-DEMO_TAG", "ANONYMIZE-TEST_TAG", "VFL-TRAIN-DEMO_TAG", "DIFFERENTIAL-P-TEST_TAG",
            "SIDECAR_TAG", "POLICY-CHECKPOINT-GATEWAY_TAG")
REPOSITORIES = ("MICROSERVICE_REPOSITORY_NAME", "SIDECAR_REPOSITORY_NAME")
STAMP = ("dynamos/data-steward", "dynamos/request-user", "dynamos/request-type")
HOSTNAME = "kubernetes.io/hostname"
INSPECTOR = "stayup-inspector"
COLUMNS = ("check", "subject", "expected", "observed", "result")


def row(check, subject, expected, observed, ok):
    result = ok if isinstance(ok, str) else ("pass" if ok else "fail")
    return dict(zip(COLUMNS, (check, subject, str(expected), str(observed), result)))


def write_rows(path, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", newline="") as f:
        writer = csv.DictWriter(f, COLUMNS)
        writer.writeheader()
        writer.writerows(rows)


def default_out(name):
    scratch = pathlib.Path(os.environ.get("HARNESS_SCRATCH", "~/stayup")).expanduser()
    return scratch / "runs" / f"{name}-{time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())}"


def sha256(path):
    return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()


def target(pinned):
    accounts = {entry["repository"].split("/")[0] for entry in pinned.values()}
    tags = {entry["tag"] for entry in pinned.values()}
    if len(accounts) != 1 or len(tags) != 1:
        raise Failed(f"the pins must name one account and one tag; they name {sorted(accounts)} and {sorted(tags)}")
    return accounts.pop(), tags.pop()


def values(release, account, tag):
    chosen = {"dockerArtifactAccount": account, "branchNameTag": tag}
    if release == "agents":
        chosen.update(microserviceRepositoryName=account, sidecarRepositoryName=account, localDev="false",
                      chainImageTag=tag)
    return chosen


@functools.cache
def apply_method():
    version = cluster.run(["helm", "version", "--template", "{{.Version}}"]).strip()
    return ["--server-side=false"] if version.startswith("v4") else []


def helm_arguments(release, chart, chosen):
    path = cluster.ROOT / "charts" / chart
    arguments = [release, str(path), "-f", str(path / "values.yaml"), *apply_method()]
    for key, value in chosen.items():
        arguments += ["--set-string", f"{key}={value}"]
    return arguments


def deployed():
    listed = {entry["name"]: entry for entry in json.loads(cluster.run(["helm", "list", "-A", "-o", "json"]))}
    missing = [name for name in REQUIRED if listed.get(name, {}).get("status") not in ("deployed", "failed")]
    if missing:
        raise Failed(f"releases neither deployed nor failed: {' '.join(missing)}")
    return [(release, chart, listed[release]["namespace"]) for release, chart in RELEASES if release in listed]


def objects(text):
    decoder = json.JSONDecoder()
    found = []
    position = 0
    while position < len(text):
        if text[position].isspace():
            position += 1
            continue
        item, position = decoder.raw_decode(text, position)
        found.extend(item["items"] if item.get("kind") == "List" else [item])
    return found


def rendered(release, chart, namespace, chosen):
    answer = json.loads(cluster.run(["helm", "upgrade", *helm_arguments(release, chart, chosen), "-n", namespace,
                                     "--dry-run", "-o", "json"], timeout=120))
    manifest = answer["manifest"]
    found = objects(cluster.run(["kubectl", "create", "--dry-run=client", "-o", "json", "-f", "-"], stdin=manifest))
    return found, answer.get("config") or {}


def supplied(release, namespace):
    return json.loads(cluster.run(["helm", "get", "values", release, "-n", namespace, "-o", "json"])) or {}


def kept_rows(release, namespace, config, chosen):
    rows = []
    for key, value in sorted(supplied(release, namespace).items()):
        if key not in config:
            observed, ok = "dropped", False
        elif config.get(key) == value:
            observed, ok = "kept, same value", True
        else:
            observed, ok = f"kept, {json.dumps(value)} -> {json.dumps(config.get(key))}", key in chosen
        rows.append(row("render kept value", f"{release} {key}", "kept; changed only if this install sets it",
                        observed, ok))
    return rows


def pod_spec(item):
    if item["kind"] == "Pod":
        return item["spec"]
    if item["kind"] in ("Deployment", "StatefulSet", "DaemonSet", "Job", "ReplicaSet"):
        return item["spec"]["template"]["spec"]
    return None


def containers(spec):
    return spec.get("initContainers", []) + spec["containers"]


def environment(spec, name):
    for container in spec["containers"]:
        if container["name"] == name:
            return {entry["name"]: entry.get("value", "") for entry in container.get("env", [])}
    return {}


def agent_rows(check, steward, spec, account, tag, local_dev):
    found = environment(spec, steward)
    subject = f"{steward}/{steward}"
    rows = [row(check, f"{subject} {name}", tag, found.get(name, "(unset)"), found.get(name) == tag)
            for name in JOB_TAGS]
    rows += [row(check, f"{subject} {name}", account, found.get(name, "(unset)"), found.get(name) == account)
             for name in REPOSITORIES]
    observed = found.get("LOCAL_DEV", "(unset)")
    rows.append(row(check, f"{subject} LOCAL_DEV", "false", observed, local_dev or observed == "false"))
    return rows


def render(mode, pinned):
    account, tag = target(pinned)
    rows = []
    for release, chart, namespace in deployed():
        chosen = values(release, account, tag)
        found, config = rendered(release, chart, namespace, chosen)
        rows += kept_rows(release, namespace, config, chosen)
        for item in found:
            spec = pod_spec(item)
            if spec is None:
                continue
            subject = f"{item['metadata'].get('namespace', namespace)}/{item['metadata']['name']}"
            for container in containers(spec):
                found = cluster.parse_image(container["image"])
                if found[0] not in cluster.ACCOUNTS:
                    continue
                rows.append(row("render image", f"{subject} {container['name']}", f"{account}/<a pinned name>:{tag}",
                                container["image"], found[0] == account and found[1] in pinned and found[2] == tag))
            if item["kind"] == "Deployment" and item["metadata"]["name"] in STEWARDS:
                rows += agent_rows("render agent", item["metadata"]["name"], spec, account, tag, "")
    for (namespace, name), node in cluster.PLACEMENT.items():
        patched = kjson("-n", namespace, "patch", "deployment", name, "--type", "merge", "-p", pin_patch(node),
                        "--dry-run=server")
        observed = (patched["spec"]["template"]["spec"].get("nodeSelector") or {}).get(HOSTNAME, "(none)")
        rows.append(row("render placement", f"{namespace}/{name}", node, observed, observed == node))
    for name in LAUNCH:
        path = cluster.ROOT / "configuration" / "etcd_launch_files" / name
        rows.append(row("render launch file", name, "in the tree", "present" if path.is_file() else "absent",
                        path.is_file()))
    if not any(entry["check"] == "render image" for entry in rows):
        rows.append(row("render image", "-", "at least one image", "none rendered", False))
    return rows


def pin_patch(node):
    return json.dumps({"spec": {"template": {"spec": {"nodeSelector": {HOSTNAME: node}}}}})


def orchestrator_pod():
    pods = kjson("-n", "orchestrator", "get", "pods", "-l", "app=orchestrator",
                 "--field-selector=status.phase=Running")["items"]
    if len(pods) != 1:
        raise Failed(f"expected one running orchestrator pod, found {len(pods)}")
    return pods[0]["metadata"]["name"]


def launch_in_volume(name):
    return cluster.run(["kubectl", "-n", "orchestrator", "exec", orchestrator_pod(), "-c", "orchestrator", "--",
                        "cat", f"/app/etcd/{name}"], binary=True)


def stamp_missing(claim):
    annotations = claim["metadata"].get("annotations") or {}
    return [key for key in STAMP if not annotations.get(key)]


def unstamped():
    return [(namespace, claim["metadata"]["name"]) for namespace in STEWARDS
            for claim in reset.state_claims(namespace) if stamp_missing(claim)]


def state(mode, pinned):
    account, tag = (cluster.KIND_ACCOUNT, cluster.KIND_TAG) if mode == "kind" else target(pinned)
    rows = []
    for name, node in cluster.nodes().items():
        rows.append(row("SC-0 node", name, "Ready", "Ready" if node["ready"] else "NotReady", node["ready"]))
    for pod in kjson("get", "pods", "-A")["items"]:
        subject = f"{pod['metadata']['namespace']}/{pod['metadata']['name']}"
        statuses = {entry["name"]: entry for key in ("initContainerStatuses", "containerStatuses")
                    for entry in pod["status"].get(key, [])}
        for container in containers(pod["spec"]):
            found = cluster.parse_image(container["image"])
            if found[0] not in cluster.ACCOUNTS:
                continue
            identity = statuses.get(container["name"], {}).get("imageID", "")
            if mode == "kind":
                rows.append(row("SC-0 digest", f"{subject} {container['name']}", "a pinned digest",
                                f"{container['image']} {identity}", NOT_ON_KIND))
                continue
            pin = pinned.get(found[1], {}).get("digest", "(not pinned)")
            rows.append(row("SC-0 digest", f"{subject} {container['name']}", f"{account}/{found[1]}@{pin}",
                            identity or "(no imageID)",
                            found[0] == account and found[1] in pinned and identity.endswith("@" + pin)))
    deployments = {(d["metadata"]["namespace"], d["metadata"]["name"]): d
                   for d in kjson("get", "deployments", "-A")["items"]}
    for steward in STEWARDS:
        spec = deployments[(steward, steward)]["spec"]["template"]["spec"]
        rows += agent_rows("SC-0 agent", steward, spec, account, tag, NOT_ON_KIND if mode == "kind" else "")
    for (namespace, name), node in cluster.PLACEMENT.items():
        if mode == "kind":
            rows.append(row("SC-0 placement", f"{namespace}/{name}", node, "one node", NOT_ON_KIND))
            continue
        selector = deployments[(namespace, name)]["spec"]["template"]["spec"].get("nodeSelector") or {}
        labels = deployments[(namespace, name)]["spec"]["selector"]["matchLabels"]
        chosen = ",".join(f"{key}={value}" for key, value in labels.items())
        on_nodes = sorted({pod["spec"].get("nodeName", "(none)")
                           for pod in kjson("-n", namespace, "get", "pods", "-l", chosen)["items"]})
        rows.append(row("SC-0 placement", f"{namespace}/{name}", node,
                        f"selector {selector.get(HOSTNAME, '(none)')}, pods on {' '.join(on_nodes) or '(no pod)'}",
                        selector.get(HOSTNAME) == node and on_nodes == [node]))
    for name in LAUNCH:
        want = sha256(cluster.ROOT / "configuration" / "etcd_launch_files" / name)
        try:
            got = hashlib.sha256(launch_in_volume(name)).hexdigest()
        except Failed as error:
            got = f"unreadable: {error}"
        rows.append(row("SC-0 launch file", name, want, got, got == want))
    claims = [(namespace, claim) for namespace in STEWARDS for claim in reset.state_claims(namespace)]
    for namespace, claim in claims:
        missing = stamp_missing(claim)
        rows.append(row("SC-0 claim stamp", f"{namespace}/{claim['metadata']['name']}", "the three stamp annotations",
                        "all three" if not missing else "missing " + " ".join(missing), not missing))
    rows.append(row("SC-0 claim stamp", "state claims without the stamp", 0,
                    sum(1 for _, claim in claims if stamp_missing(claim)),
                    not any(stamp_missing(claim) for _, claim in claims)))
    return rows


def record(folder, releases):
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "helm-list.json").write_text(cluster.run(["helm", "list", "-A", "-o", "json"]))
    for release, _, namespace in releases:
        (folder / f"values-{release}.json").write_text(
            cluster.run(["helm", "get", "values", release, "-n", namespace, "-o", "json"]))
    for kind in ("nodes", "deployments", "pods", "pvc", "pv", "svc"):
        (folder / f"{kind}.json").write_text(kubectl("get", kind, "-A", "-o", "json", timeout=120))


def apply(out, pinned):
    account, tag = target(pinned)
    releases = deployed()
    record(out / "before", releases)
    rows = render("fabric", pinned)
    write_rows(out / "render.csv", rows)
    failed = [entry for entry in rows if entry["result"] == "fail"]
    if failed:
        raise Failed(f"{len(failed)} rendered values are wrong, nothing changed; see {out / 'render.csv'}")
    pod = orchestrator_pod()
    for name in LAUNCH:
        (out / "before" / f"launch-{name}").write_bytes(launch_in_volume(name))
        source = cluster.ROOT / "configuration" / "etcd_launch_files" / name
        kubectl("cp", str(source), f"orchestrator/{pod}:/app/etcd/{name}", "-c", "orchestrator")
        if hashlib.sha256(launch_in_volume(name)).hexdigest() != sha256(source):
            raise Failed(f"launch file {name} in the orchestrator's volume differs from the tree after the copy")
    for release, chart, namespace in releases:
        answer = cluster.run(["helm", "upgrade", *helm_arguments(release, chart, values(release, account, tag)),
                              "-n", namespace], timeout=300)
        (out / f"upgrade-{release}.txt").write_text(answer)
    for (namespace, name), node in cluster.PLACEMENT.items():
        kubectl("-n", namespace, "patch", "deployment", name, "--type", "merge", "-p", pin_patch(node))
    for namespace, name in cluster.REQUEST_PATH:
        kubectl("-n", namespace, "rollout", "status", f"deployment/{name}", "--timeout=600s", timeout=620)
    record(out / "after", releases)


def inspect(mode, namespace, claim, folder):
    manifest = {
        "apiVersion": "v1", "kind": "Pod", "metadata": {"name": INSPECTOR, "namespace": namespace},
        "spec": {
            "restartPolicy": "Never",
            "containers": [{
                "name": "inspector", "image": cluster.image(mode, "vfl-train-demo"), "imagePullPolicy": "IfNotPresent",
                "command": ["sleep", "3600"],
                "volumeMounts": [{"name": "state", "mountPath": "/state", "readOnly": True}],
            }],
            "volumes": [{"name": "state", "persistentVolumeClaim": {"claimName": claim}}],
        },
    }
    kubectl("apply", "-f", "-", stdin=json.dumps(manifest))
    try:
        kubectl("-n", namespace, "wait", "--for=condition=Ready", f"pod/{INSPECTOR}", "--timeout=180s", timeout=200)
        listing = kubectl("-n", namespace, "exec", INSPECTOR, "--", "sh", "-c",
                          "cd /state && find . -type f -exec sha256sum {} + | LC_ALL=C sort -k2", timeout=300)
        audit = cluster.run(["kubectl", "-n", namespace, "exec", INSPECTOR, "--", "sh", "-c",
                             "if [ -f /state/audit/audit.log ]; then cat /state/audit/audit.log; fi"],
                            timeout=300, binary=True)
    finally:
        kubectl("-n", namespace, "delete", "pod", INSPECTOR, "--ignore-not-found=true", "--grace-period=1",
                "--wait=true", "--timeout=60s", timeout=90)
    (folder / "files.sha256").write_text(listing)
    (folder / "audit.log").write_bytes(audit)
    inside = {line.split(None, 1)[1]: line.split(None, 1)[0] for line in listing.splitlines()}
    if inside.get("./audit/audit.log", hashlib.sha256(b"").hexdigest()) != hashlib.sha256(audit).hexdigest():
        raise Failed(f"{namespace}/{claim}: the copied audit log is not the file the claim holds")
    return len(inside)


def claims(mode, out):
    out.mkdir(parents=True, exist_ok=False)
    copied = 0
    for namespace in STEWARDS:
        for claim in reset.state_claims(namespace):
            name = claim["metadata"]["name"]
            folder = out / namespace / name
            folder.mkdir(parents=True)
            (folder / "claim.json").write_text(json.dumps(claim, indent=1, sort_keys=True))
            if claim["status"].get("phase") != "Bound":
                (folder / "NOT-BOUND").write_text(f"phase {claim['status'].get('phase')}: no volume, nothing to copy\n")
                print(f"not bound {namespace}/{name}")
                continue
            files = inspect(mode, namespace, name, folder)
            copied += 1
            print(f"copied    {namespace}/{name}: the audit log and the sha256 of {files} files")
    lines = [f"{sha256(path)}  {path.relative_to(out)}" for path in sorted(out.rglob("*")) if path.is_file()]
    (out / "SHA256SUMS").write_text("\n".join(lines) + "\n")
    print(f"claims: {copied} copied to {out}; sha256 of its SHA256SUMS: {sha256(out / 'SHA256SUMS')}")


def delete_claims(copied, laptop_sha256):
    if sha256(copied / "SHA256SUMS") != laptop_sha256:
        raise Failed("the sha256 given is not that of the copy's SHA256SUMS here: pull and verify the copy first")
    for line in (copied / "SHA256SUMS").read_text().splitlines():
        digest, _, name = line.partition("  ")
        if sha256(copied / name) != digest:
            raise Failed(f"the copy's file {name} differs from its SHA256SUMS line")
    doomed = unstamped()
    phases = {(namespace, claim["metadata"]["name"]): claim["status"].get("phase")
              for namespace in STEWARDS for claim in reset.state_claims(namespace)}
    for namespace, name in doomed:
        folder = copied / namespace / name
        if (folder / "NOT-BOUND").is_file() and phases.get((namespace, name)) == "Bound":
            raise Failed(f"{namespace}/{name} was not bound when copied and is bound now; nothing deleted")
        if not ((folder / "files.sha256").is_file() or (folder / "NOT-BOUND").is_file()):
            raise Failed(f"{namespace}/{name} has no copy under {copied}; nothing deleted")
    reset.clear_jobs()
    reset.clear_claims(set(doomed))
    left = unstamped()
    if left:
        raise Failed(f"unstamped claims left: {left}")
    print(f"delete-claims: {len(doomed)} unstamped claims deleted: {' '.join(f'{ns}/{n}' for ns, n in doomed)}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["render", "apply", "claims", "delete-claims"])
    parser.add_argument("--mode", choices=["kind", "fabric"], required=True)
    parser.add_argument("--pins", default=str(cluster.pins.DEFAULT))
    parser.add_argument("--out")
    parser.add_argument("--copied")
    parser.add_argument("--laptop-sha256")
    args = parser.parse_args()
    out = pathlib.Path(args.out).expanduser() if args.out else default_out(args.command)
    try:
        cluster.guard(args.mode)
        pinned = cluster.pinned(args.pins)
        if args.command == "render":
            rows = render(args.mode, pinned)
            write_rows(out / "render.csv", rows)
            failed = [entry for entry in rows if entry["result"] == "fail"]
            for entry in failed:
                print(f"FAIL {entry['check']}: {entry['subject']}: expected {entry['expected']}, "
                      f"rendered {entry['observed']}")
            print(f"render: {len(rows) - len(failed)} of {len(rows)} values as SC-0 wants them; {out / 'render.csv'}")
            return 1 if failed else 0
        if args.command == "apply":
            if args.mode != "fabric":
                raise Failed("apply changes the cluster and runs in fabric mode only; kind mode has render")
            apply(out, pinned)
            print(f"apply: done; {out}")
        elif args.command == "claims":
            claims(args.mode, out)
        else:
            if not (args.copied and args.laptop_sha256):
                raise Failed("delete-claims needs --copied and --laptop-sha256")
            delete_claims(pathlib.Path(args.copied).expanduser(), args.laptop_sha256)
    except Failed as error:
        print(f"FAIL {args.command}: {error}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
