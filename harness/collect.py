import csv
import io
import itertools
import json
import pathlib
import tarfile
import threading

import checks
import cluster
import gates
import install
import records
import reset
import slicecheck
from checks import NAMESPACES, POD_COLUMNS, SAMPLER
from cluster import Failed, STEWARDS, Void, kjson

HARVEST_S = 5
GUID = "GUID"
CLAIM_COLUMNS = ("namespace", "claim", "phase", "selected_node", "stamped", "volume")
SNAPSHOT = ("cd /var/log/pods && set -- $(ls -d {globs} 2>/dev/null); [ $# -gt 0 ] || exit 0; "
            "tar --ignore-failed-read -cf - \"$@\"; s=$?; [ $s -le 1 ] || exit $s")


def write(path, columns, rows):
    with open(path, "w", newline="") as f:
        writer = csv.DictWriter(f, columns, lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)


def orchestrator():
    pods = kjson("-n", "orchestrator", "get", "pods", "-l", "app=orchestrator")["items"]
    return sorted((pod["metadata"]["uid"], sum(s.get("restartCount", 0) for s in pod["status"].get("containerStatuses", [])))
                  for pod in pods if not pod["metadata"].get("deletionTimestamp"))


def shown(identity):
    return ", ".join(f"pod {uid} restarts {restarts}" for uid, restarts in identity) or "no pod"


class Harvest:
    def __init__(self, mode, out):
        self.mode, self.out = mode, pathlib.Path(out)
        self.lock = threading.Lock()
        self.stop = threading.Event()
        self.seen, self.errors = {}, []
        self.thread = None

    def begin(self):
        self.nodes = {name: info["ip"] for name, info in cluster.nodes().items()}
        reset.before_deletion.append(self.harvest)
        self.thread = threading.Thread(target=self.loop, daemon=True)
        self.thread.start()

    def end(self):
        self.stop.set()
        self.thread.join(timeout=300)
        reset.before_deletion.remove(self.harvest)

    def finish(self):
        if self.thread is None:
            raise Failed("the harvest never started")
        self.end()
        self.harvest()
        write(self.out / "pods.csv", POD_COLUMNS, sorted(self.seen.values(), key=lambda row: row["first_seen_us"]))
        return len(self.errors)

    def loop(self):
        while not self.stop.wait(HARVEST_S):
            try:
                self.harvest()
            except Exception as error:
                self.errors.append(error)

    def snapshot(self, node, address):
        script = SNAPSHOT.format(globs=" ".join(f"{namespace}_*" for namespace in NAMESPACES))
        argv = (["docker", "exec", node, "sh", "-c", script] if self.mode == "kind"
                else cluster.on(address, ["sudo", "sh", "-c", script]))
        return cluster.run(argv, timeout=120, binary=True)

    def harvest(self):
        with self.lock:
            failed = []
            for step in (self.list_pods, *(lambda n=node, a=address: self.extract(n, self.snapshot(n, a))
                                           for node, address in self.nodes.items())):
                try:
                    step()
                except Failed as error:
                    failed.append(error)
            if failed:
                raise next((error for error in failed if isinstance(error, Void)), failed[0])

    def extract(self, node, data):
        if not data:
            return
        root = self.out / "raw" / "pods" / node
        with tarfile.open(fileobj=io.BytesIO(data), mode="r:") as tar:
            for member in tar:
                parts = pathlib.PurePosixPath(member.name).parts
                if not member.isfile() or not parts or ".." in parts or member.name.startswith("/"):
                    continue
                body = tar.extractfile(member).read()
                target = root.joinpath(*parts)
                if target.exists() and target.stat().st_size > len(body):
                    target.rename(next(aside for n in itertools.count(1)
                                       if not (aside := target.with_name(f"{target.name}.before-{n}")).exists()))
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(body)

    def list_pods(self):
        now = reset.micros()
        for pod in kjson("get", "pods", "-A")["items"]:
            if pod["metadata"]["namespace"] not in NAMESPACES:
                continue
            row = self.seen.setdefault(pod["metadata"]["uid"], {"first_seen_us": now})
            row.update({**checks.pod_row(pod), "last_seen_us": now})


class Unit(Harvest):
    def __init__(self, mode, out, seeded=True):
        super().__init__(mode, out)
        self.seeded = seeded
        self.guid, self.audited = [], set()
        self.gated = False

    def __enter__(self):
        self.start_us = reset.micros()
        (self.out / "env").mkdir(parents=True, exist_ok=True)
        self.clocks("before")
        self.identity = orchestrator()
        self.begin()
        return self

    def base(self):
        self.identity = orchestrator()
        gates.run(self.mode, self.out, "after the clean start")
        self.gated = True

    def clocks(self, when):
        wrong = [row for row in slicecheck.clocks(self.mode, when, self.out / "env") if row["result"] != "pass"]
        if wrong:
            raise Failed("clock probe " + "; ".join(f"{row['subject']}: {row['observed']}" for row in wrong))

    def audit(self, namespace, claim):
        folder = self.out / "raw" / "claims" / namespace / claim["metadata"]["name"]
        folder.mkdir(parents=True)
        install.inspect(self.mode, namespace, claim["metadata"]["name"], folder)
        self.audited.add((namespace, claim["metadata"]["name"]))
        found = records.parse((folder / "audit.log").read_text())
        if self.seeded and any(record.get("relationId") == GUID for record in found):
            self.guid.append(f"{namespace}/{claim['metadata']['name']}")
        node = (claim["metadata"].get("annotations") or {}).get("volume.kubernetes.io/selected-node", "")
        return node, found

    def audit_rest(self):
        for namespace in STEWARDS:
            for claim in reset.state_claims(namespace):
                if (namespace, claim["metadata"]["name"]) not in self.audited and claim["status"].get("phase") == "Bound":
                    self.audit(namespace, claim)

    def listings(self):
        folder = self.out / "raw" / "listings"
        folder.mkdir(parents=True, exist_ok=True)
        pods = [pod for pod in kjson("get", "pods", "-A")["items"] if pod["metadata"]["namespace"] in NAMESPACES]
        claims = [claim for namespace in STEWARDS for claim in kjson("-n", namespace, "get", "pvc")["items"]]
        jobs = [job for namespace in STEWARDS for job in kjson("-n", namespace, "get", "jobs")["items"]]
        events = {namespace: kjson("-n", namespace, "get", "events")["items"] for namespace in STEWARDS}
        for name, value in (("pods", pods), ("claims", claims), ("jobs", jobs), ("events", events),
                            ("volumes", kjson("get", "pv")["items"])):
            (folder / f"{name}.json").write_text(json.dumps(value, indent=1, sort_keys=True))
        write(self.out / "claims.csv", CLAIM_COLUMNS, [{
            "namespace": claim["metadata"]["namespace"], "claim": claim["metadata"]["name"],
            "phase": claim["status"].get("phase", ""),
            "selected_node": (claim["metadata"].get("annotations") or {}).get("volume.kubernetes.io/selected-node", ""),
            "stamped": "no" if install.stamp_missing(claim) else "yes", "volume": claim["spec"].get("volumeName", ""),
        } for claim in claims])

    def void_causes(self):
        found = []
        now = orchestrator()
        if now != self.identity:
            found.append(f"void R10: orchestrator restarted during the unit: {shown(self.identity)} before, "
                         f"{shown(now)} after")
        if self.guid:
            found.append(f"void R10: orchestrator restarted: records with relationId {GUID} in a seeded unit, "
                         f"on {' '.join(self.guid)}")
        for item in kjson("get", "nodes")["items"]:
            ready = next(c for c in item["status"]["conditions"] if c["type"] == "Ready")
            if ready["status"] != "True":
                raise Failed(f"node {item['metadata']['name']} is not Ready at the unit's end")
            if reset.stamp_us(ready["lastTransitionTime"]) >= self.start_us:
                found.append(f"void node: {item['metadata']['name']} was not Ready during the unit and is Ready "
                             f"again since {ready['lastTransitionTime']}")
        return found

    def __exit__(self, kind, error, trace):
        self.end()
        voids = [str(error)] if isinstance(error, Void) else []
        problems = []
        for what, action in (("final harvest", self.harvest), ("listings", self.listings),
                             ("claim audit logs", self.audit_rest), ("clocks after", lambda: self.clocks("after")),
                             ("void checks", lambda: voids.extend(self.void_causes()))):
            try:
                action()
            except Void as found:
                voids.append(str(found))
            except Exception as found:
                problems.append(f"{what}: {type(found).__name__}: {found}")
        write(self.out / "pods.csv", POD_COLUMNS, sorted(self.seen.values(), key=lambda row: row["first_seen_us"]))
        try:
            wrong = checks.verdict(self.out, self.mode, cluster.pinned())
        except (Exception, SystemExit) as found:
            wrong = []
            problems.append(f"verdict: {type(found).__name__}: {found}")
        voids += [str(found) for found in self.errors if isinstance(found, Void)]
        hit, unseen = checks.markers(self.out, self.start_us)
        if hit:
            raise Failed(hit + (f"; void causes as well, not taken: {'; '.join(voids)}" if voids else ""))
        if voids:
            raise Void(voids[0] + (f" (and {len(voids) - 1} more void causes)" if len(voids) > 1 else ""))
        problems += [f"harvest pass: {type(found).__name__}: {found}" for found in self.errors]
        if problems:
            raise Failed(f"collect: {problems[0]}" + (f" ({len(problems)} problems)" if len(problems) > 1 else ""))
        if wrong:
            raise Failed(f"verdict: {wrong[0]}" + (f" ({len(wrong)} rows fail, in verdict.csv)" if len(wrong) > 1 else ""))
        if unseen:
            raise Failed(f"markers not judged: {unseen[0]}")
        if error is not None:
            return False
        if not self.gated:
            raise Failed("gates not run: the unit did not call base() after its clean start")
        gaps = checks.artifacts(self.out)
        if gaps:
            raise Failed(f"{gaps[0]} ({len(gaps)} in all)")
        return False
