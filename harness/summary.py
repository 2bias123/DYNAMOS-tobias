#!/usr/bin/env python3
import argparse
import csv
import pathlib
import statistics
import sys

import cluster

NAME = "SUMMARY.md"
INTERVALS = ("value_us", "duration_us", "total_us", "rtt_us", "after_due_us", "after_write_us", "persist_us",
             "audit_us", "decide_us", "reverify_us", "train_us")
GROUPS = ("case", "check", "event", "config", "steward")
KEYS = ("row", "case", "check", "gate", "steward", "subject", "claim", "trial", "episode", "test", "marker")
AGGREGATED = {"gates.csv": ("gate", "when"), "verdict.csv": ("check", "class")}


def tables(out):
    found = []
    for path in sorted(pathlib.Path(out).rglob("*.csv")):
        rel = path.relative_to(out)
        if "raw" in rel.parts:
            continue
        lines = path.read_text(errors="replace").splitlines()
        if lines and lines[0] == cluster.KIND_LINE:
            lines = lines[1:]
        found.append((rel, list(csv.DictReader(lines))))
    return found


def ms(us):
    return f"{us / 1000:.1f} ms"


FAILING = ("fail", "empty")


def passed(value):
    text = (value or "").strip()
    return text.lower() if text.lower() in ("pass", "fail") else text or "empty"


def checks_of(rel, rows):
    lines = []
    name = rel.name
    if not rows:
        return lines
    columns = rows[0].keys()
    if name == "markers.csv":
        for row in rows:
            hits = row.get("hits", "")
            lines.append(f"- check marker {row.get('marker')} ({row.get('text')}, {row.get('where')}): "
                         f"{'pass' if hits == '0' else 'fail'} ({hits} hits in {row.get('files')} files)")
        return lines
    if name in AGGREGATED and "result" in columns:
        groups = {}
        for row in rows:
            key = " · ".join(row.get(column, "") for column in AGGREGATED[name])
            groups.setdefault(key, []).append(passed(row.get("result")))
        for key, results in groups.items():
            failing = sum(result in FAILING for result in results)
            other = sorted({result for result in results if result != "pass" and result not in FAILING})
            lines.append(f"- check {rel} {key}: {'fail' if failing else 'pass'} ({len(results)} rows, {failing} failing"
                         f"{'; also ' + ', '.join(other) if other else ''})")
        return lines
    if "machines" in columns:
        two = [index for index, row in enumerate(rows, start=1) if not row.get("machines", "").startswith("one:")]
        lines.append(f"- check clocks {rel}: {'pass' if not two else 'fail'} ({len(rows)} intervals"
                     f"{', each on one machine' if not two else f', row {two[0]} on two machines'})")
    if "result" in columns:
        for index, row in enumerate(rows, start=1):
            key = " · ".join(row[column] for column in KEYS if column in columns and row.get(column)) or f"row {index}"
            lines.append(f"- check {rel} {key}: {passed(row.get('result'))}")
    return lines


def values_of(rel, rows):
    lines = []
    if not rows:
        return lines
    columns = rows[0].keys()
    group = next((column for column in GROUPS if column in columns), None)
    for column in INTERVALS:
        if column not in columns:
            continue
        buckets = {}
        for row in rows:
            text = (row.get(column) or "").strip()
            if text.lstrip("-").isdigit():
                buckets.setdefault(row.get(group, "") if group else "", []).append(int(text))
        for key, numbers in buckets.items():
            label = f" ({key})" if key else ""
            lines.append(f"- {rel} {column}{label}: n={len(numbers)}, minimum {ms(min(numbers))}, "
                         f"median {ms(statistics.median(numbers))}, maximum {ms(max(numbers))}")
    return lines


def cell(text):
    return (text or "").replace("|", "/").replace("\n", " ")


def write(out, experiment, unit, attempt, outcome, reason, missing, mode):
    out = pathlib.Path(out)
    found = tables(out)
    lines = [cluster.KIND_LINE, ""] if mode == "kind" else []
    lines += [f"# {experiment} {unit}, attempt {attempt}", "",
              f"- outcome: {outcome}{': ' + reason if reason else ''}", "", "## What ran", ""]
    lines += [f"- {rel}: {len(rows)} rows" for rel, rows in found] or ["- no CSV written"]
    lines += ["", "## Checks", "",
              f"- check missing values: {'pass' if not missing else 'fail'}"
              f"{' (' + missing[0] + f', {len(missing)} in all)' if missing else ''}"]
    for rel, rows in found:
        lines += checks_of(rel, rows)
    verdict = "pass" if outcome in ("pass", "expected failure seen") else outcome
    lines += [f"- check verdict: {verdict}", "", "## Values", "",
              "Intervals from the CSVs' µs values, in ms rounded to 0.1 ms; the median of an even n is the mean of "
              "the middle two.", ""]
    described = [line for rel, rows in found for line in values_of(rel, rows)]
    lines += described or ["- no interval column"]
    cases = next((rows for rel, rows in found if rel.name == "cases.csv"), None)
    if experiment == "e1" and cases:
        lines += ["", "## Rows", "", "| row | case | steward | expected | observed | result |", "|---|---|---|---|---|---|"]
        lines += [f"| {cell(row.get('row'))} | {cell(row.get('case'))} | {cell(row.get('steward'))} | "
                  f"{cell(row.get('expected'))} | {cell(row.get('observed'))} | {cell(row.get('result'))} |"
                  for row in cases]
    temporary = out / f"{NAME}.tmp"
    temporary.write_text("\n".join(lines) + "\n")
    temporary.replace(out / NAME)
    if not (out / NAME).is_file() or (out / NAME).stat().st_size == 0:
        raise OSError(f"{out / NAME} is empty after writing")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("folder")
    parser.add_argument("--experiment", required=True)
    parser.add_argument("--unit", required=True)
    parser.add_argument("--attempt", required=True)
    parser.add_argument("--outcome", required=True)
    parser.add_argument("--reason", default="")
    parser.add_argument("--mode", choices=["kind", "fabric"], required=True)
    args = parser.parse_args()
    import checks
    write(args.folder, args.experiment, args.unit, args.attempt, args.outcome, args.reason,
          checks.missing(args.folder), args.mode)
    return 0


if __name__ == "__main__":
    sys.exit(main())
