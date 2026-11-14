#!/usr/bin/env python3
import argparse
import collections
import csv
import datetime
import pathlib
import select
import subprocess
import sys
import time

import cluster
import collect
import gates
import install
import reset
from cluster import Failed, NOT_ON_KIND, STEWARDS, kjson, kubectl
from install import row

EXCHANGES = 200
ROUNDS = 3
RUN_DEADLINE_S = {"kind": 300, "fabric": 900}
GATEWAY_END_S = 120
IDLE_SEEN_S = 90
IDLE_UP_BOUND_S = 60
GATEWAY = "policy-checkpoint-gateway"
ECHO = 'while read -r _; do echo "$EPOCHREALTIME"; done'
CLOCK_COLUMNS = ("when", "vm", "offset_us", "uncertainty_us", "exchanges", "reference_clock")


def now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def seconds(stamp):
    return datetime.datetime.fromisoformat(stamp.replace("Z", "+00:00")).timestamp()


def probe(target):
    shell = subprocess.Popen(cluster.on(target, ["bash", "-c", ECHO]), stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1)
    best = None
    try:
        for _ in range(EXCHANGES):
            before = time.time_ns()
            shell.stdin.write("\n")
            shell.stdin.flush()
            if not select.select([shell.stdout], [], [], 15)[0]:
                raise Failed("no answer within 15 s")
            line = shell.stdout.readline().strip()
            after = time.time_ns()
            whole, _, fraction = line.replace(",", ".").partition(".")
            if not (whole.isdigit() and fraction.isdigit()):
                raise Failed(f"the answer was '{line}', not a time")
            remote = int(whole) * 1_000_000 + int(fraction.ljust(6, "0")[:6])
            trip = (after - before) // 1000
            if best is None or trip < best[0]:
                best = (trip, remote - (before + after) // 2000)
    except OSError as error:
        raise Failed(str(error)) from None
    finally:
        shell.kill()
        shell.wait()
    return best[1], (best[0] + 1) // 2


def clocks(mode, when, out):
    reference = "laptop" if mode == "kind" else "control"
    rows = []
    lines = []
    for vm in [reference] if mode == "kind" else [reference, *cluster.nodes()]:
        target = None if vm == reference else cluster.host(mode, vm)
        try:
            offset, uncertainty = probe(target)
        except Failed as error:
            rows.append(row("SC-3 clock offset", f"{vm} {when}", "recorded", error, False))
            continue
        lines.append((when, vm, offset, uncertainty, EXCHANGES, f"host@{reference}"))
        rows.append(row("SC-3 clock offset", f"{vm} {when}", "recorded, no bound",
                        f"{offset} us, uncertainty {uncertainty} us, against {reference}", True))
        for name, command in (("chronyc", ["chronyc", "tracking"]), ("timedatectl", ["timedatectl"])):
            try:
                text = cluster.run(cluster.on(target, command), timeout=30)
            except Failed as error:
                text = f"not available: {error}\n"
            (out / "clocks").mkdir(exist_ok=True)
            (out / "clocks" / f"{when}-{vm}-{name}.txt").write_text(text)
    fresh = not (out / "clocks.csv").exists()
    with open(out / "clocks.csv", "a", newline="") as f:
        writer = csv.writer(f)
        if fresh:
            writer.writerow(CLOCK_COLUMNS)
        writer.writerows(lines)
    return rows


def sender_rows(mode, orchestrator):
    rows = []
    for steward in STEWARDS:
        target = cluster.host(mode, steward)
        subject = steward if mode == "fabric" else f"{steward} (sent from the laptop)"
        try:
            version = cluster.run(cluster.on(target, ["python3", "--version"]), timeout=30).strip()
        except Failed as error:
            version = str(error)
        rows.append(row("SC-4 python3 on the VM", subject, "Python 3", version, version.startswith("Python 3")))
        try:
            code = reset.put(target, f"{orchestrator}/api/v1/policyEnforcer", reset.seed_file(steward).read_text())
        except Failed as error:
            code = str(error)
        rows.append(row("SC-4 seed PUT from the VM", subject, 200, code, code == 200))
    wrong = reset.differing()
    rows.append(row("SC-4 seed comparison", "the four stewards", "etcd equals the seed",
                    "equal" if not wrong else "; ".join(wrong), not wrong))
    return rows


def claim_rows(mode, steward, before):
    found = reset.state_claims(steward)
    subject = f"{steward}/{found[0]['metadata']['name'] if found else '(no claim)'}"
    rows = [row("SC-1 claim made by the agent", subject, "no state claim before the run, one after it",
                f"{before} before, {len(found)} after", before == 0 and len(found) == 1)]
    if len(found) != 1:
        return rows, None
    claim = found[0]
    annotations = claim["metadata"].get("annotations") or {}
    stamp = dict(zip(install.STAMP, (steward.upper(), cluster.USER, cluster.REQUEST_TYPE)))
    for key, value in stamp.items():
        rows.append(row("SC-1 claim stamp", f"{subject} {key}", value, annotations.get(key, "(unset)"),
                        annotations.get(key) == value))
    selected = annotations.get("volume.kubernetes.io/selected-node", "(unset)")
    rows.append(row("SC-1 claim selected-node", subject, steward, selected,
                    NOT_ON_KIND if mode == "kind" else selected == steward))
    phase = claim["status"].get("phase")
    rows.append(row("SC-1 claim bound", subject, "Bound", phase, phase == "Bound"))
    affinity = "(no volume)"
    if claim["spec"].get("volumeName"):
        required = kjson("get", "pv", claim["spec"]["volumeName"])["spec"].get("nodeAffinity", {}).get("required", {})
        named = sorted({value for term in required.get("nodeSelectorTerms", [])
                        for expression in term.get("matchExpressions", [])
                        if expression["key"] == install.HOSTNAME for value in expression.get("values", [])})
        affinity = " ".join(named) or "(none)"
    rows.append(row("SC-1 volume node affinity", subject, steward, affinity,
                    NOT_ON_KIND if mode == "kind" else affinity == steward))
    return rows, claim["metadata"]["name"]


def chain_row(mode, steward):
    pods = reset.chain_pods(steward)
    if len(pods) != 1:
        return row("SC-1 chain pod node", steward, "one chain pod", f"{len(pods)} chain pods", False), None
    name = pods[0]["metadata"]["name"]
    node = pods[0]["spec"].get("nodeName", "(none)")
    return row("SC-1 chain pod node", f"{steward}/{name}", steward, node,
               NOT_ON_KIND if mode == "kind" else node == steward), name


def gateway_status(pod):
    return next((status for status in pod["status"].get("containerStatuses", []) if status["name"] == GATEWAY), {})


def gateway_end(steward, pod):
    state = gateway_status(kjson("-n", steward, "get", "pod", pod)).get("state", {})
    return (state.get("terminated") or {}).get("finishedAt")


def gateway_ends(chains):
    ends = {}

    def probe():
        for steward, pod in chains.items():
            if steward not in ends:
                try:
                    ends[steward] = gateway_end(steward, pod)
                except (Failed, KeyError) as error:
                    ends[steward] = Failed(f"{steward}/{pod} not readable before its end was seen: {error}")
                if ends[steward] is None:
                    del ends[steward]
        return len(ends) == len(chains)

    try:
        cluster.until("the jobs' enforcement points ended", GATEWAY_END_S, probe)
    except Failed:
        pass
    return {steward: ends.get(steward, Failed(f"the job's enforcement point in {steward}/{pod} ended: not within "
                                                f"{GATEWAY_END_S} s")) for steward, pod in chains.items()}


def idle_pod(steward, claim):
    for pod in kjson("-n", steward, "get", "pods", "-l", f"job-name=idle-{claim}")["items"]:
        if pod["status"].get("phase") != "Running":
            continue
        try:
            log = kubectl("-n", steward, "logs", pod["metadata"]["name"], "-c", GATEWAY)
        except Failed:
            continue
        if "Agreement loaded" in log:
            return pod
    return None


def idle_rows(mode, steward, claim, ended, pinned):
    try:
        if isinstance(ended, Failed):
            raise ended
        pod = cluster.until(f"an idle pod of idle-{claim} Running with 'Agreement loaded' in its log", IDLE_SEEN_S,
                            lambda: idle_pod(steward, claim))
    except Failed as error:
        return [row("SC-2 idle up after the job", steward, f"0 to {IDLE_UP_BOUND_S} s", error, False)]
    subject = f"{steward}/{pod['metadata']['name']}"
    status = gateway_status(pod)
    started = status["state"]["running"]["startedAt"]
    gap = int(seconds(started) - seconds(ended))
    owners = [f"{owner['kind']}/{owner['name']}" for owner in pod["metadata"].get("ownerReferences", [])]
    node = pod["spec"].get("nodeName", "(none)")
    pin = pinned[GATEWAY]["digest"]
    return [
        row("SC-2 idle up after the job", subject, f"0 to {IDLE_UP_BOUND_S} s",
            f"{gap} s, from {ended} to {started}, the kubelet's whole seconds", 0 <= gap <= IDLE_UP_BOUND_S),
        row("SC-2 idle pod owner", subject, f"Job/idle-{claim}", " ".join(owners) or "(none)",
            owners == [f"Job/idle-{claim}"]),
        row("SC-2 idle pod node", subject, steward, node, NOT_ON_KIND if mode == "kind" else node == steward),
        row("SC-2 idle pod digest", subject, pin, status.get("imageID", "(none)"),
            NOT_ON_KIND if mode == "kind" else status.get("imageID", "").endswith("@" + pin)),
    ]


def image_rows(mode, out):
    return [row(entry["gate"], entry["subject"], entry["expected"], entry["observed"], entry["result"] == "pass")
            for entry in gates.chain_images(mode, out)]


def logs_row(logs):
    failed = logs.finish()
    return row("logs kept", "pod logs from /var/log/pods, every 5 s and before every deletion",
               "a final harvest", f"final harvest done; {failed} earlier passes failed", True)


def check(mode, out, rows):
    stage = "start"
    logs = collect.Harvest(mode, out)
    try:
        cluster.guard(mode)
        pinned = cluster.pinned()
        stage = "SC-3 clocks before"
        rows += clocks(mode, "before", out)
        stage = "SC-0 install"
        rows += install.state(mode, pinned)
        if any(entry["result"] == "fail" for entry in rows if entry["check"].startswith("SC-0")):
            raise Failed("an SC-0 row failed, so the run was not started")
        stage = "logs"
        logs.begin()
        stage = "clean start"
        reset.clean()
        reset.rollouts()
        stage = "chain images"
        rows += image_rows(mode, out)
        if any(entry["result"] == "fail" for entry in rows if entry["check"] == gates.IMAGES):
            raise Failed("a chain image is missing on a steward's node, so the run was not started")
        with cluster.service(mode, "orchestrator") as orchestrator, cluster.service(mode, "api-gateway") as api:
            stage = "seed"
            reset.seed(orchestrator)
            stage = "SC-4 sender route"
            rows += sender_rows(mode, orchestrator)
            stage = "SC-1 run"
            before = {steward: len(reset.state_claims(steward)) for steward in STEWARDS}
            request = reset.trigger(api, ROUNDS, reset.Events(out / "events.csv"))
            reset.wait_done(api, request, RUN_DEADLINE_S[mode])
            made = {}
            for steward in STEWARDS:
                found, claim = claim_rows(mode, steward, before[steward])
                placed, chain = chain_row(mode, steward)
                rows += [*found, placed]
                made[steward] = (claim, chain)
            stage = "SC-2 idle"
            ends = gateway_ends({steward: chain for steward, (claim, chain) in made.items() if claim and chain})
            for steward, (claim, chain) in made.items():
                if claim and chain:
                    rows += idle_rows(mode, steward, claim, ends[steward], pinned)
                else:
                    rows.append(row("SC-2 idle up after the job", steward, f"0 to {IDLE_UP_BOUND_S} s",
                                    "no claim or no chain pod to follow", False))
    except Exception as error:
        rows.append(row(stage, "-", "completed", f"{type(error).__name__}: {error}", False))
        if stage in ("start", "SC-3 clocks before"):
            return
    for stage, step in (("logs kept", lambda: logs.thread is not None and rows.append(logs_row(logs))),
                        ("SC-3 clocks after", lambda: rows.extend(clocks(mode, "after", out))),
                        ("listing", lambda: listing(out))):
        try:
            step()
        except Exception as error:
            rows.append(row(stage, "-", "completed", f"{type(error).__name__}: {error}", False))


def listing(out):
    for kind in ("pods", "jobs", "pvc", "pv"):
        (out / f"{kind}.json").write_text(kubectl("get", kind, "-A", "-o", "json", timeout=120))


def summary(mode, out, rows, started):
    counts = collections.defaultdict(collections.Counter)
    for entry in rows:
        counts[entry["check"]][entry["result"]] += 1
    failed = [entry for entry in rows if entry["result"] == "fail"]
    lines = [cluster.KIND_LINE, ""] if mode == "kind" else []
    lines += [
        "# Slice check", "",
        f"- mode: {mode}",
        f"- started {started}, ended {now()} (UTC, this machine's clock)",
        f"- one run of {ROUNDS} rounds, seeded; nothing here is counted",
        f"- verdict: {'fail' if failed else 'pass'} ({len(failed)} of {len(rows)} rows fail)", "",
        f"| check | pass | fail | {NOT_ON_KIND} |", "|---|---|---|---|",
    ]
    lines += [f"| {name} | {c['pass']} | {c['fail']} | {c[NOT_ON_KIND]} |" for name, c in counts.items()]
    if failed:
        lines += ["", "## Failing rows", ""]
        lines += [f"- {e['check']}: {e['subject']}: expected {e['expected']}, observed {e['observed']}" for e in failed]
    lines += ["", "Every row is in `checks.csv`; the clock offsets are in `clocks.csv` and `clocks/`."]
    (out / "SUMMARY.md").write_text("\n".join(lines) + "\n")
    return failed


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=["kind", "fabric"], required=True)
    parser.add_argument("--out")
    args = parser.parse_args()
    out = pathlib.Path(args.out).expanduser() if args.out else install.default_out("slicecheck")
    out.mkdir(parents=True, exist_ok=False)
    started = now()
    rows = []
    try:
        check(args.mode, out, rows)
    finally:
        install.write_rows(out / "checks.csv", rows)
        failed = summary(args.mode, out, rows, started)
    for entry in failed:
        print(f"FAIL {entry['check']}: {entry['subject']}: expected {entry['expected']}, observed {entry['observed']}")
    print(f"slicecheck: {'fail' if failed else 'pass'}, {len(failed)} of {len(rows)} rows fail; {out / 'SUMMARY.md'}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
