#!/usr/bin/env python3
"""The results of the stay-up reruns on FABRIC, computed from the extracted tables.

python3 -I compute.py --tables <run>-tables --out <dir>

Reads the per-attempt tables as the laptop extracts them (<tables>/<archive>/<archive>/...) and the run's
units.csv (from the newest closing archive, else the newest attempt archive). Exactly one attempt counts per
unit: the first whose journal outcome is `pass`; every other attempt is void whole and only listed. Writes one
CSV per quantity and results.md. One section, the E1 completeness count both ways (descriptive_*.csv), is
descriptive only: not a tested hypothesis, no verdict. Values are read in µs and reported in ms to 0.1 ms (half away from zero).
Python 3 standard library only. Exit 0 when every section ran, 1 when a section raised (its error is in
results.md), 2 on a bad argument or an unreadable tables folder.
"""
import argparse
import csv
import io
import math
import os
import random
import re
import sys
import traceback
from decimal import Decimal, ROUND_HALF_UP
from fractions import Fraction

SEED = 20261114
RESAMPLES = 10000
TEN_MS_US = 10_000
STEWARDS = ("server", "clientone", "clienttwo", "clientthree")
CONFIGS = ("a", "b", "c", "h")
KIND_LINE = "kind mode: digest and placement gates not run; nothing here is counted"
ATTEMPT_DIR = re.compile(r"^(\d+)_(.+)_a(\d+)$")
CLOSE_DIR = re.compile(r"^(\d+)_close$")
CHUNK = 8
FLOOR_CHUNKS = 2
HALVES = ((1, 16), (17, 32))

NOTES = {"kind_lines": 0}


# ---------------------------------------------------------------- reading

def read_csv(path):
    with open(path, encoding="utf-8", newline="") as handle:
        text = handle.read()
    if text.startswith(KIND_LINE):
        NOTES["kind_lines"] += 1
        text = text.split("\n", 1)[1] if "\n" in text else ""
    return list(csv.DictReader(io.StringIO(text)))


def inner(folder):
    name = os.path.basename(folder)
    nested = os.path.join(folder, name)
    return nested if os.path.isdir(nested) else folder


def as_int(value, what):
    try:
        return int(value)
    except (TypeError, ValueError):
        raise ValueError(f"{what}: not a whole number: {value!r}") from None


class Tables:
    """The extracted tables of one run, and which attempt counts per unit."""

    def __init__(self, root):
        self.root = root
        self.attempts = {}  # (unit, attempt) -> list of folders
        closes, attempt_dirs = [], []
        for name in sorted(os.listdir(root)):
            path = os.path.join(root, name)
            if not os.path.isdir(path):
                continue
            m, c = ATTEMPT_DIR.match(name), CLOSE_DIR.match(name)
            if c:
                closes.append((int(c.group(1)), path))
            elif m:
                attempt_dirs.append((int(m.group(1)), m.group(2), int(m.group(3)), path))
        if closes:
            self.journal_from = max(closes)[1]
        elif attempt_dirs:
            self.journal_from = max(attempt_dirs)[3]
        else:
            raise SystemExit(f"no archive folder under {root}")
        self.journal_kind = "closing archive" if closes else "newest attempt archive (no closing archive)"
        base = inner(self.journal_from)
        self.journal = read_csv(os.path.join(base, "units.csv"))
        self.queue = read_csv(os.path.join(base, "queue.csv"))
        self.folder_outcome = {}
        for seq, unit, attempt, path in attempt_dirs:
            self.attempts.setdefault((unit, attempt), []).append(path)
            own = os.path.join(inner(path), "units.csv")
            outcome = "unknown (no units.csv in the folder)"
            if os.path.exists(own):
                ended = [r for r in read_csv(own) if r["unit"] == unit and as_int(r["attempt"], "attempt") == attempt
                         and r["outcome"] != "started"]
                if ended:
                    outcome = ended[-1]["outcome"]
            self.folder_outcome[path] = outcome
        self.counted = {}  # unit -> folder (inner) of the counted attempt
        self.rows = []  # one per ended attempt in the journal, and one per unit with none
        for q in self.queue:
            unit = q["unit"]
            ended = [r for r in self.journal if r["unit"] == unit and r["outcome"] != "started"]
            started = [r for r in self.journal if r["unit"] == unit and r["outcome"] == "started"]
            first_pass = next((r for r in ended if r["outcome"] == "pass"), None)
            for r in ended:
                attempt = as_int(r["attempt"], "units.csv attempt")
                folders = [p for p in self.attempts.get((unit, attempt), []) if self.folder_outcome[p] == r["outcome"]]
                counted = r is first_pass
                note = ""
                if counted:
                    if len(folders) == 1:
                        self.counted[unit] = inner(folders[0])
                    elif not folders:
                        note = "counted attempt, but its tables are not in the tables folder: nothing computed"
                    else:
                        note = "counted attempt, but more than one tables folder matches: nothing computed"
                self.rows.append({"experiment": r["experiment"], "unit": unit, "attempt": attempt,
                                  "outcome": r["outcome"], "reason": r["reason"],
                                  "counted": "yes" if counted and unit in self.counted else "no",
                                  "why_not_counted": "" if counted else (
                                      "a later attempt than the first that passed" if first_pass is not None
                                      and ended.index(r) > ended.index(first_pass) else
                                      "not passed: void whole" if r["outcome"] != "pass" else ""),
                                  "tables": os.path.relpath(folders[0], root) if folders else "", "note": note})
            open_rows = [r for r in started if not any(e["attempt"] == r["attempt"] for e in ended)]
            for r in open_rows:
                self.rows.append({"experiment": r["experiment"], "unit": unit, "attempt": r["attempt"],
                                  "outcome": "started, not ended in this journal", "reason": "", "counted": "no",
                                  "why_not_counted": "not ended", "tables": "", "note": ""})
            if not ended and not open_rows:
                self.rows.append({"experiment": q["experiment"], "unit": unit, "attempt": "",
                                  "outcome": "no attempt in the journal", "reason": "", "counted": "no",
                                  "why_not_counted": "no counted attempt", "tables": "", "note": ""})
        self.experiment = {q["unit"]: q["experiment"] for q in self.queue}
        self.arguments = {q["unit"]: q.get("arguments", "") for q in self.queue}

    def units_of(self, experiment):
        return [q["unit"] for q in self.queue if q["experiment"] == experiment]

    def table(self, unit, name):
        """Rows of one table of a unit's counted attempt; None when the unit has no counted attempt."""
        folder = self.counted.get(unit)
        if folder is None:
            return None
        path = os.path.join(folder, self.experiment[unit], name)
        if not os.path.exists(path):
            raise MissingTable(f"{os.path.relpath(path, self.root)} is missing")
        return read_csv(path)

    def argument(self, unit, flag):
        words = self.arguments.get(unit, "").split()
        if flag in words and words.index(flag) + 1 < len(words):
            return as_int(words[words.index(flag) + 1], f"{unit} {flag}")
        return None


class MissingTable(Exception):
    pass


# ---------------------------------------------------------------- numbers

def median(values):
    s = sorted(values)
    n = len(s)
    if n == 0:
        return None
    mid = n // 2
    return Fraction(s[mid]) if n % 2 else (Fraction(s[mid - 1]) + Fraction(s[mid])) / 2


def ms(value_us):
    """µs (int, Fraction or float) -> ms rounded to 0.1 ms, half away from zero, as text."""
    if value_us is None:
        return ""
    f = Fraction(value_us)
    d = Decimal(f.numerator) / Decimal(f.denominator) / Decimal(1000)
    return str(d.quantize(Decimal("0.1"), rounding=ROUND_HALF_UP))


def us_text(value_us):
    if value_us is None:
        return ""
    f = Fraction(value_us)
    return str(f.numerator) if f.denominator == 1 else str(Decimal(f.numerator) / Decimal(f.denominator))


def describe(values):
    values = [v for v in values]
    if not values:
        return {"n": 0, "min": None, "median": None, "max": None}
    return {"n": len(values), "min": min(values), "median": median(values), "max": max(values)}


def percentile(sorted_values, p):
    """Linear interpolation between closest ranks (numpy's default, type 7), exact in Fractions."""
    n = len(sorted_values)
    h = Fraction(n - 1) * p
    lo = math.floor(h)
    hi = min(lo + 1, n - 1)
    a, b = Fraction(sorted_values[lo]), Fraction(sorted_values[hi])
    return a + (h - lo) * (b - a)


def bootstrap_median_ci(values):
    """Percentile bootstrap 95 % interval of the median: 10,000 resamples with replacement, a fresh
    random.Random(20261114) per interval, so each interval can be reproduced by itself."""
    data = [Fraction(v) for v in values]
    n = len(data)
    rng = random.Random(SEED)
    floats = [float(v) for v in data]  # the values are halves of whole µs: exact in a float
    meds = []
    for _ in range(RESAMPLES):
        sample = sorted(rng.choices(floats, k=n))
        mid = n // 2
        meds.append(sample[mid] if n % 2 else (sample[mid - 1] + sample[mid]) / 2)
    meds.sort()
    return percentile(meds, Fraction(25, 1000)), percentile(meds, Fraction(975, 1000))


def wilcoxon_exact(values):
    """Exact two-sided Wilcoxon signed-rank test. Zero differences are dropped (Wilcoxon's own rule); tied
    |d| get their mid-rank; the null distribution of T+ is enumerated over every sign assignment of the
    non-zero differences (with ties: the exact conditional distribution). p = min(1, 2 min(P(T+ <= t),
    P(T+ >= t)))."""
    d = [Fraction(v) for v in values]
    zeros = sum(1 for v in d if v == 0)
    nz = [v for v in d if v != 0]
    n = len(nz)
    order = sorted(range(n), key=lambda i: abs(nz[i]))
    rank2 = [0] * n  # doubled mid-ranks, whole numbers
    i, ties = 0, 0
    while i < n:
        j = i
        while j + 1 < n and abs(nz[order[j + 1]]) == abs(nz[order[i]]):
            j += 1
        if j > i:
            ties += j - i + 1
        for k in range(i, j + 1):
            rank2[order[k]] = (i + 1) + (j + 1)
        i = j + 1
    t2_plus = sum(r for r, v in zip(rank2, nz) if v > 0)
    t2_minus = sum(r for r, v in zip(rank2, nz) if v < 0)
    if n == 0:
        return {"n": len(d), "n_nonzero": 0, "zeros": zeros, "tied": ties, "T_plus": None, "T_minus": None,
                "p": None}
    total = sum(rank2)
    counts = [0] * (total + 1)
    counts[0] = 1
    for r in rank2:
        for s in range(total, r - 1, -1):
            counts[s] += counts[s - r]
    ways = 2 ** n
    lower = Fraction(sum(counts[: t2_plus + 1]), ways)
    upper = Fraction(sum(counts[t2_plus:]), ways)
    p = min(Fraction(1), 2 * min(lower, upper))
    return {"n": len(d), "n_nonzero": n, "zeros": zeros, "tied": ties, "T_plus": Fraction(t2_plus, 2),
            "T_minus": Fraction(t2_minus, 2), "p": p}


def p_text(p):
    if p is None:
        return ""
    return f"{float(p):.4g}"


def num(f):
    if f is None:
        return ""
    f = Fraction(f)
    return str(f.numerator) if f.denominator == 1 else str(float(f))


# ---------------------------------------------------------------- output

class Out:
    def __init__(self, folder, tables):
        self.folder = folder
        self.lines = []
        self.files = []
        self.failed = []
        self.t = tables

    def csv(self, name, columns, rows):
        path = os.path.join(self.folder, name)
        with open(path, "w", encoding="utf-8", newline="") as handle:
            w = csv.DictWriter(handle, fieldnames=columns, lineterminator="\n")
            w.writeheader()
            for row in rows:
                w.writerow({c: row.get(c, "") for c in columns})
        self.files.append(name)

    def md(self, *lines):
        self.lines.extend(lines)

    def table(self, header, rows):
        self.md("| " + " | ".join(header) + " |", "|" + "---|" * len(header))
        for row in rows:
            self.md("| " + " | ".join(str(x) for x in row) + " |")
        self.md("")


def desc_row(label, values):
    d = describe(values)
    return {"quantity": label, "n": d["n"], "min_us": us_text(d["min"]), "median_us": us_text(d["median"]),
            "max_us": us_text(d["max"]), "min_ms": ms(d["min"]), "median_ms": ms(d["median"]),
            "max_ms": ms(d["max"])}


DESC_COLUMNS = ("experiment", "unit", "quantity", "n", "min_us", "median_us", "max_us", "min_ms", "median_ms",
                "max_ms")


def desc_md(out, rows):
    out.table(["quantity", "n", "minimum (ms)", "median (ms)", "maximum (ms)"],
              [[r["quantity"], r["n"], r["min_ms"] or "–", r["median_ms"] or "–", r["max_ms"] or "–"] for r in rows])


def no_counted(out, units):
    missing = [u for u in units if u not in out.t.counted]
    if missing:
        out.md(f"No counted attempt (nothing computed for it): {', '.join(missing)}.", "")


# ---------------------------------------------------------------- sections

def section_attempts(out):
    t = out.t
    cols = ("experiment", "unit", "attempt", "outcome", "reason", "counted", "why_not_counted", "tables", "note")
    out.csv("attempts.csv", cols, t.rows)
    out.md("## Attempts and the counted attempt", "",
           f"Journal: `{os.path.relpath(os.path.join(inner(t.journal_from), 'units.csv'), t.root)}` "
           f"({t.journal_kind}); queue: the `queue.csv` beside it, {len(t.queue)} units. Exactly one attempt counts "
           f"per unit, the first that passed; every other attempt is void whole and listed here only.", "")
    counted = sum(1 for r in t.rows if r["counted"] == "yes")
    out.md(f"Units with a counted attempt: {counted} of {len(t.queue)}.", "")
    others = [r for r in t.rows if r["counted"] != "yes"]
    if others:
        out.table(["unit", "attempt", "outcome", "reason", "not counted because", "note"],
                  [[r["unit"], r["attempt"], r["outcome"], r["reason"].replace("|", "/")[:160] or "–",
                    r["why_not_counted"] or "–", r["note"] or "–"] for r in others])
    else:
        out.md("No attempt other than the counted ones.", "")


def section_e1(out):
    t = out.t
    units = t.units_of("e1")
    out.md("## E1", "")
    no_counted(out, units)
    cases = []
    for unit in units:
        rows = t.table(unit, "cases.csv")
        for r in rows or []:
            cases.append({"unit": unit, **{k: r[k] for k in ("row", "case", "steward", "expected", "observed",
                                                              "result")}})
    out.csv("e1_cases.csv", ("unit", "row", "case", "steward", "expected", "observed", "result"), cases)
    out.md("### Pass or fail per row and case", "",
           "Every row of every counted E1 unit's `cases.csv`, in `e1_cases.csv`. Counts of rows (one per steward "
           "or per check) per unit, decision-table row and case:", "")
    tally = {}
    for r in cases:
        key = (r["unit"], r["row"], r["case"])
        tally.setdefault(key, {"pass": 0, "fail": 0, "other": 0})
        tally[key]["pass" if r["result"] == "pass" else "fail" if r["result"] == "fail" else "other"] += 1
    out.table(["unit", "row", "case", "pass", "fail", "other result"],
              [[u, row, c.replace("|", "/"), v["pass"], v["fail"], v["other"]] for (u, row, c), v in tally.items()])
    out.md(f"All E1 case rows: {len(cases)}; pass {sum(1 for r in cases if r['result'] == 'pass')}, "
           f"fail {sum(1 for r in cases if r['result'] == 'fail')}, "
           f"other {sum(1 for r in cases if r['result'] not in ('pass', 'fail'))}.", "")

    def idle_rows(case_test, check_test):
        found = []
        for unit in units:
            if unit not in t.counted or not os.path.exists(os.path.join(t.counted[unit], "e1", "idle.csv")):
                continue
            for r in t.table(unit, "idle.csv"):
                if case_test(r["case"]) and check_test(r["check"]):
                    start, end = as_int(r["start_us"], "idle start_us"), as_int(r["end_us"], "idle end_us")
                    found.append({"unit": unit, "case": r["case"], "check": r["check"], "steward": r["steward"],
                                  "start_clock": r["start_clock"], "start_us": start, "end_clock": r["end_clock"],
                                  "end_us": end, "value_us": end - start, "value_ms": ms(end - start),
                                  "result": r["result"]})
        return found

    cols = ("unit", "case", "check", "steward", "start_clock", "start_us", "end_clock", "end_us", "value_us",
            "value_ms", "result")
    a = idle_rows(lambda c: c == "(a) revocation", lambda k: True)
    out.csv("e1_a_revocation.csv", cols, a)
    hand = idle_rows(lambda c: c == "(c) hand-over", lambda k: k == "duration logged by the agent")
    out.csv("e1_handover.csv", cols, hand)
    up = idle_rows(lambda c: True, lambda k: k == "idle up after the job")
    out.csv("e1_idle_up.csv", cols, up)
    b = []
    for unit in units:
        if unit not in t.counted or not os.path.exists(os.path.join(t.counted[unit], "e1", "expiry.csv")):
            continue
        for r in t.table(unit, "expiry.csv"):
            last = as_int(r["last_write_us"], "expiry last_write_us")
            deleted = as_int(r["deleted_us"], "expiry deleted_us") if r["deleted_us"].strip() else None
            b.append({"unit": unit, "steward": r["steward"], "clock": r["clock"], "state_class": r["state_class"],
                      "state_key": r["state_key"], "last_write_us": last, "deleted_us": "" if deleted is None
                      else deleted, "value_us": "" if deleted is None else deleted - last,
                      "value_ms": "" if deleted is None else ms(deleted - last), "form": r["form"],
                      "result": r["result"]})
    out.csv("e1_b_expiry.csv", ("unit", "steward", "clock", "state_class", "state_key", "last_write_us",
                                "deleted_us", "value_us", "value_ms", "form", "result"), b)
    b_values = [r["value_us"] for r in b if r["value_us"] != ""]
    desc = [dict(desc_row("(a) revocation: PURGED decided minus the revocation's send", [r["value_us"] for r in a]),
                 experiment="e1", unit="idle-a"),
            dict(desc_row("(b) expiry: DELETED decided minus the file's last write ALLOW", b_values),
                 experiment="e1", unit="idle-b"),
            dict(desc_row("hand-over: duration logged by the agent", [r["value_us"] for r in hand]),
                 experiment="e1", unit="idle-c"),
            dict(desc_row("idle-up, which is the gap after a job: chain gateway finishedAt to the idle process's "
                          "'Agreement loaded'", [r["value_us"] for r in up]),
                 experiment="e1", unit=" ".join(sorted({r["unit"] for r in up})) or "–")]
    out.csv("e1_descriptives.csv", DESC_COLUMNS, desc)
    out.md("### (a), (b), the hand-over, idle-up and the gap after a job", "",
           "Each value is end stamp minus start stamp of its row, µs in, ms to 0.1 ms out. Values in "
           "`e1_a_revocation.csv`, `e1_b_expiry.csv`, `e1_handover.csv`, `e1_idle_up.csv`.", "")
    desc_md(out, desc)
    if len(b_values) != len(b):
        out.md(f"(b): {len(b) - len(b_values)} row(s) without a DELETED stamp, not in n.", "")
    big = max(a, key=lambda r: r["value_us"]) if a else None
    out.csv("e1_a_largest.csv", ("unit", "steward", "value_us", "value_ms", "n"),
            [{"unit": big["unit"], "steward": big["steward"], "value_us": big["value_us"],
              "value_ms": big["value_ms"], "n": len(a)}] if big else [])
    out.md(f"Largest (a) value: {big['value_ms']} ms ({big['steward']}, n = {len(a)})." if big else
           "Largest (a) value: none (n = 0).", "")


def trial_values(t, unit, name):
    rows = t.table(unit, name)
    if rows is None:
        return None
    out = []
    for r in rows:
        sent = as_int(r["sent_us"], f"{name} sent_us")
        end = as_int(r["end_us"], f"{name} end_us")
        ret = as_int(r["returned_us"], f"{name} returned_us")
        out.append({"unit": unit, "trial": r["trial"], "sent_clock": r["sent_clock"], "end_clock": r["end_clock"],
                    "sent_us": sent, "end_us": end, "returned_us": ret, "end_minus_send_us": end - sent,
                    "end_minus_send_ms": ms(end - sent), "return_minus_send_us": ret - sent,
                    "return_minus_send_ms": ms(ret - sent), "end_before_return": "yes" if end < ret else "no",
                    "end_op": r["end_op"], "end_decision": r["end_decision"], "result": r["result"]})
    return out


TRIAL_COLS = ("unit", "trial", "sent_clock", "end_clock", "sent_us", "end_us", "returned_us", "end_minus_send_us",
              "end_minus_send_ms", "return_minus_send_us", "return_minus_send_ms", "end_before_return", "end_op",
              "end_decision", "result")


def section_e2(out):
    t = out.t
    out.md("## E2 watch and poll", "")
    arms = (("watch", "trials-watch.csv"), ("poll", "trials-poll.csv"))
    no_counted(out, [u for u, _ in arms])
    trials, desc, counts, deaths = [], [], [], []
    for unit, name in arms:
        rows = trial_values(t, unit, name)
        if rows is None:
            continue
        trials += rows
        desc.append(dict(desc_row(f"{unit}: first write DENY decided minus send",
                                  [r["end_minus_send_us"] for r in rows]), experiment="e2", unit=unit))
        desc.append(dict(desc_row(f"{unit}: return minus send", [r["return_minus_send_us"] for r in rows]),
                         experiment="e2", unit=unit))
        counts.append({"unit": unit, "n_trials": len(rows),
                       "deny_before_return": sum(1 for r in rows if r["end_before_return"] == "yes")})
        events = t.table(unit, "events.csv")
        died = sum(1 for e in events if e["event"] == "chain death")
        flips = sum(1 for e in events if e["event"] == "flip sent")
        deaths.append({"unit": unit, "chain_deaths": died, "revocations": flips,
                       "deaths_per_revocation": "" if flips == 0 else f"{died / flips:.3f}"})
    out.csv("e2_trials.csv", TRIAL_COLS, trials)
    out.csv("e2_descriptives.csv", DESC_COLUMNS, desc)
    out.csv("e2_deny_before_return.csv", ("unit", "n_trials", "deny_before_return"), counts)
    out.csv("e2_chain_deaths.csv", ("unit", "chain_deaths", "revocations", "deaths_per_revocation"), deaths)
    out.md("Per trial (in `e2_trials.csv`, with each stamp's clock label): `end_us` (the `decidedUnixMicros` of the "
           "first `write` DENY of `e2_probe` after the send) minus `sent_us`, and `returned_us` minus `sent_us`.", "")
    desc_md(out, desc)
    out.table(["arm", "trials (n)", "trials whose DENY was decided before the return"],
              [[c["unit"], c["n_trials"], c["deny_before_return"]] for c in counts])
    out.md("Chain deaths per revocation: `chain death` events over `flip sent` events (each a revocation, a "
           "repeated trial's flip included) in the arm's `events.csv`.", "")
    out.table(["arm", "chain deaths", "revocations", "deaths per revocation"],
              [[d["unit"], d["chain_deaths"], d["revocations"], d["deaths_per_revocation"] or "–"] for d in deaths])


def section_e4(out):
    t = out.t
    out.md("## E4", "")
    no_counted(out, ["growth", "flip"])
    growth = t.table("growth", "rounds-growth.csv")
    rows = []
    if growth is not None:
        g = sorted(growth, key=lambda r: as_int(r["round"], "round"))
        prev = None
        for r in g:
            cum = as_int(r["bytes_cum"], "bytes_cum")
            rows.append({"round": r["round"], "bytes_cum": cum, "bytes_added": cum - (prev or 0),
                         "from": "the log's start" if prev is None else "the previous round's write record"})
            prev = cum
    out.csv("e4_growth_bytes_per_round.csv", ("round", "bytes_cum", "bytes_added", "from"), rows)
    out.md("### Growth: audit-record bytes added per round (server's claim)", "",
           "Bytes on server's audit log up to each round's write record (`bytes_cum`), minus the previous round's; "
           "round 0's from the log's start. Bytes, whole numbers.", "")
    if rows:
        out.table(["round", "bytes added", "audit-log bytes up to the round's write"],
                  [[r["round"], r["bytes_added"], r["bytes_cum"]] for r in rows])
        out.md(f"n = {len(rows)} rounds.", "")
    storage = t.table("growth", "storage.csv")
    st = []
    if storage is not None:
        last_data = ""
        if growth:
            last = max(growth, key=lambda r: as_int(r["round"], "round"))
            last_data = last["data_bytes"]
        for r in storage:
            st.append({"steward": r["steward"], "claim": r["claim"],
                       "state_size_state_file_count": r["state_files"], "state_size_audit_bytes": r["audit_bytes"],
                       "server_only_sampled_data_bytes": last_data if r["steward"] == "server" else "",
                       "file_count_all_files_on_claim": r["files"]})
    out.csv("e4_growth_storage.csv", ("steward", "claim", "state_size_state_file_count", "state_size_audit_bytes",
                                      "server_only_sampled_data_bytes", "file_count_all_files_on_claim"), st)
    out.md("### Growth: state size and file count per steward (the claim at the unit's end, `storage.csv`)", "",
           "State size per steward is reported as the state-file count and the audit bytes per steward from "
           "`storage.csv` (`state_files`, `audit_bytes`); server's sampled data bytes (`rounds-growth.csv` "
           "`data_bytes` at the last round) are reported for server only. File count: every file on the claim "
           "(`storage.csv` `files`). Whole numbers.", "")
    if st:
        out.table(["steward", "state size: state-file count", "state size: audit bytes",
                   "server only: sampled data bytes", "file count: all files on the claim"],
                  [[r["steward"], r["state_size_state_file_count"], r["state_size_audit_bytes"],
                    r["server_only_sampled_data_bytes"] or "–", r["file_count_all_files_on_claim"]] for r in st])
        out.md(f"n = {len(st)} stewards.", "")
    flip = t.table("flip", "rounds-flip.csv")
    fl = []
    if flip is not None:
        n_rounds, after = t.argument("flip", "--rounds"), t.argument("flip", "--flip-after")
        by_round = {}
        for r in flip:
            by_round.setdefault(as_int(r["round"], "round"), []).append(r)
        persisted = denied = neither = absent = 0
        for k in range(after, n_rounds):
            got = by_round.get(k, [])
            if not got:
                absent += 1
                neither += 1
                continue
            decision = got[0]["decision"]
            if decision == "ALLOW":
                persisted += 1
            elif decision == "DENY":
                denied += 1
            else:
                neither += 1
        fl.append({"run": "1 (the run with the change)", "rounds": n_rounds, "change_after_round": after - 1,
                   "rounds_after_change": n_rounds - after, "persisted": persisted, "denied": denied,
                   "neither": neither, "of_which_no_write_row": absent})
    out.csv("e4_flip_rounds_after_change.csv", ("run", "rounds", "change_after_round", "rounds_after_change",
                                                "persisted", "denied", "neither", "of_which_no_write_row"), fl)
    out.md("### Flip: rounds persisted, denied and neither after the change (server's writes, `rounds-flip.csv`)",
           "", "After the change = rounds F to N − 1 by index, F and N from the unit's arguments in `queue.csv`.", "")
    if fl:
        out.table(["run", "rounds after the change", "persisted (write ALLOW)", "denied (write DENY)",
                   "neither", "of which no write row"],
                  [[r["run"], r["rounds_after_change"], r["persisted"], r["denied"], r["neither"],
                    r["of_which_no_write_row"]] for r in fl])
    expiry = t.table("flip", "expiry.csv")
    ex, forms, kept = [], {}, {}
    if expiry is not None:
        for r in expiry:
            due = as_int(r["due_us"], "due_us")
            deleted = as_int(r["deleted_us"], "deleted_us") if r["deleted_us"].strip() else None
            ex.append({"steward": r["steward"], "clock": r["clock"], "state_class": r["state_class"],
                       "state_key": r["state_key"], "due_us": due, "deleted_us": "" if deleted is None else deleted,
                       "deleted_minus_due_us": "" if deleted is None else deleted - due,
                       "deleted_minus_due_ms": "" if deleted is None else ms(deleted - due),
                       "form": r["form"], "result": r["result"]})
            forms[r["form"] or "(no DELETED record)"] = forms.get(r["form"] or "(no DELETED record)", 0) + 1
            kept.setdefault(r["steward"], (as_int(r["deferred"], "deferred"), as_int(r["cancelled"], "cancelled")))
    out.csv("e4_run2_deleted_minus_due.csv", ("steward", "clock", "state_class", "state_key", "due_us",
                                              "deleted_us", "deleted_minus_due_us", "deleted_minus_due_ms", "form",
                                              "result"), ex)
    counts = [{"count": f"form {f}", "n": v} for f, v in sorted(forms.items())]
    counts += [{"count": f"DEFERRED, {s}", "n": d} for s, (d, _) in kept.items()]
    counts += [{"count": f"CANCELLED, {s}", "n": c} for s, (_, c) in kept.items()]
    if kept:
        counts += [{"count": "DEFERRED, all stewards", "n": sum(d for d, _ in kept.values())},
                   {"count": "CANCELLED, all stewards", "n": sum(c for _, c in kept.values())}]
    out.csv("e4_run2_counts.csv", ("count", "n"), counts)
    out.md("### Run 2 (retention 120 s): per file, the DELETED time minus its due time", "")
    if ex:
        out.table(["steward", "state", "DELETED minus due (ms)", "form", "result"],
                  [[r["steward"], f"{r['state_class']}/{r['state_key']}", r["deleted_minus_due_ms"] or "–",
                    r["form"] or "–", r["result"]] for r in ex])
        out.md(f"n = {len(ex)} files.", "")
        out.md("Counts by form, and `DEFERRED` and `CANCELLED` records (per claim, in the expiry window between run "
               "1's shutdown and run 2's first read or write, as `expiry.csv` counts them):", "")
        out.table(["count", "n"], [[c["count"], c["n"]] for c in counts])


def section_e5(out):
    t = out.t
    out.md("## E5", "")
    arms = (("latency", "trials-latency.csv"), ("poll-control", "trials-poll.csv"))
    no_counted(out, [u for u, _ in arms] + ["staleness"])
    trials, desc, counts = [], [], []
    for unit, name in arms:
        rows = trial_values(t, unit, name)
        if rows is None:
            continue
        trials += rows
        desc.append(dict(desc_row(f"{unit}: the trial blob's PURGED decided minus send",
                                  [r["end_minus_send_us"] for r in rows]), experiment="e5", unit=unit))
        counts.append({"unit": unit, "n_trials": len(rows),
                       "purged_before_return": sum(1 for r in rows if r["end_before_return"] == "yes")})
    out.csv("e5_trials.csv", TRIAL_COLS, trials)
    out.csv("e5_descriptives.csv", DESC_COLUMNS, desc)
    out.csv("e5_purged_before_return.csv", ("unit", "n_trials", "purged_before_return"), counts)
    out.md("### Latency and poll control: PURGED minus send", "")
    desc_md(out, desc)
    out.table(["arm", "trials (n)", "trials whose PURGED was decided before the request returned"],
              [[c["unit"], c["n_trials"], c["purged_before_return"]] for c in counts])
    episodes = t.table("staleness", "episodes-staleness.csv")
    ep = []
    for r in episodes or []:
        rec, pur = as_int(r["recovery_us"], "recovery_us"), as_int(r["purge_us"], "purge_us")
        ep.append({"episode": r["episode"], "clock": r["clock"], "recovery_us": rec, "purge_us": pur,
                   "purged_minus_recovery_us": pur - rec, "purged_minus_recovery_ms": ms(pur - rec),
                   "purge_source": r["purge_source"], "result": r["result"]})
    out.csv("e5_staleness.csv", ("episode", "clock", "recovery_us", "purge_us", "purged_minus_recovery_us",
                                 "purged_minus_recovery_ms", "purge_source", "result"), ep)
    out.md("### Staleness: recovery stamp to PURGED, per episode", "")
    if ep:
        out.table(["episode", "recovery to PURGED (ms)", "clock", "view", "result"],
                  [[r["episode"], r["purged_minus_recovery_ms"], r["clock"], r["purge_source"], r["result"]]
                   for r in ep])
        out.md(f"n = {len(ep)} episodes.", "")


def section_e3(out):
    t = out.t
    out.md("## E3", "")
    units = t.units_of("e3")
    quad_of = {}
    for unit in units:
        q = t.argument(unit, "--quad")
        quad_of[unit] = q if q is not None else as_int(unit.split("-")[-1], "quad number")
    counted = sorted(quad_of[u] for u in units if u in t.counted)
    planned = sorted(quad_of.values())
    chunks = []
    for k in range(math.ceil(len(planned) / CHUNK)):
        members = planned[k * CHUNK:(k + 1) * CHUNK]
        whole = len(members) == CHUNK and all(q in counted for q in members)
        chunks.append({"chunk": k + 1, "quadruplets": f"{members[0]}-{members[-1]}",
                       "counted": sum(1 for q in members if q in counted), "whole": "yes" if whole else "no"})
    analysed = sorted(q for c, ch in zip(range(len(chunks)), chunks) if ch["whole"] == "yes"
                      for q in planned[c * CHUNK:(c + 1) * CHUNK])
    whole = sum(1 for ch in chunks if ch["whole"] == "yes")
    below = whole < FLOOR_CHUNKS
    left_out = [q for q in counted if q not in analysed]
    status = [dict(ch) for ch in chunks]
    out.csv("e3_chunks.csv", ("chunk", "quadruplets", "counted", "whole"), status)
    out.md(f"Quadruplets with a counted attempt: {len(counted)} of {len(planned)}"
           + (f" ({', '.join(str(q) for q in counted)})" if 0 < len(counted) < len(planned) else "") + ". "
           f"Whole chunks of eight: {whole} of {len(chunks)}. "
           + ("Below the floor (fewer than two whole chunks): reported, not analysed." if below else
              f"Analysed: {len(analysed)} quadruplets ({analysed[0]}-{analysed[-1]} in whole chunks)"
              + (f"; counted but left out (not in a whole chunk): {', '.join(str(q) for q in left_out)}"
                 if left_out else "") + "."), "")
    out.table(["chunk", "quadruplets", "counted", "whole"],
              [[c["chunk"], c["quadruplets"], c["counted"], c["whole"]] for c in chunks])
    if below:
        rows = []
        for unit in units:
            if unit not in t.counted:
                continue
            r, w = t.table(unit, "rounds.csv"), t.table(unit, "writes.csv")
            rows.append({"quad": quad_of[unit], "unit": unit, "rounds_rows": len(r), "writes_rows": len(w)})
        out.csv("e3_below_floor.csv", ("quad", "unit", "rounds_rows", "writes_rows"), rows)
        out.md("Counted E3 tables read (rows only; nothing computed below the floor): "
               + (", ".join(f"q{r['quad']} {r['rounds_rows']} rounds rows / {r['writes_rows']} writes rows"
                            for r in rows) or "none") + ".", "")
        for name in ("e3_run_medians.csv", "e3_quad_differences.csv", "e3_write_span_medians.csv",
                     "e3_tests.csv", "e3_drift.csv", "e3_flatness.csv", "e3_flatness_count.csv",
                     "e3_expectation.csv"):
            out.csv(name, ("status",), [{"status": "below the floor: not analysed"}])
        return
    unit_of = {quad_of[u]: u for u in units}
    run_med, flat, spans = {}, [], {}
    run_rows, span_rows = [], []
    for q in analysed:
        rounds = t.table(unit_of[q], "rounds.csv")
        writes = t.table(unit_of[q], "writes.csv")
        for config in CONFIGS:
            mine = [r for r in rounds if r["config"] == config]
            dur = [(as_int(r["round"], "round"), as_int(r["duration_us"], "duration_us")) for r in mine]
            w1 = [v for k, v in dur if 1 <= k <= 49]
            early = [v for k, v in dur if 1 <= k <= 21]
            late = [v for k, v in dur if 22 <= k <= 49]
            m = median(w1)
            run_med[(q, config)] = m
            position = mine[0]["position"] if mine else ""
            run_rows.append({"quad": q, "config": config, "position": position, "n_rounds": len(w1),
                             "median_us": us_text(m), "median_ms": ms(m)})
            f = None if not early or not late else median(late) - median(early)
            flat.append({"quad": q, "config": config, "n_rounds_1_21": len(early), "n_rounds_22_49": len(late),
                         "late_minus_early_us": us_text(f), "late_minus_early_ms": ms(f),
                         "abs_above_10_ms": "" if f is None else ("yes" if abs(f) > TEN_MS_US else "no")})
            if config in ("c", "h"):
                for s in STEWARDS:
                    span = [as_int(r["total_us"], "total_us") for r in writes
                            if r["config"] == config and r["steward"] == s]
                    ms_ = median(span)
                    spans[(q, config, s)] = ms_
                    span_rows.append({"quad": q, "config": config, "steward": s, "n_writes": len(span),
                                      "median_total_us": us_text(ms_), "median_total_ms": ms(ms_)})
    out.csv("e3_run_medians.csv", ("quad", "config", "position", "n_rounds", "median_us", "median_ms"), run_rows)
    out.csv("e3_write_span_medians.csv", ("quad", "config", "steward", "n_writes", "median_total_us",
                                          "median_total_ms"), span_rows)
    diffs = {"c − a": {}, "c − h": {}}
    for s in STEWARDS:
        diffs[f"per-write c − h, {s}"] = {}
    qrows = []
    for q in analysed:
        row = {"quad": q}
        for name, (x, y) in (("c − a", ("c", "a")), ("c − h", ("c", "h"))):
            mx, my = run_med[(q, x)], run_med[(q, y)]
            d = None if mx is None or my is None else mx - my
            if d is not None:
                diffs[name][q] = d
            row[name] = d
        for s in STEWARDS:
            mx, my = spans[(q, "c", s)], spans[(q, "h", s)]
            d = None if mx is None or my is None else mx - my
            if d is not None:
                diffs[f"per-write c − h, {s}"][q] = d
            row[s] = d
        qrows.append(row)
    out.csv("e3_quad_differences.csv",
            ("quad", "c_minus_a_us", "c_minus_a_ms", "c_minus_h_us", "c_minus_h_ms")
            + tuple(f"per_write_c_minus_h_{s}_{u}" for s in STEWARDS for u in ("us", "ms")),
            [{"quad": r["quad"], "c_minus_a_us": us_text(r["c − a"]), "c_minus_a_ms": ms(r["c − a"]),
              "c_minus_h_us": us_text(r["c − h"]), "c_minus_h_ms": ms(r["c − h"]),
              **{f"per_write_c_minus_h_{s}_us": us_text(r[s]) for s in STEWARDS},
              **{f"per_write_c_minus_h_{s}_ms": ms(r[s]) for s in STEWARDS}} for r in qrows])
    tests = []
    for name, values in diffs.items():
        v = [values[q] for q in sorted(values)]
        w = wilcoxon_exact(v)
        lo, hi = bootstrap_median_ci(v) if v else (None, None)
        tests.append({"quantity": name, "n": len(v), "median_us": us_text(median(v)), "median_ms": ms(median(v)),
                      "ci95_low_us": us_text(lo), "ci95_high_us": us_text(hi), "ci95_low_ms": ms(lo),
                      "ci95_high_ms": ms(hi), "wilcoxon_n_nonzero": w["n_nonzero"], "wilcoxon_zeros": w["zeros"],
                      "wilcoxon_tied": w["tied"], "T_plus": num(w["T_plus"]), "T_minus": num(w["T_minus"]),
                      "p_exact_two_sided": p_text(w["p"]), "_p": w["p"], "_hi": hi, "_med": median(v)})
    out.csv("e3_tests.csv", ("quantity", "n", "median_us", "median_ms", "ci95_low_us", "ci95_high_us",
                             "ci95_low_ms", "ci95_high_ms", "wilcoxon_n_nonzero", "wilcoxon_zeros", "wilcoxon_tied",
                             "T_plus", "T_minus", "p_exact_two_sided"), tests)
    drift = []
    for name, values in diffs.items():
        for lo_q, hi_q in HALVES:
            v = [values[q] for q in sorted(values) if lo_q <= q <= hi_q]
            m = median(v)
            drift.append({"quantity": name, "quadruplets": f"{lo_q}-{hi_q}", "n": len(v), "median_us": us_text(m),
                          "median_ms": ms(m)})
    out.csv("e3_drift.csv", ("quantity", "quadruplets", "n", "median_us", "median_ms"), drift)
    out.csv("e3_flatness.csv", ("quad", "config", "n_rounds_1_21", "n_rounds_22_49", "late_minus_early_us",
                                "late_minus_early_ms", "abs_above_10_ms"), flat)
    judged = [f for f in flat if f["abs_above_10_ms"] != ""]
    above = sum(1 for f in judged if f["abs_above_10_ms"] == "yes")
    out.csv("e3_flatness_count.csv", ("runs", "runs_with_a_value", "runs_abs_above_10_ms"),
            [{"runs": len(flat), "runs_with_a_value": len(judged), "runs_abs_above_10_ms": above}])
    ch = next(x for x in tests if x["quantity"] == "c − h")
    n_above = sum(1 for d in diffs["c − h"].values() if d > TEN_MS_US)
    holds = ch["_hi"] is not None and ch["_hi"] <= TEN_MS_US
    expectation = [{"n": ch["n"], "median_c_minus_h_us": ch["median_us"], "median_c_minus_h_ms": ch["median_ms"],
                    "median_at_most_10_ms": "" if ch["_med"] is None else ("yes" if ch["_med"] <= TEN_MS_US
                                                                           else "no"),
                    "ci95_high_us": ch["ci95_high_us"], "ci95_high_ms": ch["ci95_high_ms"],
                    "ci95_high_at_most_10_ms": "" if ch["_hi"] is None else ("yes" if holds else "no"),
                    "quadruplets_above_10_ms": n_above,
                    "expectation_holds": "" if ch["_hi"] is None else ("yes" if holds else "no")}]
    out.csv("e3_expectation.csv", tuple(expectation[0]), expectation)

    out.md(f"Analysed quadruplets: n = {len(analysed)}. Round durations: `rounds.csv` `duration_us`, rounds by "
           f"their `round` number; write spans: `writes.csv` `total_us`, every write of the run. ms to 0.1 ms.", "")
    out.md("### Per run: median round duration over rounds 1 to 49 (ms)", "")
    out.table(["quad"] + [f"{c}" for c in CONFIGS] + ["rounds per run (n)"],
              [[q] + [ms(run_med[(q, c)]) or "–" for c in CONFIGS]
               + ["/".join(str(r["n_rounds"]) for r in run_rows if r["quad"] == q)] for q in analysed])
    out.md("### Per run: each steward's median write span (ms; c and h)", "")
    out.table(["quad"] + [f"{c} {s}" for c in ("c", "h") for s in STEWARDS],
              [[q] + [ms(spans[(q, c, s)]) or "–" for c in ("c", "h") for s in STEWARDS] for q in analysed])
    out.md("### Per quadruplet: c − a, c − h and the per-write c − h per steward (ms)", "")
    out.table(["quad", "c − a", "c − h"] + [f"per-write c − h {s}" for s in STEWARDS],
              [[r["quad"], ms(r["c − a"]) or "–", ms(r["c − h"]) or "–"] + [ms(r[s]) or "–" for s in STEWARDS]
               for r in qrows])
    out.md("### Tests: exact two-sided Wilcoxon signed-rank on the per-quadruplet differences; percentile-bootstrap "
           "95 % interval of their median (10,000 resamples, seed 20261114)", "")
    out.table(["quantity", "n", "median (ms)", "95 % interval (ms)", "T+", "T−", "non-zero", "zeros", "tied",
               "p (exact, two-sided)"],
              [[x["quantity"], x["n"], x["median_ms"] or "–",
                f"{x['ci95_low_ms']} to {x['ci95_high_ms']}" if x["ci95_low_ms"] else "–", x["T_plus"] or "–",
                x["T_minus"] or "–", x["wilcoxon_n_nonzero"], x["wilcoxon_zeros"], x["wilcoxon_tied"],
                x["p_exact_two_sided"] or "–"] for x in tests])
    out.md("p to 4 significant figures. T+ and T− are rank sums (mid-ranks for ties).", "")
    out.md("### Drift: the medians of the per-quadruplet differences, quadruplets 1 to 16 and 17 to 32", "")
    out.table(["quantity", "quadruplets", "n", "median (ms)"],
              [[d["quantity"], d["quadruplets"], d["n"], d["median_ms"] or "–"] for d in drift])
    out.md("### Flatness per run: median of rounds 22 to 49 minus median of rounds 1 to 21 (ms)", "")
    out.table(["quad"] + list(CONFIGS),
              [[q] + [next(f["late_minus_early_ms"] for f in flat if f["quad"] == q and f["config"] == c) or "–"
                      for c in CONFIGS] for q in analysed])
    out.md(f"Runs whose absolute value exceeds 10 ms: {above} of {len(judged)} runs with a value "
           f"({len(flat)} runs). Nothing is excluded by it.", "")
    out.md("### Expectation: c − h at most 10 ms a round (set 13 Sep 2026)", "")
    e = expectation[0]
    out.table(["n", "median c − h (ms)", "median ≤ 10 ms", "upper end of the 95 % interval (ms)",
               "upper end ≤ 10 ms", "quadruplets with c − h above 10 ms", "the expectation holds"],
              [[e["n"], e["median_c_minus_h_ms"] or "–", e["median_at_most_10_ms"] or "–",
                e["ci95_high_ms"] or "–", e["ci95_high_at_most_10_ms"] or "–", e["quadruplets_above_10_ms"],
                e["expectation_holds"] or "–"]])
    out.md("Compared unrounded, in µs: at most 10,000 µs; above means more than 10,000 µs.", "")


DESCRIPTIVE = "descriptive only; not a tested hypothesis; no verdict"


def matches(operation, record):
    """The harness's own matching rule (e1.py `matching`): same steward, op and decision, and for a write the same
    class and key."""
    return (record["steward"] == operation["steward"] and record["op"] == operation["expected_op"]
            and record["decision"] == operation["expected_decision"]
            and (operation["expected_op"] != "write"
                 or (record["state_class"], record["state_key"]) == (operation["state_class"],
                                                                    operation["state_key"])))


def section_completeness(out):
    """Completeness both ways, as counts. Descriptive: not a tested hypothesis, no verdict."""
    t = out.t
    out.md("## Descriptive check: E1 completeness both ways", "",
           "**Descriptive only. This count is not a tested hypothesis; it carries no pass or fail verdict and no "
           "test.** It counts one record per operation by time window, and one ALLOW record per state file. "
           "Units: every counted unit whose tables hold an `operations.csv`.", "")
    units = [u for u in (q["unit"] for q in t.queue) if u in t.counted
             and os.path.exists(os.path.join(t.counted[u], t.experiment[u], "operations.csv"))]
    window_rows, op_rows, file_rows = [], [], []
    for unit in units:
        operations = t.table(unit, "operations.csv")
        records = t.table(unit, "records.csv")
        comp_path = os.path.join(t.counted[unit], t.experiment[unit], "completeness.csv")
        completeness = t.table(unit, "completeness.csv") if os.path.exists(comp_path) else None
        stewards = []
        for r in operations + (completeness or []):
            if r["steward"] not in stewards:
                stewards.append(r["steward"])
        for steward in stewards:
            mine = [o for o in operations if o["steward"] == steward]
            counts = {"exactly_one": 0, "none": 0, "more_than_one": 0}
            for o in mine:
                sent, ret = as_int(o["sent_us"], "sent_us"), as_int(o["returned_us"], "returned_us")
                found = [r for r in records if matches(o, r) and sent <= as_int(r["decided_us"], "decided_us") <= ret]
                k = len(found)
                counts["none" if k == 0 else "exactly_one" if k == 1 else "more_than_one"] += 1
                window_rows.append({"status": DESCRIPTIVE, "unit": unit, "steward": steward, "clock": o["clock"],
                                    "sent_us": sent, "returned_us": ret, "operation": o["operation"],
                                    "identity": o["identity"], "state_class": o["state_class"],
                                    "state_key": o["state_key"], "expected_op": o["expected_op"],
                                    "expected_decision": o["expected_decision"], "records_in_window": k,
                                    "record_clocks": " ".join(sorted({r["clock"] for r in found}))})
            candidates = [r for r in records if any(matches(o, r) for o in mine)]
            unmatched = [r for r in candidates if not any(
                matches(o, r) and as_int(o["sent_us"], "sent_us") <= as_int(r["decided_us"], "decided_us")
                <= as_int(o["returned_us"], "returned_us") for o in mine)]
            op_rows.append({"status": DESCRIPTIVE, "unit": unit, "steward": steward, "operations": len(mine),
                            "operations_with_exactly_one_record": counts["exactly_one"],
                            "operations_with_no_record": counts["none"],
                            "operations_with_more_than_one_record": counts["more_than_one"],
                            "records_of_the_operations_kinds": len(candidates),
                            "records_matched_by_no_operation": len(unmatched)})
            comp = [c for c in completeness or [] if c["steward"] == steward]
            if comp:
                c = comp[0]
                none = len(c["unaudited"].split()) if c["unaudited"].strip() else 0
                file_rows.append({"status": DESCRIPTIVE, "unit": unit, "steward": steward, "claim": c["claim"],
                                  "state_files": c["state_files"], "write_allow_records": c["write_allow"],
                                  "state_files_with_no_write_allow_record": none,
                                  "state_files_with_exactly_one_write_allow_record": "not countable",
                                  "state_files_with_more_than_one_write_allow_record": "not countable"})
            else:
                file_rows.append({"status": DESCRIPTIVE, "unit": unit, "steward": steward, "claim": "",
                                  "state_files": "not countable", "write_allow_records": "",
                                  "state_files_with_no_write_allow_record": "not countable",
                                  "state_files_with_exactly_one_write_allow_record": "not countable",
                                  "state_files_with_more_than_one_write_allow_record": "not countable"})
    op_cols = ("status", "unit", "steward", "operations", "operations_with_exactly_one_record",
               "operations_with_no_record", "operations_with_more_than_one_record",
               "records_of_the_operations_kinds", "records_matched_by_no_operation")
    out.csv("descriptive_e1_completeness_operations.csv", op_cols, op_rows)
    out.csv("descriptive_e1_completeness_operation_windows.csv",
            ("status", "unit", "steward", "clock", "sent_us", "returned_us", "operation", "identity", "state_class",
             "state_key", "expected_op", "expected_decision", "records_in_window", "record_clocks"), window_rows)
    file_cols = ("status", "unit", "steward", "claim", "state_files", "write_allow_records",
                 "state_files_with_no_write_allow_record", "state_files_with_exactly_one_write_allow_record",
                 "state_files_with_more_than_one_write_allow_record")
    out.csv("descriptive_e1_completeness_state_files.csv", file_cols, file_rows)
    if not units:
        out.md("No counted unit has an `operations.csv`: nothing counted.", "")
        return
    out.md("### Operations to records (`operations.csv`, `records.csv`)", "",
           "An operation's window is its own `sent_us` to `returned_us`, both ends included. A record belongs to an "
           "operation when it has the operation's steward, expected op and expected decision, and for a write its "
           "class and key (the harness's matching rule), and is decided in the window. Windows of concurrent "
           "operations overlap, so one record can fall in several windows. \"Records matched by no operation\": "
           "records of a kind some operation of the steward expects, decided in no window of such an operation; "
           "records of other kinds are not counted. Per-operation counts in "
           "`descriptive_e1_completeness_operation_windows.csv`.", "")
    out.table(["unit", "steward", "operations", "exactly one record", "no record", "more than one record",
               "records of those kinds", "records matched by no operation"],
              [[r["unit"], r["steward"], r["operations"], r["operations_with_exactly_one_record"],
                r["operations_with_no_record"], r["operations_with_more_than_one_record"],
                r["records_of_the_operations_kinds"], r["records_matched_by_no_operation"]] for r in op_rows])
    out.md("### State files to write ALLOW records (`completeness.csv`)", "",
           "Not countable as asked: the extracted tables do not list the state files. `completeness.csv` gives per "
           "claim the number of state files, the number of write ALLOW records and the files without a write ALLOW "
           "record of their class and key (`unaudited`, files of another form included); the per-file listing is "
           "under `raw/`, which the laptop does not extract. So the files with no write ALLOW record are counted, "
           "and the files with exactly one and with more than one are not.", "")
    out.table(["unit", "steward", "state files", "write ALLOW records on the claim", "files with no write ALLOW",
               "files with exactly one", "files with more than one"],
              [[r["unit"], r["steward"], r["state_files"], r["write_allow_records"] or "–",
                r["state_files_with_no_write_allow_record"], r["state_files_with_exactly_one_write_allow_record"],
                r["state_files_with_more_than_one_write_allow_record"]] for r in file_rows])


SECTIONS = (("attempts", section_attempts), ("E1", section_e1), ("E2", section_e2), ("E4", section_e4),
            ("E5", section_e5), ("E3", section_e3), ("descriptive completeness", section_completeness))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--tables", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args(argv)
    if not os.path.isdir(args.tables):
        print(f"not a folder: {args.tables}", file=sys.stderr)
        return 2
    os.makedirs(args.out, exist_ok=True)
    tables = Tables(os.path.abspath(args.tables))
    out = Out(args.out, tables)
    head = ["# Results", "",
            f"- tables: `{tables.root}`",
            f"- computed by `compute.py`; values in µs, reported in ms to 0.1 ms (half away from zero); bytes and "
            f"counts as whole numbers; n beside every value",
            f"- bootstrap: percentile, {RESAMPLES:,} resamples, seed {SEED} (a fresh generator per interval); "
            f"percentiles by linear interpolation", ""]
    for name, fn in SECTIONS:
        try:
            fn(out)
        except MissingTable as error:
            out.failed.append(name)
            out.md(f"**{name}: not computed: {error}.**", "")
        except Exception as error:  # a crash stays visible in results.md and in the exit code
            out.failed.append(name)
            out.md(f"**{name}: the section raised {type(error).__name__}: {error}**", "", "```",
                   traceback.format_exc().rstrip(), "```", "")
    if NOTES["kind_lines"]:
        out.md(f"A kind-mode first line was skipped in {NOTES['kind_lines']} file(s).", "")
    out.md("## Files", "", *[f"- `{f}`" for f in out.files], "")
    if out.failed:
        head.append(f"**Sections not completed: {', '.join(out.failed)}.**")
        head.append("")
    with open(os.path.join(args.out, "results.md"), "w", encoding="utf-8") as handle:
        handle.write("\n".join(head + out.lines).rstrip() + "\n")
    print(f"results.md and {len(out.files)} CSV files in {args.out}"
          + (f"; sections not completed: {', '.join(out.failed)}" if out.failed else ""))
    return 1 if out.failed else 0


if __name__ == "__main__":
    sys.exit(main())
