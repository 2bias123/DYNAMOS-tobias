#!/usr/bin/env python3
import argparse
import csv
import hashlib
import json
import pathlib
import sys
import time

import cluster
import collect
import e1
import records
import reset
from cluster import Failed, STEWARDS, kjson, kubectl

RUN_DEADLINE_S = {"kind": 900, "fabric": 2700}
RESUME_ROUNDS = 3
POLL_S = 0.1
EXPIRY_MARGIN_S = 10
IDLE_SEEN_S = 180
SAMPLED_S = 30
NOT_FOUND = "not found"
REVOKED = "allowed = false"
SAMPLING = """import os, time
def size(top):
    total = count = 0
    for root, _, names in os.walk(top):
        for name in names:
            try:
                total += os.path.getsize(os.path.join(root, name))
                count += 1
            except OSError:
                pass
    return total, count
while True:
    data, files = size("/state/data")
    audit, _ = size("/state/audit")
    print(time.time_ns() // 1000, data, audit, files, flush=True)
    time.sleep(1)
"""
GROWTH_COLUMNS = ("round", "clock", "closed_us", "accuracy", "write_clock", "write_us", "decision", "records_cum",
                  "bytes_cum", "sample_clock", "sample_us", "data_bytes", "audit_bytes", "state_files")
FLIP_COLUMNS = ("round", "clock", "closed_us", "accuracy", "at_flip", "write_clock", "write_us", "decision", "reason")
STORAGE_COLUMNS = ("steward", "claim", "node", "files", "state_files", "audit_bytes", "audit_records")
EXPIRY_COLUMNS = ("steward", "clock", "state_class", "state_key", "last_write_us", "put_clock", "put_us", "due_us",
                  "deleted_us", "after_write_us", "after_due_us", "form", "deleted_records", "deferred", "cancelled",
                  "result")


def claim_name(steward):
    digest = hashlib.sha256(cluster.USER.encode()).hexdigest()[:8]
    return f"state-{steward}-{digest}-{cluster.REQUEST_TYPE.lower()}"


def case(rows, row, steward, expected, observed, ok):
    rows.append({"row": row, "case": row, "steward": steward, "expected": expected, "observed": observed,
                 "result": "pass" if ok else "fail"})


def finish(out, cases, name):
    e1.write(out / "cases.csv", e1.CASE_COLUMNS, cases)
    failed = [entry for entry in cases if entry["result"] == "fail"]
    if failed:
        raise Failed(f"{name} failed: " + "; ".join(f"{entry['row']} {entry['steward']}: {entry['observed']}"
                                                     for entry in failed))
    print(f"{name} passed: {len(cases)} checks")
    return 0


def lines_of(out, steward):
    folder = out / "raw" / "claims" / steward / claim_name(steward)
    return [line for line in (folder / "audit.log").read_text().splitlines() if line.startswith("{")]


def read_claims(unit, out):
    found, storage, rows = {}, [], []
    for steward in STEWARDS:
        node, logged = e1.claim_records(unit, steward)
        found[steward] = (node, logged)
        rows += [e1.record_row(steward, node, record) for record in logged]
        folder = out / "raw" / "claims" / steward / claim_name(steward)
        listing = (folder / "files.sha256").read_text().splitlines()
        storage.append({"steward": steward, "claim": claim_name(steward), "node": node, "files": len(listing),
                        "state_files": sum(1 for line in listing if line.split(None, 1)[-1].startswith("./data/")),
                        "audit_bytes": (folder / "audit.log").stat().st_size, "audit_records": len(logged)})
    e1.write(out / "records.csv", e1.RECORD_COLUMNS, rows)
    e1.write(out / "storage.csv", STORAGE_COLUMNS, storage)
    return found


def status(api, request):
    code, text = cluster.http("GET", f"{api}/api/v1/getTrainingStatus?id={request}", timeout=10)
    if code == 200:
        reset.keep(request, text)
    try:
        found = json.loads(text)
    except ValueError:
        return {}
    return found if isinstance(found, dict) else {}


def results(api, request, rounds):
    found = status(api, request).get("results") or []
    if len(found) != rounds:
        raise Failed(f"run {request}: {len(found)} round results, not {rounds}")
    return {int(entry["train_round"]): entry for entry in found}


def closed(entry):
    return reset.stamp_us(entry["timestamp"]), str(entry["accuracy"])


def until_rounds(api, request, rounds, seconds):
    deadline = time.monotonic() + seconds
    state = ""
    while time.monotonic() < deadline:
        found = status(api, request)
        state = found.get("status", "")
        if len(found.get("results") or []) >= rounds:
            return reset.micros()
        if state in ("done", "failed"):
            raise Failed(f"run {request}: status {state} before round {rounds - 1} closed")
        time.sleep(POLL_S)
    lost = reset.raced()
    if lost and state == "pending":
        raise cluster.Void(f"void R9: start race: 'Could not connect with gRPC localhost:<port> after 7 tries' in a "
                           f"chain pod of {' '.join(lost)}, request {request} still pending after {seconds} s")
    raise Failed(f"run {request}: round {rounds - 1} not closed after {seconds} s, status '{state}'")


def agreement(steward, change):
    body = json.loads(reset.seed_file(steward).read_text())
    change(body["relations"][cluster.USER]["stateDirectives"])
    return body


def put_terms(orchestrator, bodies, events, what, mode=None, own_vm=()):
    stamps = {}
    for steward, body in bodies.items():
        if steward in own_vm:
            code, sent, clock = reset.put_stamped(mode, steward, f"{orchestrator}/api/v1/policyEnforcer",
                                                  json.dumps(body))
            text = ""
            events.add(what, steward, 0, f"http {code}; sent from {steward}'s VM, time is the send there", at=sent,
                       clock=clock)
            stamps[steward] = (clock, sent)
        else:
            sent = reset.micros()
            code, text = cluster.http("PUT", f"{orchestrator}/api/v1/policyEnforcer", json.dumps(body).encode())
            events.add(what, steward, reset.micros() - sent, f"http {code}; time is the send", at=sent)
        if code != 200:
            raise Failed(f"{what}: {steward}: http {code} {text[:200]}")

    def held():
        for steward, body in bodies.items():
            got = json.loads(reset.etcd(f"get /policyEnforcer/agreements/{steward} --print-value-only"))
            if reset.terms(got) != reset.terms(body):
                return False
        return True

    cluster.until(f"{what}: etcd holds the terms sent", 30, held)
    return stamps


def first_run(found):
    end = next((index for index, record in enumerate(found)
                if record.get("op") == "shutdown" and records.job_of(record)), len(found) - 1)
    after = next((index for index in range(end + 1, len(found))
                  if records.job_of(found[index]) and found[index].get("op") in ("read", "write")), len(found))
    return end, after


def run_writes(found):
    _, after = first_run(found)
    return [record for record in found[:after] if record.get("op") == "write" and records.job_of(record)]


def destroyed(found):
    return [record for record in found if record.get("decision") in ("PURGED", "DELETED")]


def key_of(record):
    return record.get("stateClass", ""), record.get("stateKey", "")


def expiry(steward, node, found, retention_s, slack_s, put=None):
    last = {}
    for record in run_writes(found):
        if record.get("decision") == "ALLOW":
            last[key_of(record)] = max(last.get(key_of(record), 0), record["decidedUnixMicros"])
    end, after = first_run(found)
    expired = [record for record in found[end + 1:after] if record.get("op") == "expired"]
    kept = {decision: sum(1 for record in expired if record.get("decision") == decision)
            for decision in ("DEFERRED", "CANCELLED")}
    rows = []
    for (state_class, state_key), written in sorted(last.items()):
        deleted = [record for record in expired
                   if record.get("decision") == "DELETED" and key_of(record) == (state_class, state_key)]
        due = max(written + retention_s * 1_000_000, put[1] if put else 0)
        row = {"steward": steward, "clock": f"gateway@{node}" if node else "gateway", "state_class": state_class,
               "state_key": state_key, "last_write_us": written, "put_clock": put[0] if put else "",
               "put_us": put[1] if put else "", "due_us": due, "deleted_us": "", "after_write_us": "",
               "after_due_us": "", "form": "", "deleted_records": len(deleted), "deferred": kept["DEFERRED"],
               "cancelled": kept["CANCELLED"], "result": "fail"}
        if len(deleted) == 1:
            at = deleted[0]["decidedUnixMicros"]
            row.update(deleted_us=at, after_write_us=at - written, after_due_us=at - due,
                       form="job" if records.job_of(deleted[0]) else "idle",
                       result="pass" if due <= at <= due + slack_s * 1_000_000 else "fail")
        rows.append(row)
    return rows


def window_shown(rows):
    if not rows:
        return "no state file written by the run, so nothing to expire"
    return "; ".join(f"{row['state_class']}/{row['state_key']}: {row['deleted_records']} DELETED"
                     + (f", {int(row['after_write_us']) / 1e6:.1f} s after its last write and "
                        f"{int(row['after_due_us']) / 1e6:.1f} s after its due time"
                        + (f" (R put {(int(row['put_us']) - int(row['last_write_us'])) / 1e6:.1f} s after it)"
                           if row["put_us"] != "" else "") + f", {row['form']} form"
                        if row["deleted_us"] != "" else "")
                     + f", {row['deferred']} DEFERRED and {row['cancelled']} CANCELLED kept" for row in rows)


def start_sampler(mode, events):
    spec = {
        "restartPolicy": "Never",
        "containers": [{"name": "sampler", "image": cluster.image(mode, "vfl-train-demo"),
                        "imagePullPolicy": "IfNotPresent", "command": ["python3", "-c", SAMPLING],
                        "volumeMounts": [{"name": "state", "mountPath": "/state", "readOnly": True}]}],
        "volumes": [{"name": "state", "persistentVolumeClaim": {"claimName": claim_name("server"), "readOnly": True}}],
    }
    if mode == "fabric":
        spec["nodeSelector"] = {"kubernetes.io/hostname": "server"}
    manifest = {"apiVersion": "v1", "kind": "Pod", "metadata": {"name": collect.SAMPLER, "namespace": "server"},
                "spec": spec}
    kubectl("apply", "-f", "-", stdin=json.dumps(manifest))
    events.add("sampler created, waits for the server claim", "server", 0, f"pod/{collect.SAMPLER} on {claim_name('server')}")


def keep_sampler(mode, events):
    cluster.until("server: the job's enforcement point ended", e1.FINISHED_S, lambda: e1.gateway_ended("server"))
    node, finished = e1.gateway_ended("server")
    placed = kjson("-n", "server", "get", "pod", collect.SAMPLER)["spec"].get("nodeName", "")
    if mode == "fabric" and placed != node:
        raise Failed(f"pod/{collect.SAMPLER} on {placed}, the job's enforcement point on {node}: two clocks")
    wanted = finished + 1_000_000

    def last_sample():
        stamps = [int(line.split()[0]) for line in kubectl("-n", "server", "logs", collect.SAMPLER).splitlines()
                  if len(line.split()) == 4 and all(part.isdigit() for part in line.split())]
        return stamps[-1] if stamps and stamps[-1] >= wanted else None

    sampled = cluster.until(f"pod/{collect.SAMPLER}: a sample after the job's enforcement point ended", SAMPLED_S,
                            last_sample, every=1)
    events.add("sampler kept to a sample after the job's end", "server", sampled - finished,
               f"enforcement point ended at {finished} (kubelet, whole seconds) on {node}; sample at {sampled}",
               at=finished, clock=f"kubelet@{node}" if node else "kubelet")


def stop_sampler(out):
    try:
        (out / "raw" / "sampler.log").write_text(kubectl("-n", "server", "logs", collect.SAMPLER))
    finally:
        kubectl("-n", "server", "delete", "pod", collect.SAMPLER, "--ignore-not-found=true", "--grace-period=1",
                "--wait=true", "--timeout=90s", timeout=120)


def samples(out):
    found = []
    for line in (out / "raw" / "sampler.log").read_text().splitlines():
        parts = line.split()
        if len(parts) == 4 and all(part.isdigit() for part in parts):
            found.append(tuple(int(part) for part in parts))
    return found


def growth(args, out):
    mode = args.mode
    cases, rows = [], []
    try:
        with collect.Unit(mode, out) as unit:
            events = e1.start(mode, out, unit)
            with cluster.service(mode, "api-gateway") as api:
                start_sampler(mode, events)
                begun = reset.micros()
                request = reset.trigger(api, args.rounds, events)
                cluster.until(f"pod/{collect.SAMPLER} running", 300, lambda: kjson(
                    "-n", "server", "get", "pod", collect.SAMPLER)["status"].get("phase") == "Running", every=1)
                reset.wait_done(api, request, RUN_DEADLINE_S[mode])
                events.add("run done", "api-gateway", reset.micros() - begun, f"request {request}")
                rounds = results(api, request, args.rounds)
                try:
                    keep_sampler(mode, events)
                finally:
                    stop_sampler(out)
            found = read_claims(unit, out)
    finally:
        try:
            kubectl("-n", "server", "delete", "pod", collect.SAMPLER, "--ignore-not-found=true", "--grace-period=1",
                    "--wait=true", "--timeout=90s", timeout=120)
        except Failed as error:
            print(f"growth: {collect.SAMPLER} not deleted, the next clean start will refuse it: {error}", flush=True)
    taken = samples(out)
    node = found["server"][0]
    lines = lines_of(out, "server")
    logged = found["server"][1]
    writes = [(index, record) for index, record in enumerate(logged[:first_run(logged)[1]])
              if record.get("op") == "write" and records.job_of(record)]
    for number, (index, record) in enumerate(writes):
        sample = next((entry for entry in taken if entry[0] >= record["decidedUnixMicros"]), None)
        at, accuracy = closed(rounds[number]) if number in rounds else ("", "")
        rows.append({
            "round": number, "clock": "api-gateway", "closed_us": at, "accuracy": accuracy,
            "write_clock": f"gateway@{node}", "write_us": record["decidedUnixMicros"],
            "decision": record.get("decision", ""), "records_cum": index + 1,
            "bytes_cum": sum(len(line.encode()) + 1 for line in lines[:index + 1]), "sample_clock": f"sampler@{node}",
            "sample_us": sample[0] if sample else "", "data_bytes": sample[1] if sample else "",
            "audit_bytes": sample[2] if sample else "", "state_files": sample[3] if sample else "",
        })
    e1.write(out / "rounds-growth.csv", GROWTH_COLUMNS, rows)
    for steward in STEWARDS:
        made = run_writes(found[steward][1])
        allowed = [record for record in made if record.get("decision") == "ALLOW"]
        case(cases, "persisted every round", steward, f"{args.rounds} write ALLOW records by the run's job, nothing else",
             f"{len(made)} write records, {len(allowed)} ALLOW", len(allowed) == len(made) == args.rounds)
        gone = destroyed(found[steward][1])
        case(cases, "no destruction", steward, "no PURGED or DELETED record", f"{len(gone)} PURGED or DELETED records",
             not gone)
    first = next((record for record in logged if record.get("op") == "read"), {})
    case(cases, "clean-slate read", "server", f"the first read record DENY '{NOT_FOUND}'",
         f"{first.get('decision', 'no read')} '{first.get('reason', '')}'",
         first.get("decision") == "DENY" and first.get("reason") == NOT_FOUND)
    if writes and taken:
        case(cases, "sampler covers the run", "server",
             "a sample at or before round 0's write and one at or after the last round's write, same VM clock",
             f"samples {taken[0][0]} to {taken[-1][0]}, writes {writes[0][1]['decidedUnixMicros']} to "
             f"{writes[-1][1]['decidedUnixMicros']}, {len(taken)} samples",
             taken[0][0] <= writes[0][1]["decidedUnixMicros"] and taken[-1][0] >= writes[-1][1]["decidedUnixMicros"])
    else:
        case(cases, "sampler covers the run", "server", "samples and writes", f"{len(taken)} samples, "
             f"{len(writes)} writes", False)
    files = [row for row in csv_rows(out / "storage.csv") if row["steward"] == "server"]
    case(cases, "state persisted", "server", "at least one state file on the claim at the end",
         f"{files[0]['state_files']} state files" if files else "no listing",
         bool(files) and int(files[0]["state_files"]) >= 1)
    return finish(out, cases, "E4 growth")


def idle_job(steward, name):
    try:
        jobs = kjson("-n", steward, "get", "jobs", "-l", reset.IDLE)["items"]
    except Failed as error:
        if isinstance(error, cluster.Void):
            raise
        return False
    return any(job["metadata"]["name"] == name for job in jobs)


def csv_rows(path):
    return list(csv.DictReader(pathlib.Path(path).read_text().splitlines()))


def flip(args, out):
    mode = args.mode
    if not 0 < args.flip_after < args.rounds:
        raise Failed(f"--flip-after {args.flip_after} must lie inside the run of {args.rounds} rounds")
    cases = []
    with collect.Unit(mode, out) as unit:
        events = e1.start(mode, out, unit)
        with cluster.service(mode, "api-gateway") as api, cluster.service(mode, "orchestrator") as orchestrator:
            put_terms(orchestrator, {steward: agreement(steward, lambda sd: sd.update(onRevocation=""))
                                     for steward in STEWARDS}, events, "seed: deny but retain")
            begun = reset.micros()
            request = reset.trigger(api, args.rounds, events)
            seen = until_rounds(api, request, args.flip_after, RUN_DEADLINE_S[mode])
            put_terms(orchestrator, {"server": agreement("server", lambda sd: sd.update(allowed=False, onRevocation=""))},
                      events, f"flip: server allowed=false, round {args.flip_after - 1} closed and seen at {seen}")
            reset.wait_done(api, request, RUN_DEADLINE_S[mode])
            done = reset.micros()
            events.add("run done", "api-gateway", done - begun, f"request {request}")
            rounds = results(api, request, args.rounds)
            reset.gap(events)
            stamps = put_terms(orchestrator, {steward: agreement(steward, lambda sd: sd.update(retentionSeconds=args.retention))
                                              for steward in STEWARDS}, events, f"seed: retention {args.retention} s",
                               mode, own_vm=("server",))
            put_done = reset.micros()
            for steward in STEWARDS:
                name = f"idle-{claim_name(steward)}"
                cluster.until(f"job/{name} exists in {steward}", IDLE_SEEN_S,
                              lambda: idle_job(steward, name))
                events.add("idle job seen", steward, 0, f"job/{name}")
            wait = (max(done + args.retention * 1_000_000, put_done) + (args.slack + EXPIRY_MARGIN_S) * 1_000_000
                    - reset.micros())
            events.add("expiry wait", "all", max(0, wait), f"until the later of {args.retention} s after the run's end "
                                                           f"and the retention put, plus {args.slack + EXPIRY_MARGIN_S} s, "
                                                           f"on this host")
            time.sleep(max(0, wait) / 1_000_000)
            begun = reset.micros()
            second = reset.trigger(api, RESUME_ROUNDS, events)
            reset.wait_done(api, second, RUN_DEADLINE_S[mode])
            events.add("run done", "api-gateway", reset.micros() - begun, f"request {second}")
        found = read_claims(unit, out)
    windows, flips = [], []
    for steward in STEWARDS:
        node, logged = found[steward]
        made = run_writes(logged)
        end, second = first_run(logged)
        allowed = [record for record in made if record.get("decision") == "ALLOW"]
        denied = [record for record in made if record.get("decision") == "DENY"]
        if steward == "server":
            order = [record.get("decision") for record in made]
            after_deny = order[order.index("DENY"):] if "DENY" in order else []
            case(cases, "allow then deny", steward,
                 f"at least {args.flip_after} and fewer than {args.rounds} ALLOW writes, then only DENY "
                 f"'{REVOKED}', at least one",
                 f"{len(allowed)} ALLOW, {len(denied)} DENY with reasons "
                 f"{sorted({record.get('reason', '') for record in denied})}, "
                 f"{'an ALLOW after a DENY' if 'ALLOW' in after_deny else 'no ALLOW after a DENY'}",
                 args.flip_after <= len(allowed) < args.rounds and denied and "ALLOW" not in after_deny
                 and all(record.get("reason") == REVOKED for record in denied) and len(made) == args.rounds)
            for number, record in enumerate(made):
                at, accuracy = closed(rounds[number]) if number in rounds else ("", "")
                flips.append({"round": number, "clock": "api-gateway", "closed_us": at, "accuracy": accuracy,
                              "at_flip": "before" if number < args.flip_after else "after",
                              "write_clock": f"gateway@{node}", "write_us": record["decidedUnixMicros"],
                              "decision": record.get("decision", ""), "reason": record.get("reason", "")})
        else:
            case(cases, "persisted every round", steward, f"{args.rounds} write ALLOW records by run 1's job",
                 f"{len(made)} write records, {len(allowed)} ALLOW", len(allowed) == len(made) == args.rounds)
        early = destroyed(logged[:end + 1])
        purged = [record for record in logged if record.get("decision") == "PURGED"]
        case(cases, "run 1 destroys nothing", steward, "no PURGED record at all, no DELETED up to run 1's shutdown record",
             f"{len(purged)} PURGED, {len(early)} PURGED or DELETED up to run 1's shutdown record",
             not early and not purged)
        rows = expiry(steward, node, logged, args.retention, args.slack, stamps.get(steward))
        windows += rows
        if steward in stamps and mode == "fabric":
            case(cases, "put on the claim's VM", steward, f"the claim on {steward}, where the put was stamped",
                 f"the claim on {node or '(no selected node)'}", node == steward)
        due = (f"the later of its last write ALLOW + {args.retention} s and the retention put on {steward}'s VM"
               if steward in stamps else f"its last write ALLOW + {args.retention} s")
        case(cases, "expiry window", steward,
             f"every file run 1 wrote has one DELETED record from its due time ({due}) to {args.slack} s after it, "
             f"either form; DEFERRED and CANCELLED kept",
             window_shown(rows), bool(rows) and all(row["result"] == "pass" for row in rows))
        if steward == "server":
            read = next((record for record in logged[second:] if record.get("op") == "read"), {})
            gone = any(record.get("decision") == "DELETED" for record in logged[:second])
            case(cases, "nothing to resume", steward, f"after the expiry, run 2's first read DENY '{NOT_FOUND}'",
                 f"{read.get('decision', 'no read')} '{read.get('reason', '')}', "
                 f"{'a' if gone else 'no'} DELETED record before run 2",
                 gone and read.get("decision") == "DENY" and read.get("reason") == NOT_FOUND)
    e1.write(out / "rounds-flip.csv", FLIP_COLUMNS, flips)
    e1.write(out / "expiry.csv", EXPIRY_COLUMNS, windows)
    return finish(out, cases, "E4 flip")


def window(args, out):
    folder = pathlib.Path(args.fixture)
    found = records.parse((folder / "audit.log").read_text())
    last = max(record["decidedUnixMicros"] for record in run_writes(found) if record.get("decision") == "ALLOW")
    cases, kept = [], {}
    for name, shift_s, put_s, wanted in (("as recorded", 0, None, "pass"), ("deleted too late", 36, None, "fail"),
                                         ("deleted too early", -6, None, "fail"),
                                         ("R put after the due time, deleted after the put", 32, 150, "pass"),
                                         ("R put after the due time, deleted before the put", 0, 150, "fail"),
                                         ("R put before the due time", 0, 60, "pass")):
        moved = [dict(record, decidedUnixMicros=record["decidedUnixMicros"] + shift_s * 1_000_000)
                 if record.get("op") == "expired" and record.get("decision") == "DELETED" else record
                 for record in found]
        put = None if put_s is None else ("fixture", last + put_s * 1_000_000)
        rows = expiry("fixture", "", moved, args.retention, args.slack, put)
        got = "pass" if rows and all(row["result"] == "pass" for row in rows) else "fail"
        kept[name] = rows
        case(cases, f"window {name}", "fixture", f"{wanted}, the planted DEFERRED and CANCELLED tolerated",
             f"{got}: {window_shown(rows)}", got == wanted and bool(rows)
             and all(row["deferred"] >= 1 and row["cancelled"] >= 1 for row in rows))
    e1.write(out / "expiry.csv", EXPIRY_COLUMNS, kept["as recorded"])
    return finish(out, cases, "E4 window")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("case", choices=["growth", "flip", "window"])
    parser.add_argument("fixture", nargs="?")
    parser.add_argument("--mode", choices=["kind", "fabric"])
    parser.add_argument("--out", required=True)
    parser.add_argument("--rounds", type=int, default=50)
    parser.add_argument("--flip-after", type=int, default=10)
    parser.add_argument("--retention", type=int, default=120)
    parser.add_argument("--slack", type=int, default=35)
    args = parser.parse_args()
    out = pathlib.Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    try:
        if args.case == "window":
            if not args.fixture:
                raise Failed("window needs a fixture folder")
        else:
            if args.mode is None:
                raise Failed(f"{args.case} needs --mode")
            cluster.guard(args.mode)
        return {"growth": growth, "flip": flip, "window": window}[args.case](args, out)
    except cluster.Void as error:
        print(str(error), file=sys.stderr)
        return 3
    except (Failed, ValueError, KeyError, StopIteration) as error:
        print(f"e4 {args.case}: {type(error).__name__}: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
