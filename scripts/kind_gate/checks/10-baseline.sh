#!/usr/bin/env bash
# Baseline: the request path restarts clean, one three-round VFL run reaches
# done, the server job's enforcement point logs one allowed write per round,
# and every DYNAMOS container on the cluster runs the branch's tag.

set -u

EXP=GATE
root="$(cd "$(dirname "$0")/../../.." && pwd)"
. "$root/scripts/kind_gate/context.sh"
. "$root/scripts/capture_lib.sh"

TAG=stay-up-enforcement
CYCLES=3
USER_NAME="jake.jongejans@student.uva.nl"
STEWARD_NS=(server clientone clienttwo clientthree)
APIPORT=18080
ORCHPORT=18082
export PORT="$ORCHPORT"
POLL_MAX="$(poll_max_for_cycles "$CYCLES")"

PIDS=()
cleanup() {
	local p
	for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done
	pkill -f "port-forward.*${APIPORT}:8080" 2>/dev/null
}
trap cleanup EXIT

run_chain() {
	local rid
	step "reset + canonical seed, then delete the state PVCs (clean slate)"
	reset_and_seed
	delete_state_pvcs

	step "trigger the chain (cycles=${CYCLES})"
	rid=$(trigger "$CYCLES") || exit 1
	( wait_done "$rid" ) >/dev/null
}

# A chain service dials its neighbour for seven seconds and then gives up
# for good. On a node that starts these images for the first time the model
# service can take longer than that to listen, and the run stays pending.
lost_start_race() {
	local ns pod
	for ns in "${STEWARD_NS[@]}"; do
		pod=$(steward_pod "$ns")
		[ -n "$pod" ] || continue
		kubectl logs -n "$ns" "$pod" --all-containers 2>/dev/null \
			| grep -q 'Could not connect with gRPC localhost:[0-9]* after 7 tries' && return 0
	done
	return 1
}

if ! run_chain; then
	lost_start_race || fail "the run did not reach done, and no service gave up dialing its neighbour"
	echo "START RACE: a chain service gave up dialing its neighbour before it listened; repeating the run once"
	run_chain || fail "the repeated run did not reach done"
fi

step "one allowed write per round on the server's enforcement point"
pod=$(steward_pod server)
[ -n "$pod" ] || fail "no chain pod in server"
allow_n=$(kubectl logs -n server "$pod" -c policy-checkpoint-gateway 2>&1 | grep -c '"op":"write","decision":"ALLOW"')
[ "$allow_n" -eq "$CYCLES" ] || fail "expected $CYCLES ALLOW write audit lines on the server gateway, got $allow_n"
echo "OK: $allow_n ALLOW write audit lines, one per round"

step "every DYNAMOS container runs the tag ${TAG}"
images=$(kubectl get pods -A -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' \
	| grep -E '^(docker\.io/)?(dynamos1|tamjiyan|2bias123)/' | sort -u)
echo "$images"
for ns in "${STEWARD_NS[@]}"; do
	pod=$(steward_pod "$ns")
	[ -n "$pod" ] || fail "no chain pod in $ns"
	kubectl get pod -n "$ns" "$pod" -o jsonpath='{.spec.containers[*].image}' | grep -q "/policy-checkpoint-gateway:${TAG}" \
		|| fail "the chain pod in $ns has no enforcement point container on tag ${TAG}"
done
other=$(echo "$images" | grep -v ":${TAG}\$")
[ -z "$other" ] || fail "DYNAMOS images on another tag: $other"
echo "OK: all on ${TAG}"
