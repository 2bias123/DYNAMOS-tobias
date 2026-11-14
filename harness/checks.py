#!/usr/bin/env python3
import argparse
import csv
import datetime
import gzip
import pathlib
import re
import sys

import cluster
import install
from cluster import NOT_ON_KIND, STEWARDS

HARNESS = pathlib.Path(__file__).resolve().parent
SCHEMA = HARNESS / "schema.csv"
TYPES = ("int", "text")


def schema(path=SCHEMA):
    found = {}
    for number, row in enumerate(csv.DictReader(pathlib.Path(path).read_text().splitlines()), start=1):
        if row.get("type") not in TYPES or row.get("may_be_empty") not in ("yes", "no") or not row.get("column"):
            raise ValueError(f"{path}: row {number} is not file,column,{'|'.join(TYPES)},yes|no")
        found.setdefault(row["file"], {})[row["column"]] = (row["type"], row["may_be_empty"] == "yes")
    return found


def whole(value):
    return re.fullmatch(r"-?[0-9]+", value) is not None


def table(path):
    lines = pathlib.Path(path).read_text().splitlines()
    if lines and lines[0] == cluster.KIND_LINE:
        lines = lines[1:]
    parsed = list(csv.reader(lines))
    header = parsed[0] if parsed else []
    rows = []
    for fields in parsed[1:]:
        if not fields:
            rows.append(None)
            continue
        row = dict(zip(header, fields))
        if len(fields) > len(header):
            row[None] = fields[len(header):]
        rows.append(row)
    return header, rows


def problems_in(path, name, columns):
    if columns is None:
        return [f"not in schema {name}"]
    header, rows = table(path)
    problems = [f"not in schema {name}:{column}" for column in header if column not in columns]
    present = {column: kind for column, kind in columns.items() if column in header}
    problems += [f"missing value {name}:{column}:header" for column, (kind, may_be_empty) in columns.items()
                 if column not in header and not may_be_empty]
    for number, row in enumerate(rows, start=1):
        if row is None:
            problems.append(f"missing value {name}:*:{number} (an empty line)")
            continue
        if None in row:
            problems.append(f"not in schema {name}:a field beyond the header:{number}")
        for column, (kind, may_be_empty) in present.items():
            value = row.get(column)
            if value is None or value.strip() == "":
                if not may_be_empty:
                    problems.append(f"missing value {name}:{column}:{number}")
            elif kind == "int" and not whole(value):
                problems.append(f"missing value {name}:{column}:{number} (not an integer: {value!r})")
    return problems


def missing(folder, recursive=True, path=SCHEMA):
    known = schema(path)
    folder = pathlib.Path(folder)
    files = sorted(folder.rglob("*.csv") if recursive else folder.glob("*.csv"))
    problems = []
    for found in files:
        problems += problems_in(found, str(found.relative_to(folder)), known.get(found.name))
    return problems


MARKERS = (
    ("M1", "STATE_LOCK_NOT_ACQUIRED", "gateway"),
    ("M2", "IDLE_GATEWAY_NOT_STOPPED", "agent"),
    ("M3", "IDLE_GATEWAY_NOT_RUNNING", "agent"),
    ("M4", "No policy gateway reachable", "service"),
)
MARKER_COLUMNS = ("marker", "text", "where", "files", "lines", "hits", "first_hit")
GATEWAY = "policy-checkpoint-gateway"
CRI = re.compile(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(?:\.(\d+))?(Z|[+-]\d\d:\d\d) ")


def cri_us(line):
    found = CRI.match(line)
    if not found:
        return None
    zone = "+00:00" if found.group(3) == "Z" else found.group(3)
    whole = datetime.datetime.fromisoformat(found.group(1) + zone)
    return int(whole.timestamp()) * 1_000_000 + int((found.group(2) or "0").ljust(6, "0")[:6])


def log_lines(path):
    data = path.read_bytes()
    if path.name.endswith(".gz"):
        data = gzip.decompress(data)
    return data.decode(errors="replace").splitlines()


def where_of(namespace, container):
    if container == GATEWAY:
        return "gateway"
    if container == namespace:
        return "agent"
    if container.startswith("linkerd"):
        return None
    return "service"


def markers(folder, since_us, out=None):
    folder = pathlib.Path(folder)
    pods = list(csv.DictReader((folder / "pods.csv").read_text().splitlines()))
    chains = {row["uid"]: row["namespace"] for row in pods if row["class"] == "chain"}
    files = {"gateway": {}, "agent": {}, "service": {}}
    judged = set()
    for path in sorted((folder / "raw" / "pods").glob("*/*/*/*")):
        namespace = path.parent.parent.name.split("_", 1)[0]
        where = where_of(namespace, path.parent.name) if namespace in cluster.STEWARDS else None
        if path.is_file() and where:
            files[where].setdefault(namespace, []).append(path)
            if path.parent.parent.name.rsplit("_", 1)[-1] in chains:
                judged.add((namespace, where))
    unseen = [f"no agent log collected in {namespace}" for namespace in cluster.STEWARDS
              if namespace not in files["agent"]]
    unseen += [f"a chain pod ran in {namespace} but no {where} log of a chain pod was collected"
               for namespace in sorted(set(chains.values())) for where in ("gateway", "service")
               if (namespace, where) not in judged]
    rows, hit = [], []
    for marker, text, where in MARKERS:
        paths = [path for found in files[where].values() for path in found]
        lines = hits = 0
        first = ""
        for path in paths:
            for line in log_lines(path):
                stamp = cri_us(line)
                if stamp is not None and stamp < since_us:
                    continue
                lines += 1
                if text in line:
                    hits += 1
                    first = first or str(path.relative_to(folder))
        rows.append({"marker": marker, "text": text, "where": where, "files": len(paths), "lines": lines,
                     "hits": hits, "first_hit": first})
        if hits:
            hit.append(f"{marker} '{text}' {hits} lines, first in {first}")
    with open(pathlib.Path(out or folder) / "markers.csv", "w", newline="") as f:
        writer = csv.DictWriter(f, MARKER_COLUMNS, lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)
    reason = f"markers {' '.join(entry.split()[0] for entry in hit)} hit: {'; '.join(hit)}" if hit else ""
    return reason, unseen


ARTIFACTS = ("events.csv", "pods.csv", "claims.csv", "markers.csv", "verdict.csv", "env/clocks.csv", "env/gates.csv",
             "raw/listings/pods.json",
             "raw/listings/claims.json", "raw/listings/jobs.json", "raw/listings/events.json")


def artifacts(folder):
    folder = pathlib.Path(folder)
    problems = [f"artifact missing {name}" for name in ARTIFACTS if not (folder / name).is_file()]
    if not any(path.is_file() for path in (folder / "raw" / "pods").rglob("*")):
        problems.append("artifact missing raw/pods/: no pod log collected")
    clocks = folder / "env" / "clocks.csv"
    if clocks.is_file() and {row.get("when") for row in csv.DictReader(clocks.read_text().splitlines())} != {"before", "after"}:
        problems.append("artifact missing env/clocks.csv: not one set before and one after the unit")
    return problems


NAMESPACES = (*STEWARDS, "orchestrator", "api-gateway")
SAMPLER = "harness-e4-sampler"
STANDALONE = "harness-standalone"
POD_COLUMNS = ("namespace", "pod", "uid", "node", "class", "owner", "phase", "first_seen_us", "last_seen_us",
               "restarts", "images", "declared")
VERDICT_COLUMNS = ("namespace", "pod", "uid", "class", "check", "subject", "expected", "observed", "result")


def owner_of(meta):
    return next((f"{ref['kind']}/{ref['name']}" for ref in meta.get("ownerReferences", [])), "")


def deployment_of(owner):
    kind, _, name = owner.partition("/")
    return name.rsplit("-", 1)[0] if kind == "ReplicaSet" else ""


def pod_class(namespace, name, labels, owner):
    if namespace not in STEWARDS:
        return "request path" if (namespace, deployment_of(owner)) in cluster.PLACEMENT else "unclassed"
    if labels.get("type") == "agent" and deployment_of(owner) == namespace:
        return "agent"
    if labels.get("dynamos/gateway") == "idle" and owner.startswith(f"Job/idle-state-{namespace}-"):
        return "idle"
    job = owner.removeprefix("Job/") if owner.startswith("Job/") else "" if owner else labels.get("job-name", "")
    if labels.get("app") == namespace and job and not job.startswith("idle-"):
        return "chain"
    if name == install.INSPECTOR and not owner:
        return "inspector"
    if name == SAMPLER and not owner:
        return "sampler"
    if name == STANDALONE and not owner:
        return "standalone"
    return "unclassed"


def pod_row(pod):
    meta, status = pod["metadata"], pod["status"]
    owner = owner_of(meta)
    statuses = status.get("containerStatuses") or []
    started = {s["name"]: s.get("imageID", "") for key in ("initContainerStatuses", "containerStatuses")
               for s in status.get(key) or []}
    declared = [*(pod["spec"].get("initContainers") or []), *pod["spec"]["containers"]]
    return {
        "namespace": meta["namespace"], "pod": meta["name"], "uid": meta["uid"],
        "node": pod["spec"].get("nodeName", ""), "owner": owner, "phase": status.get("phase", ""),
        "class": pod_class(meta["namespace"], meta["name"], meta.get("labels") or {}, owner),
        "restarts": sum(s.get("restartCount", 0) for s in statuses),
        "images": " ".join(f"{c['name']}={started.get(c['name'], '')}" for c in declared),
        "declared": " ".join(f"{c['name']}={c['image']}" for c in declared),
    }


def placed(row):
    if row["class"] == "request path":
        return cluster.PLACEMENT[(row["namespace"], deployment_of(row["owner"]))]
    return row["namespace"]


def judge_image(identity, pinned, declared):
    name = cluster.parse_image(declared)[1]
    pin = pinned.get(name)
    if pin is None:
        return "a pinned image", f"{declared} running {identity}", False
    expected = f"{pin['repository']}@{pin['digest']}"
    return expected, identity, identity.removeprefix("docker.io/") == expected


def verdict(folder, mode, pinned):
    folder = pathlib.Path(folder)
    rows = []
    for pod in csv.DictReader((folder / "pods.csv").read_text().splitlines()):
        base = {key: pod[key] for key in ("namespace", "pod", "uid", "class")}
        known = pod["class"] != "unclassed"
        rows.append({**base, "check": "class", "subject": "-", "expected": "one of the classes",
                     "observed": pod["class"], "result": "pass" if known else "fail"})
        if known:
            want = placed(pod)
            rows.append({**base, "check": "node", "subject": "-", "expected": want, "observed": pod["node"] or "(none)",
                         "result": NOT_ON_KIND if mode == "kind" else "not scheduled" if not pod["node"]
                         else "pass" if pod["node"] == want else "fail"})
        declared = dict(entry.partition("=")[::2] for entry in pod["declared"].split())
        for entry in pod["images"].split():
            container, _, identity = entry.partition("=")
            if container.startswith("linkerd"):
                continue
            if not identity:
                rows.append({**base, "check": "digest", "subject": container, "expected": "an image ID",
                             "observed": "(none: the container was not seen started)", "result": "not started"})
                continue
            expected, observed, ok = judge_image(identity, pinned, declared.get(container, ""))
            rows.append({**base, "check": "digest", "subject": container, "expected": expected, "observed": observed,
                         "result": NOT_ON_KIND if mode == "kind" else "pass" if ok else "fail"})
    with open(folder / "verdict.csv", "w", newline="") as f:
        writer = csv.DictWriter(f, VERDICT_COLUMNS, lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)
    return [f"{row['check']} {row['namespace']}/{row['pod']}{' ' + row['subject'] if row['subject'] != '-' else ''}: "
            f"expected {row['expected']}, observed {row['observed']}" for row in rows if row["result"] == "fail"]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["missing", "artifacts", "markers"])
    parser.add_argument("folder")
    parser.add_argument("--schema", default=str(SCHEMA))
    parser.add_argument("--since-us", type=int, default=0)
    parser.add_argument("--out")
    args = parser.parse_args()
    if args.command == "markers":
        if not args.out:
            parser.error("markers needs --out")
        hit, unseen = markers(args.folder, args.since_us, args.out)
        problems = [hit] if hit else [f"markers not judged: {entry}" for entry in unseen]
    elif args.command == "missing":
        problems = missing(args.folder, path=args.schema)
    else:
        problems = artifacts(args.folder)
    for problem in problems:
        print(problem)
    if problems:
        print(problems[0], file=sys.stderr)
        return 1
    print(f"{args.command} check: nothing missing under {args.folder}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
