#!/usr/bin/env bash
# No idle process under store-only. The four steward agents get
# GATEWAY_STORE_ONLY=true the way the E3 capture sets it, before the reset.
# One run reaches done and leaves state on the server's claim. Over two
# supervision periods after the last job's enforcement point has ended, the
# agents go on with their passes over the claims, no steward namespace has an
# idle Job and no agent has logged that it started one. The variable is
# removed before the check ends, also when it fails.

set -u

EXP=GATE
root="$(cd "$(dirname "$0")/../../.." && pwd)"
. "$root/scripts/kind_gate/context.sh"
. "$root/scripts/capture_lib.sh"

CYCLES=3
USER_NAME="jake.jongejans@student.uva.nl"
STEWARD_NS=(server clientone clienttwo clientthree)
APIPORT=18080
ORCHPORT=18082
export PORT="$ORCHPORT"
POLL_MAX="$(poll_max_for_cycles "$CYCLES")"

NODE=stayup-control-plane
GATEWAY=policy-checkpoint-gateway
PERIOD=30
STARTED='Idle gateway started on PVC'
PASS='Supervision pass done, [1-9]'

disable_store_only() {
	local ns
	for ns in "${STEWARD_NS[@]}"; do
		kubectl set env "deployment/${ns}" -n "$ns" GATEWAY_STORE_ONLY- >/dev/null 2>&1
	done
}

PIDS=()
cleanup() {
	local p
	disable_store_only
	for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done
	pkill -f "port-forward.*${APIPORT}:8080" 2>/dev/null
}
trap cleanup EXIT

seconds() { date -d "$1" +%s; }

# The log of the steward's agent, without an agent that is on its way out.
agent_log() { # $1 = steward namespace
	local pod
	pod=$(kubectl -n "$1" get pods -l type=agent -o json 2>/dev/null \
		| jq -r '[.items[] | select(.metadata.deletionTimestamp == null)] | sort_by(.metadata.creationTimestamp) | last | .metadata.name // empty')
	[ -n "$pod" ] || return 0
	kubectl -n "$1" logs "$pod" -c "$1" --tail=-1 --timestamps 2>/dev/null
}

idle_jobs() { kubectl -n "$1" get jobs -l dynamos/gateway=idle -o name 2>/dev/null; }

store_only_set() { # $1 = steward namespace; whether the agent's container in its deployment carries the variable
	local deployment
	deployment=$(kubectl -n "$1" get deployment "$1" -o json) || fail "cannot read the agent's deployment in $1"
	echo "$deployment" \
		| jq -e --arg c "$1" '[.spec.template.spec.containers[] | select(.name == $c) | .env[]? | select(.name == "GATEWAY_STORE_ONLY")] | length == 1' >/dev/null
}

# Wait until the enforcement point of a chain pod has ended; prints when.
gateway_ended() { # $1 ns, $2 pod, $3 deadline in seconds
	local i ended
	for i in $(seq 1 "$3"); do
		ended=$(kubectl -n "$1" get pod "$2" -o json 2>/dev/null \
			| jq -r --arg c "$GATEWAY" '.status.containerStatuses[]? | select(.name == $c) | .state.terminated.finishedAt // empty')
		if [ -n "$ended" ]; then
			echo "$ended"
			return 0
		fi
		sleep 1
	done
	return 1
}

state_files() { # $1 ns, $2 claim
	local vol
	vol=$(kubectl get pvc -n "$1" "$2" -o jsonpath='{.spec.volumeName}')
	docker exec "$NODE" sh -c "find '/var/local-path-provisioner/${vol}_$1_$2/data' -name '*.bin' 2>/dev/null | wc -l"
}

# The agent's passes over at least one claim that were logged after a time.
passes_since() { # $1 ns, $2 time in seconds
	local n=0 ts
	while read -r ts _; do
		[ "$(seconds "$ts")" -gt "$2" ] && n=$((n + 1))
	done < <(agent_log "$1" | grep "$PASS")
	echo "$n"
}

run_chain() {
	local rid
	reset_and_seed
	delete_state_pvcs
	rid=$(trigger "$CYCLES") || exit 1
	( wait_done "$rid" ) >/dev/null
}

# As in the baseline check: a chain service that gave up dialing its
# neighbour leaves the run pending.
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

step "GATEWAY_STORE_ONLY=true on the four steward agents, before the reset"
for ns in "${STEWARD_NS[@]}"; do
	kubectl set env "deployment/${ns}" -n "$ns" GATEWAY_STORE_ONLY=true >/dev/null \
		|| fail "could not set GATEWAY_STORE_ONLY on $ns"
done
for ns in "${STEWARD_NS[@]}"; do
	kubectl -n "$ns" rollout status "deployment/$ns" --timeout=120s >/dev/null \
		|| fail "the agent in $ns did not roll out with GATEWAY_STORE_ONLY"
done

step "reset, the state claims deleted, one run (cycles=${CYCLES})"
for try in 1 2 3; do
	run_chain && break
	lost_start_race || fail "the run did not reach done, and no service gave up dialing its neighbour"
	[ "$try" -lt 3 ] || fail "the run lost the start race three times"
	echo "START RACE: a chain service gave up dialing its neighbour before it listened; repeating the run"
done

step "the jobs' enforcement points ran store-only and have ended; the server's claim holds state"
last=0
for ns in "${STEWARD_NS[@]}"; do
	store_only_set "$ns" || fail "the agent's deployment in $ns does not carry GATEWAY_STORE_ONLY"
	pvc=$(state_pvc_of "$ns")
	[ -n "$pvc" ] || fail "no state claim in $ns"
	pod=$(steward_pod "$ns")
	[ -n "$pod" ] || fail "no chain pod in $ns"
	kubectl -n "$ns" get pod "$pod" -o json | jq -e --arg c "$GATEWAY" '
		.spec.containers[] | select(.name == $c)
		| [.env[] | select(.name == "GATEWAY_STORE_ONLY" and .value == "true")] | length == 1' >/dev/null \
		|| fail "the enforcement point in $ns/$pod was not deployed with GATEWAY_STORE_ONLY=true"
	ended=$(gateway_ended "$ns" "$pod" 120) \
		|| fail "the enforcement point in $ns/$pod had not ended 120s after the run was done"
	[ "$(seconds "$ended")" -gt "$last" ] && last=$(seconds "$ended")
	echo "    $ns/$pod: enforcement point ended $ended, claim $pvc"
done
files=$(state_files server "$(state_pvc_of server)")
[ "$files" -ge 1 ] || fail "the server's claim holds no state file after the run"
echo "OK: four enforcement points ended, the last at $(date -d "@$last" +%T); the server's claim holds $files state files"

step "over two periods after that: no idle Job, no idle start logged"
while :; do
	for ns in "${STEWARD_NS[@]}"; do
		[ -z "$(idle_jobs "$ns")" ] || fail "$ns has an idle Job under store-only: $(idle_jobs "$ns")"
	done
	[ $(( $(date +%s) - last )) -ge $(( 2 * PERIOD + 5 )) ] && break
	sleep 5
done
for ns in "${STEWARD_NS[@]}"; do
	agent_log "$ns" | grep -q "$STARTED" && fail "the agent in $ns logged that it started an idle process under store-only"
	passes=$(passes_since "$ns" "$last")
	[ "$passes" -ge 2 ] || fail "the agent in $ns logged $passes passes over its claim since the last enforcement point ended, expected at least 2"
	echo "    $ns: $passes passes over its claim, no idle Job, no idle start logged"
done
echo "OK: $(( $(date +%s) - last ))s after the last enforcement point ended, no steward namespace has an idle Job"

step "the variable is removed from the four agents"
disable_store_only
for ns in "${STEWARD_NS[@]}"; do
	kubectl -n "$ns" rollout status "deployment/$ns" --timeout=120s >/dev/null \
		|| fail "the agent in $ns did not roll out without GATEWAY_STORE_ONLY"
	store_only_set "$ns" && fail "the agent's deployment in $ns still carries GATEWAY_STORE_ONLY"
done
echo "OK: GATEWAY_STORE_ONLY is off the four steward agents"
