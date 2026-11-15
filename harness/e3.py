#!/usr/bin/env python3
import argparse
import decimal
import gzip
import json
import pathlib
import re
import sys
import time
import zlib

import checks
import cluster
import collect
import e1
import e4
import gates
import install
import records
import reset
from cluster import Failed, STEWARDS, kjson, kubectl

ORDERS = (("a", "b", "h", "c"), ("b", "c", "a", "h"), ("c", "h", "b", "a"), ("h", "a", "c", "b"))
MODES = {"a": "none", "b": "passthrough", "c": "none", "h": "store-only"}
NAMES = {"a": "no gateway", "b": "pass-through", "c": "full enforcement", "h": "store-only"}
GATED = ("vfl-train-model-demo", "vfl-train-demo")
RUN_DEADLINE_S = {"kind": 900, "fabric": 2700}
IDLE_WAIT_S = 120
IDLE_PASS_S = 35
NO_GATEWAY = "No policy gateway deployed (GATEWAY_PORT not set), continuing without one"
DIAL = "Gateway not ready at"
CONNECTED = "Successfully connected to gateway"
PASSTHROUGH = "Pass-through mode: decisions and audit only, state writes skipped"
STORE_ONLY = "Store-only mode: governance and audit skipped, state I/O only"
NOT_FOUND = "not found"
STARTED = re.compile(r"Running VFL for (\d+) rounds")
OPENED = re.compile(r"Running VFL training round (\d+)")
DISPATCH = "- Sending training request"
CLOSED = re.compile(r"- Intermediate accuracy achieved: (\S+) for round (\d+)")
SPAN = "Write timing"
ROUND_COLUMNS = ("quad", "position", "config", "request", "round", "clock", "opened_us", "dispatched_us", "closed_us",
                 "duration_us", "reverify_us", "train_us", "accuracy", "window")
WRITE_COLUMNS = ("quad", "position", "config", "steward", "write", "clock", "logged_us", "decide_us", "audit_us",
                 "persist_us", "total_us")


def service_of(steward):
    return "vfl-train-model-demo" if steward == "server" else "vfl-train-demo"


def zap(line):
    parts = line.split("\t")
    if len(parts) < 4:
        return None
    try:
        at = int((decimal.Decimal(parts[0]) * 1_000_000).to_integral_value())
    except decimal.InvalidOperation:
        return None
    return at, parts[3], parts[4] if len(parts) > 4 else ""


def metadata(name):
    return json.loads(reset.etcd(f"get /microservices/{name}/chainMetadata --print-value-only"))


def put_metadata(name, value):
    kubectl("exec", "-i", "-n", "core", "etcd-0", "-c", "etcd", "--", "sh", "-c",
            reset.ETCDCTL + f"put /microservices/{name}/chainMetadata", stdin=json.dumps(value, separators=(",", ":")))


def gateway_required():
    return [f"{name}: requiresGateway {metadata(name).get('requiresGateway')!r}, not true" for name in GATED
            if metadata(name).get("requiresGateway") is not True]


def drop_gateway(events):
    kept = {name: metadata(name) for name in GATED}
    try:
        for name, value in kept.items():
            put_metadata(name, {key: entry for key, entry in value.items() if key != "requiresGateway"})
        left = [name for name in GATED if "requiresGateway" in metadata(name)]
    except BaseException:
        restore(kept, events)
        raise
    if left:
        restore(kept, events)
        raise Failed(f"config a: requiresGateway still set on {' '.join(left)} after the put")
    events.add("config a: requiresGateway dropped", " ".join(GATED), 0, "the chain metadata in etcd, put back after the run")
    return kept


def restore(kept, events):
    for name, value in kept.items():
        put_metadata(name, value)
    wrong = [name for name, value in kept.items() if metadata(name) != value]
    if wrong:
        raise Failed(f"config a: the chain metadata of {' '.join(wrong)} not put back")
    events.add("config a: chain metadata put back", " ".join(GATED), 0, "")


def newest_chain_pod(steward):
    pods = [pod for pod in reset.chain_pods(steward) if not pod["metadata"]["name"].startswith("idle-")]
    if not pods:
        raise Failed(f"{steward}: no chain pod after the run")
    return max(pods, key=lambda pod: pod["metadata"]["creationTimestamp"])


def chain_view(steward, folder, gateway):
    if gateway:
        cluster.until(f"{steward}: the job's enforcement point ended", e1.FINISHED_S, lambda: e1.gateway_ended(steward))
    pod = newest_chain_pod(steward)
    name, node = pod["metadata"]["name"], pod["spec"].get("nodeName", "")
    containers = [container["name"] for container in pod["spec"]["containers"]]
    volumes = [volume["name"] for volume in pod["spec"].get("volumes", [])]
    logs = {}
    for container in [service_of(steward), *([checks.GATEWAY] if checks.GATEWAY in containers else [])]:
        logs[container] = kubectl("-n", steward, "logs", name, "-c", container, timeout=120)
        (folder / f"{steward}-{container}.log").write_text(logs[container])
    ended = e1.gateway_ended(steward) if gateway else None
    return {"pod": name, "node": node, "containers": containers, "volumes": volumes, "logs": logs, "ended": ended}


def api_gateway_pod():
    pods = [pod for pod in kjson("-n", "api-gateway", "get", "pods", "-l", "app=api-gateway")["items"]
            if not pod["metadata"].get("deletionTimestamp")]
    if len(pods) != 1:
        raise Failed(f"api-gateway: {len(pods)} pods, not 1")
    restarts = sum(status.get("restartCount", 0) for status in pods[0]["status"].get("containerStatuses") or [])
    return pods[0], (pods[0]["metadata"]["uid"], restarts)


def api_gateway_log(folder, identity):
    pod, now = api_gateway_pod()
    if now != identity:
        raise Failed(f"api-gateway: pod {identity[0]} with {identity[1]} restarts at the trigger, pod {now[0]} with "
                     f"{now[1]} restarts at the log's read")
    text = kubectl("-n", "api-gateway", "logs", pod["metadata"]["name"], "-c", "api-gateway", timeout=120)
    (folder / "api-gateway.log").write_text(text)
    return pod["spec"].get("nodeName", ""), text


def rounds_of(text, rounds, node, done, quad, position, config, request):
    lines = [found for line in text.splitlines() if (found := zap(line))]
    begun = [index for index, (_, message, _) in enumerate(lines) if (hit := STARTED.fullmatch(message))
             and int(hit.group(1)) == rounds]
    if not begun:
        raise Failed(f"config {config}: no 'Running VFL for {rounds} rounds' line in the api-gateway log")
    opened, dispatched, closed = {}, {}, {}
    current = None
    for at, message, _ in lines[begun[-1] + 1:]:
        if hit := OPENED.fullmatch(message):
            current = int(hit.group(1))
            opened.setdefault(current, at)
        elif message == DISPATCH and current is not None:
            dispatched.setdefault(current, at)
        elif hit := CLOSED.fullmatch(message):
            closed.setdefault(int(hit.group(2)), (at, hit.group(1)))
    rows = []
    for number in range(rounds):
        if number not in opened or number not in dispatched or number not in closed:
            raise Failed(f"config {config}: round {number} lacks a marker in the api-gateway log (open "
                         f"{number in opened}, dispatch {number in dispatched}, close {number in closed})")
        end, accuracy = closed[number]
        if number not in done or float(done[number]["accuracy"]) != float(accuracy):
            raise Failed(f"config {config}: round {number}'s accuracy in the api-gateway log, {accuracy}, is not the "
                         f"training status's {done.get(number, {}).get('accuracy')} for request {request}")
        rows.append({"quad": quad, "position": position, "config": config, "request": request, "round": number,
                     "clock": f"api-gateway@{node}" if node else "api-gateway", "opened_us": opened[number],
                     "dispatched_us": dispatched[number], "closed_us": end, "duration_us": end - opened[number],
                     "reverify_us": dispatched[number] - opened[number], "train_us": end - dispatched[number],
                     "accuracy": accuracy, "window": "yes" if number >= 1 else "no"})
    return rows


def spans(view, steward, quad, position, config):
    rows = []
    for line in view["logs"].get(checks.GATEWAY, "").splitlines():
        found = zap(line)
        if not found or found[1] != SPAN:
            continue
        fields = json.loads(found[2])
        rows.append({"quad": quad, "position": position, "config": config, "steward": steward, "write": len(rows),
                     "clock": f"gateway@{view['node']}" if view["node"] else "gateway", "logged_us": found[0],
                     "decide_us": fields["decideMicros"], "audit_us": fields["auditMicros"],
                     "persist_us": fields["persistMicros"], "total_us": fields["totalMicros"]})
    return rows


def harvested_log(folder, since_us):
    since = since_us // 1_000_000 * 1_000_000
    seen = set()
    for path in sorted(pathlib.Path(folder).iterdir()):
        if not path.is_file() or path.name.endswith(".tmp"):
            continue
        data = path.read_bytes()
        if path.name.endswith(".gz"):
            try:
                data = gzip.decompress(data)
            except (OSError, EOFError, zlib.error) as error:
                raise Failed(f"{path}: not a whole gzip file: {error}")
        seen.update(line for line in data.decode(errors="replace").split("\n")[:-1] if line)
    stamped = [(checks.cri_us(line), line) for line in seen]
    return "\n".join(line for at, line in sorted(item for item in stamped if item[0] is not None) if at >= since)


def whole_agent_log(unit, steward, since_us):
    pods = [pod for pod in kjson("-n", steward, "get", "pods", "-l", "type=agent")["items"]
            if not pod["metadata"].get("deletionTimestamp")]
    if not pods:
        raise Failed(f"{steward}: no agent pod")
    pod = max(pods, key=lambda pod: pod["metadata"]["creationTimestamp"])
    node = pod["spec"].get("nodeName", "")
    unit.harvest()
    folder = (unit.out / "raw" / "pods" / node / f"{steward}_{pod['metadata']['name']}_{pod['metadata']['uid']}"
              / steward)
    with unit.lock:
        if not folder.is_dir():
            raise Failed(f"{steward}: the agent {pod['metadata']['name']}'s log is not in the harvest at {folder}")
        return node, harvested_log(folder, since_us)


def handover(unit, steward, claim, since, events, config):
    node, text = whole_agent_log(unit, steward, since)
    lines = [line for line in text.splitlines() if (hit := e1.HANDED.search(line)) and hit.group(1) == claim]
    if len(lines) != 1:
        return f"{len(lines)} hand-over lines for {claim}, not 1"
    took = e1.duration_us(e1.HANDED.search(lines[0]).group(2))
    events.add(f"config {config}: hand-over", steward, took, f"logged by the agent for {claim}",
               at=checks.cri_us(lines[0]), clock=f"agent@{node}" if node else "agent")
    return ""


def idle_gap(steward, claim, ended, events, config):
    node, finished = ended
    deadline = finished + IDLE_WAIT_S * 1_000_000
    found = e1.idle_pod(steward, claim)
    while found is None and reset.micros() < deadline:
        time.sleep(1)
        found = e1.idle_pod(steward, claim)
    if found is None:
        return f"no idle process with its agreement loaded {IDLE_WAIT_S} s after the job's enforcement point ended"
    pod, loaded, began = found
    if pod["spec"].get("nodeName", "") != node:
        return (f"the idle pod {pod['metadata']['name']} on {pod['spec'].get('nodeName', '')}, the job's enforcement "
                f"point on {node}: the gap's two stamps on two machines")
    events.add(f"config {config}: idle gap", steward, loaded - finished,
               f"job's enforcement point ended (kubelet, whole seconds) to 'Agreement loaded' of {pod['metadata']['name']}"
               f" on {pod['spec'].get('nodeName', '')}; its container started {(began - finished) / 1e6:.0f} s after",
               at=finished, clock=f"kubelet@{node}" if node else "kubelet")
    return ""


def inspect_server(mode, folder):
    claims = reset.state_claims("server")
    if len(claims) != 1:
        raise Failed(f"server: {len(claims)} state claims after the run, not 1")
    target = folder / "claims" / "server"
    target.mkdir(parents=True)
    install.inspect(mode, "server", claims[0]["metadata"]["name"], target)
    node = (claims[0]["metadata"].get("annotations") or {}).get("volume.kubernetes.io/selected-node", "")
    found = records.parse((target / "audit.log").read_text())
    e1.write(folder / "records.csv", e1.RECORD_COLUMNS, [e1.record_row("server", node, record) for record in found])
    return found, e1.state_files((target / "files.sha256").read_text())


def judge(mode, config, views, found, files, writes, rounds, cases):
    def add(case, steward, expected, observed, ok):
        e1.add(cases, f"config {config}", case, steward, expected, observed, ok)

    gateway = config != "a"
    for steward, view in views.items():
        has = checks.GATEWAY in view["containers"] and "gateway-state" in view["volumes"]
        none = checks.GATEWAY not in view["containers"] and "gateway-state" not in view["volumes"]
        add("chain pod", steward, "the enforcement point and its state volume" if gateway else "neither",
            f"containers {' '.join(view['containers'])}; volumes {' '.join(view['volumes'])}", has if gateway else none)
        log = view["logs"][service_of(steward)]
        if gateway:
            add("connected", steward, f"'{CONNECTED}' in {service_of(steward)}",
                "present" if CONNECTED in log else "absent", CONNECTED in log)
            banner = view["logs"].get(checks.GATEWAY, "")
            wanted = {"b": PASSTHROUGH, "c": None, "h": STORE_ONLY}[config]
            shown = [text for text in (PASSTHROUGH, STORE_ONLY) if text in banner]
            add("mode banner", steward, f"'{wanted}'" if wanted else "no pass-through or store-only banner",
                "; ".join(shown) or "none", shown == ([wanted] if wanted else []))
            made = [row for row in writes if row["steward"] == steward]
            add("write spans", steward, f"{rounds} 'Write timing' spans" + {
                "b": ", each with no persist time", "c": "", "h": ", each with no decide and no audit time"}[config],
                f"{len(made)} spans; decide {sum(row['decide_us'] for row in made)} µs, audit "
                f"{sum(row['audit_us'] for row in made)} µs, persist {sum(row['persist_us'] for row in made)} µs in all",
                len(made) == rounds and all({"b": row["persist_us"] == 0, "c": True,
                                             "h": row["decide_us"] == 0 and row["audit_us"] == 0}[config]
                                            for row in made))
        else:
            add("no gateway", steward, f"'{NO_GATEWAY}' in {service_of(steward)}, and no '{DIAL}'",
                f"{'present' if NO_GATEWAY in log else 'absent'}; dial {'seen' if DIAL in log else 'not seen'}",
                NO_GATEWAY in log and DIAL not in log)
    if not gateway:
        left = {steward: len(reset.state_claims(steward)) for steward in STEWARDS}
        add("no state claim", "all", "no state claim in any steward namespace",
            ", ".join(f"{steward} {count}" for steward, count in left.items()), not any(left.values()))
        return
    written = [record for record in found if record.get("op") == "write" and records.job_of(record)]
    allowed = [record for record in written if record.get("decision") == "ALLOW"]
    read = next((record for record in found if record.get("op") == "read"), {})
    if config == "h":
        decided = [record for record in found if record.get("op") in ("read", "write")]
        add("no decision records", "server", "no read or write record", f"{len(decided)} read or write records",
            not decided)
    else:
        add("decisions recorded", "server", f"{rounds} write ALLOW records by the job, nothing else",
            f"{len(written)} write records, {len(allowed)} ALLOW", len(allowed) == len(written) == rounds)
        add("clean-slate read", "server", f"the first read record DENY '{NOT_FOUND}'",
            f"{read.get('decision', 'no read')} '{read.get('reason', '')}'",
            read.get("decision") == "DENY" and read.get("reason") == NOT_FOUND)
    add("state files", "server", "none" if config == "b" else "at least one", f"{len(files)} state files",
        not files if config == "b" else bool(files))
    if config in ("b", "h"):
        latest = max(view["ended"][1] for view in views.values())
        time.sleep(max(0, latest + IDLE_PASS_S * 1_000_000 - reset.micros()) / 1_000_000)
        idle = {steward: len(kjson("-n", steward, "get", "jobs", "-l", reset.IDLE)["items"]) for steward in STEWARDS}
        add("no idle job", "all", "no idle Job: the agents start none in this mode",
            ", ".join(f"{steward} {count}" for steward, count in idle.items()), not any(idle.values()))


def configuration(args, out, unit, events, position, config):
    mode, quad = args.mode, args.quad
    folder = out / "raw" / f"q{quad:02d}-{position}-{config}"
    folder.mkdir(parents=True)
    if position > 1 and (now := collect.orchestrator()) != unit.identity:
        raise cluster.Void(f"void R10: orchestrator restarted during the unit, before config {config}'s clean start: "
                           f"{collect.shown(unit.identity)} before, {collect.shown(now)} after")
    reset.clean_start(mode, events, gateway=MODES[config])
    unit.identity = collect.orchestrator()
    wrong = gateway_required()
    if wrong:
        raise Failed(f"clean start of config {config}: " + "; ".join(wrong))
    gates.run(mode, out, f"after config {config}'s clean start")
    unit.gated = True
    kept = drop_gateway(events) if config == "a" else None
    cases, problems = [], []
    try:
        with cluster.service(mode, "api-gateway") as api:
            since = reset.micros() - 5_000_000
            begun = reset.micros()
            _, serving = api_gateway_pod()
            request = reset.trigger(api, args.rounds, events)
            reset.wait_done(api, request, RUN_DEADLINE_S[mode])
            events.add(f"config {config}: run done", "api-gateway", reset.micros() - begun, f"request {request}")
            done = e4.results(api, request, args.rounds)
    finally:
        if kept is not None:
            restore(kept, events)
    views = {steward: chain_view(steward, folder, config != "a") for steward in STEWARDS}
    for steward, view in views.items():
        if any(record.get("relationId") == collect.GUID for record in records.parse(view["logs"].get(checks.GATEWAY, ""))):
            unit.guid.append(f"{steward}/{view['pod']} (config {config})")
    node, text = api_gateway_log(folder, serving)
    table = rounds_of(text, args.rounds, node, done, quad, position, config, request)
    writes = [row for steward, view in views.items() for row in spans(view, steward, quad, position, config)]
    found, files = [], []
    if config != "a":
        for steward in STEWARDS:
            claim = e1.only_claim(steward)["metadata"]["name"]
            problem = handover(unit, steward, claim, since, events, config)
            if not problem and config == "c":
                problem = idle_gap(steward, claim, views[steward]["ended"], events, config)
            if problem:
                problems.append((steward, problem))
        found, files = inspect_server(mode, folder)
    for steward, problem in problems:
        e1.add(cases, f"config {config}", "hand-over and idle gap" if config == "c" else "hand-over", steward,
               "one hand-over line from the agent" + (" and an idle process up after the job" if config == "c" else ""),
               problem, False)
    judge(mode, config, views, found, files, writes, args.rounds, cases)
    return table, writes, cases


def quad(args, out):
    if args.quad < 1:
        raise Failed(f"--quad {args.quad}: quadruplets count from 1")
    order = ORDERS[(args.quad - 1) % len(ORDERS)]
    table, writes, cases = [], [], []
    with collect.Unit(args.mode, out) as unit:
        events = reset.Events(out / "events.csv")
        events.add("quadruplet", f"q{args.quad:02d}", 0, f"Williams order {' '.join(order)}, {args.rounds} rounds each")
        try:
            for position, config in enumerate(order, start=1):
                rows, made, judged = configuration(args, out, unit, events, position, config)
                table += rows
                writes += made
                cases += judged
        finally:
            e1.write(out / "rounds.csv", ROUND_COLUMNS, table)
            e1.write(out / "writes.csv", WRITE_COLUMNS, writes)
            e1.write(out / "cases.csv", e1.CASE_COLUMNS, cases)
    failed = [entry for entry in cases if entry["result"] == "fail"]
    if failed:
        raise Failed(f"E3 q{args.quad:02d} failed: " + "; ".join(f"{entry['row']} {entry['case']} {entry['steward']}: "
                                                               f"{entry['observed']}" for entry in failed))
    for config in order:
        shown = sorted(row["duration_us"] for row in table if row["config"] == config and row["window"] == "yes")
        middle = shown[len(shown) // 2] / 1e3 if shown else 0
        print(f"config {config} ({NAMES[config]}): rounds 1 to {args.rounds - 1}, median {middle:.1f} ms")
    print(f"E3 q{args.quad:02d} passed: order {' '.join(order)}, {len(cases)} checks")
    return 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("case", choices=["quad"])
    parser.add_argument("--mode", choices=["kind", "fabric"], required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--quad", type=int, required=True)
    parser.add_argument("--rounds", type=int, default=50)
    args = parser.parse_args()
    out = pathlib.Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    try:
        if args.rounds < 2:
            raise Failed(f"--rounds {args.rounds}: the counted window starts at round 1")
        cluster.guard(args.mode)
        return quad(args, out)
    except cluster.Void as error:
        print(str(error), file=sys.stderr)
        return 3
    except (Failed, ValueError, KeyError) as error:
        print(f"e3 {args.case}: {type(error).__name__}: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
