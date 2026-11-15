import argparse
import collections
import csv
import fcntl
import hashlib
import io
import json
import math
import os
import pathlib
import shlex
import signal
import socket
import subprocess
import sys
import time

import re
import shutil

import archives
import checks
import cluster
import summary

HARNESS = pathlib.Path(__file__).resolve().parent
COLUMNS = ("experiment", "unit", "host", "attempts", "expected_minutes", "arguments")
JOURNAL = ("experiment", "unit", "host", "attempt", "pgid", "clock", "start_us", "end_us", "outcome", "reason")
ARCHIVES = ("seq", "name", "unit", "attempt", "outcome", "bytes", "sha256", "made_us")
HOSTS = ("laptop", "control", "dynamos", *cluster.STEWARDS)
VMS = ("control", "dynamos", *cluster.STEWARDS)
DONE = ("pass", "expected failure seen")
EXPECTED = "expected_failure"
VOID_EXIT = 3
START_RACE = "void R9: start race"
IN_A_ROW = 3
FULL_SHAPE = "quad-01"
ELSEWHERE = "counted-elsewhere.csv"
ELSEWHERE_COLUMNS = ("unit", "run", "harness_commit")
HEX40 = re.compile(r"[0-9a-f]{40}")
LIMITS = {"HARNESS_FREE_GB": 20, "HARNESS_WAITING_MAX": 2, "HARNESS_PAUSE_S": 60, "HARNESS_DISK_STOP_S": 900}


class Refused(Exception):
    pass


def limit(name, mode):
    if mode == "kind" and os.environ.get(name):
        return float(os.environ[name])
    if mode == "kind" and name == "HARNESS_WAITING_MAX":
        return math.inf
    return LIMITS[name]


def micros():
    return time.time_ns() // 1000


def utc(us=None):
    seconds = time.time() if us is None else us / 1e6
    return time.strftime("%Y-%m-%d %H:%M:%S UTC", time.gmtime(seconds))


def sha256(path):
    return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()


def positive(text):
    try:
        return math.isfinite(float(text)) and float(text) > 0
    except ValueError:
        return False


def splits(text):
    try:
        shlex.split(text)
    except ValueError:
        return False
    return True


def read_queue(path):
    lines = pathlib.Path(path).read_text().splitlines()
    reader = csv.DictReader(lines)
    header = tuple(reader.fieldnames or ())
    if header not in (COLUMNS, (*COLUMNS, EXPECTED)):
        raise Refused(f"{path}: header {','.join(header)}, not {','.join(COLUMNS)}[,{EXPECTED}]")
    units = []
    for number, row in enumerate(reader, start=1):
        if None in row or any(row[c] is None for c in header):
            raise Refused(f"{path}: row {number} has not {len(header)} fields")
        problems = [
            *([f"unit {row['unit']!r} twice"] if any(u["unit"] == row["unit"] for u in units) else []),
            *([f"no program {row['experiment']}.py"] if not (HARNESS / f"{row['experiment']}.py").is_file() else []),
            *([f"host {row['host']!r} not one of {', '.join(HOSTS)}"] if row["host"] not in HOSTS else []),
            *([f"attempts {row['attempts']!r} not a whole number of 1 or more"]
              if not (checks.whole(row["attempts"]) and int(row["attempts"]) >= 1) else []),
            *([f"expected minutes {row['expected_minutes']!r} not a finite number above 0"]
              if not positive(row["expected_minutes"]) else []),
            *([f"arguments {row['arguments']!r} do not split into words"] if not splits(row["arguments"]) else []),
        ]
        if not row["unit"] or "/" in row["unit"] or not row["experiment"]:
            problems.append("empty or unusable unit or experiment name")
        if problems:
            raise Refused(f"{path}: row {number}: {'; '.join(problems)}")
        row.setdefault(EXPECTED, "")
        units.append(row)
    return units


def journal_rows(folder):
    lines = (folder / "units.csv").read_text().splitlines()
    if lines and lines[0] == cluster.KIND_LINE:
        lines = lines[1:]
    return list(csv.DictReader(lines))


def append(folder, row):
    text = io.StringIO()
    csv.DictWriter(text, JOURNAL, lineterminator="\n").writerow(row)
    fd = os.open(folder / "units.csv", os.O_WRONLY | os.O_APPEND)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        os.write(fd, text.getvalue().encode())
        os.fsync(fd)
    finally:
        os.close(fd)


def start_journal(folder, mode):
    head = io.StringIO()
    if mode == "kind":
        head.write(cluster.KIND_LINE + "\n")
    csv.DictWriter(head, JOURNAL, lineterminator="\n").writeheader()
    (folder / "units.csv").write_text(head.getvalue())


def arguments(unit, mode, out):
    return [part.replace("{out}", str(out)).replace("{mode}", mode) for part in shlex.split(unit["arguments"])]


def last_line(*paths):
    for path in paths:
        lines = [line for line in pathlib.Path(path).read_text(errors="replace").splitlines() if line.strip()]
        if lines:
            return lines[-1].strip()
    return ""


def watchdog_seconds(expected_minutes):
    return (2 * expected_minutes + 30) * 60


def supervise(argv, out, deadline_s, grace_s=30, began=None, counted="yes"):
    environment = {**os.environ, "HARNESS_DEADLINE_US": str(micros() + int(deadline_s * 1_000_000)),
                   "HARNESS_COUNTED": counted}
    with open(out / "stdout.log", "w") as stdout, open(out / "stderr.log", "w") as stderr:
        process = subprocess.Popen(argv, cwd=HARNESS, stdout=stdout, stderr=stderr, start_new_session=True,
                                   env=environment)
        if began:
            began(process.pid)
        try:
            return process.wait(timeout=deadline_s), process.pid
        except subprocess.TimeoutExpired:
            pass
        for signal_number in (signal.SIGTERM, signal.SIGKILL):
            try:
                os.killpg(process.pid, signal_number)
            except ProcessLookupError:
                break
            deadline = time.monotonic() + grace_s
            while alive(process.pid) and time.monotonic() < deadline:
                process.poll()
                time.sleep(0.2)
        process.poll()
        return None, process.pid


def attempt(folder, unit, number, mode):
    out = folder / unit["experiment"] / unit["unit"] / f"a{number}"
    out.mkdir(parents=True, exist_ok=False)
    argv = [sys.executable, str(HARNESS / f"{unit['experiment']}.py"), *arguments(unit, mode, out)]
    base = {"experiment": unit["experiment"], "unit": unit["unit"], "host": unit["host"], "attempt": number,
            "clock": f"host@{socket.gethostname()}", "start_us": micros()}
    deadline_s = watchdog_seconds(float(unit["expected_minutes"]))
    counted = json.loads((folder / "run.json").read_text())["counted"]
    code, pgid = supervise(argv, out, deadline_s, counted=counted, began=lambda pgid: append(
        folder, {**base, "pgid": pgid, "end_us": "", "outcome": "started", "reason": ""}))
    said = last_line(out / "stderr.log", out / "stdout.log")
    expected = unit[EXPECTED]
    if code is None:
        outcome, reason = "fail", (f"watchdog: no end within {deadline_s / 60:g} min; its process group got "
                                   f"SIGTERM, then SIGKILL")
    elif code == VOID_EXIT and expected and expected in said:
        outcome, reason = "expected failure seen", f"void, exit {code}: {said}"
    elif code == VOID_EXIT:
        outcome, reason = "void", said or "no cause given"
    elif expected and code == 0:
        outcome, reason = "fail", f"expected failure {expected!r} not seen: the unit passed"
    elif expected and expected in said:
        outcome, reason = "expected failure seen", f"exit {code}: {said}"
    elif expected:
        outcome, reason = "fail", f"expected failure {expected!r} not seen: exit {code}: {said}"
    elif code == 0:
        outcome, reason = "pass", ""
    else:
        outcome, reason = "fail", f"exit {code}: {said}"
    try:
        problems = checks.missing(out)
    except Exception as error:
        problems = [f"missing-value check could not read the folder: {type(error).__name__}: {error}"]
    if outcome == "pass" and problems:
        (out / "missing.txt").write_text("\n".join(problems) + "\n")
        outcome, reason = "fail", f"{problems[0]} ({len(problems)} in all, in missing.txt)"
    try:
        summary.write(out, unit["experiment"], unit["unit"], number, outcome, reason, problems, mode)
    except Exception as error:
        outcome, reason = "fail", f"SUMMARY.md not written: {type(error).__name__}: {error}"
        if expected and expected in reason:
            outcome = "expected failure seen"
    ended = micros()
    append(folder, {**base, "pgid": pgid, "end_us": ended, "outcome": outcome, "reason": reason})
    report(folder, "running")
    pack(folder, unit, number, outcome, base["start_us"], ended)
    return outcome, reason


def archive_rows(folder):
    path = folder / "archives.csv"
    return list(csv.DictReader(path.read_text().splitlines())) if path.exists() else []


def run_files(folder):
    entries = {"pins.csv": HARNESS / "pins.csv"}
    for name in ("units.csv", "RUN.md", "archives.csv", "queue.csv", "run.json", "STATUS"):
        if (folder / name).is_file():
            entries[name] = (folder / name).read_bytes()
    return entries


def pack(folder, unit, number, outcome, started, ended):
    outbox = folder / "outbox"
    outbox.mkdir(exist_ok=True)
    made = archive_rows(folder)
    seq = len(made) + 1
    if unit is None:
        name, label, attempt = f"{seq:03d}_close", "close", ""
    else:
        name, label, attempt = f"{seq:03d}_{unit['unit']}_a{number}", unit["unit"], str(number)
    entries = run_files(folder)
    if unit is not None:
        out = folder / unit["experiment"] / unit["unit"] / f"a{number}"
        for path in sorted(out.rglob("*")):
            if path.is_file() and not path.is_symlink():
                entries[f"{unit['experiment']}/{path.relative_to(out)}"] = path
    got = archives.pack(outbox, name, entries)
    row = {"seq": seq, "name": got["name"], "unit": label, "attempt": attempt or "close", "outcome": outcome,
           "bytes": got["bytes"], "sha256": got["sha256"], "made_us": micros()}
    text = io.StringIO()
    writer = csv.DictWriter(text, ARCHIVES, lineterminator="\n")
    if not (folder / "archives.csv").exists():
        writer.writeheader()
    writer.writerow(row)
    with open(folder / "archives.csv", "a") as f:
        f.write(text.getvalue())
        f.flush()
        os.fsync(f.fileno())
    print(f"archive {got['name']}: {got['members']} members, {got['bytes']} bytes, sha256 {got['sha256']}", flush=True)
    return row


def acknowledged(folder, row):
    ack = folder / "acked" / f"{row['name']}.ok"
    try:
        return ack.read_text().split()[0] == row["sha256"]
    except (OSError, IndexError):
        return False


def prune(folder):
    gone = []
    for row in archive_rows(folder):
        if row["attempt"] == "close" or not acknowledged(folder, row):
            continue
        unit = next((u for u in read_queue(folder / "queue.csv") if u["unit"] == row["unit"]), None)
        if unit is None:
            continue
        target = (folder / unit["experiment"] / unit["unit"] / f"a{row['attempt']}").resolve()
        if folder.resolve() not in target.parents or not target.is_dir():
            continue
        shutil.rmtree(target)
        gone.append(row["name"])
        with open(folder / "pruned.log", "a") as f:
            f.write(f"{utc()} pruned {target.relative_to(folder.resolve())} ({row['name']} acknowledged)\n")
    return gone


def free_gb(folder, mode):
    import gates
    found = {vm: None for vm in VMS}
    try:
        found["control"] = gates.free_bytes(None, str(folder))[0] // 10**9
    except (cluster.Failed, cluster.Void, OSError):
        pass
    if mode == "fabric":
        try:
            listed = cluster.nodes()
        except (cluster.Failed, cluster.Void, OSError):
            listed = {}
        for vm in VMS[1:]:
            if vm in listed:
                try:
                    found[vm] = gates.free_bytes(listed[vm]["ip"], "/")[0] // 10**9
                except (cluster.Failed, cluster.Void, OSError):
                    pass
    return found


def status(folder, units, state, free=None, mode="kind"):
    rows = journal_rows(folder)
    done = len({row["unit"] for row in rows if row["outcome"] in DONE})
    made = archive_rows(folder)
    pulled = sum(acknowledged(folder, row) for row in made)
    free = free if free is not None else free_gb(folder, mode)
    disk = " ".join(f"{vm} {free[vm] if free[vm] is not None else '?'}" for vm in VMS)
    line = (f"units {done}/{len(units)} · pulled {pulled} · waiting {len(made) - pulled} · free GB {disk} · "
            f"state={state}\n")
    temporary = folder / "STATUS.tmp"
    temporary.write_text(line)
    os.replace(temporary, folder / "STATUS")


def hold(folder, units, mode):
    low_since = None
    while True:
        prune(folder)
        made = archive_rows(folder)
        waiting = sum(not acknowledged(folder, row) for row in made)
        free = free_gb(folder, mode)
        low = [(vm, gb) for vm, gb in free.items() if gb is not None and gb < limit("HARNESS_FREE_GB", mode)]
        if waiting < limit("HARNESS_WAITING_MAX", mode) and not low:
            status(folder, units, "running", free)
            return None
        if (folder / "STOP").exists():
            return None
        if waiting >= limit("HARNESS_WAITING_MAX", mode):
            why = f"{waiting} archives waiting"
        else:
            why = f"disk {low[0][0]} {low[0][1]}"
        if waiting or not low:
            low_since = None
        else:
            low_since = low_since or time.monotonic()
            if time.monotonic() - low_since >= limit("HARNESS_DISK_STOP_S", mode):
                return why
        status(folder, units, f"paused:{why}", free)
        time.sleep(limit("HARNESS_PAUSE_S", mode))


def report(folder, state):
    meta = json.loads((folder / "run.json").read_text())
    rows = journal_rows(folder)
    lines = [cluster.KIND_LINE, ""] if meta["mode"] == "kind" else []
    lines += [
        "# Run", "",
        f"- queue: `{meta['queue']}`, sha256 `{meta['queue_sha256']}`, {meta['units']} units",
        f"- mode: {meta['mode']}; counted: {meta['counted']}",
        f"- started {utc(meta['started_us'])}; this file written {utc()} (this machine's clock)",
        f"- state: {state}", "",
        "| unit | experiment | host | attempts | outcome | reason | minutes |", "|---|---|---|---|---|---|---|",
    ]
    if meta["counted"] == "no (pilot)":
        try:
            shape = full_shape(meta["queue"])
        except (Refused, OSError, csv.Error, ValueError):
            shape = None
        if shape is not None:
            lines[-3:-3] = [f"- {FULL_SHAPE} runs with its row of queue.csv: {shape['arguments']} "
                            f"({shape['expected_minutes']} expected minutes), not with its row of this queue"]
    try:
        elsewhere = (counted_elsewhere(meta["queue"], read_queue(folder / "queue.csv")) if meta["counted"] == "yes"
                     else {})
    except (Refused, OSError, csv.Error, ValueError):
        elsewhere = {}
    for unit in read_queue(folder / "queue.csv"):
        mine = [row for row in rows if row["unit"] == unit["unit"]]
        ended = [row for row in mine if row["outcome"] != "started"]
        if not mine and unit["unit"] in elsewhere:
            where = elsewhere[unit["unit"]]
            lines.append(f"| {unit['unit']} | {unit['experiment']} | {unit['host']} | 0 | counted in {where['run']} at "
                         f"{where['harness_commit'][:7]} ({ELSEWHERE}), not started here | | |")
            continue
        if not mine:
            lines.append(f"| {unit['unit']} | {unit['experiment']} | {unit['host']} | 0 | not started | | |")
            continue
        last = ended[-1] if ended else mine[-1]
        minutes = (f"{(int(last['end_us']) - int(mine[0]['start_us'])) / 6e7:.1f}" if last["end_us"] else "")
        reason = last["reason"].replace("|", "\\|")
        lines.append(f"| {unit['unit']} | {unit['experiment']} | {unit['host']} | {len(ended) or 1} | "
                     f"{last['outcome']} | {reason} | {minutes} |")
    voided = [row for row in rows if row["outcome"] == "void"]
    lines += ["", f"## Voids: {len(voided)}", ""]
    causes = collections.Counter((row["unit"], row["reason"].split(":", 1)[0]) for row in voided)
    lines += [f"- {unit}: {count} × {cause}" for (unit, cause), count in causes.items()]
    ended = [row for row in rows if row["outcome"] not in ("started", "interrupted")]
    raced = sum(row["outcome"] == "void" and row["reason"].startswith(START_RACE) for row in rows)
    lines += ["", f"Start-race voids: {raced} of {len(ended)} ended attempts"]
    temporary = folder / "RUN.md.tmp"
    temporary.write_text("\n".join(lines) + "\n")
    os.replace(temporary, folder / "RUN.md")


def prepare(queue_path, folder, mode, counted):
    units = read_queue(queue_path)
    if folder.exists():
        other = sorted(path.name for path in folder.iterdir() if path.name != "STATUS")
        if other:
            raise Refused(f"{folder} exists without a journal and holds {', '.join(other[:5])}; only "
                          f"STATUS may be there before a run starts")
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "queue.csv").write_bytes(pathlib.Path(queue_path).read_bytes())
    (folder / "run.json").write_text(json.dumps({
        "queue": str(pathlib.Path(queue_path).resolve()), "queue_sha256": sha256(queue_path), "units": len(units),
        "mode": mode, "counted": counted, "started_us": micros()}, indent=1) + "\n")
    start_journal(folder, mode)
    (folder / "archives.csv").write_text(",".join(ARCHIVES) + "\n")
    return units


def alive(pgid):
    try:
        os.killpg(pgid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def lock(folder):
    fd = os.open(folder / "runner.lock", os.O_WRONLY | os.O_CREAT, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(fd)
        raise Refused(f"another runner holds {folder}") from None
    return fd


def unfinished(rows):
    ended = {(row["unit"], row["attempt"]) for row in rows if row["outcome"] != "started"}
    return [row for row in rows if row["outcome"] == "started" and (row["unit"], row["attempt"]) not in ended]


def reopen(queue_path, folder, mode, counted):
    meta = json.loads((folder / "run.json").read_text())
    if (meta["mode"], meta["counted"]) != (mode, counted):
        raise Refused(f"{folder} was started in mode {meta['mode']}, counted {meta['counted']}")
    if sha256(queue_path) != meta["queue_sha256"] or sha256(folder / "queue.csv") != meta["queue_sha256"]:
        raise Refused(f"the queue {queue_path} differs from the one {folder} started with")
    rows = journal_rows(folder)
    for row in unfinished(rows):
        if alive(int(row["pgid"])):
            raise Refused(f"unit {row['unit']} attempt {row['attempt']} is still running as process group "
                          f"{row['pgid']}; it is left alone")
    for row in unfinished(rows):
        append(folder, {**row, "end_us": "", "outcome": "interrupted",
                        "reason": f"the runner ended during this attempt; seen on resume at {utc()}"})
    return read_queue(folder / "queue.csv")


def short(text):
    return " ".join(text.split())[:300]


def close(folder, units, mode, state):
    began = micros()
    status(folder, units, state, mode=mode)
    pack(folder, None, None, state.split(":", 1)[0], began, micros())
    status(folder, units, state, mode=mode)


def stopped(folder, state, code, units=None, mode="kind", why=None):
    report(folder, state)
    print(state, file=sys.stderr)
    if units is not None:
        close(folder, units, mode, f"stopped:{short(why or state)}")
    return code


def full_shape(queue_path):
    counted = pathlib.Path(queue_path).with_name("queue.csv")
    pilot = {unit["unit"]: unit for unit in read_queue(queue_path)}
    if FULL_SHAPE not in pilot:
        return None
    row = next((unit for unit in read_queue(counted) if unit["unit"] == FULL_SHAPE), None)
    if row is None or row["experiment"] != pilot[FULL_SHAPE]["experiment"]:
        raise Refused(f"{counted} has no {pilot[FULL_SHAPE]['experiment']} row {FULL_SHAPE} for the pilot's counted shape")
    return row


def counted_elsewhere(queue_path, units):
    path = pathlib.Path(queue_path).with_name(ELSEWHERE)
    if not path.is_file():
        return {}
    reader = csv.DictReader(path.read_text().splitlines())
    if tuple(reader.fieldnames or ()) != ELSEWHERE_COLUMNS:
        raise Refused(f"{path}: header {','.join(reader.fieldnames or ())}, not {','.join(ELSEWHERE_COLUMNS)}")
    names = {unit["unit"] for unit in units}
    found = {}
    for number, row in enumerate(reader, start=1):
        if None in row or any(value is None for value in row.values()):
            raise Refused(f"{path}: row {number} has not {len(ELSEWHERE_COLUMNS)} fields")
        problems = [
            *([f"unit {row['unit']!r} not in the queue"] if row["unit"] not in names else []),
            *([f"unit {row['unit']!r} twice"] if row["unit"] in found else []),
            *([f"run {row['run']!r} empty or a path"] if not row["run"] or "/" in row["run"] else []),
            *([f"harness commit {row['harness_commit']!r} not 40 hex"]
              if not HEX40.fullmatch(row["harness_commit"] or "") else []),
        ]
        if problems:
            raise Refused(f"{path}: row {number}: {'; '.join(problems)}")
        found[row["unit"]] = row
    return found


def in_a_row(folder, units, mode, streak):
    if len(streak) < IN_A_ROW:
        return None
    why = f"three units in a row failed: {', '.join(streak[-IN_A_ROW:])}"
    return stopped(folder, why, 1, units, mode, why)


def execute(folder, units, mode, queue_path):
    meta = json.loads((folder / "run.json").read_text())
    counted = meta["counted"] == "yes"
    try:
        full = full_shape(queue_path) if meta["counted"] == "no (pilot)" else None
        elsewhere = counted_elsewhere(queue_path, units) if counted else {}
    except (Refused, OSError, csv.Error, ValueError) as error:
        return stopped(folder, f"stopped before the first unit: refused: {error}", 1, units, mode, f"refused: {error}")
    rows = journal_rows(folder)
    lost, streak = [], []
    for unit in units:
        if unit["unit"] in elsewhere:
            print(f"{unit['unit']}: counted in {elsewhere[unit['unit']]['run']} at "
                  f"{elsewhere[unit['unit']]['harness_commit']}, not started here", flush=True)
            continue
        mine = [row for row in rows if row["unit"] == unit["unit"] and row["outcome"] != "started"]
        if any(row["outcome"] in DONE for row in mine):
            streak = []
            continue
        failed = [row for row in mine if row["outcome"] == "fail"]
        if failed and counted:
            lost.append((unit["unit"], failed[-1]["reason"]))
            streak.append(unit["unit"])
            if (code := in_a_row(folder, units, mode, streak)) is not None:
                return code
            continue
        if failed:
            return stopped(folder, f"stopped at {unit['unit']}: it failed in attempt {failed[-1]['attempt']}, "
                                   f"and the queue does not go past a failed unit", 1, units, mode)
        while True:
            if (folder / "STOP").exists():
                return stopped(folder, f"ended by the STOP file before {unit['unit']}", 2, units, mode,
                               f"STOP file before {unit['unit']}")
            voided = sum(row["outcome"] == "void" for row in mine)
            if voided >= int(unit["attempts"]) and counted:
                last = next(row["reason"] for row in reversed(mine) if row["outcome"] == "void")
                lost.append((unit["unit"], f"all {voided} attempts void (last: {last})"))
                streak.append(unit["unit"])
                if (code := in_a_row(folder, units, mode, streak)) is not None:
                    return code
                break
            if voided >= int(unit["attempts"]):
                return stopped(folder, f"stopped at {unit['unit']}: {voided} of {unit['attempts']} attempts void", 1,
                               units, mode)
            disk = hold(folder, units, mode)
            if disk:
                return stopped(folder, f"stopped before {unit['unit']}: {disk} for "
                                       f"{limit('HARNESS_DISK_STOP_S', mode):g} s with nothing waiting and nothing "
                                       f"left to prune", 1, units, mode, disk)
            if (folder / "STOP").exists():
                continue
            try:
                problem = cluster.tree_problem()
            except (OSError, KeyError, ValueError, csv.Error) as error:
                problem = f"tree.csv or the tree unreadable: {type(error).__name__}: {error}"
            if problem:
                return stopped(folder, f"stopped before {unit['unit']}: refused: {problem}", 1, units, mode,
                               f"refused: {problem}")
            made = [int(path.name[1:]) for path in (folder / unit["experiment"] / unit["unit"]).glob("a*")
                    if checks.whole(path.name[1:])]
            number = max((int(row["attempt"]) for row in mine), default=0) + 1
            number = max(number, max(made, default=0) + 1)
            shaped = unit
            if full is not None and unit["unit"] == FULL_SHAPE:
                shaped = {**unit, "arguments": full["arguments"], "expected_minutes": full["expected_minutes"]}
                print(f"{FULL_SHAPE} runs with its row of queue.csv: {full['arguments']}", flush=True)
            outcome, reason = attempt(folder, shaped, number, mode)
            mine.append({"attempt": str(number), "outcome": outcome, "reason": reason})
            print(f"{unit['unit']} attempt {number}: {outcome}{': ' + reason if reason else ''}", flush=True)
            status(folder, units, "running", mode=mode)
            if outcome in DONE:
                streak = []
                break
            if outcome != "void" and counted:
                lost.append((unit["unit"], reason))
                streak.append(unit["unit"])
                if (code := in_a_row(folder, units, mode, streak)) is not None:
                    return code
                break
            if outcome != "void":
                return stopped(folder, f"stopped at {unit['unit']}: {reason}", 1, units, mode)
            report(folder, "running")
        report(folder, "running")
    problems = checks.missing(folder, recursive=False)
    if problems:
        return stopped(folder, f"{'the queue went through' if lost else 'every unit passed'}, but the run's own "
                               f"files fail: {problems[0]} "
                               f"({len(problems)} in all)", 1, units, mode)
    besides = (f"; {len(elsewhere)} units counted in another run ({ELSEWHERE}), not started here" if elsewhere
               else "")
    if lost:
        report(folder, f"finished: {len(lost)} failed: " + "; ".join(f"{name}: {why}" for name, why in lost) + besides)
        close(folder, units, mode, f"done:{len(lost)} failed")
        return 1
    report(folder, ("finished: every unit that was to run passed" if elsewhere else "finished: every unit passed")
           + besides)
    close(folder, units, mode, "done")
    return 0


def default_folder(mode):
    scratch = pathlib.Path(os.environ.get("HARNESS_SCRATCH", "~/stayup")).expanduser()
    return scratch / "runs" / f"run-{time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())}-{mode}"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("queue")
    parser.add_argument("--mode", choices=["kind", "fabric"], required=True)
    parser.add_argument("--run", "--run-dir", dest="run")
    flags = parser.add_mutually_exclusive_group()
    flags.add_argument("--pilot", action="store_true")
    flags.add_argument("--smoke", action="store_true")
    args = parser.parse_args()
    folder = pathlib.Path(args.run).expanduser() if args.run else default_folder(args.mode)
    counted = ("no (kind mode)" if args.mode == "kind" else "no (pilot)" if args.pilot
               else "no (smoke)" if args.smoke else "yes")
    try:
        cluster.guard(args.mode)
        if (folder / "units.csv").exists():
            held = lock(folder)
            units = reopen(args.queue, folder, args.mode, counted)
        else:
            units = prepare(args.queue, folder, args.mode, counted)
            held = lock(folder)
    except (Refused, cluster.Failed, OSError, ValueError, KeyError) as error:
        print(f"refused: {type(error).__name__}: {error}", file=sys.stderr)
        if folder.is_dir() and not (folder / "runner.lock").exists():
            temporary = folder / "STATUS.tmp"
            temporary.write_text(f"units 0/0 · pulled 0 · waiting 0 · free GB control ? dynamos ? server ? clientone ? "
                                 f"clienttwo ? clientthree ? · state=stopped:{short('refused: ' + str(error))}\n")
            os.replace(temporary, folder / "STATUS")
        return 4
    print(f"run folder {folder}", flush=True)
    try:
        status(folder, units, "running", mode=args.mode)
        return execute(folder, units, args.mode, pathlib.Path(args.queue))
    except Exception as error:
        state = f"stopped: the runner itself failed: {type(error).__name__}: {error}"
        try:
            report(folder, state)
            close(folder, units, args.mode, f"stopped:{short('the runner itself failed: ' + str(error))}")
        except Exception as again:
            print(f"closing failed too: {type(again).__name__}: {again}", file=sys.stderr)
        finally:
            print(state, file=sys.stderr)
        return 1
