#!/usr/bin/env python3
import argparse
import csv
import hashlib
import json
import os
import pathlib
import socket
import subprocess
import sys
import time

import cluster
import collect
import e1
import e2
import pins
import records
import reset
from cluster import Failed

CLASS = "e5_probe"
PURGE_S = 35
DENY_AFTER_S = 10
ETCD_PORT = 30005
LOCAL_PORT = 50061
LOCAL_POLL_S = 5
MAX_STALE_S = 20
RECOVERY_STOP_S = 120
FORWARD_UP_S = 20
LOCAL_UP_S = 30
JOB = "e5-staleness"
BUILD = ("go", "build", "-tags", "local", "-trimpath", "-o")
BUILD_COLUMNS = ("head", "go_tree", "set_commit", "set_go_tree", "command", "go_version", "sha256")
EPISODE_COLUMNS = ("episode", "clock", "baseline_us", "outage_us", "stale_us", "stale_cache_age_ms", "flip_sent_us",
                   "held_until_us", "recovery_us", "purge_us", "value_us", "purge_source", "blob_after_hold",
                   "blob_after_purge", "machines", "result")


def purged(relation):
    return e2.probe(CLASS, relation, "purge", "PURGED")


def deny_after(number, pod, end, relation):
    e2.first(e2.STEWARD, pod["name"], end["decidedUnixMicros"], DENY_AFTER_S, e2.probe(CLASS, relation, "write", "DENY"),
             f"trial {number}: a write DENY of {CLASS} after the PURGED record")


def latency(args, out):
    return e2.standalone_arm(args, out, "latency", "e5-latency", True, 30, CLASS, purged, PURGE_S, "E5 latency",
                             deny_after)


def poll(args, out):
    return e2.standalone_arm(args, out, "poll", "e5-poll", False, args.poll, CLASS, purged, PURGE_S, "E5 poll control",
                             deny_after)


def git(*argv):
    return cluster.run(["git", "-C", str(cluster.ROOT), *argv]).strip()


def set_tag():
    tag = {row["tag"] for row in pins.load(pins.DEFAULT)}
    if len(tag) != 1:
        raise Failed(f"pins.csv names {len(tag)} tags, not one")
    return tag.pop().removeprefix("stay-up-")


def build(folder):
    folder = pathlib.Path(folder)
    folder.mkdir(parents=True, exist_ok=True)
    binary = folder / "gw"
    commit = git("rev-parse", set_tag() + "^{commit}")
    row = {"head": git("rev-parse", "HEAD"), "go_tree": git("rev-parse", "HEAD:go"), "set_commit": commit,
           "set_go_tree": git("rev-parse", f"{commit}:go")}
    if row["go_tree"] != row["set_go_tree"]:
        raise Failed(f"go/ at HEAD {row['go_tree']} is not go/ of the set's commit {commit}: {row['set_go_tree']}")
    changed = git("status", "--porcelain", "--", "go")
    if changed:
        raise Failed(f"go/ has changes not committed, the build would not be the set's: {changed[:200]}")
    command = [*BUILD, str(binary), "./cmd/policy-checkpoint-gateway"]
    environment = {**os.environ, "CGO_ENABLED": "0", "GOOS": "linux", "GOARCH": "amd64"}
    try:
        done = subprocess.run(command, cwd=cluster.ROOT / "go", env=environment, capture_output=True, text=True,
                              timeout=600)
    except subprocess.TimeoutExpired:
        raise Failed("build: not done within 600 s") from None
    if done.returncode != 0:
        raise Failed(f"build: exit {done.returncode}: {' '.join(done.stderr.split())[-400:]}")
    row.update(command="CGO_ENABLED=0 GOOS=linux GOARCH=amd64 " + " ".join(command[:-2]) + " gw " + command[-1],
               go_version=cluster.run(["go", "version"]).strip(),
               sha256=hashlib.sha256(binary.read_bytes()).hexdigest())
    e1.write(folder / "build.csv", BUILD_COLUMNS, [row])
    return binary


def built(binary):
    binary = pathlib.Path(binary).expanduser()
    rows = list(csv.DictReader((binary.parent / "build.csv").read_text().splitlines()))
    if len(rows) != 1:
        raise Failed(f"{binary.parent / 'build.csv'}: {len(rows)} rows, not 1")
    got = hashlib.sha256(binary.read_bytes()).hexdigest()
    if got != rows[0]["sha256"]:
        raise Failed(f"{binary}: sha256 {got}, build.csv says {rows[0]['sha256']}")
    if not rows[0]["set_commit"].startswith(set_tag()):
        raise Failed(f"{binary}: built for {rows[0]['set_commit']}, pins.csv is the set stay-up-{set_tag()}")
    return binary, rows[0]


class Forward:
    def __init__(self):
        if cluster.listening(ETCD_PORT):
            raise Failed(f"local port {ETCD_PORT} is already in use")
        self.process = subprocess.Popen(["kubectl", "-n", "core", "port-forward", "pod/etcd-0", f"{ETCD_PORT}:2379"],
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            cluster.until(f"etcd forward on {ETCD_PORT}", FORWARD_UP_S,
                          lambda: cluster.listening(ETCD_PORT) or self.process.poll() is not None, every=0.2)
            if self.process.poll() is not None:
                raise Failed(f"etcd forward on {ETCD_PORT} ended with exit {self.process.returncode}")
        except Failed:
            self.stop()
            raise

    def stop(self):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        cluster.until(f"etcd forward on {ETCD_PORT} closed", 10, lambda: not cluster.listening(ETCD_PORT), every=0.2)


class Local:
    def __init__(self, binary, folder):
        if cluster.listening(LOCAL_PORT):
            raise Failed(f"local port {LOCAL_PORT} is already in use")
        self.state = folder / "state"
        self.state.mkdir(parents=True)
        self.log = folder / "gw.log"
        self.handle = open(self.log, "w")
        environment = {**os.environ, "DATA_STEWARD_NAME": e2.STEWARD.upper(), "REQUEST_USER": cluster.USER,
                       "REQUEST_TYPE": cluster.REQUEST_TYPE, "JOB_NAME": JOB, "LOCAL_JOB_NAME": JOB,
                       "GATEWAY_PORT": str(LOCAL_PORT), "STATE_DIR": str(self.state),
                       "AGREEMENT_POLL_INTERVAL_SECONDS": str(LOCAL_POLL_S), "AGREEMENT_WATCH_DISABLED": "true",
                       "MAX_AGREEMENT_STALENESS_SECONDS": str(MAX_STALE_S)}
        self.process = subprocess.Popen([str(binary)], env=environment, stdout=self.handle, stderr=subprocess.STDOUT)
        try:
            cluster.until(f"local gateway serving on {LOCAL_PORT}", LOCAL_UP_S,
                          lambda: f"Serving on {LOCAL_PORT}" in self.log.read_text() or self.process.poll() is not None,
                          every=0.5)
            if self.process.poll() is not None:
                raise Failed(f"local gateway ended with exit {self.process.returncode}: {self.log.read_text()[-300:]}")
        except Failed:
            self.stop()
            raise

    def records(self):
        path = self.state / "audit" / "audit.log"
        return records.parse(path.read_text()) if path.is_file() else []

    def blobs(self):
        return sorted(str(path.relative_to(self.state)) for path in (self.state / "data").rglob("*") if path.is_file())

    def write(self):
        payload = json.dumps({"identity": {"steward": e2.STEWARD.upper(), "user": cluster.USER,
                                           "request_type": cluster.REQUEST_TYPE, "job_id": JOB, "local_job_name": JOB},
                              "state_key": "probe", "state_class": CLASS, "payload": "AQID"})
        before = reset.micros()
        cluster.run(["grpcurl", "-plaintext", "-import-path", str(cluster.ROOT / "proto-files"), "-proto",
                     "policyCheckpointGateway.proto", "-d", payload, f"localhost:{LOCAL_PORT}",
                     "dynamos.PolicyCheckpointGateway/RequestStateWrite"], timeout=30)
        found = [record for record in records.since(self.records(), before, "write")
                 if record.get("stateClass") == CLASS]
        if not found:
            raise Failed("local gateway: no write record for the probe write")
        return found[-1]

    def stop(self):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        self.handle.close()
        cluster.until(f"local gateway on {LOCAL_PORT} closed", 10, lambda: not cluster.listening(LOCAL_PORT), every=0.2)


def until_record(local, since_us, seconds, match, what):
    return cluster.until(what, seconds, lambda: next((record for record in records.since(local.records(), since_us)
                                                      if match(record)), None), every=0.2)


def episode(mode, number, binary, orchestrator, folder, events, found):
    url = f"{orchestrator}/api/v1/policyEnforcer"
    clock = f"host@{socket.gethostname()}"
    forward = local = None
    try:
        forward = Forward()
        code, _, _, sender = e2.timed_put(mode, "control", url, e2.terms(True))
        if code != 200:
            raise Failed(f"episode {number}: seed http {code}")
        local = Local(binary, folder)
        baseline = local.write()
        if baseline.get("decision") != "ALLOW" or not local.blobs():
            raise Failed(f"episode {number}: baseline write {baseline.get('decision')}, blobs {local.blobs()}")
        outage = reset.micros()
        forward.stop()
        events.add("outage: etcd forward stopped", "local", 0, f"episode {number}", at=outage, clock=clock)
        stale = cluster.until(f"episode {number}: a write DENY on a stale view", MAX_STALE_S + LOCAL_POLL_S + 15,
                              lambda: (found := local.write()).get("decision") == "DENY"
                              and found.get("policySource") == "stale" and found, every=1)
        code, flip, _, _ = e2.timed_put(mode, "control", url, e2.terms(False))
        events.add("flip sent during the outage", "local", 0, f"episode {number}: http {code}", at=flip, clock=sender)
        if code != 200:
            raise Failed(f"episode {number}: flip http {code}")
        time.sleep(2 * LOCAL_POLL_S)
        held = reset.micros()
        kept = local.blobs()
        early = records.since(local.records(), 0, "purge") + records.since(local.records(), 0, "expired")
        if not kept or [record for record in early if record.get("decision") in ("PURGED", "DELETED")]:
            raise Failed(f"episode {number}: through the outage {len(kept)} blobs kept, "
                         f"{len(early)} purge or expiry records: destruction on a non-fresh view")
        recovery = reset.micros()
        forward = None
        forward = Forward()
        events.add("recovery: etcd forward relaunched", "local", reset.micros() - recovery,
                   f"episode {number}: time is the stamp before the relaunch", at=recovery, clock=clock)
        relation = e1.seeded_relation(e2.STEWARD)
        purge = until_record(local, recovery, RECOVERY_STOP_S, purged(relation),
                             f"episode {number}: the PURGED record after the recovery")
        time.sleep(1)
        left = local.blobs()
        end_clock = f"gateway@{socket.gethostname()}"
        shown, same = e1.machines(mode, clock, end_clock)
        ok = purge.get("policySource") == "fresh" and not left and same
        row = {"episode": number, "clock": clock, "baseline_us": baseline["decidedUnixMicros"], "outage_us": outage,
               "stale_us": stale["decidedUnixMicros"], "stale_cache_age_ms": stale.get("cacheAgeMs", ""),
               "flip_sent_us": flip, "held_until_us": held, "recovery_us": recovery,
               "purge_us": purge["decidedUnixMicros"], "value_us": purge["decidedUnixMicros"] - recovery,
               "purge_source": purge.get("policySource", ""), "blob_after_hold": len(kept),
               "blob_after_purge": len(left), "machines": shown, "result": "pass" if ok else "fail"}
        code, _, _, _ = e2.timed_put(mode, "control", url, e2.terms(True))
        events.add("re-enable sent", "local", 0, f"episode {number}: http {code}", clock=sender)
        if code != 200:
            raise Failed(f"episode {number}: re-enable http {code}")
        return row
    finally:
        if local is not None:
            found += local.records()
            local.stop()
        if forward is not None:
            forward.stop()


def staleness(args, out):
    mode, rows, cases, found = args.mode, [], [], []
    with collect.Unit(mode, out) as unit:
        events = e1.start(mode, out, unit)
        binary, row = built(args.binary) if args.binary else built(build(out / "raw" / "staleness"))
        e1.write(out / "build.csv", BUILD_COLUMNS, [row])
        try:
            with cluster.service(mode, "orchestrator") as orchestrator:
                for number in range(1, args.episodes + 1):
                    rows.append(episode(mode, number, binary, orchestrator,
                                        out / "raw" / "staleness" / f"episode{number}", events, found))
        finally:
            if any(record.get("relationId") == collect.GUID for record in found):
                unit.guid.append("the local gateway")
    e1.write(out / "episodes-staleness.csv", EPISODE_COLUMNS, rows)
    e1.write(out / "records.csv", e1.RECORD_COLUMNS,
             [e1.record_row(e2.STEWARD, "", record) | {"clock": f"gateway@{socket.gethostname()}"} for record in found])
    for row in rows:
        e1.add(cases, "staleness", f"episode {row['episode']}", "local",
               "a stale write DENY in the outage, nothing destroyed through it, one PURGED on a fresh view after the "
               "recovery, no blob left",
               f"PURGED {int(row['value_us']) / 1000:.1f} ms after the recovery stamp, {row['purge_source']}; "
               f"blobs {row['blob_after_hold']} after the hold, {row['blob_after_purge']} after the purge",
               row["result"] == "pass")
    return e1.conclude(out, cases, None, "E5 staleness")


ARMS = {"latency": latency, "poll": poll, "staleness": staleness}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("arm", choices=sorted([*ARMS, "build"]))
    parser.add_argument("--mode", choices=["kind", "fabric"])
    parser.add_argument("--out", required=True)
    parser.add_argument("--trials", type=int, default=0)
    parser.add_argument("--episodes", type=int, default=1)
    parser.add_argument("--poll", type=int, default=5)
    parser.add_argument("--cadence-ms", type=int, default=500)
    parser.add_argument("--lifetime", type=int, default=7200)
    parser.add_argument("--binary")
    args = parser.parse_args()
    out = pathlib.Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    try:
        if args.arm == "build":
            print(build(out))
            return 0
        if args.mode is None:
            raise Failed(f"{args.arm} needs --mode")
        cluster.guard(args.mode)
        return ARMS[args.arm](args, out)
    except cluster.Void as error:
        print(str(error), file=sys.stderr)
        return 3
    except (Failed, ValueError, KeyError, OSError) as error:
        print(f"e5 {args.arm}: {type(error).__name__}: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
