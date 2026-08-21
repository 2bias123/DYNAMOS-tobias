#!/usr/bin/env bash
set -u

# E1 closing invariant: every file under /state/data on every steward PVC maps
# to a recorded ALLOW write audit line in that PVC's audit/audit.log. A state
# file with no ALLOW line behind it got there outside the governed path
# (tampering or a bug), and that fails the check.
#
# This reads the PERSISTED state, not a live gateway. The gateway exits a couple
# of seconds after the chain shuts down, so a post-run check has to read the PVC
# directly. For each steward it frees the state PVC (drops the lingering chain
# Job), mounts it read-only in a throwaway inspector pod, pulls /state to the
# host, and runs check_audit_completeness.sh in local-dir mode. The completeness
# logic itself lives in that script; this only gathers the state and captures
# the result.
#
# Run it after an E1 live run, while that run's state is still on the PVCs.
# Dropping the lingering Jobs is the same thing reset.sh does; the state PVCs
# survive it.
#
# Output goes to results/e1-decision-correctness/audit-completeness/ with a
# captures.md line. Exits non-zero if any steward fails.
#
# Usage: capture_e1_completeness.sh

EXP=E1
root="$(cd "$(dirname "$0")/.." && pwd)"
# Override for shakedown runs that must not land in the evidence tree.
results_dir="${E1_RESULTS_DIR:-$root/results/e1-decision-correctness}"
. "$root/scripts/capture_lib.sh"

STEWARD_NS=(server clientone clienttwo clientthree)
# A node-present image with python3; the chain client image fits and is already
# loaded in kind. python3 keeps the pod alive and tars /state to the host.
INSPECTOR_IMAGE="${INSPECTOR_IMAGE:-tamjiyan/vfl-train-demo:latest}"
INSPECTOR=e1-inspector

# Drop lingering chain Jobs in $1 and wait for their pods to release the PVC.
free_pvc() {
	local ns="$1" i
	kubectl -n "$ns" delete jobs --all --ignore-not-found=true --wait=true >/dev/null 2>&1
	kubectl -n "$ns" delete pod "$INSPECTOR" --ignore-not-found=true --wait=true >/dev/null 2>&1
	for i in $(seq 1 30); do
		kubectl get pods -n "$ns" -o name 2>/dev/null | grep -q jake || return 0
		sleep 2
	done
}

# Mount the steward's state PVC read-only in an inspector pod, pull /state to a
# host temp dir, run the completeness check, delete the pod. Returns the check's
# exit code.
inspect_steward() {
	local ns="$1" tmp rc=0
	free_pvc "$ns"
	if ! start_state_inspector "$ns" "$INSPECTOR" "$INSPECTOR_IMAGE"; then
		kubectl -n "$ns" delete pod "$INSPECTOR" --ignore-not-found=true --wait=false >/dev/null 2>&1
		return 1
	fi

	# Streaming tar mode ("w|"): kubectl exec's stdout is a non-seekable pipe,
	# and the default "w" mode calls tell() on it, which fails with Illegal seek.
	tmp=$(mktemp -d)
	kubectl exec -n "$ns" "$INSPECTOR" -c inspector -- python3 -c \
		'import tarfile,sys; t=tarfile.open(fileobj=sys.stdout.buffer, mode="w|"); t.add("/state", arcname="state"); t.close()' \
		> "$tmp/state.tar" 2>"$tmp/gather.err"
	kubectl -n "$ns" delete pod "$INSPECTOR" --ignore-not-found=true --wait=false >/dev/null 2>&1

	if ! tar xf "$tmp/state.tar" -C "$tmp" 2>/dev/null; then
		echo "[$ns] could not read /state off the PVC"
		[ -s "$tmp/gather.err" ] && sed 's/^/[gather] /' "$tmp/gather.err"
		rm -rf "$tmp"
		return 1
	fi
	"$root/scripts/check_audit_completeness.sh" "$tmp/state" || rc=1
	rm -rf "$tmp"
	return "$rc"
}

do_completeness() {
	local ns fails=0
	for ns in "${STEWARD_NS[@]}"; do
		step "steward $ns"
		inspect_steward "$ns" || fails=$((fails + 1))
	done
	echo
	[ "$fails" -eq 0 ] || fail "completeness FAILED in $fails of ${#STEWARD_NS[@]} stewards"
	echo "OK: completeness PASS on all ${#STEWARD_NS[@]} steward PVCs"
}

run_capture audit-completeness completeness-invariant "scripts/capture_e1_completeness.sh" do_completeness \
	"E1 closing invariant: every /state/data/*.bin maps to an ALLOW audit line on all four steward PVCs (persisted-state check via inspector pods)"
