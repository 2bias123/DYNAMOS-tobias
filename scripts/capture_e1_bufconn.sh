#!/usr/bin/env bash
set -u

# Runs every unit test of the gateway package (the bufconn half of E1) and
# saves the raw go test output under
# results/campaign-n50/e1-decision-correctness/bufconn/, adding a line to that
# experiment's captures.md. The artifact ends with how many test functions
# ran. Among them: the write/read decision tables, identity
# checks (mismatch + registration latch), the write- and read-refused-when-
# audit-unavailable rows, the audit-before-rename invariant, the lock-conflict
# row, and the destroy rows (revocation purge, deferral, regrant-cancel,
# retain, invalid directives, boot rescan, purge event, retention-expiry
# delete/retain). -count=1 forces a fresh run so the capture can't be a
# cached result.
#
# Usage: capture_e1_bufconn.sh

root="$(cd "$(dirname "$0")/.." && pwd)"
# Override for shakedown runs that must not land in the evidence tree.
results_dir="${E1_RESULTS_DIR:-$root/results/campaign-n50/e1-decision-correctness}"
out_dir="$results_dir/bufconn"
ts="$(date +%Y%m%d-%H%M%S)"
out="$out_dir/${ts}_go-test-bufconn-oracle.txt"

cmd="go test -v -count=1 ./cmd/policy-checkpoint-gateway/"

run() {
	echo "\$ date"
	date
	echo
	echo "\$ git rev-parse HEAD"
	git -C "$root" rev-parse HEAD
	echo
	echo "\$ git status --short go/cmd/policy-checkpoint-gateway"
	git -C "$root" status --short go/cmd/policy-checkpoint-gateway
	echo
	echo "\$ go version"
	go version
	echo
	echo "\$ cd go && $cmd"
	(cd "$root/go" && go test -v -count=1 ./cmd/policy-checkpoint-gateway/)
}

mkdir -p "$out_dir"
run 2>&1 | tee "$out"
rc=${PIPESTATUS[0]}

# go test -v prints one unindented result line per test function; a
# subtest's is indented.
n=$(grep -cE '^--- (PASS|FAIL|SKIP): ' "$out")
{
	echo
	echo "tests run: $n test functions ($(grep -c '^--- PASS: ' "$out") passed, $(grep -c '^--- FAIL: ' "$out") failed, $(grep -c '^--- SKIP: ' "$out") skipped), $(grep -cE '^ +--- (PASS|FAIL|SKIP): ' "$out") subtests"
} | tee -a "$out"

commit="$(git -C "$root" rev-parse --short HEAD)"
note="E1 bufconn oracle run, whole package: $n test functions"
[ "$rc" -ne 0 ] && note="$note; FAILED (exit=$rc)"
echo "\`$(basename "$results_dir")/bufconn/${ts}_go-test-bufconn-oracle.txt | $ts | (cd go && $cmd) | $commit | $note\`" \
	>> "$results_dir/captures.md"

echo
echo "captured: $out (exit=$rc)"
exit "$rc"
