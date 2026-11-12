#!/usr/bin/env bash
# A completed idle Job marks its claim as empty. Here the mark goes stale:
# the server's agent is refused the deletion of idle Jobs for a while, so its
# hand-over leaves a completed idle Job in place, the job's enforcement point
# writes state on the claim, and the completed Job is still there when that
# enforcement point has ended. The agent must then delete the Job and put an
# idle process on the claim.
#   1  reset, the claims deleted, one run; then a reset, since the request
#      path gives a user one run per reset. The server's claim holds state
#      and the agent's idle process holds the claim
#   2  an admission policy refuses the server's agent the deletion of a Job
#      whose name starts with idle-, in namespace server only
#   3  the idle Job is replaced by a Job of its name that exits 0 at once
#   4  a run: the agent logs that it could not stop the idle Job, the planted
#      Job stays, the job's enforcement point serves, and the claim's
#      audit.log holds allowed writes decided after the planted Job completed
#   5  the policy is removed. Within two periods plus 5 s of that and of the
#      job's enforcement point ending: the agent has deleted the planted Job,
#      an idle Job of the agent's holds the lock, and the state files are
#      unchanged
# The check ends with a reset: the agents restart, so the marker of step 4
# leaves their logs.

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
PERIOD=30
NOT_STOPPED=IDLE_GATEWAY_NOT_STOPPED
STALE='an enforcement point used the PVC after it completed'
POLICY=stayup-gate-keep-idle-jobs
AGENT_USER="system:serviceaccount:$NS:job-creator-$NS"

PIDS=()
pvc=""
planted=""

remove_policy() {
	kubectl delete validatingadmissionpolicybinding "$POLICY" --ignore-not-found >/dev/null 2>&1
	kubectl delete validatingadmissionpolicy "$POLICY" --ignore-not-found >/dev/null 2>&1
}

cleanup() {
	local rc=$? p
	if [ "$rc" != 0 ]; then
		echo "--- $NS at the failure"
		kubectl -n "$NS" get jobs,pods,pvc 2>&1
		agent_log "$NS" | grep -E "Idle|idle|Supervision of" | tail -n 20
	fi
	remove_policy
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

chain_pod() { # prints the pod of the namespace's chain Job
	local job
	job=$(kubectl -n "$NS" get jobs -l 'dynamos/gateway!=idle' --sort-by=.metadata.creationTimestamp -o name 2>/dev/null \
		| grep jake | tail -1 | cut -d/ -f2)
	[ -n "$job" ] || return 1
	kubectl -n "$NS" get pods -l job-name="$job" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# Wait until the enforcement point of a chain pod has ended; prints when.
gateway_ended() { # $1 pod, $2 deadline in seconds
	local i ended
	for i in $(seq 1 "$2"); do
		ended=$(kubectl -n "$NS" get pod "$1" -o json 2>/dev/null \
			| jq -r --arg c "$GATEWAY" '.status.containerStatuses[]? | select(.name == $c) | .state.terminated.finishedAt // empty')
		if [ -n "$ended" ]; then
			echo "$ended"
			return 0
		fi
		sleep 1
	done
	return 1
}

state_dir() {
	local vol
	vol=$(kubectl get pvc -n "$NS" "$pvc" -o jsonpath='{.spec.volumeName}')
	[ -n "$vol" ] || return 1
	echo "/var/local-path-provisioner/${vol}_${NS}_${pvc}"
}

# The claim's state files, by content and name.
state_files() {
	local dir
	dir=$(state_dir) || return 1
	docker exec "$NODE" sh -c "cd '$dir/data' 2>/dev/null && find . -name '*.bin' -exec sha256sum {} + | sort -k2"
}

# What the API server answers when the agent deletes the claim's idle Job;
# nothing is deleted.
agent_deletes() {
	kubectl -n "$NS" delete job "idle-$pvc" --as="$AGENT_USER" --dry-run=server 2>&1
}

first_run() {
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

step "the cluster serves the admission policy API"
resources=$(kubectl api-resources --api-group=admissionregistration.k8s.io -o name 2>&1)
for resource in validatingadmissionpolicies validatingadmissionpolicybindings; do
	echo "$resources" | grep -qx "$resource.admissionregistration.k8s.io" \
		|| fail "the cluster does not serve $resource.admissionregistration.k8s.io, which this check needs"
done
kubectl explain validatingadmissionpolicy --api-version=admissionregistration.k8s.io/v1 >/dev/null 2>&1 \
	|| fail "the cluster does not serve ValidatingAdmissionPolicy in admissionregistration.k8s.io/v1, which this check needs"
echo "OK: validatingadmissionpolicies and their bindings are served in admissionregistration.k8s.io/v1"

step "1: reset, the claims deleted, one run; then a reset"
for try in 1 2 3; do
	first_run && break
	lost_start_race || fail "the run did not reach done, and no service gave up dialing its neighbour"
	[ "$try" -lt 3 ] || fail "the run lost the start race three times"
	echo "START RACE: a chain service gave up dialing its neighbour before it listened; repeating the run"
done
pvc=$(state_pvc_of "$NS")
[ -n "$pvc" ] || fail "no state claim in $NS"
reset_and_seed
up=""
for i in $(seq 1 90); do
	up=$(idle_up_at) && break
	sleep 1
done
[ -n "$up" ] || fail "no idle process holds the lock on $NS/$pvc 90s after the reset"
[ "$(state_files | grep -c .)" -ge 1 ] || fail "the claim $NS/$pvc holds no state file"
echo "OK: $pvc holds $(state_files | grep -c .) state files and the agent's idle process holds the lock"

step "2: the server's agent is refused the deletion of idle Jobs"
kubectl apply -f - >/dev/null <<EOF || fail "cannot create the admission policy $POLICY"
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: $POLICY
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
    - apiGroups: ["batch"]
      apiVersions: ["v1"]
      operations: ["DELETE"]
      resources: ["jobs"]
  validations:
  - expression: "!(oldObject.metadata.name.startsWith('idle-') && request.userInfo.username == '$AGENT_USER')"
    message: "the kind gate keeps idle Jobs from the agent in $NS"
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: $POLICY
spec:
  policyName: $POLICY
  validationActions: [Deny]
  matchResources:
    namespaceSelector:
      matchLabels:
        kubernetes.io/metadata.name: $NS
EOF
for i in $(seq 1 30); do
	agent_deletes | grep -q "$POLICY" && break
	sleep 1
done
answer=$(agent_deletes)
echo "$answer" | grep -q "$POLICY" || fail "30s after the policy was created the agent's deletion of idle-$pvc is not refused by it: $answer"
echo "OK: $answer"

step "3: the idle Job is replaced by a Job of its name that exits 0"
planted=""
for try in 1 2 3; do
	kubectl -n "$NS" delete job "idle-$pvc" --cascade=foreground --wait=true --timeout=60s >/dev/null 2>&1
	if kubectl -n "$NS" create job "idle-$pvc" --image="$IMAGE" -- /bin/true >/dev/null 2>&1; then
		planted=$(job_uid "idle-$pvc")
		break
	fi
	echo "the agent put its idle Job back before the planted one was created; again"
done
[ -n "$planted" ] || fail "could not plant a Job named idle-$pvc in three tries"
kubectl -n "$NS" label job "idle-$pvc" dynamos/gateway=idle >/dev/null || fail "cannot label the planted Job"
kubectl -n "$NS" wait --for=condition=complete "job/idle-$pvc" --timeout=60s >/dev/null \
	|| fail "the planted Job did not complete within 60s"
[ "$(job_uid "idle-$pvc")" = "$planted" ] || fail "the planted Job was replaced before the run"
completed=$(kubectl -n "$NS" get job "idle-$pvc" -o jsonpath='{.status.completionTime}')
[ -n "$completed" ] || fail "the planted Job has no completion time"
echo "OK: idle-$pvc is the planted Job $planted, complete since $completed, on a claim that holds state"

step "4: a run while the agent cannot stop the idle Job"
rid=$(trigger "$CYCLES") || exit 1
if ! ( wait_done "$rid" ) >/dev/null; then
	lost_start_race && fail "START RACE: a chain service gave up dialing its neighbour before it listened; this run of the check is void"
	fail "the run did not reach done"
fi
line=$(agent_log "$NS" | grep "$NOT_STOPPED" | grep "$pvc" | head -1)
[ -n "$line" ] || fail "the agent in $NS did not log $NOT_STOPPED for $pvc: its hand-over was not held back"
echo "    $line"
[ "$(job_uid "idle-$pvc")" = "$planted" ] || fail "the planted Job is gone after the run, while the agent may not delete it"
pod=$(chain_pod)
[ -n "$pod" ] || fail "no chain pod in $NS"
kubectl logs -n "$NS" "$pod" -c "$GATEWAY" 2>&1 | grep -q 'Serving on' || fail "the enforcement point in $NS/$pod did not serve"
dir=$(state_dir) || fail "the claim $pvc is not bound"
allowed=$(docker exec "$NODE" cat "$dir/audit/audit.log" \
	| jq -c --argjson t "$(( $(seconds "$completed") * 1000000 ))" 'select(.op == "write" and .decision == "ALLOW" and .decidedUnixMicros >= $t)' | grep -c .)
[ "$allowed" -ge "$CYCLES" ] || fail "audit.log of $pvc holds $allowed allowed writes decided after the planted Job completed, expected at least $CYCLES"
echo "OK: the hand-over failed, the planted Job stayed, and $allowed writes were allowed on a claim marked as empty"

step "5: the policy is removed; the agent deletes the planted Job and covers the claim"
remove_policy
for i in $(seq 1 30); do
	agent_deletes | grep -q "$POLICY" || break
	sleep 1
done
answer=$(agent_deletes)
echo "$answer" | grep -q "$POLICY" && fail "30s after the policy was removed the agent's deletion is still refused: $answer"
lifted=$(date +%s)
ended=$(gateway_ended "$pod" 120) || fail "the enforcement point in $NS/$pod had not ended 120s after the run was done"
t0=$(seconds "$ended")
[ "$lifted" -gt "$t0" ] && t0=$lifted
bound=$(( t0 + 2 * PERIOD + 5 ))
before=$(state_files)
[ -n "$before" ] || fail "the claim $pvc holds no state file after the run"
# The times asserted are the cluster's; the wait goes on a little longer so
# that a value just inside the bound is still read.
deleted="" up=""
while :; do
	[ -n "$deleted" ] || deleted=$(agent_log "$NS" | grep "Idle job idle-$pvc deleted: $STALE" | head -1)
	uid=$(job_uid "idle-$pvc")
	if [ -n "$uid" ] && [ "$uid" != "$planted" ]; then
		up=$(idle_up_at) && break
	fi
	[ "$(date +%s)" -le $(( bound + 15 )) ] || break
	sleep 1
done
uid=$(job_uid "idle-$pvc")
[ "$uid" != "$planted" ] \
	|| fail "the planted Job idle-$pvc is still there $(( $(date +%s) - t0 ))s after the policy went and the job's enforcement point ended, more than two periods plus 5s"
[ -n "$deleted" ] || fail "the planted Job is gone, but the agent did not log that it deleted idle-$pvc because $STALE"
echo "    $deleted"
[ "$(seconds "${deleted%% *}")" -le "$bound" ] || fail "the agent deleted the planted Job at ${deleted%% *}, more than two periods plus 5s after $(date -d "@$t0" +%T)"
[ -n "$uid" ] && [ -n "$up" ] || fail "no idle process of the agent's holds the lock on $pvc two periods plus 5s after $(date -d "@$t0" +%T)"
[ "$(seconds "$up")" -le "$bound" ] || fail "the idle process read the agreement at $up, more than two periods plus 5s after $(date -d "@$t0" +%T)"
steward=$(annotation "$pvc" dynamos/data-steward)
user=$(annotation "$pvc" dynamos/request-user)
request_type=$(annotation "$pvc" dynamos/request-type)
kubectl -n "$NS" get job "idle-$pvc" -o json | jq -e --arg pvc "$pvc" --arg s "$steward" --arg u "$user" \
	--arg t "$request_type" --arg img "$IMAGE" --arg c "$GATEWAY" '
	.metadata.labels["dynamos/gateway"] == "idle"
	and .spec.ttlSecondsAfterFinished == null and .spec.activeDeadlineSeconds == null
	and (.spec.template.spec
		| .restartPolicy == "OnFailure" and .terminationGracePeriodSeconds == 10
		and ([.volumes[].persistentVolumeClaim.claimName] == [$pvc])
		and (.containers | length == 1)
		and (.containers[0]
			| .name == $c and .image == $img and .command == ["/app/" + $c]
			and ((.env | map({(.name): .value}) | add)
				== {DATA_STEWARD_NAME: $s, REQUEST_USER: $u, REQUEST_TYPE: $t, GATEWAY_IDLE: "true", STATE_DIR: "/state"})))' >/dev/null \
	|| fail "the new idle Job $NS/idle-$pvc is not the agent's for the claim: wrong identity, image, command, volume or lifetime"
[ "$(state_files)" = "$before" ] || fail "the state files of $pvc changed between the end of the job's enforcement point and the idle process"
echo "OK: planted Job deleted $(( $(seconds "${deleted%% *}") - t0 ))s and idle process up $(( $(seconds "$up") - t0 ))s after the later of the policy's removal and the end of the job's enforcement point; $(echo "$before" | grep -c .) state files unchanged"

step "reset: the agents restart"
reset_and_seed
agent_log "$NS" | grep -q "$NOT_STOPPED" && fail "the agent in $NS still shows $NOT_STOPPED after the reset"
echo "OK: no $NOT_STOPPED in the log of the agent in $NS"
