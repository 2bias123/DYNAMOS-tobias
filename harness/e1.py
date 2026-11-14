#!/usr/bin/env python3
import argparse
import csv
import datetime
import hashlib
import json
import os
import pathlib
import re
import socket
import subprocess
import sys
import time

import checks
import cluster
import collect
import e4
import install
import records
import reset
from cluster import Failed, STEWARDS, kjson, kubectl

ROUNDS = 3
RUN_DEADLINE_S = {"kind": 300, "fabric": 900}
RECORD_COLUMNS = ("steward", "clock", "decided_us", "op", "decision", "reason", "state_class", "state_key",
                  "policy_source", "relation_id", "job_id")
CASE_COLUMNS = ("row", "case", "steward", "expected", "observed", "result")


def write(path, columns, rows):
    with open(path, "w", newline="") as f:
        writer = csv.DictWriter(f, columns, lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)


def run(mode, api, events, rounds=ROUNDS):
    begun = reset.micros()
    request = reset.trigger(api, rounds, events)
    reset.wait_done(api, request, RUN_DEADLINE_S[mode])
    events.add("run done", "api-gateway", reset.micros() - begun, f"request {request}")


def claim_records(unit, steward):
    claims = reset.state_claims(steward)
    if len(claims) != 1:
        raise Failed(f"{steward}: {len(claims)} state claims after the run, not 1")
    return unit.audit(steward, claims[0])


def record_row(steward, node, record):
    return {
        "steward": steward, "clock": f"gateway@{node}" if node else "", "decided_us": record["decidedUnixMicros"],
        "op": record.get("op", ""), "decision": record.get("decision", ""), "reason": record.get("reason", ""),
        "state_class": record.get("stateClass", ""), "state_key": record.get("stateKey", ""),
        "policy_source": record.get("policySource", ""), "relation_id": record.get("relationId", ""),
        "job_id": records.job_of(record),
    }


def seeded_relation(steward):
    return reset.terms(json.loads(reset.seed_file(steward).read_text()))[cluster.USER]["ID"]


def allowed_write(record, relation):
    return (records.job_of(record) != "" and record.get("relationId") == relation
            and record.get("policySource") in ("fresh", "cached")
            and (record.get("directives") or {}).get("allowed") is True)


def start(mode, out, unit):
    events = reset.Events(out / "events.csv")
    reset.clean_start(mode, events)
    unit.base()
    return events


def w4(mode, out):
    with collect.Unit(mode, out) as unit:
        events = start(mode, out, unit)
        with cluster.service(mode, "api-gateway") as api:
            run(mode, api, events)
        rows, cases, table = [], [], []
        for steward in STEWARDS:
            node, found = claim_records(unit, steward)
            rows += [record_row(steward, node, record) for record in found]
            relation = seeded_relation(steward)
            writes = records.since(found, 0, "write")
            allowed = [record for record in writes
                       if record.get("decision") == "ALLOW" and allowed_write(record, relation)]
            ok = bool(allowed) and len(allowed) == len(writes)
            cases.append({
                "row": "W4", "case": "write allowed", "steward": steward,
                "expected": f"write records only ALLOW, at least one, each by the job's enforcement point on relation "
                            f"{relation} with a fresh or cached view and allowed terms",
                "observed": f"{len(writes)} write records, {len(allowed)} of them ALLOW as expected",
                "result": "pass" if ok else "fail",
            })
            completeness(out, steward, found, cases, table)
        write(out / "records.csv", RECORD_COLUMNS, rows)
        write(out / "cases.csv", CASE_COLUMNS, cases)
        write(out / "completeness.csv", COMPLETENESS_COLUMNS, table)
    failed = [case for case in cases if case["result"] == "fail"]
    if failed:
        raise Failed("W4 failed: " + "; ".join(f"{case['steward']}: {case['observed']}" for case in failed))
    print("W4 passed on " + ", ".join(f"{case['steward']} ({case['observed']})" for case in cases))
    return 0


ORPHAN_GRACE_S = 10
WAIT_SHOWN_US = 5_000_000
PLANTS = {
    "foreground": (("deploy gap: chain pods gone",), "chain job deleted in the foreground, not waited for"),
    "orphaned": (("deploy gap: chain pods gone", "deploy gap: held"),
                 f"chain job removed, its pods deleted with a {ORPHAN_GRACE_S} s grace, not waited for"),
}


def plant(how, events):
    reset.harvest()
    planted = []
    for steward in STEWARDS:
        pods = [pod["metadata"]["name"] for pod in reset.chain_pods(steward)]
        if not kjson("-n", steward, "get", "jobs", "-l", reset.CHAIN)["items"] or not pods:
            raise Failed(f"p-gap: no chain job with a pod in {steward} after the run, so nothing was planted")
        if how == "foreground":
            began = reset.micros()
            kubectl("-n", steward, "delete", "jobs", "-l", reset.CHAIN, "--cascade=foreground", "--wait=false")
        else:
            kubectl("-n", steward, "delete", "jobs", "-l", reset.CHAIN, "--cascade=orphan", "--wait=true")
            began = reset.micros()
            kubectl("-n", steward, "delete", "pods", *pods, f"--grace-period={ORPHAN_GRACE_S}", "--wait=false")
        events.add(f"p-gap: {PLANTS[how][1]}", steward, 0, " ".join(pods))
        planted.append((steward, began))
    return planted


def gap_after(path, planted, needed):
    with open(path, newline="") as f:
        rows = list(csv.DictReader(f))
    last = max(at for _, at in planted)
    after = [row for row in rows if int(row["at_us"]) > last]
    sent = min((int(row["at_us"]) for row in after if row["event"] == "trigger"), default=None)
    if sent is None:
        raise Failed("p-gap: no trigger after the plant in events.csv")
    short = [steward for steward, at in planted if sent - at < reset.GAP_S * 1_000_000]
    waits = {(row["subject"], row["event"]): int(row["duration_us"]) for row in after if int(row["at_us"]) <= sent}
    waited = [steward for steward, _ in planted
              if all(waits.get((steward, event), 0) > WAIT_SHOWN_US for event in needed)]
    return sent, short, waited


def p_gap(mode, out):
    with collect.Unit(mode, out) as unit:
        events = start(mode, out, unit)
        plants = {}
        with cluster.service(mode, "api-gateway") as api:
            run(mode, api, events)
            for how in PLANTS:
                plants[how] = plant(how, events)
                run(mode, api, events)
    seen, wrong = [], []
    for how, planted in plants.items():
        sent, short, waited = gap_after(out / "events.csv", planted, PLANTS[how][0])
        first = min(at for _, at in planted)
        needed = " and ".join(f"'{event}'" for event in PLANTS[how][0])
        seen.append(f"{how}: trigger {(sent - first) / 1e6:.1f} s after the first plant, "
                    f"{needed} each over {WAIT_SHOWN_US // 1_000_000} s in {' '.join(waited) or 'none'}")
        if short or not waited:
            wrong.append(f"{how}: trigger under {reset.GAP_S} s after the plant in {' '.join(short) or 'none'}, "
                         f"{needed} each over {WAIT_SHOWN_US // 1_000_000} s in {' '.join(waited) or 'none'}")
    if wrong:
        print("deploy gap did not hold: " + "; ".join(wrong), file=sys.stderr)
        return 2
    print("deploy gap held: " + "; ".join(seen) + "; the waits are in events.csv", file=sys.stderr)
    return 1


HOLDER = "harness-lock-holder"
HOLD_S = 45
HOLDING = f"""import fcntl, time
lock = open("/state/.lock", "a")
fcntl.flock(lock, fcntl.LOCK_EX)
print("lock held", time.time_ns() // 1000, flush=True)
time.sleep({HOLD_S})
"""


def hold(mode, namespace, claim):
    manifest = {
        "apiVersion": "v1", "kind": "Pod", "metadata": {"name": HOLDER, "namespace": namespace},
        "spec": {
            "restartPolicy": "Never",
            "containers": [{"name": "holder", "image": cluster.image(mode, "vfl-train-demo"),
                            "imagePullPolicy": "IfNotPresent", "command": ["python3", "-c", HOLDING],
                            "volumeMounts": [{"name": "state", "mountPath": "/state"}]}],
            "volumes": [{"name": "state", "persistentVolumeClaim": {"claimName": claim}}],
        },
    }
    kubectl("apply", "-f", "-", stdin=json.dumps(manifest))
    cluster.until(f"{HOLDER} running in {namespace}", 120,
                  lambda: kjson("-n", namespace, "get", "pod", HOLDER)["status"].get("phase") == "Running")


def idle_running(namespace):
    return any(pod["status"].get("phase") == "Running" and not pod["metadata"].get("deletionTimestamp")
               for pod in kjson("-n", namespace, "get", "pods", "-l", reset.IDLE)["items"])


def p_m1(mode, out):
    steward = "server"
    try:
        with collect.Unit(mode, out) as unit:
            events = start(mode, out, unit)
            with cluster.service(mode, "api-gateway") as api:
                run(mode, api, events)
                claims = reset.state_claims(steward)
                if len(claims) != 1:
                    raise Failed(f"p-m1: {len(claims)} state claims in {steward} after the first run, not 1")
                cluster.until(f"the idle gateway running in {steward}", 180, lambda: idle_running(steward))
                hold(mode, steward, claims[0]["metadata"]["name"])
                events.add("p-m1: lock holder started, waiting for the lock the idle gateway holds", steward, 0,
                           f"pod/{HOLDER} on {claims[0]['metadata']['name']}, holds {HOLD_S} s once it has the lock")
                try:
                    run(mode, api, events)
                except cluster.Void:
                    raise
                except Failed as error:
                    events.add("p-m1: the second run did not finish", "api-gateway", 0, str(error)[:300])
                held = kubectl("-n", steward, "logs", HOLDER).strip()
                events.add("p-m1: lock holder log", steward, 0, held or "nothing logged")
                reset.harvest()
    finally:
        try:
            kubectl("-n", steward, "delete", "pod", HOLDER, "--ignore-not-found=true", "--grace-period=1",
                    "--wait=true", "--timeout=90s", timeout=120)
        except Failed as error:
            print(f"p-m1: {HOLDER} not deleted, the next clean start will refuse it: {error}", flush=True)
    print("p-m1: no marker seen with the lock held through the hand-over", file=sys.stderr)
    return 2


def p_restart(mode, out):
    with collect.Unit(mode, out) as unit:
        events = start(mode, out, unit)
        with cluster.service(mode, "api-gateway") as api:
            begun = reset.micros()
            request = reset.trigger(api, ROUNDS, events)
            reset.harvest()
            kubectl("-n", "orchestrator", "rollout", "restart", "deployment/orchestrator")
            events.add("p-restart: orchestrator restarted inside the run", "orchestrator", 0, f"request {request}")
            kubectl("-n", "orchestrator", "rollout", "status", "deployment/orchestrator", "--timeout=180s", timeout=200)
            try:
                reset.wait_done(api, request, RUN_DEADLINE_S[mode])
                events.add("run done", "api-gateway", reset.micros() - begun, f"request {request}")
            except Failed as error:
                events.add("p-restart: the run did not finish", "api-gateway", 0, str(error)[:300])
    print("p-restart: the orchestrator restart was not seen as a void", file=sys.stderr)
    return 2


IDLE_COLUMNS = ("case", "check", "steward", "start_clock", "start_us", "end_clock", "end_us", "value_us", "bound_us",
                "machines", "result")
POLL_S = 30
FINISHED_S = 120
UP_MARGIN_S = 30
REVOKED_MARGIN_S = 10
EXPIRY_MARGIN_S = 60
STANDALONE_POLL_S = 600
PROBE = ("harness_probe", "probe")
HANDED = re.compile(r"No idle gateway left on PVC (\S+) after (\S+)")
DURATION = re.compile(r"(\d+(?:\.\d+)?)(h|ms|us|µs|ns|m|s)")
SCALE = {"h": 3_600_000_000, "m": 60_000_000, "s": 1_000_000, "ms": 1_000, "us": 1, "µs": 1, "ns": 0.001}
NO_NODE = "harness/no-such-node"
POLICY = "harness-keep-idle-jobs"
PLANTING = f"""import os, pathlib
path = pathlib.Path("/state/data/{PROBE[0]}/{PROBE[1]}.bin")
path.parent.mkdir(parents=True, exist_ok=True)
path.write_bytes(b"harness")
print("planted", os.stat(path).st_mtime_ns // 1000, flush=True)
"""


def seconds(us):
    return f"{us / 1e6:.3f}"


def rfc3339(us):
    return datetime.datetime.fromtimestamp(us / 1e6, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def duration_us(text):
    parts = DURATION.findall(text)
    if not parts or "".join(number + unit for number, unit in parts) != text:
        raise Failed(f"not a duration: {text!r}")
    return round(sum(float(number) * SCALE[unit] for number, unit in parts))


def machines(mode, start_clock, end_clock):
    if mode == "kind":
        return "kind: one clock", True
    first, second = start_clock.partition("@")[2], end_clock.partition("@")[2]
    if first and first == second:
        return f"one: {first}", True
    return f"two: {first or '?'} and {second or '?'}", False


def interval(mode, rows, case, check, steward, start, end, bound_us, ok):
    shown, same = machines(mode, start[0], end[0] if end else "")
    rows.append({"case": case, "check": check, "steward": steward, "start_clock": start[0], "start_us": start[1],
                 "end_clock": end[0] if end else "", "end_us": end[1] if end else "",
                 "value_us": end[1] - start[1] if end else "", "bound_us": "" if bound_us is None else bound_us,
                 "machines": shown, "result": "pass" if ok and same and end else "fail"})
    return same


def add(cases, row, case, steward, expected, observed, ok):
    cases.append({"row": row, "case": case, "steward": steward, "expected": expected, "observed": observed,
                  "result": "pass" if ok else "fail"})


def conclude(out, cases, rows, name, expiry=None):
    write(out / "cases.csv", CASE_COLUMNS, cases)
    if rows is not None:
        write(out / "idle.csv", IDLE_COLUMNS, rows)
    if expiry is not None:
        write(out / "expiry.csv", e4.EXPIRY_COLUMNS, expiry)
    failed = [case for case in cases if case["result"] == "fail"]
    if failed:
        raise Failed(f"{name} failed: " + "; ".join(f"{case['case']} {case['steward']}: {case['observed']}"
                                                    for case in failed))
    print(f"{name} passed: {len(cases)} checks")
    return 0


def only_claim(steward):
    claims = reset.state_claims(steward)
    if len(claims) != 1:
        raise Failed(f"{steward}: {len(claims)} state claims, not 1")
    return claims[0]


def gateway_status(pod):
    return next((status for status in pod["status"].get("containerStatuses") or []
                 if status["name"] == checks.GATEWAY), {})


def gateway_ended(steward):
    for pod in sorted(reset.chain_pods(steward), key=lambda pod: pod["metadata"]["creationTimestamp"], reverse=True):
        ended = gateway_status(pod).get("state", {}).get("terminated", {}).get("finishedAt")
        if ended:
            return pod["spec"].get("nodeName", ""), reset.stamp_us(ended)
    return None


def gateway_started(steward):
    for pod in sorted(reset.chain_pods(steward), key=lambda pod: pod["metadata"]["creationTimestamp"], reverse=True):
        state = gateway_status(pod).get("state", {})
        began = (state.get("running") or state.get("terminated") or {}).get("startedAt")
        if began:
            return reset.stamp_us(began)
    return None


def idle_pod(steward, claim):
    for pod in kjson("-n", steward, "get", "pods", "-l", f"job-name=idle-{claim}")["items"]:
        if pod["metadata"].get("deletionTimestamp") or pod["status"].get("phase") != "Running":
            continue
        began = gateway_status(pod).get("state", {}).get("running", {}).get("startedAt")
        if not began:
            continue
        log = kubectl("-n", steward, "logs", pod["metadata"]["name"], "-c", checks.GATEWAY, "--timestamps")
        loaded = next((checks.cri_us(line) for line in log.splitlines() if "Agreement loaded" in line), None)
        if loaded is not None:
            return pod, loaded, reset.stamp_us(began)
    return None


def up_within(value_us, bound_s):
    return 0 <= value_us <= bound_s * 1_000_000


def idle_up(mode, steward, bound_s, rows, cases, case):
    claim = only_claim(steward)["metadata"]["name"]
    node, ended = cluster.until(f"{steward}: the job's enforcement point ended", FINISHED_S,
                                lambda: gateway_ended(steward))
    deadline = max(ended + (bound_s + UP_MARGIN_S) * 1_000_000, reset.micros() + 5_000_000)
    found = idle_pod(steward, claim)
    while found is None and reset.micros() < deadline:
        time.sleep(1)
        found = idle_pod(steward, claim)
    start = (f"kubelet@{node}", ended)
    if found is None:
        interval(mode, rows, case, "idle up after the job", steward, start, None, bound_s * 1_000_000, False)
        observed = (f"idle up not within {bound_s} s: no idle process running with its agreement loaded "
                    f"{bound_s + UP_MARGIN_S} s after the job's enforcement point ended")
        ok = False
    else:
        pod, loaded, began = found
        value = loaded - ended
        ok = up_within(value, bound_s)
        end_clock = f"log@{pod['spec'].get('nodeName', '')}"
        same = interval(mode, rows, case, "idle up after the job", steward, start, (end_clock, loaded),
                        bound_s * 1_000_000, ok)
        observed = (f"idle {'up' if ok else f'up not within {bound_s} s:'} {value / 1e6:.1f} s after the job's "
                    f"enforcement point ended (its container started {(began - ended) / 1e6:.0f} s after), pod "
                    f"{pod['metadata']['name']}"
                    + ("" if same else f"; the two stamps on {machines(mode, start[0], end_clock)[0]}"))
        ok = ok and same
    add(cases, "stay-up", f"{case}: idle up", steward,
        f"an idle process up (its 'Agreement loaded' line, logged once it holds the lock) within {bound_s} s of the "
        f"job's enforcement point ending (kubelet's whole-second finishedAt), both on the steward's VM", observed, ok)
    return found


def job_uid(steward, name):
    found = kjson("-n", steward, "get", "jobs", "--field-selector", f"metadata.name={name}")["items"]
    return found[0]["metadata"]["uid"] if found else ""


def snapshot(mode, out, label, steward):
    claim = only_claim(steward)["metadata"]["name"]
    folder = out / "raw" / "snapshots" / label / steward
    folder.mkdir(parents=True)
    install.inspect(mode, steward, claim, folder)
    return (folder / "audit.log").read_bytes(), (folder / "files.sha256").read_text()


def state_files(listing):
    return [line for line in listing.splitlines() if line.split(None, 1)[-1].startswith("./data/")]


def complete(steward, claim, seconds_):
    try:
        kubectl("-n", steward, "wait", "--for=condition=complete", f"job/idle-{claim}", f"--timeout={seconds_}s",
                timeout=seconds_ + 30)
        return True
    except cluster.Void:
        raise
    except Failed:
        return False


def written_keys(found):
    return sorted({e4.key_of(record) for record in e4.run_writes(found) if record.get("decision") == "ALLOW"})


def revocation_verdict(found, at, bound_s, wanted):
    purged = records.since(found, 0, "purge", "PURGED")
    if not purged:
        return purged, [f"no PURGED record: not within {bound_s} s of the send"]
    problems = []
    values = [record["decidedUnixMicros"] - at for record in purged]
    if min(values) < 0:
        problems.append(f"{sum(1 for value in values if value < 0)} PURGED records before the send")
    if max(values) > bound_s * 1_000_000:
        problems.append(f"PURGED {max(values) / 1e6:.3f} s after the send: not within {bound_s} s of the send")
    keys = sorted(e4.key_of(record) for record in purged)
    if keys != sorted(wanted):
        problems.append(f"PURGED records for {keys}, state written {sorted(wanted)}: not one per state file")
    wrong = [f"{record.get('stateClass', '')}/{record.get('stateKey', '')} "
             f"{'with job fields' if records.job_of(record) else ''} {record.get('policySource', '')}"
             for record in purged if records.job_of(record) or record.get("policySource") != "fresh"]
    if wrong:
        problems.append(f"not idle form on fresh terms: {'; '.join(wrong)}")
    return purged, problems


def revocation_case(mode, steward, end_clock, sent, found, bound_s, wanted, rows, cases, left=None):
    clock, at = sent
    purged, problems = revocation_verdict(found, at, bound_s, wanted)
    for record in purged:
        interval(mode, rows, "(a) revocation", f"PURGED {record.get('stateClass', '')}/{record.get('stateKey', '')}",
                 steward, (clock, at), (end_clock, record["decidedUnixMicros"]), bound_s * 1_000_000,
                 0 <= record["decidedUnixMicros"] - at <= bound_s * 1_000_000)
    if not purged:
        interval(mode, rows, "(a) revocation", "PURGED", steward, (clock, at), None, bound_s * 1_000_000, False)
    if left:
        problems.append(f"{left} state files left")
    shown, same = machines(mode, clock, end_clock)
    if not same:
        problems.append(f"send and record on {shown}")
    values = [record["decidedUnixMicros"] - at for record in purged]
    observed = "; ".join(problems) or (f"{len(purged)} PURGED for {len(wanted)} state files written, "
                                       f"{min(values) / 1e6:.3f} to {max(values) / 1e6:.3f} s after the send; "
                                       f"{left or 0} state files left; clocks {shown}")
    add(cases, "stay-up", "(a) revocation", steward,
        f"one PURGED record per state file the run wrote, idle form (no job fields) on fresh terms, decided 0 to "
        f"{bound_s} s after the revocation's send from the steward's own VM, no state file left",
        observed, not problems)


def expiry_rows(steward, clock, written, after, retention_s, slack_s):
    expired = [record for record in after if record.get("op") == "expired"]
    kept = {decision: sum(1 for record in expired if record.get("decision") == decision)
            for decision in ("DEFERRED", "CANCELLED")}
    rows = []
    for (state_class, state_key), at in sorted(written.items()):
        deleted = [record for record in expired
                   if record.get("decision") == "DELETED" and e4.key_of(record) == (state_class, state_key)]
        due = at + retention_s * 1_000_000
        row = {"steward": steward, "clock": clock, "state_class": state_class, "state_key": state_key,
               "last_write_us": at, "put_clock": "", "put_us": "", "due_us": due, "deleted_us": "",
               "after_write_us": "", "after_due_us": "", "form": "", "deleted_records": len(deleted),
               "deferred": kept["DEFERRED"], "cancelled": kept["CANCELLED"], "result": "fail"}
        if len(deleted) == 1:
            when = deleted[0]["decidedUnixMicros"]
            row.update(deleted_us=when, after_write_us=when - at, after_due_us=when - due,
                       form="job" if records.job_of(deleted[0]) else "idle",
                       result="pass" if due <= when <= due + slack_s * 1_000_000 else "fail")
        rows.append(row)
    return rows


def expiry_text(row, retention_s, slack_s):
    name = f"{row['state_class']}/{row['state_key']}"
    if row["deleted_us"] == "":
        if row["deleted_records"] == 0:
            return f"{name}: no DELETED record: later than retention + {slack_s} s"
        return f"{name}: {row['deleted_records']} DELETED records, not one"
    after = int(row["after_write_us"]) / 1e6
    if int(row["after_due_us"]) < 0:
        return f"{name}: DELETED {after:.1f} s after its last write: earlier than retention {retention_s} s"
    if int(row["after_due_us"]) > slack_s * 1_000_000:
        return f"{name}: DELETED {after:.1f} s after its last write: later than retention + {slack_s} s"
    return f"{name}: DELETED {after:.1f} s after its last write, {row['form']} form"


def run_expiry(found):
    end, _ = e4.first_run(found)
    written = {}
    for record in e4.run_writes(found):
        if record.get("decision") == "ALLOW":
            written[e4.key_of(record)] = max(written.get(e4.key_of(record), 0), record["decidedUnixMicros"])
    return written, found[end + 1:]


def expiry_case(steward, clock, written, after, retention_s, slack_s, cases, table):
    rows = expiry_rows(steward, clock, written, after, retention_s, slack_s)
    table += rows
    kept = f"; {rows[0]['deferred']} DEFERRED and {rows[0]['cancelled']} CANCELLED kept" if rows else ""
    add(cases, "stay-up", "(b) expiry", steward,
        f"every state file has one DELETED record, either form, from retention {retention_s} s to retention + "
        f"{slack_s} s after its last write ALLOW; DEFERRED and CANCELLED kept",
        ("; ".join(expiry_text(row, retention_s, slack_s) for row in rows) or "no state file written") + kept,
        bool(rows) and all(row["result"] == "pass" for row in rows))


def write_records(out, found):
    write(out / "records.csv", RECORD_COLUMNS,
          [record_row(steward, node, record) for steward, (node, logged) in found.items() for record in logged])


def idle_d(args, out, retention=None):
    mode, cases, rows = args.mode, [], []
    with collect.Unit(mode, out) as unit:
        events = start(mode, out, unit)
        with cluster.service(mode, "api-gateway") as api, cluster.service(mode, "orchestrator") as orchestrator:
            run(mode, api, events, args.rounds)
            held = {steward: idle_up(mode, steward, args.idle_up_bound, rows, cases, "run") for steward in STEWARDS}
            before = {steward: snapshot(mode, out, "before", steward) for steward in STEWARDS}
            begun = reset.micros()
            if retention is not None:
                e4.put_terms(orchestrator, {"server": e4.agreement("server", lambda sd: sd.update(
                    retentionSeconds=retention))}, events, f"p-d: server retention {retention} s inside the window")
            wait = args.nothing_due_polls * POLL_S + 5
            events.add("(d) window", "all", wait * 1_000_000, f"{args.nothing_due_polls} polls of {POLL_S} s plus 5 s")
            time.sleep(max(0, begun + wait * 1_000_000 - reset.micros()) / 1e6)
            ended = reset.micros()
            after = {steward: snapshot(mode, out, "after", steward) for steward in STEWARDS}
            now = {steward: idle_pod(steward, only_claim(steward)["metadata"]["name"]) for steward in STEWARDS}
        found = {steward: claim_records(unit, steward) for steward in STEWARDS}
    write_records(out, found)
    host = f"host@{socket.gethostname()}"
    for steward in STEWARDS:
        (old_audit, old_list), (new_audit, new_list) = before[steward], after[steward]
        added = records.parse(new_audit.decode())[len(records.parse(old_audit.decode())):]
        same = old_audit == new_audit and old_list == new_list
        files = len(state_files(old_list))
        interval(mode, rows, "(d) nothing due", "window", steward, (host, begun), (host, ended), None, same)
        if same:
            observed = f"audit log and {files} state files byte-identical over {seconds(ended - begun)} s"
        elif added:
            observed = (f"a new record: {len(added)} added ("
                        + ", ".join(f"{record.get('op')}/{record.get('decision', '')}" for record in added) + ")")
        else:
            observed = "a state file or the audit log changed, no record added"
        add(cases, "stay-up", "(d) nothing due", steward,
            f"over {args.nothing_due_polls} polls of {POLL_S} s plus 5 s the audit log and every state file unchanged, "
            f"at least one state file (the idle form logs no poll: that the polls took place is not shown)",
            observed, same and files >= 1)
        pod = now[steward][0] if now[steward] else None
        restarts = sum(status.get("restartCount", 0) for status in (pod or {}).get("status", {}).get(
            "containerStatuses") or [])
        kept = (pod is not None and held[steward] is not None
                and pod["metadata"]["uid"] == held[steward][0]["metadata"]["uid"] and restarts == 0)
        add(cases, "stay-up", "(d) the same idle process", steward,
            "the idle pod from before the window still running with its agreement loaded, not restarted",
            f"pod {pod['metadata']['name']} running, {restarts} restarts" if pod is not None
            else "no idle process running with its agreement loaded after the window", kept)
    return conclude(out, cases, rows, "E1 idle (d)")


def idle_c(args, out):
    mode, cases, rows = args.mode, [], []
    with collect.Unit(mode, out) as unit:
        events = start(mode, out, unit)
        with cluster.service(mode, "api-gateway") as api:
            run(mode, api, events, args.rounds)
            for steward in STEWARDS:
                idle_up(mode, steward, args.idle_up_bound, rows, cases, "run 1")
            names = {steward: only_claim(steward)["metadata"]["name"] for steward in STEWARDS}
            before = {steward: snapshot(mode, out, "before", steward) for steward in STEWARDS}
            uids = {steward: job_uid(steward, f"idle-{names[steward]}") for steward in STEWARDS}
            since = reset.micros() - 5_000_000
            run(mode, api, events, args.rounds)
            later = {steward: job_uid(steward, f"idle-{names[steward]}") for steward in STEWARDS}
            began = {steward: gateway_started(steward) for steward in STEWARDS}
            logs = {steward: agent_log(steward, since) for steward in STEWARDS}
            for steward in STEWARDS:
                idle_up(mode, steward, args.idle_up_bound, rows, cases, "run 2")
        found = {steward: claim_records(unit, steward) for steward in STEWARDS}
    write_records(out, found)
    for steward in STEWARDS:
        handover_case(mode, steward, names[steward], before[steward], found[steward], uids[steward], later[steward],
                      began[steward], logs[steward], args.rounds, rows, cases)
    return conclude(out, cases, rows, "E1 idle (c)")


def agent_log(steward, since_us):
    pods = [pod for pod in kjson("-n", steward, "get", "pods", "-l", "type=agent")["items"]
            if not pod["metadata"].get("deletionTimestamp")]
    if not pods:
        raise Failed(f"{steward}: no agent pod")
    pod = max(pods, key=lambda pod: pod["metadata"]["creationTimestamp"])
    return pod["spec"].get("nodeName", ""), kubectl("-n", steward, "logs", pod["metadata"]["name"], "-c", steward,
                                                    "--timestamps", f"--since-time={rfc3339(since_us)}")


def handover_case(mode, steward, claim, before, found, uid, later, began, log, rounds, rows, cases):
    node, logged = found
    agent_node, text = log
    earlier = records.parse(before[0].decode())
    lines = [line for line in text.splitlines() if (hit := HANDED.search(line)) and hit.group(1) == claim]
    replaced = not later or later != uid
    second = logged[len(earlier):]
    prefix = logged[:len(earlier)] == earlier
    first = next((record for record in second if records.job_of(record)), None)
    problems = []
    if len(lines) != 1:
        problems.append(f"{len(lines)} hand-over lines for {claim}, not 1")
    if not replaced:
        problems.append(f"the idle Job from before the run still there when the job decided (uid {uid}): idle process "
                        f"present when the job decided")
    if not prefix:
        problems.append("the audit log from before the run is not a prefix of the one after it")
    if first is None:
        problems.append("no record from the job's enforcement point")
    observed = ""
    if len(lines) == 1:
        handed = checks.cri_us(lines[0])
        took = duration_us(HANDED.search(lines[0]).group(2))
        agent_clock = f"agent@{agent_node}"
        interval(mode, rows, "(c) hand-over", "duration logged by the agent", steward, (agent_clock, handed - took),
                 (agent_clock, handed), None, True)
        if first is not None:
            gateway = f"gateway@{node}" if node else "gateway"
            ok = first["decidedUnixMicros"] >= handed
            same = interval(mode, rows, "(c) hand-over", "hand-over line to the job's first record", steward,
                            (agent_clock, handed), (gateway, first["decidedUnixMicros"]), None, ok)
            if not ok:
                problems.append(f"the job decided {seconds(handed - first['decidedUnixMicros'])} s before the hand-over line")
            if not same:
                problems.append(f"hand-over line and first record on {machines(mode, agent_clock, gateway)[0]}")
            if began is None or began < handed // 1_000_000 * 1_000_000:
                problems.append("the job's enforcement point has no start time, or started before the hand-over line")
            observed = (f"hand-over {took / 1e3:.0f} ms, logged {seconds(first['decidedUnixMicros'] - handed)} s before "
                        f"the job's first record")
    add(cases, "stay-up", "(c) hand-over", steward,
        "one hand-over line from the agent, the idle Job from before the run gone (uid changed) when the job "
        "decides, the job's enforcement point started and decided first after that line",
        "; ".join(problems) or observed, not problems)
    writes = [record for record in second if record.get("op") == "write" and records.job_of(record)]
    allowed = [record for record in writes if record.get("decision") == "ALLOW"]
    add(cases, "stay-up", "(c) every round persists", steward, f"{rounds} write ALLOW records by run 2's job, nothing else",
        f"{len(writes)} write records, {len(allowed)} ALLOW", len(allowed) == len(writes) == rounds)
    if steward == "server":
        last = {}
        for record in earlier:
            if record.get("op") == "write" and record.get("decision") == "ALLOW":
                last[e4.key_of(record)] = record.get("writtenUnixSeconds")
        read = next((record for record in second if record.get("op") == "read"), {})
        add(cases, "stay-up", "(c) state read back", steward,
            "run 2's first read ALLOW, its written time that of run 1's last write of the same state",
            f"{read.get('decision', 'no read')} {e4.key_of(read)}, written {read.get('writtenUnixSeconds')}, "
            f"run 1's last write {last.get(e4.key_of(read))}",
            read.get("decision") == "ALLOW" and read.get("writtenUnixSeconds") is not None
            and read.get("writtenUnixSeconds") == last.get(e4.key_of(read)))


def revoke(mode, orchestrator, steward, events):
    body = e4.agreement(steward, lambda sd: sd.update(allowed=False))
    code, at, clock = reset.put_stamped(mode, steward, f"{orchestrator}/api/v1/policyEnforcer", json.dumps(body))
    events.add("(a) revocation sent", steward, 0, f"http {code}; sent from {steward}'s VM, time is the send there",
               at=at, clock=clock)
    if code != 200:
        raise Failed(f"(a) revocation for {steward}: http {code}")
    return clock, at


def idle_a(args, out):
    mode, cases, rows = args.mode, [], []
    with collect.Unit(mode, out) as unit:
        events = start(mode, out, unit)
        with cluster.service(mode, "api-gateway") as api, cluster.service(mode, "orchestrator") as orchestrator:
            run(mode, api, events, args.rounds)
            for steward in STEWARDS:
                idle_up(mode, steward, args.idle_up_bound, rows, cases, "run")
            sent = {steward: revoke(mode, orchestrator, steward, events) for steward in STEWARDS}
            done = {steward: complete(steward, only_claim(steward)["metadata"]["name"],
                                      args.revocation_bound + REVOKED_MARGIN_S + 50) for steward in STEWARDS}
        found = {steward: claim_records(unit, steward) for steward in STEWARDS}
    write_records(out, found)
    for steward in STEWARDS:
        node, logged = found[steward]
        listing = (out / "raw" / "claims" / steward / only_claim_name(out, steward) / "files.sha256").read_text()
        revocation_case(mode, steward, f"gateway@{node}" if node else "gateway", sent[steward], logged,
                        args.revocation_bound, written_keys(logged), rows, cases, left=len(state_files(listing)))
        add(cases, "stay-up", "(a) idle process ended", steward, "the idle Job complete after the purge (exit 0)",
            "complete" if done[steward] else "not complete", done[steward])
    return conclude(out, cases, rows, "E1 idle (a)")


def only_claim_name(out, steward):
    folders = [path.name for path in (out / "raw" / "claims" / steward).iterdir() if path.is_dir()]
    if len(folders) != 1:
        raise Failed(f"{steward}: {len(folders)} audited claims, not 1")
    return folders[0]


def idle_b(args, out):
    mode, cases, rows, table = args.mode, [], [], []
    with collect.Unit(mode, out) as unit:
        events = start(mode, out, unit)
        with cluster.service(mode, "api-gateway") as api, cluster.service(mode, "orchestrator") as orchestrator:
            e4.put_terms(orchestrator, {steward: e4.agreement(steward, lambda sd: sd.update(
                retentionSeconds=args.retention)) for steward in STEWARDS}, events, f"seed: retention {args.retention} s")
            run(mode, api, events, args.rounds)
            for steward in STEWARDS:
                idle_up(mode, steward, args.idle_up_bound, rows, cases, "run")
            wait = args.retention + args.expiry_slack + EXPIRY_MARGIN_S
            done = {steward: complete(steward, only_claim(steward)["metadata"]["name"], wait) for steward in STEWARDS}
        found = {steward: claim_records(unit, steward) for steward in STEWARDS}
    write_records(out, found)
    for steward in STEWARDS:
        node, logged = found[steward]
        written, after = run_expiry(logged)
        expiry_case(steward, f"gateway@{node}" if node else "gateway", written, after, args.retention,
                    args.expiry_slack, cases, table)
        jobs = [record for record in after if records.job_of(record) and record.get("op") != "shutdown"]
        add(cases, "stay-up", "(b) no job in the window", steward, "no record by a job after the run's shutdown record",
            f"{len(jobs)} job records after it", not jobs)
        listing = (out / "raw" / "claims" / steward / only_claim_name(out, steward) / "files.sha256").read_text()
        left = len(state_files(listing))
        add(cases, "stay-up", "(b) idle process ended", steward, "no state file left and the idle Job complete",
            f"{left} state files left, idle Job {'complete' if done[steward] else 'not complete'}",
            left == 0 and done[steward])
    return conclude(out, cases, rows, "E1 idle (b)", expiry=table)


def expiry_check(args, out):
    cases, table = [], []
    found = records.parse((pathlib.Path(args.fixture) / "audit.log").read_text())
    written, after = run_expiry(found)
    expiry_case("fixture", "gateway", written, after, args.retention, args.expiry_slack, cases, table)
    return conclude(out, cases, None, "E1 expiry check", expiry=table)


def shifted(found, op, decision, seconds_):
    return [dict(record, decidedUnixMicros=record["decidedUnixMicros"] + round(seconds_ * 1_000_000))
            if record.get("op") == op and record.get("decision") == decision else record for record in found]


def windows(args, out):
    folder, cases, table = pathlib.Path(args.fixture), [], []
    expiring = records.parse((folder / "e1-expiry" / "audit.log").read_text())
    for name, move, wanted in (("as recorded", 0, "pass"), ("deleted 14 s later", 14, "pass"),
                               ("deleted 36 s later", 36, "fail"), ("deleted 21 s earlier", -21, "fail")):
        written, after = run_expiry(shifted(expiring, "expired", "DELETED", move))
        rows = expiry_rows("fixture", "gateway", written, after, args.retention, args.expiry_slack)
        got = "pass" if rows and all(row["result"] == "pass" for row in rows) else "fail"
        table += rows
        add(cases, "check", f"(b) window, {name}", "fixture", wanted,
            f"{got}: " + "; ".join(expiry_text(row, args.retention, args.expiry_slack) for row in rows), got == wanted)
    revoked = records.parse((folder / "e1-revocation" / "audit.log").read_text())
    at = int((folder / "e1-revocation" / "sent_us").read_text())
    wanted_keys = written_keys(revoked)
    purge = next(record for record in revoked if record.get("decision") == "PURGED")
    for name, found, wanted in (
            ("as recorded", revoked, "pass"),
            ("purged 4.9 s later", shifted(revoked, "purge", "PURGED", 4.9), "pass"),
            ("purged 5 s later", shifted(revoked, "purge", "PURGED", 5), "fail"),
            ("purged twice", revoked + [purge], "fail"),
            ("purged by a job", [dict(record, identity={**record["identity"], "jobId": "a-job"})
                                 if record is purge else record for record in revoked], "fail"),
            ("not purged", [record for record in revoked if record is not purge], "fail")):
        _, problems = revocation_verdict(found, at, args.revocation_bound, wanted_keys)
        got = "fail" if problems else "pass"
        add(cases, "check", f"(a) bound, {name}", "fixture", wanted, f"{got}: {'; '.join(problems) or 'within'}",
            got == wanted)
    for value_s, wanted in ((0, "pass"), (args.idle_up_bound, "pass"), (args.idle_up_bound + 1, "fail"), (-1, "fail")):
        got = "pass" if up_within(value_s * 1_000_000, args.idle_up_bound) else "fail"
        add(cases, "check", f"idle up bound, {value_s} s", "fixture", wanted, got, got == wanted)
    return conclude(out, cases, None, "E1 windows", expiry=table)


def standalone(mode, steward, watch, events):
    env = [{"name": "DATA_STEWARD_NAME", "value": steward.upper()}, {"name": "REQUEST_USER", "value": cluster.USER},
           {"name": "REQUEST_TYPE", "value": cluster.REQUEST_TYPE}, {"name": "GATEWAY_IDLE", "value": "true"},
           {"name": "STATE_DIR", "value": "/state"},
           {"name": "AGREEMENT_POLL_INTERVAL_SECONDS", "value": str(STANDALONE_POLL_S)}]
    if not watch:
        env.append({"name": "AGREEMENT_WATCH_DISABLED", "value": "true"})
    mount = [{"name": "state", "mountPath": "/state"}]
    spec = {
        "restartPolicy": "Never",
        "initContainers": [{"name": "plant", "image": cluster.image(mode, "vfl-train-demo"),
                            "imagePullPolicy": "IfNotPresent", "command": ["python3", "-c", PLANTING],
                            "volumeMounts": mount}],
        "containers": [{"name": checks.GATEWAY, "image": cluster.image(mode, checks.GATEWAY),
                        "imagePullPolicy": "IfNotPresent", "command": [f"/app/{checks.GATEWAY}"], "env": env,
                        "volumeMounts": mount}],
        "volumes": [{"name": "state", "emptyDir": {}}],
    }
    if mode == "fabric":
        spec["nodeSelector"] = {"kubernetes.io/hostname": steward}
    manifest = {"apiVersion": "v1", "kind": "Pod", "metadata": {"name": checks.STANDALONE, "namespace": steward},
                "spec": spec}
    kubectl("apply", "-f", "-", stdin=json.dumps(manifest))
    cluster.until(f"pod/{checks.STANDALONE} running with its agreement loaded", 180, lambda: kjson(
        "-n", steward, "get", "pod", checks.STANDALONE)["status"].get("phase") == "Running" and "Agreement loaded" in
        kubectl("-n", steward, "logs", checks.STANDALONE, "-c", checks.GATEWAY))
    planted = next((int(line.split()[1]) for line in kubectl("-n", steward, "logs", checks.STANDALONE, "-c", "plant")
                    .splitlines() if line.startswith("planted ")), None)
    if planted is None:
        raise Failed(f"pod/{checks.STANDALONE}: the planted state file's time was not logged")
    node = kjson("-n", steward, "get", "pod", checks.STANDALONE)["spec"].get("nodeName", "")
    events.add("standalone gateway up", steward, 0,
               f"pod/{checks.STANDALONE}, idle form, watch {'on' if watch else 'off'}, poll {STANDALONE_POLL_S} s, "
               f"{PROBE[0]}/{PROBE[1]} planted at {planted} on {node}")
    return node, planted


def standalone_records(steward):
    return records.parse(kubectl("-n", steward, "logs", checks.STANDALONE, "-c", checks.GATEWAY))


def drop_standalone(steward):
    try:
        kubectl("-n", steward, "delete", "pod", checks.STANDALONE, "--ignore-not-found=true", "--grace-period=1",
                "--wait=true", "--timeout=90s", timeout=120)
    except Failed as error:
        print(f"{checks.STANDALONE} not deleted, the next clean start will refuse it: {error}", flush=True)


def p_a(args, out):
    mode, steward, cases, rows = args.mode, "server", [], []
    try:
        with collect.Unit(mode, out) as unit:
            events = start(mode, out, unit)
            with cluster.service(mode, "orchestrator") as orchestrator:
                node, _ = standalone(mode, steward, False, events)
                sent = revoke(mode, orchestrator, steward, events)
                time.sleep(args.revocation_bound + REVOKED_MARGIN_S)
                found = standalone_records(steward)
            revocation_case(mode, steward, f"gateway@{node}", sent, found, args.revocation_bound, [PROBE], rows, cases)
    finally:
        drop_standalone(steward)
    return conclude(out, cases, rows, "E1 p-a")


def p_b_upper(args, out):
    mode, steward, cases, table = args.mode, "server", [], []
    try:
        with collect.Unit(mode, out) as unit:
            events = start(mode, out, unit)
            with cluster.service(mode, "orchestrator") as orchestrator:
                e4.put_terms(orchestrator, {steward: e4.agreement(steward, lambda sd: sd.update(
                    retentionSeconds=args.retention))}, events, f"p-b-upper: retention {args.retention} s")
            node, planted = standalone(mode, steward, True, events)
            wait = planted + (args.retention + args.expiry_slack + REVOKED_MARGIN_S) * 1_000_000 - reset.micros()
            events.add("p-b-upper: wait", steward, max(0, wait), "until retention + slack + 10 s after the planted write")
            time.sleep(max(0, wait) / 1e6)
            found = standalone_records(steward)
            expiry_case(steward, f"gateway@{node}", {PROBE: planted}, found, args.retention, args.expiry_slack, cases,
                        table)
    finally:
        drop_standalone(steward)
    return conclude(out, cases, None, "E1 p-b-upper", expiry=table)


def planted_job(mode, steward, claim, command, restart, extra):
    stamp = claim["metadata"]["annotations"]
    name = claim["metadata"]["name"]
    env = [{"name": "DATA_STEWARD_NAME", "value": stamp["dynamos/data-steward"]},
           {"name": "REQUEST_USER", "value": stamp["dynamos/request-user"]},
           {"name": "REQUEST_TYPE", "value": stamp["dynamos/request-type"]},
           {"name": "GATEWAY_IDLE", "value": "true"}, {"name": "STATE_DIR", "value": "/state"}]
    template = {"metadata": {"labels": {"dynamos/gateway": "idle"}},
                "spec": {"restartPolicy": restart, "terminationGracePeriodSeconds": 10,
                         "containers": [{"name": checks.GATEWAY, "image": cluster.image(mode, checks.GATEWAY),
                                         "imagePullPolicy": "IfNotPresent", "command": command, "env": env,
                                         "volumeMounts": [{"name": "state", "mountPath": "/state"}]}],
                         "volumes": [{"name": "state", "persistentVolumeClaim": {"claimName": name}}], **extra}}
    manifest = {"apiVersion": "batch/v1", "kind": "Job",
                "metadata": {"name": f"idle-{name}", "namespace": steward, "labels": {"dynamos/gateway": "idle"}},
                "spec": {"backoffLimit": 0, "template": template}}
    for _ in range(3):
        kubectl("-n", steward, "delete", "job", f"idle-{name}", "--cascade=foreground", "--ignore-not-found=true",
                "--wait=true", "--timeout=60s", timeout=90)
        try:
            kubectl("create", "-f", "-", stdin=json.dumps(manifest))
        except cluster.Void:
            raise
        except Failed:
            continue
        return job_uid(steward, f"idle-{name}")
    raise Failed(f"could not plant job/idle-{name} in three tries: the agent put its own back first")


def composite(error, marker, wanted, cases):
    text = str(error)
    names = text.split(" hit:", 1)[0].split()[1:] if text.startswith("markers ") else []
    seen = [case for case in cases if case["result"] == "fail" and wanted in case["observed"]]
    if names == [marker] and seen:
        return f"{seen[0]['observed'].split(':')[0] if wanted.startswith('idle up') else wanted} and {text}"
    return None


def p_up(args, out):
    mode, steward, cases, rows = args.mode, "server", [], []
    try:
        with collect.Unit(mode, out) as unit:
            events = start(mode, out, unit)
            with cluster.service(mode, "api-gateway") as api:
                run(mode, api, events, args.rounds)
                claim = only_claim(steward)
                planted = planted_job(mode, steward, claim, [f"/app/{checks.GATEWAY}"], "OnFailure",
                                      {"nodeSelector": {NO_NODE: "true"}})
                created = reset.micros()
                events.add("p-up: idle Job planted with a node selector no node carries", steward, 0,
                           f"job/idle-{claim['metadata']['name']} uid {planted}")
                idle_up(mode, steward, args.idle_up_bound, rows, cases, "run")
                name = claim["metadata"]["name"]
                deadline = created + (120 + 3 * POLL_S + 15) * 1_000_000
                while reset.micros() < deadline:
                    uid = job_uid(steward, f"idle-{name}")
                    if uid and uid != planted and idle_pod(steward, name):
                        break
                    time.sleep(2)
                events.add("p-up: the agent's own idle Job", steward, 0,
                           f"uid {job_uid(steward, f'idle-{name}') or 'none'}, planted {planted}")
    except cluster.Void:
        raise
    except Failed as error:
        write(out / "cases.csv", CASE_COLUMNS, cases)
        write(out / "idle.csv", IDLE_COLUMNS, rows)
        found = composite(error, "M3", "idle up not within", cases)
        if found:
            print(found, file=sys.stderr)
            return 1
        raise
    write(out / "cases.csv", CASE_COLUMNS, cases)
    write(out / "idle.csv", IDLE_COLUMNS, rows)
    print("p-up: no M3 marker, or the idle process came up in time", file=sys.stderr)
    return 2


def agent_refused(steward, name):
    user = f"system:serviceaccount:{steward}:job-creator-{steward}"
    try:
        kubectl("-n", steward, "delete", "job", name, f"--as={user}", "--dry-run=server")
    except cluster.Void:
        raise
    except Failed as error:
        return POLICY in str(error)
    return False


def keep_idle_jobs(steward):
    user = f"system:serviceaccount:{steward}:job-creator-{steward}"
    policy = {"apiVersion": "admissionregistration.k8s.io/v1", "kind": "ValidatingAdmissionPolicy",
              "metadata": {"name": POLICY},
              "spec": {"failurePolicy": "Fail",
                       "matchConstraints": {"resourceRules": [{"apiGroups": ["batch"], "apiVersions": ["v1"],
                                                               "operations": ["DELETE"], "resources": ["jobs"]}]},
                       "validations": [{"expression": f"!(oldObject.metadata.name.startsWith('idle-') && "
                                                      f"request.userInfo.username == '{user}')",
                                        "message": f"{POLICY}: the harness keeps idle Jobs from the agent"}]}}
    binding = {"apiVersion": "admissionregistration.k8s.io/v1", "kind": "ValidatingAdmissionPolicyBinding",
               "metadata": {"name": POLICY},
               "spec": {"policyName": POLICY, "validationActions": ["Deny"],
                        "matchResources": {"namespaceSelector": {"matchLabels": {
                            "kubernetes.io/metadata.name": steward}}}}}
    kubectl("apply", "-f", "-", stdin=json.dumps({"apiVersion": "v1", "kind": "List", "items": [policy, binding]}))


def drop_policy():
    for kind in ("validatingadmissionpolicybinding", "validatingadmissionpolicy"):
        kubectl("delete", kind, POLICY, "--ignore-not-found=true")


def p_c(args, out):
    mode, steward, cases, rows = args.mode, "server", [], []
    if mode != "kind":
        raise Failed("p-c changes the cluster's admission policies and runs on kind only")
    try:
        with collect.Unit(mode, out) as unit:
            events = start(mode, out, unit)
            with cluster.service(mode, "api-gateway") as api:
                run(mode, api, events, args.rounds)
                idle_up(mode, steward, args.idle_up_bound, rows, cases, "run 1")
                claim = only_claim(steward)
                name = claim["metadata"]["name"]
                before = snapshot(mode, out, "before", steward)
                keep_idle_jobs(steward)
                cluster.until(f"the agent refused the deletion of idle-{name}", 30,
                              lambda: agent_refused(steward, f"idle-{name}"), every=1)
                uid = planted_job(mode, steward, claim, ["/bin/true"], "Never", {})
                kubectl("-n", steward, "wait", "--for=condition=complete", f"job/idle-{name}", "--timeout=60s", timeout=90)
                events.add("p-c: the agent may not delete idle Jobs; the idle Job replaced by one that exits 0", steward,
                           0, f"job/idle-{name} uid {uid}")
                since = reset.micros() - 5_000_000
                run(mode, api, events, args.rounds)
                later = job_uid(steward, f"idle-{name}")
                began = gateway_started(steward)
                log = agent_log(steward, since)
                drop_policy()
            found = claim_records(unit, steward)
            handover_case(mode, steward, name, before, found, uid, later, began, log, args.rounds, rows, cases)
    except cluster.Void:
        raise
    except Failed as error:
        write(out / "cases.csv", CASE_COLUMNS, cases)
        write(out / "idle.csv", IDLE_COLUMNS, rows)
        found = composite(error, "M2", "idle process present when the job decided", cases)
        if found:
            print(found, file=sys.stderr)
            return 1
        raise
    finally:
        drop_policy()
    write(out / "cases.csv", CASE_COLUMNS, cases)
    write(out / "idle.csv", IDLE_COLUMNS, rows)
    print("p-c: no M2 marker, or the idle Job was replaced", file=sys.stderr)
    return 2


INVALID = "invalid stateDirectives; fail closed"
REVOKED = "allowed = false"
TERMS = (
    ("W1", "R1", "allowed false", lambda relation: relation["stateDirectives"].update(allowed=False), REVOKED, "DENY"),
    ("W1", "R1", "no state directives", lambda relation: relation.pop("stateDirectives"), "stateDirectives absent",
     "DENY"),
    ("W1", "R1", "unknown onRevocation", lambda relation: relation["stateDirectives"].update(onRevocation="shred"),
     INVALID, "DENY"),
    ("W1", "R1", "negative retention", lambda relation: relation["stateDirectives"].update(retentionSeconds=-1),
     INVALID, "DENY"),
    ("W4", "R2", "resume disabled", lambda relation: relation["stateDirectives"].update(resumeAllowed=False),
     "resume disabled", "ALLOW"),
)
COMPLETENESS_COLUMNS = ("steward", "claim", "state_files", "write_allow", "unaudited", "result")
STATE_PATH = re.compile(r"\./data/([^/]+)/([^/]+)\.bin")
WRITING_S = {"kind": 300, "fabric": 600}
SETTLE_REVOKED_S = POLL_S + 5


def relation_terms(steward, change):
    body = json.loads(reset.seed_file(steward).read_text())
    change(body["relations"][cluster.USER])
    return body


def job_runs(found):
    runs, ended = [], True
    for record in found:
        if not records.job_of(record):
            continue
        if ended and record.get("op") != "shutdown":
            runs.append([])
        if runs:
            runs[-1].append(record)
        ended = record.get("op") == "shutdown"
    return runs


def ops(found, op):
    return [record for record in found if record.get("op") == op]


def destructions(found):
    return [record for record in found
            if (record.get("op"), record.get("decision")) in (("purge", "PURGED"), ("expired", "DELETED"))]


def listing_of(out, steward):
    return (out / "raw" / "claims" / steward / only_claim_name(out, steward) / "files.sha256").read_text()


def state_keys(listing):
    found, other = [], []
    for line in state_files(listing):
        path = line.split(None, 1)[-1]
        hit = STATE_PATH.fullmatch(path)
        if hit:
            found.append((hit.group(1), hit.group(2)))
        else:
            other.append(path)
    return found, other


def completeness(out, steward, logged, cases, table):
    files, other = state_keys(listing_of(out, steward))
    granted = [record for record in ops(logged, "write") if record.get("decision") == "ALLOW"]
    allowed = {e4.key_of(record) for record in granted}
    unaudited = [f"{state_class}/{key}" for state_class, key in files if (state_class, key) not in allowed] + other
    empty = (not files and not other) or not allowed
    ok = not empty and not unaudited
    table.append({"steward": steward, "claim": only_claim_name(out, steward), "state_files": len(files) + len(other),
                  "write_allow": len(granted), "unaudited": " ".join(unaudited),
                  "result": "pass" if ok else "fail"})
    if empty:
        observed = (f"completeness on an empty claim: {len(files) + len(other)} state files, {len(allowed)} state "
                    f"keys with a write ALLOW record")
    elif unaudited:
        observed = f"{len(unaudited)} state files without a write ALLOW record: {' '.join(unaudited)}"
    else:
        observed = f"{len(files)} state files, each with a write ALLOW record"
    add(cases, "completeness", "every state file has a write ALLOW record", steward,
        "at least one state file and one write ALLOW record; every state file data/<class>/<key>.bin with a write "
        "ALLOW record of its class and key", observed, ok)
    return ok


def decisions(found, verdict, reason, relation):
    if not found:
        return False, "none"
    wrong = [f"{record.get('decision', '')} {record.get('reason', '')!r} on {record.get('relationId', '')}"
             for record in found if record.get("decision") != verdict or record.get("relationId") != relation
             or (reason is not None and record.get("reason") != reason)]
    return not wrong, f"{len(found)}, {len(wrong)} otherwise" + (f": {wrong[0]}" if wrong else "")


def terms(args, out):
    mode, cases = args.mode, []
    with collect.Unit(mode, out) as unit:
        events = start(mode, out, unit)
        with cluster.service(mode, "api-gateway") as api, cluster.service(mode, "orchestrator") as orchestrator:
            for _, _, name, change, _, _ in TERMS:
                e4.put_terms(orchestrator, {steward: relation_terms(steward, change) for steward in STEWARDS}, events,
                             f"terms: {name}")
                run(mode, api, events, args.rounds)
        found = {steward: claim_records(unit, steward) for steward in STEWARDS}
    write_records(out, found)
    for steward in STEWARDS:
        relation = seeded_relation(steward)
        runs = job_runs(found[steward][1])
        add(cases, "runs", "one run per set of terms", steward, f"{len(TERMS)} runs of job records", f"{len(runs)}",
            len(runs) == len(TERMS))
        if len(runs) != len(TERMS):
            continue
        for (write_row, read_row, name, _, reason, verdict), logged in zip(TERMS, runs):
            denied = verdict == "DENY"
            ok, seen = decisions(ops(logged, "write"), verdict, reason if denied else None, relation)
            if not denied:
                ok = ok and all(allowed_write(record, relation) for record in ops(logged, "write"))
            add(cases, write_row, f"write, {name}", steward,
                f"every write record {verdict}" + (f" with reason {reason!r}" if denied else " on allowed terms")
                + f" on relation {relation}, at least one", f"write records: {seen}", ok)
            ok, seen = decisions(ops(logged, "read"), "DENY", reason, relation)
            add(cases, read_row, f"read, {name}", steward,
                f"every read record DENY with reason {reason!r} on relation {relation}, at least one",
                f"read records: {seen}", ok)
            if reason == INVALID:
                invalid = ops(logged, "invalid_directives")
                add(cases, write_row, f"invalid directives recorded, {name}", steward,
                    "at least one invalid_directives record by the job's enforcement point",
                    f"{len(invalid)}: {invalid[0].get('reason', '') if invalid else ''}", bool(invalid))
            destroyed = destructions(logged)
            add(cases, write_row, f"nothing destroyed, {name}", steward, "no PURGED or DELETED record in the run",
                f"{len(destroyed)}", not destroyed)
    return conclude(out, cases, None, "E1 terms")


def last_writes(logged):
    last = {}
    for record in ops(logged, "write"):
        if record.get("decision") == "ALLOW":
            last[e4.key_of(record)] = record.get("writtenUnixSeconds")
    return last


def r3(args, out):
    mode, cases, table = args.mode, [], []
    with collect.Unit(mode, out) as unit:
        events = start(mode, out, unit)
        with cluster.service(mode, "api-gateway") as api:
            run(mode, api, events, args.rounds)
            run(mode, api, events, args.rounds)
        found = {steward: claim_records(unit, steward) for steward in STEWARDS}
    write_records(out, found)
    for steward in STEWARDS:
        relation = seeded_relation(steward)
        runs = job_runs(found[steward][1])
        add(cases, "runs", "two runs", steward, "2 runs of job records", f"{len(runs)}", len(runs) == 2)
        if len(runs) == 2:
            first = ops(runs[0], "read")
            ok, seen = decisions(first, "DENY", "not found", relation)
            add(cases, "outside", "read of an absent object", steward,
                "run 1's read records DENY 'not found' on the seeded relation, at least one", f"read records: {seen}", ok)
            last = last_writes(runs[0])
            read = next(iter(ops(runs[1], "read")), {})
            add(cases, "R3", "read within retention", steward,
                "run 2's first read ALLOW on the seeded relation, its written time that of run 1's last write of the "
                "same state",
                f"{read.get('decision', 'no read')} {e4.key_of(read)} on {read.get('relationId', '')}, written "
                f"{read.get('writtenUnixSeconds')}, run 1's last write {last.get(e4.key_of(read))}",
                read.get("decision") == "ALLOW" and read.get("relationId") == relation
                and read.get("writtenUnixSeconds") is not None
                and read.get("writtenUnixSeconds") == last.get(e4.key_of(read)))
        completeness(out, steward, found[steward][1], cases, table)
    write(out / "completeness.csv", COMPLETENESS_COLUMNS, table)
    return conclude(out, cases, None, "E1 R3")


def serving_pod(steward, service=None):
    for pod in reset.chain_pods(steward):
        if pod["metadata"].get("deletionTimestamp") or pod["status"].get("phase") != "Running":
            continue
        running = {status["name"] for status in pod["status"].get("containerStatuses") or []
                   if "running" in status.get("state", {})}
        if checks.GATEWAY in running and (service is None or service in running):
            return pod["metadata"]["name"]
    return None


def chain_log(steward, pod):
    try:
        return records.parse(kubectl("-n", steward, "logs", pod, "-c", checks.GATEWAY, timeout=120))
    except cluster.Void:
        raise
    except Failed:
        return []


def writing(steward):
    pod = serving_pod(steward)
    if pod and any(record.get("decision") == "ALLOW" and records.job_of(record) for record in ops(chain_log(steward, pod),
                                                                                               "write")):
        return pod
    return None


def finish(api, request, mode, events, what):
    try:
        reset.wait_done(api, request, RUN_DEADLINE_S[mode])
        events.add("run done", "api-gateway", 0, f"request {request}")
    except cluster.Void:
        raise
    except Failed as error:
        events.add(f"{what}: the run did not finish", "api-gateway", 0, str(error)[:300])


def revoke_all(orchestrator, events, what, keep=False):
    change = (lambda sd: sd.update(allowed=False, onRevocation="")) if keep else (lambda sd: sd.update(allowed=False))
    e4.put_terms(orchestrator, {steward: e4.agreement(steward, change) for steward in STEWARDS}, events, what)


def d1_job(args, out):
    mode, cases = args.mode, []
    with collect.Unit(mode, out) as unit:
        events = start(mode, out, unit)
        with cluster.service(mode, "api-gateway") as api, cluster.service(mode, "orchestrator") as orchestrator:
            request = reset.trigger(api, args.rounds, events)
            pods = {steward: cluster.until(f"{steward}: a write ALLOW by the job's enforcement point", WRITING_S[mode],
                                           lambda steward=steward: writing(steward), every=2) for steward in STEWARDS}
            events.add("d1: every steward's job has written", "all", 0, " ".join(pods.values()))
            revoke_all(orchestrator, events, "d1: revocation with purge during the job")
            standing = {steward: serving_pod(steward) for steward in STEWARDS}
            finish(api, request, mode, events, "d1")
        found = {steward: claim_records(unit, steward) for steward in STEWARDS}
    write_records(out, found)
    for steward in STEWARDS:
        logged = found[steward][1]
        purged = [record for record in logged if record.get("op") == "purge" and record.get("decision") == "PURGED"]
        first = min((record["decidedUnixMicros"] for record in purged), default=None)
        written = sorted({e4.key_of(record) for record in ops(logged, "write") if record.get("decision") == "ALLOW"
                          and (first is None or record["decidedUnixMicros"] < first)})
        wrong = [f"{record.get('stateClass', '')}/{record.get('stateKey', '')} {record.get('policySource', '')}"
                 + ("" if records.job_of(record) else " without job fields") for record in purged
                 if not records.job_of(record) or record.get("policySource") != "fresh"]
        keys = sorted(e4.key_of(record) for record in purged)
        add(cases, "D1", "job form: one PURGED per state file", steward,
            "one purge PURGED record per state file the job wrote, each with job fields and on fresh terms, while "
            "the job's enforcement point was still serving",
            f"{len(purged)} PURGED for {len(written)} state files written"
            + (f"; not job form on fresh terms: {'; '.join(wrong)}" if wrong else "")
            + ("" if standing[steward] else "; the job's enforcement point no longer serving after the revocation"),
            bool(purged) and keys == written and not wrong and standing[steward] is not None)
        later = [record for record in ops(logged, "write") if first is not None
                 and record["decidedUnixMicros"] > first and record.get("decision") == "ALLOW"]
        add(cases, "D1", "no write allowed after the purge", steward, "no write ALLOW record after the first PURGED",
            f"{len(later)}", first is not None and not later)
        files, other = state_keys(listing_of(out, steward))
        add(cases, "D1", "no state left", steward, "no state file on the claim at the unit's end",
            f"{len(files) + len(other)} state files", not files and not other)
    return conclude(out, cases, None, "E1 D1 job form")


def d6(args, out):
    mode, cases = args.mode, []
    with collect.Unit(mode, out) as unit:
        events = start(mode, out, unit)
        with cluster.service(mode, "api-gateway") as api, cluster.service(mode, "orchestrator") as orchestrator:
            run(mode, api, events, args.rounds)
            revoke_all(orchestrator, events, "d6: revocation without purge", keep=True)
            events.add("d6: settle", "all", SETTLE_REVOKED_S * 1_000_000, "one poll and 5 s for either form to act")
            time.sleep(SETTLE_REVOKED_S)
            kept = {steward: snapshot(mode, out, "revoked", steward)[1] for steward in STEWARDS}
            run(mode, api, events, args.rounds)
        found = {steward: claim_records(unit, steward) for steward in STEWARDS}
    write_records(out, found)
    for steward in STEWARDS:
        relation = seeded_relation(steward)
        logged = found[steward][1]
        runs = job_runs(logged)
        add(cases, "runs", "two runs", steward, "2 runs of job records", f"{len(runs)}", len(runs) == 2)
        if len(runs) == 2:
            for op in ("write", "read"):
                ok, seen = decisions(ops(runs[1], op), "DENY", REVOKED, relation)
                add(cases, "D6", f"{op} denied", steward,
                    f"every {op} record of run 2 DENY with reason {REVOKED!r} on relation {relation}, at least one",
                    f"{op} records: {seen}", ok)
        destroyed = destructions(logged)
        add(cases, "D6", "nothing destroyed", steward, "no PURGED or DELETED record in the unit",
            f"{len(destroyed)}", not destroyed)
        before, after = state_files(kept[steward]), state_files(listing_of(out, steward))
        add(cases, "D6", "state kept", steward,
            "the state files after the revocation, at least one, byte-identical at the unit's end",
            f"{len(before)} state files after the revocation, {len(after)} at the end, "
            f"{'identical' if before == after else 'changed'}", bool(before) and before == after)
    return conclude(out, cases, None, "E1 D6")


SERVICE = "vfl-train-model-demo"
ADVERSARIAL = "adversarial"
BATTERY = """import concurrent.futures, json, os, sys, time
import grpc
import policyCheckpointGateway_pb2 as pb
import policyCheckpointGateway_pb2_grpc as pbg
channel = grpc.insecure_channel("localhost:%s" % os.environ["GATEWAY_PORT"])
grpc.channel_ready_future(channel).result(timeout=20)
stub = pbg.PolicyCheckpointGatewayStub(channel)
fields = dict(steward=os.environ["DATA_STEWARD_NAME"], user=os.environ["REQUEST_USER"],
              request_type=os.environ["REQUEST_TYPE"], job_id=os.environ["JOB_NAME"],
              local_job_name=os.environ["LOCAL_JOB_NAME"])
sent = []
def write(identity, key, label):
    began = time.time_ns() // 1000
    try:
        answer = stub.RequestStateWrite(pb.StateWriteRequest(identity=identity, state_class=sys.argv[1], state_key=key,
                                                             payload=b"\\x01\\x02\\x03"), timeout=10)
        said = "ALLOW" if answer.allowed else "DENY"
    except grpc.RpcError as error:
        said = str(error.code().name)
    sent.append({"identity": label, "key": key, "sent_us": began, "returned_us": time.time_ns() // 1000,
                 "answer": said})
    return said
out = {"tampered": write(pb.Identity(**dict(fields, steward="TAMPERED")), "mismatch-probe", "tampered")}
with concurrent.futures.ThreadPoolExecutor(int(sys.argv[2])) as pool:
    out["concurrent"] = list(pool.map(lambda _: write(pb.Identity(**fields), "concurrent-slot", "own"),
                                      range(int(sys.argv[2]))))
out["operations"] = sent
print(json.dumps(out), flush=True)
"""
OPERATION_COLUMNS = ("steward", "clock", "sent_us", "returned_us", "operation", "identity", "state_class", "state_key",
                     "expected_op", "expected_decision", "answer", "records", "result")
EXPECTED_RECORD = {"tampered": ("identity_mismatch", ""), "own": ("write", "ALLOW")}
SENT_EVENT = "adversarial: tampered identity and concurrent writes sent"
NO_OPERATION_ROW = "operations sent and no operations.csv row"


def operation_rows(steward, node, sent):
    rows = []
    for operation in sent:
        op, decision = EXPECTED_RECORD[operation["identity"]]
        rows.append({"steward": steward, "clock": f"sender@{node}" if node else "sender",
                     "sent_us": operation["sent_us"], "returned_us": operation["returned_us"], "operation": "write",
                     "identity": operation["identity"], "state_class": ADVERSARIAL, "state_key": operation["key"],
                     "expected_op": op, "expected_decision": decision, "answer": operation["answer"],
                     "records": "", "result": ""})
    return rows


def matching(operation, record):
    return (record["steward"] == operation["steward"] and record["op"] == operation["expected_op"]
            and record["decision"] == operation["expected_decision"]
            and (operation["expected_op"] != "write" or (record["state_class"], record["state_key"])
                 == (operation["state_class"], operation["state_key"])))


def judge_operations(operations, logged, sent):
    if sent and not operations:
        return [NO_OPERATION_ROW]
    problems = []
    groups = {}
    for operation in operations:
        groups.setdefault((operation["steward"], operation["expected_op"], operation["expected_decision"],
                           operation["state_class"], operation["state_key"]), []).append(operation)
    for key, group in groups.items():
        low, high = min(int(op["sent_us"]) for op in group), max(int(op["returned_us"]) for op in group)
        found = [record for record in logged if matching(group[0], record) and low <= int(record["decided_us"]) <= high]
        for operation in group:
            operation["records"] = len(found)
            operation["result"] = "pass" if len(found) == len(group) else "fail"
        if len(found) != len(group):
            problems.append(f"{len(found)} {key[1]} {key[2] or '-'} records for {len(group)} operations on "
                            f"{key[3]}/{key[4]} between their sends and returns")
    return problems


def operations_case(cases, steward, operations, logged, sent):
    problems = judge_operations(operations, logged, sent)
    add(cases, "adversarial", "one record per operation", steward,
        "every operation the battery sent has exactly one record of its expected op and decision, decided between "
        "its send and its return, both on the steward's VM",
        "; ".join(problems) or f"{len(operations)} operations, one record each", not problems)


def operations_check(args, out):
    folder = pathlib.Path(args.fixture)
    rows = lambda name: list(csv.DictReader((folder / name).read_text().splitlines())) if (folder / name).is_file() else []
    operations, logged = rows("operations.csv"), rows("records.csv")
    sent = any(row["event"] == SENT_EVENT for row in rows("events.csv"))
    cases = []
    operations_case(cases, operations[0]["steward"] if operations else "server", operations, logged, sent)
    write(out / "operations.csv", OPERATION_COLUMNS, operations)
    return conclude(out, cases, None, "E1 operations check")
PLANT_ROGUE = f"mkdir -p /state/data/{ADVERSARIAL} && printf rogue > /state/data/{ADVERSARIAL}/rogue.bin"
SNAPSHOT_TRIES = 6
STOPPED_S = 30


def job_gateway_stopped(steward, pod):
    found = kjson("-n", steward, "get", "pods", "--field-selector", f"metadata.name={pod}")["items"]
    return not found or gateway_status(found[0]).get("state", {}).get("terminated", {}).get("exitCode") == 0


def remove_through_pod(mode, steward, path):
    claim = only_claim(steward)["metadata"]["name"]
    manifest = {
        "apiVersion": "v1", "kind": "Pod", "metadata": {"name": install.INSPECTOR, "namespace": steward},
        "spec": {
            "restartPolicy": "Never",
            "containers": [{
                "name": "inspector", "image": cluster.image(mode, "vfl-train-demo"), "imagePullPolicy": "IfNotPresent",
                "command": ["sleep", "3600"],
                "volumeMounts": [{"name": "state", "mountPath": "/state"}],
            }],
            "volumes": [{"name": "state", "persistentVolumeClaim": {"claimName": claim}}],
        },
    }
    kubectl("apply", "-f", "-", stdin=json.dumps(manifest))
    try:
        kubectl("-n", steward, "wait", "--for=condition=Ready", f"pod/{install.INSPECTOR}", "--timeout=180s", timeout=200)
        kubectl("-n", steward, "exec", install.INSPECTOR, "--", "rm", path, timeout=120)
    finally:
        kubectl("-n", steward, "delete", "pod", install.INSPECTOR, "--ignore-not-found=true", "--grace-period=1",
                "--wait=true", "--timeout=60s", timeout=90)


def settled_snapshot(mode, out, steward, events):
    problem = ""
    for attempt in range(1, SNAPSHOT_TRIES + 1):
        try:
            taken = snapshot(mode, out, f"planted-{attempt}", steward)
        except cluster.Void:
            raise
        except Failed as error:
            problem = str(error)[:200]
        else:
            moving = [line for line in state_files(taken[1]) if line.endswith(".tmp")]
            if not moving:
                return taken
            problem = f"a write in flight: {moving[0].split(None, 1)[-1]}"
        events.add("adversarial: listing taken during a write, taken again", steward, 0, f"try {attempt}: {problem}")
    raise Failed(f"adversarial: no settled listing of {steward}'s claim in {SNAPSHOT_TRIES} tries: {problem}")


def adversarial(args, out):
    mode, steward, cases, table = args.mode, "server", [], []
    with collect.Unit(mode, out) as unit:
        events = start(mode, out, unit)
        with cluster.service(mode, "api-gateway") as api:
            request = reset.trigger(api, args.rounds, events)
            pod = cluster.until(f"{steward}: a write ALLOW by the job's enforcement point", WRITING_S[mode],
                                lambda: writing(steward) and serving_pod(steward, SERVICE), every=2)
            events.add("adversarial: chain up", steward, 0, f"pod/{pod}")
            sent = reset.micros()
            answer = kubectl("exec", "-i", "-n", steward, pod, "-c", SERVICE, "--", "python3", "-u", "-c", BATTERY,
                             ADVERSARIAL, str(args.concurrent), timeout=120).strip().splitlines()
            events.add("adversarial: tampered identity and concurrent writes sent", steward, reset.micros() - sent,
                       answer[-1][:300] if answer else "no answer")
            if not answer:
                raise Failed("adversarial: the battery in the chain pod printed nothing")
            got = json.loads(answer[-1])
            node = kjson("-n", steward, "get", "pod", pod)["spec"].get("nodeName", "")
            operations = operation_rows(steward, node, got.get("operations") or [])
            kubectl("exec", "-n", steward, pod, "-c", checks.GATEWAY, "--", "sh", "-c", PLANT_ROGUE)
            events.add("adversarial: a file written past the enforcement point", steward, 0,
                       f"data/{ADVERSARIAL}/rogue.bin")
            planted = settled_snapshot(mode, out, steward, events)
            rogue, through = f"/state/data/{ADVERSARIAL}/rogue.bin", ""
            try:
                kubectl("exec", "-n", steward, pod, "-c", checks.GATEWAY, "--", "rm", rogue)
            except cluster.Void:
                raise
            except Failed as error:
                deadline = time.monotonic() + STOPPED_S
                while not job_gateway_stopped(steward, pod):
                    if time.monotonic() >= deadline:
                        raise error
                    time.sleep(1)
                remove_through_pod(mode, steward, rogue)
                through = f"through pod/{install.INSPECTOR} on the claim: the job's gateway had ended"
            events.add("adversarial: the planted file removed", steward, 0, through)
            reset.wait_done(api, request, RUN_DEADLINE_S[mode])
            events.add("run done", "api-gateway", 0, f"request {request}")
        found = {name: claim_records(unit, name) for name in STEWARDS}
    write_records(out, found)
    logged = found[steward][1]
    mismatched = ops(logged, "identity_mismatch")
    files, _ = state_keys(listing_of(out, steward))
    add(cases, "adversarial", "tampered identity", steward,
        "the write refused PERMISSION_DENIED, one identity_mismatch record, no state file for it",
        f"{got.get('tampered')}, {len(mismatched)} identity_mismatch records, "
        f"{'a' if (ADVERSARIAL, 'mismatch-probe') in files else 'no'} state file",
        got.get("tampered") == "PERMISSION_DENIED" and len(mismatched) == 1
        and (ADVERSARIAL, "mismatch-probe") not in files)
    allowed = [record for record in ops(logged, "write") if e4.key_of(record) == (ADVERSARIAL, "concurrent-slot")
               and record.get("decision") == "ALLOW"]
    answers = got.get("concurrent") or []
    add(cases, "adversarial", f"{args.concurrent} concurrent writes on one slot", steward,
        f"{args.concurrent} ALLOW answers, {args.concurrent} write ALLOW records for the slot, one state file for it",
        f"answers {' '.join(answers) or 'none'}, {len(allowed)} records, "
        f"{files.count((ADVERSARIAL, 'concurrent-slot'))} state files",
        answers == ["ALLOW"] * args.concurrent and len(allowed) == args.concurrent
        and files.count((ADVERSARIAL, "concurrent-slot")) == 1)
    seen, rest = state_keys(planted[1])
    audited = {e4.key_of(record) for record in records.parse(planted[0].decode()) if record.get("op") == "write"
               and record.get("decision") == "ALLOW"}
    caught = [f"{state_class}/{key}" for state_class, key in seen if (state_class, key) not in audited] + rest
    add(cases, "adversarial", "a file past the enforcement point", steward,
        f"completeness on the claim names data/{ADVERSARIAL}/rogue.bin and nothing else",
        f"without a write ALLOW record: {' '.join(caught) or 'none'}", caught == [f"{ADVERSARIAL}/rogue"])
    logged_rows = list(csv.DictReader((out / "records.csv").read_text().splitlines()))
    operations_case(cases, steward, operations, logged_rows, bool(answer))
    write(out / "operations.csv", OPERATION_COLUMNS, operations)
    for name in STEWARDS:
        completeness(out, name, found[name][1], cases, table)
    write(out / "completeness.csv", COMPLETENESS_COLUMNS, table)
    return conclude(out, cases, None, "E1 adversarial")


def p_empty(args, out):
    mode, cases, table = args.mode, [], []
    with collect.Unit(mode, out) as unit:
        events = start(mode, out, unit)
        with cluster.service(mode, "api-gateway") as api, cluster.service(mode, "orchestrator") as orchestrator:
            run(mode, api, events, args.rounds)
            for steward in STEWARDS:
                name = only_claim(steward)["metadata"]["name"]
                cluster.until(f"{steward}: job/idle-{name} made by the agent", FINISHED_S,
                              lambda steward=steward, name=name: job_uid(steward, f"idle-{name}"))
            revoke_all(orchestrator, events, "p-empty: revocation with purge empties the claims")
            done = {steward: complete(steward, only_claim(steward)["metadata"]["name"], 60) for steward in STEWARDS}
            events.add("p-empty: idle Jobs complete", "all", 0, " ".join(f"{s} {'yes' if d else 'no'}"
                                                                          for s, d in done.items()))
            if not all(done.values()):
                raise Failed("p-empty: the idle Jobs did not complete after the revocation, so the claims were not "
                             "shown emptied: " + " ".join(s for s, d in done.items() if not d))
        found = {steward: claim_records(unit, steward) for steward in STEWARDS}
    write_records(out, found)
    for steward in STEWARDS:
        completeness(out, steward, found[steward][1], cases, table)
    write(out / "completeness.csv", COMPLETENESS_COLUMNS, table)
    return conclude(out, cases, None, "E1 p-empty")


UNIT_BINARY = "gateway.test"
UNIT_PACKAGE = "./cmd/policy-checkpoint-gateway"
UNIT_BUILD = ("go", "test", "-c", "-trimpath", "-o")
UNIT_BUILD_COLUMNS = ("head", "go_tree", "set_commit", "set_go_tree", "command", "go_version", "tests",
                      "agreements_sha256", "sha256")
UNIT_INPUT = pathlib.Path("configuration") / "etcd_launch_files" / "agreements.json"
UNIT_COLUMNS = ("test", "result", "seconds")
UNIT_LINE = re.compile(r"--- (PASS|FAIL|SKIP): (\S+) \((\d+(?:\.\d+)?)s\)")
UNIT_TIMEOUT_S = 600


def unit_build(folder):
    import e5
    folder = pathlib.Path(folder)
    folder.mkdir(parents=True, exist_ok=True)
    binary = folder / UNIT_BINARY
    commit = e5.git("rev-parse", e5.set_tag() + "^{commit}")
    row = {"head": e5.git("rev-parse", "HEAD"), "go_tree": e5.git("rev-parse", "HEAD:go"), "set_commit": commit,
           "set_go_tree": e5.git("rev-parse", f"{commit}:go")}
    if row["go_tree"] != row["set_go_tree"]:
        raise Failed(f"go/ at HEAD {row['go_tree']} is not go/ of the set's commit {commit}: {row['set_go_tree']}")
    changed = e5.git("status", "--porcelain", "--", "go")
    if changed:
        raise Failed(f"go/ has changes not committed, the build would not be the set's: {changed[:200]}")
    counted = e5.git("grep", "-c", "-E", r"^func Test", commit, "--", "go/cmd/policy-checkpoint-gateway/*_test.go")
    tests = sum(int(line.rsplit(":", 1)[1]) for line in counted.splitlines())
    command = [*UNIT_BUILD, str(binary), UNIT_PACKAGE]
    environment = {**os.environ, "CGO_ENABLED": "0", "GOOS": "linux", "GOARCH": "amd64"}
    try:
        done = subprocess.run(command, cwd=cluster.ROOT / "go", env=environment, capture_output=True, text=True,
                              timeout=UNIT_TIMEOUT_S)
    except subprocess.TimeoutExpired:
        raise Failed(f"unit build: not done within {UNIT_TIMEOUT_S} s") from None
    if done.returncode != 0:
        raise Failed(f"unit build: exit {done.returncode}: {' '.join(done.stderr.split())[-400:]}")
    row.update(command="CGO_ENABLED=0 GOOS=linux GOARCH=amd64 " + " ".join(command[:-2]) + f" {UNIT_BINARY} "
               + command[-1], go_version=cluster.run(["go", "version"]).strip(), tests=tests,
               agreements_sha256=hashlib.sha256(cluster.run(["git", "-C", str(cluster.ROOT), "show",
                                                             f"{commit}:{UNIT_INPUT}"], binary=True)).hexdigest(),
               sha256=hashlib.sha256(binary.read_bytes()).hexdigest())
    write(folder / "unit-build.csv", UNIT_BUILD_COLUMNS, [row])
    return binary


def unit_built(binary):
    import e5
    binary = pathlib.Path(binary).expanduser()
    rows = list(csv.DictReader((binary.parent / "unit-build.csv").read_text().splitlines()))
    if len(rows) != 1:
        raise Failed(f"{binary.parent / 'unit-build.csv'}: {len(rows)} rows, not 1")
    got = hashlib.sha256(binary.read_bytes()).hexdigest()
    if got != rows[0]["sha256"]:
        raise Failed(f"{binary}: sha256 {got}, unit-build.csv says {rows[0]['sha256']}")
    if not rows[0]["set_commit"].startswith(e5.set_tag()):
        raise Failed(f"{binary}: built for {rows[0]['set_commit']}, pins.csv is the set stay-up-{e5.set_tag()}")
    return binary, rows[0]


def unit_tests(args, out):
    binary, row = unit_built(args.binary) if args.binary else unit_built(unit_build(out / "raw" / "unit"))
    write(out / "unit-build.csv", UNIT_BUILD_COLUMNS, [row])
    package = cluster.ROOT / "go" / "cmd" / "policy-checkpoint-gateway"
    needed = cluster.ROOT / UNIT_INPUT
    if not package.is_dir() or not needed.is_file():
        raise Failed(f"unit tests need {package} as their folder and {needed}")
    held = hashlib.sha256(needed.read_bytes()).hexdigest()
    if held != row["agreements_sha256"]:
        raise Failed(f"{needed}: sha256 {held}, the set's file (unit-build.csv) {row['agreements_sha256']}")
    began = reset.micros()
    try:
        done = subprocess.run([str(binary.resolve()), "-test.v", "-test.count=1"], cwd=package, capture_output=True,
                              text=True, timeout=UNIT_TIMEOUT_S)
    except subprocess.TimeoutExpired:
        raise Failed(f"unit tests: not done within {UNIT_TIMEOUT_S} s") from None
    ended = reset.micros()
    (out / "raw" / "unit").mkdir(parents=True, exist_ok=True)
    (out / "raw" / "unit" / "go-test.txt").write_text(done.stdout + done.stderr)
    found = [UNIT_LINE.fullmatch(line) for line in done.stdout.splitlines()]
    rows = [{"test": hit.group(2), "result": hit.group(1), "seconds": hit.group(3)} for hit in found if hit]
    write(out / "unit-tests.csv", UNIT_COLUMNS, rows)
    counts = {result: sum(1 for item in rows if item["result"] == result) for result in ("PASS", "FAIL", "SKIP")}
    cases = []
    add(cases, "unit", "the gateway package's tests", socket.gethostname(),
        f"{row['tests']} test functions (the set's source), every one PASS, exit 0",
        f"{len(rows)} run: {counts['PASS']} PASS, {counts['FAIL']} FAIL, {counts['SKIP']} SKIP, exit {done.returncode}, "
        f"{(ended - began) / 1e6:.1f} s",
        done.returncode == 0 and len(rows) == int(row["tests"]) == counts["PASS"])
    return conclude(out, cases, None, "E1 unit tests")


CASES = {"w4": lambda args, out: w4(args.mode, out), "p-gap": lambda args, out: p_gap(args.mode, out),
         "p-m1": lambda args, out: p_m1(args.mode, out), "p-restart": lambda args, out: p_restart(args.mode, out),
         "idle-a": idle_a, "idle-b": idle_b, "idle-c": idle_c, "idle-d": idle_d, "expiry-check": expiry_check,
         "windows": windows,
         "p-a": p_a, "p-b-upper": p_b_upper, "p-up": p_up, "p-c": p_c,
         "p-d": lambda args, out: idle_d(args, out, retention=args.retention),
         "terms": terms, "r3": r3, "d1-job": d1_job, "d6": d6, "adversarial": adversarial, "p-empty": p_empty,
         "unit-tests": unit_tests, "operations-check": operations_check}
NO_CLUSTER = ("expiry-check", "windows", "unit-tests", "operations-check")
NEEDS_FIXTURE = ("expiry-check", "windows", "operations-check")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("case", choices=sorted(CASES))
    parser.add_argument("fixture", nargs="?")
    parser.add_argument("--mode", choices=["kind", "fabric"])
    parser.add_argument("--out", required=True)
    parser.add_argument("--rounds", type=int, default=ROUNDS)
    parser.add_argument("--idle-up-bound", type=int, default=60)
    parser.add_argument("--revocation-bound", type=int, default=5)
    parser.add_argument("--retention", type=int, default=120)
    parser.add_argument("--expiry-slack", type=int, default=35)
    parser.add_argument("--nothing-due-polls", type=int, default=3)
    parser.add_argument("--concurrent", type=int, default=8)
    parser.add_argument("--binary")
    args = parser.parse_args()
    out = pathlib.Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    try:
        if args.case in NO_CLUSTER:
            if args.case in NEEDS_FIXTURE and not args.fixture:
                raise Failed(f"{args.case} needs a fixture folder")
        else:
            if args.mode is None:
                raise Failed(f"{args.case} needs --mode")
            cluster.guard(args.mode)
        return CASES[args.case](args, out)
    except cluster.Void as error:
        print(str(error), file=sys.stderr)
        return 3
    except (Failed, ValueError, KeyError, StopIteration, OSError) as error:
        print(f"e1 {args.case}: {type(error).__name__}: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
