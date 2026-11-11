#!/usr/bin/env bash
# Hand-over at deploy. After the reset the server's agent has put its idle
# Job on the server's state claim, and the idle process holds the lock. A
# run is triggered: the server's agent stops the idle Job before it creates
# the chain Job, the chain job's enforcement point serves, the service
# connects to it, and every round's write is allowed. The claim must hold
# state younger than its retention, which the baseline run leaves; on an
# empty claim an idle process exits at once.

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

NODE=stayup-control-plane
NS=server
GATEWAY=policy-checkpoint-gateway
IMAGE="tamjiyan/$GATEWAY:$TAG"
HANDED_OVER='No idle gateway left on PVC'
NOT_STOPPED=IDLE_GATEWAY_NOT_STOPPED
LOCK_MARKER=STATE_LOCK_NOT_ACQUIRED

PIDS=()
out_dir="$(mktemp -d)"
cleanup() {
	local p
	for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done
	pkill -f "port-forward.*${APIPORT}:8080" 2>/dev/null
	rm -rf "$out_dir"
}
trap cleanup EXIT

annotation() { # $1 claim, $2 key
	kubectl -n "$NS" get pvc "$1" -o json | jq -r --arg k "$2" '.metadata.annotations[$k] // empty'
}

agent_log() { # $1 = steward namespace
	kubectl -n "$1" logs -l type=agent -c "$1" --tail=-1 --timestamps 2>/dev/null
}

# The reset restarts every agent, so its log holds this check's deploy only.
handed_over() { # $1 = steward namespace; prints its one hand-over line
	local lines
	lines=$(agent_log "$1" | grep "$HANDED_OVER")
	[ "$(echo "$lines" | grep -c .)" -eq 1 ] || fail "expected one hand-over line in the log of the agent in $1, got: ${lines:-none}"
	echo "$lines"
}

seconds() { date -d "$1" +%s; }
nanos() { date -d "$1" +%s%N; }

step "reset; the server's claim holds state"
reset_and_seed
pvc=$(state_pvc_of "$NS")
[ -n "$pvc" ] || fail "no state claim in $NS"
vol=$(kubectl get pvc -n "$NS" "$pvc" -o jsonpath='{.spec.volumeName}')
[ -n "$vol" ] || fail "the claim $pvc is not bound"
files=$(docker exec "$NODE" sh -c "find '/var/local-path-provisioner/${vol}_${NS}_${pvc}/data' -name '*.bin' 2>/dev/null | wc -l")
[ "$files" -ge 1 ] || fail "the claim $pvc holds no state file"
steward=$(annotation "$pvc" dynamos/data-steward)
user=$(annotation "$pvc" dynamos/request-user)
request_type=$(annotation "$pvc" dynamos/request-type)
{ [ -n "$steward" ] && [ -n "$user" ] && [ -n "$request_type" ]; } || fail "the claim $pvc is not stamped"
echo "OK: $pvc holds $files state files, stamped $steward, $user, $request_type"

step "the agent's idle Job on the claim holds the lock"
idle="idle-$pvc"
idle_pod=""
for i in $(seq 1 60); do
	idle_pod=$(kubectl -n "$NS" get pods -l job-name="$idle" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
	[ -n "$idle_pod" ] && kubectl -n "$NS" logs "$idle_pod" 2>/dev/null | grep -q 'Agreement loaded' && break
	sleep 1
done
kubectl -n "$NS" logs "$idle_pod" 2>/dev/null | grep -q 'Agreement loaded' \
	|| fail "no idle process of the agent's read the agreement on $pvc, so none holds the lock"
agent_log "$NS" | grep -q "Idle gateway started on PVC $pvc" || fail "the agent in $NS did not log that it started the idle process on $pvc"
containers=$(kubectl -n "$NS" get pod "$idle_pod" -o jsonpath='{.spec.containers[*].name}')
[ "$containers" = "$GATEWAY" ] || fail "the idle pod has the containers '$containers', expected only $GATEWAY"
kubectl -n "$NS" get pod "$idle_pod" -o json | jq -e --arg s "$steward" --arg u "$user" --arg t "$request_type" --arg img "$IMAGE" '
	.spec.containers[0] | .image == $img
	and ((.env | map({(.name): .value}) | add)
		== {DATA_STEWARD_NAME: $s, REQUEST_USER: $u, REQUEST_TYPE: $t, GATEWAY_IDLE: "true", STATE_DIR: "/state"})' >/dev/null \
	|| fail "the idle pod $idle_pod does not run $IMAGE under the claim's identity"
kubectl -n "$NS" logs -f --timestamps "$idle_pod" > "$out_dir/idle.log" 2>&1 &
PIDS+=($!)
phase=$(kubectl -n "$NS" get pod "$idle_pod" -o jsonpath='{.status.phase}')
[ "$phase" = Running ] || fail "the idle pod is $phase before the run: the state on $pvc is gone or older than its retention"
echo "OK: $idle_pod runs and holds the lock on $pvc"

step "trigger the chain (cycles=${CYCLES}) while the idle process holds the lock"
rid=$(trigger "$CYCLES") || exit 1
( wait_done "$rid" ) >/dev/null || fail "the run did not reach done"
pod=$(steward_pod "$NS")
[ -n "$pod" ] || fail "no chain pod in $NS"
job=$(kubectl get jobs -n "$NS" -o name | grep jake | head -1 | cut -d/ -f2)
[ -n "$job" ] || fail "no chain job in $NS"

step "the agent stopped the idle Job before it created the chain Job"
line=$(handed_over "$NS") || exit 1
echo "    $line"
echo "$line" | grep -q "$HANDED_OVER $pvc " || fail "the hand-over line of the agent in $NS does not name $pvc"
agent_log "$NS" | grep -q "$NOT_STOPPED" && fail "the agent in $NS logged $NOT_STOPPED"
kubectl -n "$NS" get job "$idle" >/dev/null 2>&1 && fail "the idle Job $idle is still there"
left=$(kubectl -n "$NS" get pods -l job-name="$idle" -o name 2>/dev/null)
[ -z "$left" ] || fail "the idle Job's pod is still there: $left"
stop_line=$(grep 'Stop signal received' "$out_dir/idle.log" | head -1)
[ -n "$stop_line" ] || fail "the idle process did not log a stop signal before it went"
signalled=${stop_line%% *}
handed=${line%% *}
created=$(kubectl -n "$NS" get job "$job" -o jsonpath='{.metadata.creationTimestamp}')
started=$(kubectl -n "$NS" get pod "$pod" -o json | jq -r --arg c "$GATEWAY" \
	'.status.containerStatuses[] | select(.name == $c) | (.state.running.startedAt // .state.terminated.startedAt)')
[ -n "$started" ] || fail "the chain pod's enforcement point has no start time"
[ "$(nanos "$signalled")" -le "$(nanos "$handed")" ] || fail "the hand-over was logged at $handed, before the stop signal at $signalled"
# A Job's creation time has whole seconds only.
[ "$(seconds "$handed")" -le "$(seconds "$created")" ] || fail "the chain Job was created at $created, before the hand-over was logged at $handed"
[ "$(seconds "$created")" -le "$(seconds "$started")" ] || fail "the enforcement point started at $started, before its Job was created at $created"
echo "OK: stop signal $signalled, hand-over logged $handed (${line##* after }), chain Job created $created, its enforcement point started $started"

step "the chain job's enforcement point served, and the service connected to it"
gateway_log=$(kubectl logs -n "$NS" "$pod" -c "$GATEWAY" 2>&1)
echo "$gateway_log" | grep -q 'Serving on' || fail "the enforcement point in $NS/$pod did not serve"
echo "$gateway_log" | grep -q "$LOCK_MARKER" && fail "the enforcement point in $NS/$pod printed $LOCK_MARKER"
restarts=$(kubectl -n "$NS" get pod "$pod" -o json | jq -r --arg c "$GATEWAY" '.status.containerStatuses[] | select(.name == $c) | .restartCount')
[ "$restarts" = 0 ] || fail "the enforcement point in $NS/$pod was restarted ${restarts:-an unknown number of} times"
pod_log=$(kubectl logs -n "$NS" "$pod" --all-containers 2>&1)
echo "$pod_log" | grep -q 'Gateway connected, state-event listener started' \
	|| fail "no service in $NS/$pod logged that it connected to the enforcement point"
echo "$pod_log" | grep -q 'No policy gateway reachable' && fail "a service in $NS/$pod went on without the enforcement point"
allow_n=$(echo "$gateway_log" | grep -c '"op":"write","decision":"ALLOW"')
[ "$allow_n" -eq "$CYCLES" ] || fail "expected $CYCLES ALLOW write audit lines on the server gateway, got $allow_n"
echo "OK: served, the service connected, $allow_n ALLOW write audit lines, one per round"

step "the other stewards: one hand-over each, none of them failed"
for ns in clientone clienttwo clientthree; do
	line=$(handed_over "$ns") || exit 1
	agent_log "$ns" | grep -q "$NOT_STOPPED" && fail "the agent in $ns logged $NOT_STOPPED"
	echo "OK: $ns: ${line##* after }"
done
