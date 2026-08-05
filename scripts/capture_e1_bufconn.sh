#!/usr/bin/env bash
set -u

# Runs the E1 unit tests (the bufconn half of E1) and saves the raw go test
# output under results/e1-decision-correctness/bufconn/, adding a line to that
# experiment's captures.md. Covers the write/read decision tables, identity
# checks (mismatch + registration latch), the write- and read-refused-when-
# audit-unavailable rows, the audit-before-rename invariant, the lock-conflict
# row, and the destroy rows (revocation purge, deferral, regrant-cancel,
# retain, invalid directives, boot rescan, purge event, retention-expiry
# delete/retain). -count=1 forces a fresh run so the capture can't be a
# cached result.
#
# Usage: capture_e1_bufconn.sh

root="$(cd "$(dirname "$0")/.." && pwd)"
out_dir="$root/results/e1-decision-correctness/bufconn"
ts="$(date +%Y%m%d-%H%M%S)"
out="$out_dir/${ts}_go-test-bufconn-oracle.txt"

tests='^(TestDecideWrite|TestDecideRead|TestRequestStateWriteAllowsAndPersists|TestValidateStateReadExistingAndMissing|TestReadDenialHidesFileExistence|TestWriteDeniedWhenCacheStale|TestWriteDeniedAfterPolicyFlip|TestIdentityMismatchDeniedAndAudited|TestUnregisteredIdentityDenied|TestAcquireLockConflict|TestWriteProducesLineBeforeFileInvariantHolds|TestWriteRefusedWhenAuditUnavailable|TestCrashBetweenAuditAndRenameLeavesLineNoFile|TestReadRefusedWhenAuditUnavailable|TestSweepPurgesRevokedStateAfterConfirm|TestSweepDefersWhenConfirmFails|TestSweepCancelsOnRegrant|TestSweepRetainsWithoutPurgeDirective|TestSweepInvalidDirectivesAuditedNoPurge|TestBootIntoRevokedPurgesAtStartup|TestPurgeEventReachesSubscriber|TestSweepDeletesExpiredAfterConfirm|TestSweepRetainsExpiredWhenConfirmFails)$'
cmd="go test -v -count=1 -run '$tests' ./cmd/policy-checkpoint-gateway/"

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
	(cd "$root/go" && go test -v -count=1 -run "$tests" ./cmd/policy-checkpoint-gateway/)
}

mkdir -p "$out_dir"
run 2>&1 | tee "$out"
rc=${PIPESTATUS[0]}

commit="$(git -C "$root" rev-parse --short HEAD)"
note="E1 bufconn oracle run"
[ "$rc" -ne 0 ] && note="$note; FAILED (exit=$rc)"
echo "\`e1-decision-correctness/bufconn/${ts}_go-test-bufconn-oracle.txt | $ts | (cd go && $cmd) | $commit | $note\`" \
	>> "$root/results/e1-decision-correctness/captures.md"

echo
echo "captured: $out (exit=$rc)"
exit "$rc"
