#!/usr/bin/env bash
set -u

# Audit completeness invariant: every state file data/<class>/<key>.bin has an
# ALLOW write audit line for that class/key in audit/audit.log. The gateway
# appends and fsyncs the line before the file is renamed into place, so a
# violation means either tampering or a bug.
#
# Usage:
#   check_audit_completeness.sh <state-dir>          local state directory
#   check_audit_completeness.sh <namespace> <pod>    live gateway container

files_tmp=$(mktemp)
log_tmp=$(mktemp)
trap 'rm -f "$files_tmp" "$log_tmp"' EXIT

if [ $# -eq 1 ]; then
	(cd "$1/data" 2>/dev/null && find . -name '*.bin') | sed 's|^\./||' > "$files_tmp"
	cat "$1/audit/audit.log" 2>/dev/null > "$log_tmp"
elif [ $# -eq 2 ]; then
	kubectl exec -n "$1" "$2" -c policy-checkpoint-gateway -- \
		sh -c 'cd /state/data 2>/dev/null && find . -name "*.bin"' 2>/dev/null | sed 's|^\./||' > "$files_tmp"
	kubectl exec -n "$1" "$2" -c policy-checkpoint-gateway -- \
		cat /state/audit/audit.log 2>/dev/null > "$log_tmp"
else
	echo "usage: $0 <state-dir> | $0 <namespace> <pod>" >&2
	exit 2
fi

python3 - "$files_tmp" "$log_tmp" << 'PY'
import json, sys

with open(sys.argv[1]) as f:
    files = [l.strip() for l in f if l.strip()]

allowed = set()
lines = 0
with open(sys.argv[2]) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        lines += 1
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            print(f"UNPARSEABLE audit line: {line[:80]}")
            continue
        if rec.get("op") == "write" and rec.get("decision") == "ALLOW":
            allowed.add((rec.get("stateClass"), rec.get("stateKey")))

missing = []
for path in files:
    parts = path.split("/")
    if len(parts) != 2 or not parts[1].endswith(".bin"):
        continue
    pair = (parts[0], parts[1][: -len(".bin")])
    if pair not in allowed:
        missing.append(path)

print(f"state files: {len(files)}  audit lines: {lines}  allow-writes: {len(allowed)}")
if missing:
    for m in missing:
        print(f"MISSING audit line for state file: {m}")
    print(f"COMPLETENESS FAIL: {len(missing)} unaudited state file(s)")
    sys.exit(1)
print("COMPLETENESS PASS: every state file has an ALLOW audit line")
PY
