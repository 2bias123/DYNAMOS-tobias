import csv
import datetime
import json
import pathlib
import re
import socket
import time

import cluster
from cluster import Failed, STEWARDS, kjson, kubectl

SETTLE_S = 45
SEED_TRIES = 4
GAP_S = 30
CHAIN_GONE_S = 180
IDLE = "dynamos/gateway=idle"
CHAIN = "dynamos/gateway!=idle"
FIXTURE = "harness-fixture"
MODE_VARIABLES = ("GATEWAY_STORE_ONLY", "GATEWAY_PASSTHROUGH")
MODES = {"none": {}, "store-only": {"GATEWAY_STORE_ONLY": "true"}, "passthrough": {"GATEWAY_PASSTHROUGH": "true"}}
EVENT_COLUMNS = ("clock", "at_us", "event", "subject", "duration_us", "detail")
deletions = {}
before_deletion = []
runs = {}
FIELDS = ("allowed", "retentionSeconds", "resumeAllowed", "onRevocation")
ETCDCTL = "ETCDCTL_API=3 /usr/local/bin/etcdctl --endpoints=localhost:2379 "
RACE = re.compile(r"Could not connect with gRPC localhost:[0-9]+ after 7 tries")
SENDER = """import sys, urllib.error, urllib.request
request = urllib.request.Request(sys.argv[1], data=sys.stdin.buffer.read(), method="PUT",
                                 headers={"Content-Type": "application/json"})
try:
    print(urllib.request.urlopen(request, timeout=30).status)
except urllib.error.HTTPError as error:
    print(error.code)
"""
STAMPED = """import sys, time, urllib.error, urllib.request
request = urllib.request.Request(sys.argv[1], data=sys.stdin.buffer.read(), method="PUT",
                                 headers={"Content-Type": "application/json"})
sent = time.time_ns() // 1000
try:
    code = urllib.request.urlopen(request, timeout=30).status
except urllib.error.HTTPError as error:
    code = error.code
print(code, sent)
"""


def micros():
    return time.time_ns() // 1000


def stamp_us(text):
    return int(datetime.datetime.fromisoformat(text.replace("Z", "+00:00")).timestamp() * 1_000_000)


class Events:
    def __init__(self, path):
        self.path = pathlib.Path(path)
        if not self.path.exists():
            with open(self.path, "w", newline="") as f:
                csv.writer(f, lineterminator="\n").writerow(EVENT_COLUMNS)

    def add(self, event, subject, duration_us=0, detail="", at=None, clock=None):
        with open(self.path, "a", newline="") as f:
            csv.writer(f, lineterminator="\n").writerow(
                [clock or f"host@{socket.gethostname()}", micros() if at is None else at, event, subject,
                 int(duration_us), detail])


def etcd(command):
    return kubectl("exec", "-n", "core", "etcd-0", "-c", "etcd", "--", "sh", "-c", ETCDCTL + command)


def state_claims(namespace):
    return [
        claim for claim in kjson("-n", namespace, "get", "pvc")["items"]
        if claim["metadata"]["name"].startswith("state-") or claim["spec"].get("storageClassName") == "gateway-state"
    ]


def mounting(namespace):
    found = []
    for pod in kjson("-n", namespace, "get", "pods")["items"]:
        for volume in pod["spec"].get("volumes", []):
            if volume.get("persistentVolumeClaim", {}).get("claimName", "").startswith("state-"):
                found.append(f"pod/{pod['metadata']['name']}")
    return found


def leftovers(namespace):
    found = [f"job/{job['metadata']['name']}" for job in kjson("-n", namespace, "get", "jobs")["items"]]
    found += [f"pvc/{claim['metadata']['name']}" for claim in state_claims(namespace)]
    return found + mounting(namespace)


def strays(namespace):
    found = leftovers(namespace)
    found += [f"pod/{pod['metadata']['name']}" for pod in kjson("-n", namespace, "get", "pods")["items"]
              if pod["metadata"].get("labels", {}).get("type") != "agent" and f"pod/{pod['metadata']['name']}" not in found]
    return found


def harvest():
    for collect in before_deletion:
        collect()


def deleting(namespace):
    return {job["metadata"]["uid"] for job in kjson("-n", namespace, "get", "jobs")["items"]
            if job["metadata"].get("deletionTimestamp")}


def clear_jobs():
    harvest()
    began = micros()
    for selector in (IDLE, CHAIN):
        for namespace in STEWARDS:
            if selector == CHAIN:
                deletions[namespace] = micros()
            kubectl("-n", namespace, "delete", "jobs", "-l", selector, "--cascade=foreground", "--wait=false")
    doomed = {namespace: deleting(namespace) for namespace in STEWARDS}

    def gone():
        return all(not doomed[namespace] & {job["metadata"]["uid"] for job in kjson("-n", namespace, "get", "jobs")["items"]}
                   for namespace in STEWARDS)

    cluster.until("the deleted jobs of the four steward namespaces gone", 150, gone)
    etcd('del "/agents/jobs/" --prefix')
    return micros() - began


def agent_mode(steward):
    deployment = kjson("-n", steward, "get", "deployment", steward)
    agent = next((c for c in deployment["spec"]["template"]["spec"]["containers"] if c["name"] == steward), None)
    if agent is None:
        return f"unknown: no container {steward}"
    present = {e["name"]: e.get("value", "") for e in agent.get("env", []) if e["name"] in MODE_VARIABLES}
    return next((name for name, wanted in MODES.items() if wanted == present), f"unknown: {present}")


def set_mode(mode):
    wanted = MODES[mode]
    changed = [steward for steward in STEWARDS if agent_mode(steward) != mode]
    if changed:
        harvest()
    for steward in changed:
        settings = [f"{name}={wanted[name]}" if name in wanted else f"{name}-" for name in MODE_VARIABLES]
        kubectl("-n", steward, "set", "env", f"deployment/{steward}", "-c", steward, *settings)
    for steward in changed:
        kubectl("-n", steward, "rollout", "status", f"deployment/{steward}", "--timeout=180s", timeout=200)
    return changed


def clear_claims(names=None):
    for namespace in STEWARDS:
        found = [claim["metadata"]["name"] for claim in state_claims(namespace)]
        if names is not None:
            found = [name for name in found if (namespace, name) in names]
        if found:
            kubectl("-n", namespace, "delete", "pvc", *found, "--wait=true", "--timeout=120s", timeout=150)


def clean():
    clear_jobs()
    clear_claims()
    for namespace in STEWARDS:
        cluster.until(f"no job, state claim or pod on one left in {namespace}", 60,
                      lambda: not leftovers(namespace))


def rollouts():
    harvest()
    for namespace, name in cluster.REQUEST_PATH:
        kubectl("-n", namespace, "rollout", "restart", f"deployment/{name}")
    for namespace, name in cluster.REQUEST_PATH:
        kubectl("-n", namespace, "rollout", "status", f"deployment/{name}", "--timeout=180s", timeout=200)
    time.sleep(SETTLE_S)


def clean_start(mode, events, gateway="none", full=True):
    began = micros()
    jobs_us = clear_jobs()
    changed = set_mode(gateway)
    clear_claims()
    for namespace in STEWARDS:
        cluster.until(f"no job, state claim or pod on one left in {namespace}", 60, lambda: not leftovers(namespace))
    if full or changed:
        rollouts()
    with cluster.service(mode, "orchestrator") as orchestrator:
        seed(orchestrator)
    wrong = [f"{namespace}: {' '.join(found)}" for namespace in STEWARDS if (found := strays(namespace))]
    wrong += [f"{FIXTURE}: pod/{pod['metadata']['name']}" for pod in kjson("-n", FIXTURE, "get", "pods")["items"]]
    wrong += [f"{steward}: agent mode {got}, not {gateway}" for steward in STEWARDS
              if (got := agent_mode(steward)) != gateway]
    wrong += differing()
    events.add("clean start", "all", micros() - began,
               f"jobs of the four stewards deleted together in {jobs_us / 1e6:.1f} s; "
               f"agent mode {gateway}; agents switched: {' '.join(changed) or 'none'}; "
               f"{'with' if full or changed else 'without'} the seven rollouts;{'; '.join(wrong) or 'every check holds'}")
    if wrong:
        raise Failed("clean start: " + "; ".join(wrong))
    return full or bool(changed)


def deletion_began(namespace, jobs, pods):
    found = [(deletions[namespace], "the harness's deletion")] if namespace in deletions else []
    found += [(stamp_us(job["metadata"]["deletionTimestamp"]) + 1_000_000, f"job/{job['metadata']['name']} deletionTimestamp")
              for job in jobs if job["metadata"].get("deletionTimestamp")]
    for pod in pods:
        meta = pod["metadata"]
        if meta.get("deletionTimestamp"):
            began = stamp_us(meta["deletionTimestamp"]) - 1_000_000 * int(meta.get("deletionGracePeriodSeconds") or 0)
            found.append((began + 1_000_000, f"pod/{meta['name']} deletionTimestamp less its grace"))
        else:
            found.append((micros(), f"pod/{meta['name']} not yet deleting, seen"))
    return max(found, default=(None, "no earlier chain job seen"))


def gap(events):
    harvest()
    began = {}
    for namespace in STEWARDS:
        jobs = kjson("-n", namespace, "get", "jobs", "-l", CHAIN)["items"]
        standing = [job["metadata"]["name"] for job in jobs if not job["metadata"].get("deletionTimestamp")]
        if standing:
            deletions[namespace] = micros()
            kubectl("-n", namespace, "delete", "jobs", *standing, "--wait=false", "--ignore-not-found=true")
        events.add("deploy gap: chain jobs deleted", namespace, 0, " ".join(standing) or "none standing")
        began[namespace] = deletion_began(namespace, jobs, chain_pods(namespace))
    for namespace in STEWARDS:
        waiting = micros()
        cluster.until(f"deploy gap: chain jobs and pods gone in {namespace}", CHAIN_GONE_S,
                      lambda: not chain_pods(namespace) and not kjson("-n", namespace, "get", "jobs", "-l", CHAIN)["items"])
        events.add("deploy gap: chain pods gone", namespace, micros() - waiting, "")
        at, basis = began[namespace]
        hold = max(0, at + GAP_S * 1_000_000 - micros()) if at is not None else 0
        time.sleep(hold / 1_000_000)
        events.add("deploy gap: held", namespace, hold,
                   f"{GAP_S} s after {basis}" + (f" at {at}" if at is not None else ""))


def seed_file(steward):
    return cluster.ROOT / "configuration" / "etcd_launch_files" / f"state_aware_{steward}.json"


def terms(agreement):
    return {
        user: {"ID": relation.get("ID"), **{f: (relation.get("stateDirectives") or {}).get(f) for f in FIELDS}}
        for user, relation in agreement["relations"].items()
    }


def differing():
    found = []
    for steward in STEWARDS:
        want = terms(json.loads(seed_file(steward).read_text()))
        try:
            got = terms(json.loads(etcd(f"get /policyEnforcer/agreements/{steward} --print-value-only")))
        except (ValueError, KeyError, AttributeError, Failed) as error:
            got = f"unreadable: {error}"
        if got != want:
            found.append(f"{steward}: etcd {json.dumps(got, sort_keys=True)}, seed {json.dumps(want, sort_keys=True)}")
    return found


def put(target, url, body):
    answer = cluster.run(cluster.on(target, ["python3", "-c", SENDER, url]), stdin=body, timeout=60).strip()
    return int(answer) if answer.isdigit() else 0


def put_stamped(mode, vm, url, body):
    answer = cluster.run(cluster.on(cluster.host(mode, vm), ["python3", "-c", STAMPED, url]), stdin=body,
                         timeout=60).split()
    if len(answer) != 2 or not all(part.isdigit() for part in answer):
        raise Failed(f"stamped PUT from {vm}: the sender answered {' '.join(answer)!r}")
    clock = f"sender@{vm}" if mode == "fabric" else f"host@{socket.gethostname()}"
    return int(answer[0]), int(answer[1]), clock


def seed(orchestrator):
    wrong = []
    for _ in range(SEED_TRIES):
        wrong = []
        for steward in STEWARDS:
            code, _ = cluster.http("PUT", f"{orchestrator}/api/v1/policyEnforcer", seed_file(steward).read_bytes())
            if code != 200:
                wrong.append(f"{steward}: http {code}")
        wrong = wrong or differing()
        if not wrong:
            return
        time.sleep(5)
    raise Failed("seed: " + "; ".join(wrong))


def trigger(api, cycles, events):
    gap(events)
    body = {
        "type": cluster.REQUEST_TYPE,
        "user": {"id": "1234", "userName": cluster.USER},
        "dataProviders": list(STEWARDS),
        "data_request": {
            "type": cluster.REQUEST_TYPE,
            "data": {"learning_rate": 0.1, "cycles": cycles, "policy_removal": -1,
                     "policy_reintroduction": -1, "training_backtrack": 0},
            "requestMetadata": {},
        },
    }
    sent = micros()
    code, text = cluster.http("POST", f"{api}/api/v1/requestApproval", json.dumps(body).encode())
    try:
        request = json.loads(text)["request_id"]
    except (ValueError, KeyError, TypeError):
        raise Failed(f"trigger not accepted: http {code} {text[:300]}") from None
    events.add("trigger", "api-gateway", micros() - sent, f"request {request}, {cycles} rounds; time is the send",
               at=sent)
    runs[request] = events.path.parent
    return request


def chain_pods(namespace):
    return kjson("-n", namespace, "get", "pods", "-l", f"app={namespace},type!=agent")["items"]


def raced():
    hit = []
    for namespace in STEWARDS:
        for pod in chain_pods(namespace):
            try:
                log = kubectl("-n", namespace, "logs", pod["metadata"]["name"], "--all-containers")
            except Failed:
                continue
            if RACE.search(log):
                hit.append(namespace)
                break
    return hit


def keep(request, text):
    folder = runs.get(request)
    if folder is not None:
        (folder / f"status-{request}.json").write_text(text)


def wait_done(api, request, seconds):
    deadline = time.monotonic() + seconds
    state = ""
    while time.monotonic() < deadline:
        time.sleep(5)
        code, text = cluster.http("GET", f"{api}/api/v1/getTrainingStatus?id={request}")
        if code == 200:
            keep(request, text)
        try:
            state = json.loads(text).get("status", "")
        except (ValueError, AttributeError):
            state = ""
        if state == "done":
            return
        if state == "failed":
            raise Failed(f"run {request}: status failed: {text[:300]} (in full in status-{request}.json)")
    lost = raced()
    if lost and state == "pending":
        raise cluster.Void(f"void R9: start race: 'Could not connect with gRPC localhost:<port> after 7 tries' in a chain pod of {' '.join(lost)}, "
                           f"request {request} still pending after {seconds} s")
    race = f"; the start-race line is in a chain pod of {' '.join(lost)}" if lost else ""
    raise Failed(f"run {request}: status '{state}' after {seconds} s{race}")
