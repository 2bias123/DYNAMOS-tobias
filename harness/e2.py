#!/usr/bin/env python3
import argparse
import datetime
import json
import pathlib
import socket
import subprocess
import sys
import time

import checks
import cluster
import collect
import e1
import e4
import records
import reset
from cluster import Failed, kjson, kubectl

STEWARD = "server"
SERVICE = "vfl-train-model-demo"
WRITER_IMAGE = "vfl-train-demo"
PORT = 50050
ALLOW_S = 35
DENY_S = {"watch": 35, "poll": 45}
SETTLE_S = 1
TRIAL_TRIES = 2
LOOK_S = 0.5
SINCE_MARGIN_S = 5
UP_S = {"kind": 300, "fabric": 600}
WRITER_UP_S = 30
TRIAL_COLUMNS = ("trial", "pod", "reenable_us", "allowed_us", "sent_clock", "sent_us", "returned_us", "end_clock",
                 "end_us", "value_us", "rtt_us", "end_op", "end_decision", "end_reason", "policy_source",
                 "relation_id", "purge_records", "machines", "result")
TIMED = """import sys, time, urllib.error, urllib.request
request = urllib.request.Request(sys.argv[1], data=sys.stdin.buffer.read(), method="PUT",
                                 headers={"Content-Type": "application/json"})
sent = time.time_ns() // 1000
try:
    code = urllib.request.urlopen(request, timeout=30).status
except urllib.error.HTTPError as error:
    code = error.code
print(code, sent, time.time_ns() // 1000)
"""
WRITER = """import os, sys, threading, time
import grpc
import policyCheckpointGateway_pb2 as pb
import policyCheckpointGateway_pb2_grpc as pbg
state_class, cadence, lifetime = sys.argv[1], float(sys.argv[2]) / 1000, float(sys.argv[3])
threading.Thread(target=lambda: (sys.stdin.read(), os._exit(0)), daemon=True).start()
channel = grpc.insecure_channel("localhost:%s" % os.environ["GATEWAY_PORT"])
try:
    grpc.channel_ready_future(channel).result(timeout=20)
except Exception as error:
    print("DIALFAIL", error, flush=True)
    sys.exit(1)
stub = pbg.PolicyCheckpointGatewayStub(channel)
identity = pb.Identity(steward=os.environ["DATA_STEWARD_NAME"], user=os.environ["REQUEST_USER"],
                       request_type=os.environ["REQUEST_TYPE"], job_id=os.environ["JOB_NAME"],
                       local_job_name=os.environ["LOCAL_JOB_NAME"])
print("READY", flush=True)
end, last = time.monotonic() + lifetime, None
while time.monotonic() < end:
    try:
        answer = stub.RequestStateWrite(pb.StateWriteRequest(identity=identity, state_class=state_class,
                                                             state_key="probe", payload=b"\\x01\\x02\\x03"), timeout=10)
        now = "ALLOW" if answer.allowed else "DENY"
    except grpc.RpcError as error:
        now = "ERR %s" % error.code()
    if now != last:
        print(time.time_ns() // 1000, now, flush=True)
        last = now
    time.sleep(cadence)
"""
CHAIN_END_S = 300


def timed_put(mode, vm, url, body):
    answer = cluster.run(cluster.on(cluster.host(mode, vm), ["python3", "-c", TIMED, url]), stdin=json.dumps(body),
                         timeout=60).split()
    if len(answer) != 3 or not all(part.isdigit() for part in answer):
        raise Failed(f"timed PUT from {vm}: the sender answered {' '.join(answer)!r}")
    clock = f"sender@{vm}" if mode == "fabric" else f"host@{socket.gethostname()}"
    return int(answer[0]), int(answer[1]), int(answer[2]), clock


def terms(allowed):
    return e4.agreement(STEWARD, lambda sd: sd.update(allowed=allowed))


class Writer:
    def __init__(self, namespace, pod, container, state_class, cadence_ms, lifetime_s, log):
        self.log = pathlib.Path(log)
        self.handle = open(self.log, "w")
        self.process = subprocess.Popen(
            ["kubectl", "exec", "-i", "-n", namespace, pod, "-c", container, "--", "python3", "-u", "-c", WRITER,
             state_class, str(cadence_ms), str(lifetime_s)],
            stdin=subprocess.PIPE, stdout=self.handle, stderr=subprocess.STDOUT)
        try:
            cluster.until(f"writer in {pod}/{container} ready", WRITER_UP_S,
                          lambda: "READY" in self.log.read_text() or self.process.poll() is not None, every=0.5)
        except Failed:
            self.stop()
            raise
        if self.process.poll() is not None:
            self.stop()
            raise Failed(f"writer in {pod}/{container} ended: {self.log.read_text()[-300:]}")

    def alive(self):
        return self.process.poll() is None

    def stop(self):
        if self.process.stdin and not self.process.stdin.closed:
            self.process.stdin.close()
        try:
            self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        self.handle.close()


def since_time(us):
    moment = datetime.datetime.fromtimestamp(us / 1e6 - SINCE_MARGIN_S, datetime.timezone.utc)
    return moment.strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def logged(namespace, pod, since_us=None):
    extra = [f"--since-time={since_time(since_us)}"] if since_us is not None else []
    return records.parse(kubectl("-n", namespace, "logs", pod, "-c", checks.GATEWAY, *extra, timeout=120))


def first(namespace, pod, since_us, seconds, match, what):
    deadline = time.monotonic() + seconds
    while True:
        found = [record for record in records.since(logged(namespace, pod, since_us), since_us) if match(record)]
        if found:
            return found[0]
        if time.monotonic() >= deadline:
            raise Failed(f"{what}: no such record within {seconds} s")
        time.sleep(LOOK_S)


def probe(state_class, relation, op, decision):
    return lambda record: (record.get("op") == op and record.get("decision") == decision
                           and record.get("stateClass") == state_class and record.get("relationId") == relation)


def trial_row(number, pod, reenable, allowed, sent, end, purged, mode):
    code, at, returned, clock = sent
    end_clock = f"gateway@{pod['node']}" if pod["node"] else "gateway"
    shown, same = e1.machines(mode, clock, end_clock)
    return {"trial": number, "pod": pod["name"], "reenable_us": reenable, "allowed_us": allowed["decidedUnixMicros"],
            "sent_clock": clock, "sent_us": at, "returned_us": returned, "end_clock": end_clock,
            "end_us": end["decidedUnixMicros"], "value_us": end["decidedUnixMicros"] - at, "rtt_us": returned - at,
            "end_op": end.get("op", ""), "end_decision": end.get("decision", ""), "end_reason": end.get("reason", ""),
            "policy_source": end.get("policySource", ""), "relation_id": end.get("relationId", ""),
            "purge_records": purged, "machines": shown,
            "result": "pass" if same and code == 200 and end["decidedUnixMicros"] >= at else "fail"}


def reenable(mode, url, events, what):
    code, at, _, clock = timed_put(mode, STEWARD, url, terms(True))
    events.add("re-enable sent", STEWARD, 0, f"{what}: http {code}", at=at, clock=clock)
    if code != 200:
        raise Failed(f"{what}: re-enable http {code}")
    return at


def trials(mode, count, orchestrator, events, state_class, alive, dead, end_match, end_s, after=None):
    relation = e1.seeded_relation(STEWARD)
    url = f"{orchestrator}/api/v1/policyEnforcer"
    rows = []
    for number in range(1, count + 1):
        for attempt in range(1, TRIAL_TRIES + 1):
            began = reenable(mode, url, events, f"trial {number}")
            pod = alive()
            try:
                allowed = first(STEWARD, pod["name"], began, ALLOW_S, probe(state_class, relation, "write", "ALLOW"),
                                f"trial {number}: write ALLOW of {state_class} after the re-enable")
            except Failed as error:
                if attempt < TRIAL_TRIES and dead():
                    events.add("trial repeated", STEWARD, 0, f"trial {number}: the chain died before the write ALLOW "
                               f"after the re-enable, so the time to it is not measurable: {error}")
                    continue
                raise
            time.sleep(SETTLE_S)
            sent = timed_put(mode, STEWARD, url, terms(False))
            events.add("flip sent", STEWARD, sent[2] - sent[1], f"trial {number}: http {sent[0]}; time is the send",
                       at=sent[1], clock=sent[3])
            if sent[0] != 200:
                raise Failed(f"trial {number}: flip http {sent[0]}")
            try:
                end = first(STEWARD, pod["name"], sent[1], end_s, end_match(relation),
                            f"trial {number}: the end record of {state_class} after the flip's send")
            except Failed as error:
                if attempt < TRIAL_TRIES and dead():
                    events.add("trial repeated", STEWARD, 0, f"trial {number}: the chain died before its end: {error}")
                    continue
                raise
            break
        if after is not None:
            after(number, pod, end, relation)
        rows.append(trial_row(number, pod, began, allowed, sent, end, 0, mode))
    reenable(mode, url, events, "after the last trial")
    return rows


def denied(relation):
    return probe("e2_probe", relation, "write", "DENY")


def recheck(rows, found, state_class, end_match, relation):
    cases = []
    match, purge = end_match(relation), probe(state_class, relation, "purge", "PURGED")
    for index, row in enumerate(rows):
        upto = rows[index + 1]["reenable_us"] if index + 1 < len(rows) else None
        window = [record for record in found if record["decidedUnixMicros"] >= row["sent_us"]
                  and (upto is None or record["decidedUnixMicros"] < upto)]
        row["purge_records"] = sum(1 for record in window if purge(record))
        earliest = min((record["decidedUnixMicros"] for record in window if match(record)), default=None)
        ok = earliest == row["end_us"]
        if not ok:
            row["result"] = "fail"
        cases.append({"row": "complete log", "case": f"trial {row['trial']}", "steward": STEWARD,
                      "expected": "the end record read from the gateway's stdout is the first such record on the "
                                  "complete audit log", "observed": f"first on the audit log {earliest}, from stdout "
                                                                    f"{row['end_us']}", "result": "pass" if ok else "fail"})
    return cases


def conclude(out, arm, rows, name, extra):
    e1.write(out / f"trials-{arm}.csv", TRIAL_COLUMNS, rows)
    cases = [{"row": arm, "case": f"trial {row['trial']}", "steward": STEWARD,
              "expected": "the end record decided at or after the send, http 200, send and record on one machine",
              "observed": f"{row['end_op']}/{row['end_decision']} {int(row['value_us']) / 1000:.1f} ms after the send; "
                          f"clocks {row['machines']}", "result": row["result"]} for row in rows]
    return e1.conclude(out, cases + extra, None, name)


def serving_env(job, watch, poll_s):
    env = [{"name": "DATA_STEWARD_NAME", "value": STEWARD.upper()}, {"name": "REQUEST_USER", "value": cluster.USER},
           {"name": "REQUEST_TYPE", "value": cluster.REQUEST_TYPE}, {"name": "JOB_NAME", "value": job},
           {"name": "LOCAL_JOB_NAME", "value": job}, {"name": "GATEWAY_PORT", "value": str(PORT)}]
    gateway = env + [{"name": "STATE_DIR", "value": "/state"},
                     {"name": "AGREEMENT_POLL_INTERVAL_SECONDS", "value": str(poll_s)}]
    if not watch:
        gateway.append({"name": "AGREEMENT_WATCH_DISABLED", "value": "true"})
    return gateway, env


def standalone(mode, job, watch, poll_s, events):
    gateway, writer = serving_env(job, watch, poll_s)
    spec = {
        "restartPolicy": "Never",
        "containers": [
            {"name": checks.GATEWAY, "image": cluster.image(mode, checks.GATEWAY), "imagePullPolicy": "IfNotPresent",
             "command": [f"/app/{checks.GATEWAY}"], "env": gateway,
             "volumeMounts": [{"name": "state", "mountPath": "/state"}]},
            {"name": "writer", "image": cluster.image(mode, WRITER_IMAGE), "imagePullPolicy": "IfNotPresent",
             "command": ["python3", "-c", "import time; time.sleep(86400)"], "env": writer,
             "volumeMounts": [{"name": "state", "mountPath": "/state", "readOnly": True}]},
        ],
        "volumes": [{"name": "state", "emptyDir": {}}],
    }
    if mode == "fabric":
        spec["nodeSelector"] = {"kubernetes.io/hostname": STEWARD}
    manifest = {"apiVersion": "v1", "kind": "Pod", "metadata": {"name": checks.STANDALONE, "namespace": STEWARD},
                "spec": spec}
    kubectl("apply", "-f", "-", stdin=json.dumps(manifest))
    cluster.until(f"pod/{checks.STANDALONE} serving", 180, lambda: kjson(
        "-n", STEWARD, "get", "pod", checks.STANDALONE)["status"].get("phase") == "Running" and f"Serving on {PORT}" in
        kubectl("-n", STEWARD, "logs", checks.STANDALONE, "-c", checks.GATEWAY))
    node = kjson("-n", STEWARD, "get", "pod", checks.STANDALONE)["spec"].get("nodeName", "")
    events.add("standalone gateway up", STEWARD, 0, f"pod/{checks.STANDALONE}, serving form as {job}, watch "
               f"{'on' if watch else 'off'}, poll {poll_s} s, emptyDir state, on {node}")
    return {"name": checks.STANDALONE, "node": node}


def audit_of(pod):
    return records.parse(kubectl("-n", STEWARD, "exec", pod["name"], "-c", "writer", "--", "cat",
                                 "/state/audit/audit.log", timeout=120))


def standalone_arm(args, out, arm, job, watch, poll_s, state_class, end_match, end_s, name, after=None):
    mode = args.mode
    writer, rows, extra = None, [], []
    try:
        with collect.Unit(mode, out) as unit:
            events = e1.start(mode, out, unit)
            pod = standalone(mode, job, watch, poll_s, events)
            try:
                writer = Writer(STEWARD, pod["name"], "writer", state_class, args.cadence_ms, args.lifetime,
                                out / "raw" / "writer.log")

                def alive():
                    if not writer.alive():
                        raise Failed(f"the writer in pod/{pod['name']} ended: {writer.log.read_text()[-300:]}")
                    return pod

                with cluster.service(mode, "orchestrator") as orchestrator:
                    rows = trials(mode, args.trials, orchestrator, events, state_class, alive, lambda: False,
                                  end_match, end_s, after)
            finally:
                if writer is not None:
                    writer.stop()
                try:
                    found, unread = audit_of(pod), None
                except Failed as error:
                    found, unread = [], error
                if any(record.get("relationId") == collect.GUID for record in found):
                    unit.guid.append(f"{STEWARD}/pod/{pod['name']}")
                e1.write(out / "records.csv", e1.RECORD_COLUMNS,
                         [e1.record_row(STEWARD, pod["node"], record) for record in found])
            if unread is not None:
                raise Failed(f"the standalone pod's audit log: {unread}")
            extra = recheck(rows, found, state_class, end_match, e1.seeded_relation(STEWARD))
    finally:
        e1.drop_standalone(STEWARD)
    return conclude(out, arm, rows, name, extra)


def chain_pod():
    for pod in reset.chain_pods(STEWARD):
        if pod["metadata"].get("deletionTimestamp") or pod["status"].get("phase") != "Running":
            continue
        running = {s["name"] for s in pod["status"].get("containerStatuses") or [] if "running" in s.get("state", {})}
        if {checks.GATEWAY, SERVICE} <= running:
            return {"name": pod["metadata"]["name"], "node": pod["spec"].get("nodeName", "")}
    return None


def serving(pod):
    try:
        return "Serving on" in kubectl("-n", STEWARD, "logs", pod["name"], "-c", checks.GATEWAY)
    except Failed:
        return False


def boot(mode, api, rounds, events):
    request = reset.trigger(api, rounds, events)
    try:
        pod = cluster.until(f"request {request}: server's chain pod serving", UP_S[mode],
                            lambda: (found := chain_pod()) and serving(found) and found, every=3)
    except Failed:
        lost = reset.raced()
        if lost and e4.status(api, request).get("status") == "pending":
            raise cluster.Void(f"void R9: start race: 'Could not connect with gRPC localhost:<port> after 7 tries' "
                               f"in a chain pod of {' '.join(lost)}, request {request} still pending and not "
                               f"serving") from None
        raise
    events.add("chain up", STEWARD, 0, f"request {request}, {rounds} rounds, pod/{pod['name']} on {pod['node']}")
    return pod


def watch(args, out):
    mode = args.mode
    state = {"pod": None, "writer": None, "boots": 0}

    def dead():
        return (state["pod"] is None or not state["writer"].alive() or chain_pod() != state["pod"])

    with collect.Unit(mode, out) as unit:
        events = e1.start(mode, out, unit)
        try:
            with cluster.service(mode, "api-gateway") as api:

                def alive():
                    pod, writer = state["pod"], state["writer"]
                    if not dead():
                        return pod
                    if pod is not None:
                        events.add("chain death", STEWARD, 0, f"pod/{pod['name']}: "
                                   f"{'the writer ended' if not writer.alive() else 'no longer running and serving'}")
                        writer.stop()
                    state["pod"] = pod = boot(mode, api, args.rounds, events)
                    state["boots"] += 1
                    state["writer"] = Writer(STEWARD, pod["name"], SERVICE, "e2_probe", args.cadence_ms, args.lifetime,
                                             out / "raw" / f"writer-{state['boots']}.log")
                    return pod

                with cluster.service(mode, "orchestrator") as orchestrator:
                    rows = trials(mode, args.trials, orchestrator, events, "e2_probe", alive, dead, denied,
                                  DENY_S["watch"], restarted(args, events) or ending(args, events))
        finally:
            if state["writer"] is not None:
                state["writer"].stop()
            events.add("chain boots", STEWARD, 0, f"{state['boots']} for {args.trials} trials")
            reset.clear_jobs()
        node, found = e1.claim_records(unit, STEWARD)
        e1.write(out / "records.csv", e1.RECORD_COLUMNS, [e1.record_row(STEWARD, node, record) for record in found])
        extra = recheck(rows, found, "e2_probe", denied, e1.seeded_relation(STEWARD))
        if args.chain_end_after_trial is not None and "the chain died before the write ALLOW" not in events.path.read_text():
            raise Failed(f"the chain's end after trial {args.chain_end_after_trial} led to no trial repeated after a "
                         f"missed ALLOW, so the repeat was not shown")
    return conclude(out, "watch", rows, "E2 watch", extra)


def restarted(args, events):
    if not args.restart_orchestrator:
        return None

    def restart(number, pod, end, relation):
        if number != 1:
            return
        kubectl("-n", "orchestrator", "rollout", "restart", "deployment/orchestrator")
        kubectl("-n", "orchestrator", "rollout", "status", "deployment/orchestrator", "--timeout=180s", timeout=200)
        events.add("orchestrator restarted", "orchestrator", 0, "p-restart: inside the unit, after trial 1")
    return restart


def ending(args, events):
    if args.chain_end_after_trial is None:
        return None

    def chain_end(number, pod, end, relation):
        if number != args.chain_end_after_trial:
            return
        shutdown = lambda record: record.get("op") == "shutdown"
        found = first(STEWARD, pod["name"], end["decidedUnixMicros"], CHAIN_END_S, shutdown,
                      f"after trial {number}: the chain's own end, a shutdown record of pod/{pod['name']}'s gateway")
        events.add("chain end awaited", STEWARD, 0, f"after trial {number}: pod/{pod['name']}'s gateway recorded its "
                   f"shutdown ({found.get('reason', '')}) after the job's last round", at=found["decidedUnixMicros"],
                   clock=f"gateway@{pod['node']}" if pod["node"] else "gateway")
    return chain_end


def poll(args, out):
    return standalone_arm(args, out, "poll", "e2-poll", False, args.poll, "e2_probe", denied, DENY_S["poll"], "E2 poll")


ARMS = {"watch": watch, "poll": poll}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("arm", choices=sorted(ARMS))
    parser.add_argument("--mode", choices=["kind", "fabric"], required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--trials", type=int, required=True)
    parser.add_argument("--rounds", type=int, default=1200)
    parser.add_argument("--poll", type=int, default=30)
    parser.add_argument("--cadence-ms", type=int, required=True)
    parser.add_argument("--lifetime", type=int, default=7200)
    forced = parser.add_mutually_exclusive_group()
    forced.add_argument("--restart-orchestrator", action="store_true")
    forced.add_argument("--chain-end-after-trial", type=int)
    args = parser.parse_args()
    if args.chain_end_after_trial is not None and (args.arm != "watch" or args.mode != "kind"
                                                   or not 1 <= args.chain_end_after_trial < args.trials):
        parser.error("--chain-end-after-trial goes with watch in kind mode only, before the last trial")
    out = pathlib.Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    try:
        cluster.guard(args.mode)
        return ARMS[args.arm](args, out)
    except cluster.Void as error:
        print(str(error), file=sys.stderr)
        return 3
    except (Failed, ValueError, KeyError, OSError) as error:
        print(f"e2 {args.arm}: {type(error).__name__}: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
