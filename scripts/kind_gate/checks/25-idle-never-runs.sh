#!/usr/bin/env bash
# An idle Job whose enforcement point never runs covers nothing. After a run
# the server's claim holds state and the agent's idle process holds the
# claim. The idle Job is then replaced by a Job of its name and pod template
# whose pod no node takes: it stays Pending, and nothing is pulled. Within
# 120 s plus three periods of the planted Job's creation:
#   - the agent logs IDLE_GATEWAY_NOT_RUNNING for the claim, no earlier than
#     120 s after the creation
#   - the planted Job is gone
#   - an idle Job of the agent's is on the claim and its process holds the
#     lock

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

NS=server
GATEWAY=policy-checkpoint-gateway
IMAGE="tamjiyan/$GATEWAY:$TAG"
PERIOD=30
AFTER=120
NOT_RUNNING=IDLE_GATEWAY_NOT_RUNNING
NO_NODE=stayup-gate/no-such-node

PIDS=()
pvc=""
planted=""

cleanup() {
	local rc=$? p
	if [ "$rc" != 0 ]; then
		echo "--- $NS at the failure"
		kubectl -n "$NS" get jobs,pods,pvc 2>&1
		agent_log "$NS" | grep -E "Idle|idle|Supervision of" | tail -n 20
	fi
	# A planted Job that is still there would keep the claim without an idle
	# process.
	if [ -n "$planted" ] && [ "$(job_uid "idle-$pvc")" = "$planted" ]; then
		kubectl -n "$NS" delete job "idle-$pvc" --wait=false >/dev/null 2>&1
	fi
	for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done
	pkill -f "port-forward.*${APIPORT}:8080" 2>/dev/null
}
trap cleanup EXIT

seconds() { date -d "$1" +%s; }

annotation() { # $1 claim, $2 key
	kubectl -n "$NS" get pvc "$1" -o json | jq -r --arg k "$2" '.metadata.annotations[$k] // empty'
}

# The log of the steward's agent, without an agent that is on its way out.
agent_log() { # $1 = steward namespace
	local pod
	pod=$(kubectl -n "$1" get pods -l type=agent -o json 2>/dev/null \
		| jq -r '[.items[] | select(.metadata.deletionTimestamp == null)] | sort_by(.metadata.creationTimestamp) | last | .metadata.name // empty')
	[ -n "$pod" ] || return 0
	kubectl -n "$1" logs "$pod" -c "$1" --tail=-1 --timestamps 2>/dev/null
}

job_uid() { kubectl -n "$NS" get job "$1" -o jsonpath='{.metadata.uid}' 2>/dev/null; }

# Prints when the claim's idle process read the agreement, which it does
# only once it holds the lock.
idle_up_at() {
	local pod line
	pod=$(kubectl -n "$NS" get pods -l job-name="idle-$pvc" -o json 2>/dev/null \
		| jq -r '[.items[] | select(.metadata.deletionTimestamp == null and .status.phase == "Running")] | first | .metadata.name // empty')
	[ -n "$pod" ] || return 1
	line=$(kubectl -n "$NS" logs "$pod" --timestamps 2>/dev/null | grep 'Agreement loaded' | head -1)
	[ -n "$line" ] || return 1
	echo "${line%% *}"
}

first_run() {
	local rid
	reset_and_seed
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

step "reset, one run; the server's claim holds state and its idle process holds the claim"
for try in 1 2 3; do
	first_run && break
	lost_start_race || fail "the run did not reach done, and no service gave up dialing its neighbour"
	[ "$try" -lt 3 ] || fail "the run lost the start race three times"
	echo "START RACE: a chain service gave up dialing its neighbour before it listened; repeating the run"
done
pvc=$(state_pvc_of "$NS")
[ -n "$pvc" ] || fail "no state claim in $NS"
up=""
for i in $(seq 1 210); do
	up=$(idle_up_at) && break
	sleep 1
done
[ -n "$up" ] || fail "no idle process holds the lock on $NS/$pvc 210s after the run"
echo "OK: the agent's idle process holds the lock on $pvc since $up"

step "the idle Job is replaced by one of its name and pod template whose pod no node takes"
manifest=$(kubectl -n "$NS" get job "idle-$pvc" -o json | jq --arg k "$NO_NODE" '{apiVersion, kind,
	metadata: {name: .metadata.name, namespace: .metadata.namespace, labels: {"dynamos/gateway": "idle"}},
	spec: {template: {metadata: {labels: {"dynamos/gateway": "idle"}},
		spec: (.spec.template.spec + {nodeSelector: {($k): "true"}})}}}')
[ -n "$manifest" ] || fail "cannot read the idle Job idle-$pvc"
for try in 1 2 3; do
	kubectl -n "$NS" delete job "idle-$pvc" --cascade=foreground --wait=true --timeout=60s >/dev/null 2>&1
	if echo "$manifest" | kubectl create -f - >/dev/null 2>&1; then
		planted=$(job_uid "idle-$pvc")
		break
	fi
	echo "the agent put its idle Job back before the planted one was created; again"
done
[ -n "$planted" ] || fail "could not plant a Job named idle-$pvc in three tries"
created=$(kubectl -n "$NS" get job "idle-$pvc" -o jsonpath='{.metadata.creationTimestamp}')
[ -n "$created" ] || fail "the planted Job has no creation time"
pod=""
for i in $(seq 1 30); do
	pod=$(kubectl -n "$NS" get pods -l job-name="idle-$pvc" -o json 2>/dev/null \
		| jq -r '[.items[] | select(.metadata.deletionTimestamp == null)] | first | .metadata.name // empty')
	[ -n "$pod" ] && break
	sleep 1
done
[ -n "$pod" ] || fail "the planted Job has no pod after 30s"
shows=$(kubectl -n "$NS" get pod "$pod" -o json | jq -r '"\(.status.phase), node \(.spec.nodeName // "none"), \(.status.containerStatuses // [] | length) container statuses"')
[ "$shows" = "Pending, node none, 0 container statuses" ] || fail "the planted pod $pod should be Pending on no node with no container status: $shows"
echo "OK: idle-$pvc is the planted Job $planted, created $created; its pod $pod: $shows"

step "within ${AFTER}s plus three periods the agent reports the Job, deletes it and covers the claim"
t0=$(seconds "$created")
bound=$(( t0 + AFTER + 3 * PERIOD ))
# The times asserted are the cluster's; the wait goes on a little longer so
# that a value just inside the bound is still read.
marker="" up=""
while :; do
	[ -n "$marker" ] || marker=$(agent_log "$NS" | grep "$NOT_RUNNING" | grep "$pvc" | head -1)
	uid=$(job_uid "idle-$pvc")
	if [ -n "$uid" ] && [ "$uid" != "$planted" ]; then
		up=$(idle_up_at) && break
	fi
	[ "$(date +%s)" -le $(( bound + 15 )) ] || break
	sleep 1
done
uid=$(job_uid "idle-$pvc")
if [ "$uid" = "$planted" ]; then
	fail "the planted Job idle-$pvc is still there $(( $(date +%s) - t0 ))s after its creation, more than ${AFTER}s plus three periods; lines with $NOT_RUNNING in the agent's log: $(agent_log "$NS" | grep -c "$NOT_RUNNING")"
fi
[ -n "$marker" ] || fail "the planted Job is gone, but the agent did not log $NOT_RUNNING for $pvc"
echo "    $marker"
at=$(seconds "${marker%% *}")
[ "$at" -ge $(( t0 + AFTER )) ] || fail "the agent logged $NOT_RUNNING $(( at - t0 ))s after the planted Job's creation, earlier than ${AFTER}s"
[ "$at" -le "$bound" ] || fail "the agent logged $NOT_RUNNING $(( at - t0 ))s after the planted Job's creation, later than ${AFTER}s plus three periods"
[ -n "$uid" ] && [ -n "$up" ] || fail "no idle process of the agent's holds the lock on $pvc ${AFTER}s plus three periods after the planted Job's creation"
[ "$(seconds "$up")" -le "$bound" ] || fail "the idle process read the agreement $(( $(seconds "$up") - t0 ))s after the planted Job's creation, later than ${AFTER}s plus three periods"
steward=$(annotation "$pvc" dynamos/data-steward)
user=$(annotation "$pvc" dynamos/request-user)
request_type=$(annotation "$pvc" dynamos/request-type)
kubectl -n "$NS" get job "idle-$pvc" -o json | jq -e --arg pvc "$pvc" --arg s "$steward" --arg u "$user" \
	--arg t "$request_type" --arg img "$IMAGE" --arg c "$GATEWAY" '
	.metadata.labels["dynamos/gateway"] == "idle"
	and .spec.ttlSecondsAfterFinished == null and .spec.activeDeadlineSeconds == null
	and (.spec.template.spec
		| .restartPolicy == "OnFailure" and .terminationGracePeriodSeconds == 10 and .nodeSelector == null
		and ([.volumes[].persistentVolumeClaim.claimName] == [$pvc])
		and (.containers | length == 1)
		and (.containers[0]
			| .name == $c and .image == $img and .command == ["/app/" + $c]
			and ((.env | map({(.name): .value}) | add)
				== {DATA_STEWARD_NAME: $s, REQUEST_USER: $u, REQUEST_TYPE: $t, GATEWAY_IDLE: "true", STATE_DIR: "/state"})))' >/dev/null \
	|| fail "the new idle Job $NS/idle-$pvc is not the agent's for the claim: wrong identity, image, command, volume, node selector or lifetime"
kubectl -n "$NS" get pod "$pod" >/dev/null 2>&1 && fail "the planted pod $pod is still there"
echo "OK: $NOT_RUNNING logged $(( at - t0 ))s after the planted Job's creation, the Job and its pod gone, and an idle process of the agent's holds the lock $(( $(seconds "$up") - t0 ))s after it"
