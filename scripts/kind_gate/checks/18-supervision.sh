#!/usr/bin/env bash
# Supervision: the agent keeps an idle process on every state claim that no
# job's enforcement point holds.
#   S1  after a run each steward's claim gets one idle Job, named after the
#       claim and carrying its identity, once the job's enforcement point
#       has ended; the gap is printed
#   S3  the idle pod is deleted, not its Job: the pod is replaced and takes
#       the lock again
#   S6  a claim is deleted while its idle process runs, and another while a
#       completed idle Job exists: both deletions finish inside 60 s and the
#       agent starts nothing for either over two periods
#   S5  terms that prescribe deletion reach two stewards' idle processes:
#       the state is deleted with records that carry no job fields, the Jobs
#       complete, and the completed Job stays over two periods; the next
#       deploy's hand-over removes it, and an idle Job follows once that job
#       is gone
#   S8  a second job is deployed while the first job's pod is still there:
#       its enforcement point serves, and over two periods the agent starts
#       no idle Job on the claim. The request path gives a user one run per
#       reset: an agent deploys nothing while the user's Job exists, and
#       with that Job removed and its pod left, the second job shares the
#       first one's queue and its run does not get going. So the scenario
#       covers the deploy and the time after it, not a second run to its end
#   S2  an agent is restarted while its idle Job runs: no second idle Job,
#       the first untouched
# and the harness's side: steward_job names the chain Job beside an idle
# Job, and delete_state_pvcs returns inside 60 s with idle pods up.
# The hand-over with an idle process up is 16-handover.sh; the chain without
# a stateful service is in 20-goldens.sh. S2 comes last among the scenarios,
# after a reset of its own: a restart of one agent alone must not be followed
# by a run, and it deploys a request that is still pending once more.

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
GATEWAY=policy-checkpoint-gateway
IMAGE="tamjiyan/$GATEWAY:$TAG"
PERIOD=30
STARTED='Idle gateway started on PVC'
HANDED_OVER='No idle gateway left on PVC'
NOT_STOPPED=IDLE_GATEWAY_NOT_STOPPED
LOCK_MARKER=STATE_LOCK_NOT_ACQUIRED

PIDS=()
declare -A PVC ENDED UID_OF POD1
cleanup() {
	local rc=$? p ns
	if [ "$rc" != 0 ]; then
		for ns in "${STEWARD_NS[@]}"; do
			echo "--- $ns at the failure"
			kubectl -n "$ns" get jobs,pods,pvc 2>&1
			agent_log "$ns" | grep -E "Idle|idle|Supervision of" | tail -n 20
		done
	fi
	for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done
	pkill -f "port-forward.*${APIPORT}:8080" 2>/dev/null
	# A pod left without its Job survives the reset and holds its claim.
	for ns in "${!POD1[@]}"; do
		[ -n "${POD1[$ns]}" ] && kubectl -n "$ns" delete pod "${POD1[$ns]}" --ignore-not-found --wait=false >/dev/null 2>&1
	done
}
trap cleanup EXIT

seconds() { date -d "$1" +%s; }
nanos() { date -d "$1" +%s%N; }

annotation() { # $1 ns, $2 claim, $3 key
	kubectl -n "$1" get pvc "$2" -o json | jq -r --arg k "$3" '.metadata.annotations[$k] // empty'
}

# The log of the steward's agent, without an agent that is on its way out.
agent_log() { # $1 = steward namespace
	local pod
	pod=$(kubectl -n "$1" get pods -l type=agent -o json 2>/dev/null \
		| jq -r '[.items[] | select(.metadata.deletionTimestamp == null)] | sort_by(.metadata.creationTimestamp) | last | .metadata.name // empty')
	[ -n "$pod" ] || return 0
	kubectl -n "$1" logs "$pod" -c "$1" --tail=-1 --timestamps 2>/dev/null
}

idle_jobs() { kubectl -n "$1" get jobs -l dynamos/gateway=idle -o name 2>/dev/null; }

job_uid() { kubectl -n "$1" get job "$2" -o jsonpath='{.metadata.uid}' 2>/dev/null; }

job_complete() { # $1 ns, $2 job
	kubectl -n "$1" get job "$2" -o json 2>/dev/null \
		| jq -e '[.status.conditions[]? | select(.type == "Complete" and .status == "True")] | length == 1' >/dev/null
}

idle_pod_of() { # $1 ns, $2 idle job; prints its running pod
	kubectl -n "$1" get pods -l job-name="$2" -o json 2>/dev/null \
		| jq -r '[.items[] | select(.metadata.deletionTimestamp == null and .status.phase == "Running")] | first | .metadata.name // empty'
}

# Wait until the claim's idle Job has a running pod that has read the
# agreement, which it does only once it holds the lock. Prints the pod.
wait_idle_up() { # $1 ns, $2 claim, $3 deadline in seconds, $4 = a pod that does not count
	local i pod
	for i in $(seq 1 "$3"); do
		pod=$(idle_pod_of "$1" "idle-$2")
		if [ -n "$pod" ] && [ "$pod" != "${4:-}" ] && kubectl -n "$1" logs "$pod" 2>/dev/null | grep -q 'Agreement loaded'; then
			echo "$pod"
			return 0
		fi
		sleep 1
	done
	return 1
}

one_idle_job() { # $1 ns, $2 claim
	local jobs
	jobs=$(idle_jobs "$1")
	[ "$jobs" = "job.batch/idle-$2" ] || fail "$1 should have the one idle Job idle-$2, it has: ${jobs:-none}"
}

chain_job() { # $1 ns; prints the newest chain Job
	kubectl -n "$1" get jobs -l 'dynamos/gateway!=idle' --sort-by=.metadata.creationTimestamp -o name 2>/dev/null \
		| grep jake | tail -1 | cut -d/ -f2
}

# A finished chain job's pod stays for minutes and holds the claim against
# deletion. The harness's reset removes the Jobs before it deletes a claim;
# here the idle Jobs have to stay.
delete_chain_jobs() { # $1 ns
	kubectl -n "$1" delete jobs -l 'dynamos/gateway!=idle' --cascade=foreground --wait=true --timeout=90s >/dev/null \
		|| fail "the chain Jobs in $1 were not gone after 90s"
}

chain_pod() { # $1 ns, $2 chain Job
	kubectl -n "$1" get pods -l job-name="$2" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
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

audit_log() { # $1 ns, $2 claim
	local vol
	vol=$(kubectl get pvc -n "$1" "$2" -o jsonpath='{.spec.volumeName}')
	[ -n "$vol" ] || return 1
	docker exec "$NODE" cat "/var/local-path-provisioner/${vol}_$1_$2/audit/audit.log"
}

state_files() { # $1 ns, $2 claim
	local vol
	vol=$(kubectl get pvc -n "$1" "$2" -o jsonpath='{.spec.volumeName}')
	docker exec "$NODE" sh -c "find '/var/local-path-provisioner/${vol}_$1_$2/data' -name '*.bin' 2>/dev/null | wc -l"
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

step "S1: reset, one run; then each steward's claim gets its idle Job"
for try in 1 2 3; do
	first_run && break
	lost_start_race || fail "the run did not reach done, and no service gave up dialing its neighbour"
	[ "$try" -lt 3 ] || fail "the run lost the start race three times"
	echo "START RACE: a chain service gave up dialing its neighbour before it listened; repeating the run"
done
for ns in "${STEWARD_NS[@]}"; do
	PVC[$ns]=$(state_pvc_of "$ns")
	[ -n "${PVC[$ns]}" ] || fail "no state claim in $ns"
	pod=$(chain_pod "$ns" "$(chain_job "$ns")")
	[ -n "$pod" ] || fail "no chain pod in $ns"
	ENDED[$ns]=$(gateway_ended "$ns" "$pod" 120) \
		|| fail "the enforcement point in $ns/$pod had not ended 120s after the run was done"
done
for ns in "${STEWARD_NS[@]}"; do
	pvc=${PVC[$ns]}
	idle_pod=$(wait_idle_up "$ns" "$pvc" 90) || fail "no idle process holds the lock on $ns/$pvc 90s after the run"
	one_idle_job "$ns" "$pvc"
	if [ "$ns" = server ]; then
		# The chain Job is still there, beside the idle Job.
		eval "$(grep '^steward_job()' "$root/scripts/capture_e1_live.sh")"
		named=$(steward_job server)
		[ -n "$named" ] && [ "$named" = "$(chain_job server)" ] \
			|| fail "steward_job server names '${named}', the chain Job is '$(chain_job server)'"
		echo "OK: steward_job server names the chain Job $named beside idle-$pvc"
	fi
	steward=$(annotation "$ns" "$pvc" dynamos/data-steward)
	user=$(annotation "$ns" "$pvc" dynamos/request-user)
	request_type=$(annotation "$ns" "$pvc" dynamos/request-type)
	kubectl -n "$ns" get job "idle-$pvc" -o json | jq -e --arg pvc "$pvc" --arg s "$steward" --arg u "$user" \
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
		|| fail "the idle Job $ns/idle-$pvc is not the claim's: wrong identity, image, command, volume or lifetime"
	started=$(kubectl -n "$ns" get pod "$idle_pod" -o jsonpath='{.status.containerStatuses[0].state.running.startedAt}')
	[ -n "$started" ] || fail "the idle pod $ns/$idle_pod has no start time"
	gap=$(( $(seconds "$started") - $(seconds "${ENDED[$ns]}") ))
	[ "$gap" -ge 0 ] || fail "the idle process in $ns started at $started, before the job's enforcement point ended at ${ENDED[$ns]}"
	[ "$gap" -le 60 ] || fail "the idle process in $ns started ${gap}s after the job's enforcement point ended, more than 60s"
	agent_log "$ns" | grep -q "$STARTED $pvc" || fail "the agent in $ns did not log that it started the idle process on $pvc"
	echo "OK: $ns/idle-$pvc as $steward, $user, $request_type; up ${gap}s after the job's enforcement point ended"
done

step "S3: the server's idle pod is deleted, not its Job"
pvc=${PVC[server]}
uid=$(job_uid server "idle-$pvc")
old=$(idle_pod_of server "idle-$pvc")
[ -n "$old" ] || fail "no running idle pod in server"
kubectl -n server delete pod "$old" --wait=true --timeout=60s >/dev/null || fail "cannot delete server/$old"
new=$(wait_idle_up server "$pvc" 90 "$old") || fail "no new idle pod holds the lock on server/$pvc 90s after the old one was deleted"
one_idle_job server "$pvc"
[ "$(job_uid server "idle-$pvc")" = "$uid" ] || fail "the idle Job in server was replaced, not only its pod"
echo "OK: $old replaced by $new under the same Job, and it holds the lock"

step "S6: a claim is deleted while its idle process runs"
gone=${PVC[clientone]}
delete_chain_jobs clientone
t0=$(date +%s)
kubectl -n clientone delete pvc "$gone" --wait=true --timeout=60s >/dev/null \
	|| fail "clientone/$gone was not deleted within 60s under its running idle process"
took=$(( $(date +%s) - t0 ))
agent_log clientone | grep -q "Idle job idle-$gone deleted: its PVC is being deleted" \
	|| fail "the agent in clientone did not log that it let the claim go"
for i in $(seq 1 30); do
	[ -z "$(idle_jobs clientone)" ] && [ -z "$(kubectl -n clientone get pods -l dynamos/gateway=idle -o name 2>/dev/null)" ] && break
	sleep 1
done
[ -z "$(idle_jobs clientone)" ] || fail "clientone still has an idle Job: $(idle_jobs clientone)"
echo "OK: clientone/$gone deleted in ${took}s, its idle Job removed by the agent"

step "S5: terms that prescribe deletion, written while the idle processes are up"
before=$(audit_log server "$pvc" | grep -c .)
[ "$(state_files server "$pvc")" -ge 1 ] || fail "the claim server/$pvc holds no state file before the terms change"
asked=$(date +%s%6N)
# For two stewards only: clienttwo keeps its state and its idle process.
STEWARD_NS=(server clientthree)
seed_agreements "sd['allowed'] = False"
STEWARD_NS=(server clientone clienttwo clientthree)
for ns in server clientthree; do
	kubectl -n "$ns" wait --for=condition=complete "job/idle-${PVC[$ns]}" --timeout=30s >/dev/null \
		|| fail "the idle Job in $ns did not complete within 30s of the new terms"
	UID_OF[$ns]=$(job_uid "$ns" "idle-${PVC[$ns]}")
done
UID_OF[clienttwo]=$(job_uid clienttwo "idle-${PVC[clienttwo]}")
[ "$(state_files server "$pvc")" -eq 0 ] || fail "the claim server/$pvc still holds state files"
records=$(audit_log server "$pvc" | tail -n +"$((before + 1))")
purged=$(echo "$records" | jq -c 'select(.op == "purge" and .decision == "PURGED")')
n=$(echo "$purged" | grep -c .)
[ "$n" -ge 1 ] || fail "no deletion record in audit.log of server/$pvc after the new terms"
with_job=$(echo "$records" | jq -c 'select(.identity.jobId != null or .identity.localJobName != null)' | grep -c .)
[ "$with_job" -eq 0 ] || fail "$with_job records written while idle carry job fields"
last=$(echo "$purged" | jq -r '.decidedUnixMicros' | sort -n | tail -1)
took_ms=$(( (last - asked) / 1000 ))
[ "$took_ms" -ge 0 ] && [ "$took_ms" -le 30000 ] \
	|| fail "the last deletion was decided ${took_ms} ms after the terms were sent, outside 0 to 30000"
echo "OK: $n deletion records without job fields, the last ${took_ms} ms after the terms were sent; the idle Jobs of server and clientthree complete"

step "S6: a claim is deleted while its completed idle Job exists"
gone=${PVC[clientthree]}
delete_chain_jobs clientthree
t0=$(date +%s)
kubectl -n clientthree delete pvc "$gone" --wait=true --timeout=60s >/dev/null \
	|| fail "clientthree/$gone was not deleted within 60s beside its completed idle Job"
took=$(( $(date +%s) - t0 ))
# The finished idle pod holds the claim as well, until the agent removes the
# completed Job in its next pass.
agent_log clientthree | grep -q "Idle job idle-$gone deleted: its PVC is being deleted" \
	|| fail "the agent in clientthree did not log that it let the claim go"
echo "OK: clientthree/$gone deleted in ${took}s, once the agent had removed the completed idle Job"

step "S5 and S6: over two periods the completed Job stays, and nothing is started for a deleted claim"
t0=$(date +%s)
while :; do
	for ns in server clienttwo; do
		one_idle_job "$ns" "${PVC[$ns]}"
		[ "$(job_uid "$ns" "idle-${PVC[$ns]}")" = "${UID_OF[$ns]}" ] || fail "the idle Job in $ns was replaced"
	done
	job_complete server "idle-${PVC[server]}" || fail "the idle Job in server is no longer complete"
	for ns in clientone clientthree; do
		[ -z "$(state_pvc_of "$ns")" ] || fail "$ns has a state claim again"
		[ -z "$(idle_jobs "$ns")" ] || fail "$ns has an idle Job without a claim: $(idle_jobs "$ns")"
	done
	[ $(( $(date +%s) - t0 )) -ge $(( 2 * PERIOD + 5 )) ] && break
	sleep 5
done
echo "OK: $(( $(date +%s) - t0 ))s on, server has its one completed idle Job, clienttwo its running one, clientone and clientthree no claim and no idle Job"

step "S5 and S8: the next deploy, beside the first job's pod"
# An agent sends a request to the user's Job for as long as that Job exists,
# and deploys nothing. So the first run's Jobs are removed and their pods
# left behind: the second job is then deployed beside the first job's pod.
# Its sidecar shares the first job's queue with that pod, so this run does
# not get going; what is looked at is the deploy and the time after it.
seed_agreements ""
for ns in "${STEWARD_NS[@]}"; do
	POD1[$ns]=$(chain_pod "$ns" "$(chain_job "$ns")")
done
pod1=${POD1[server]}
[ -n "$pod1" ] || fail "the first job's pod in server is gone"
for ns in "${STEWARD_NS[@]}"; do
	kubectl -n "$ns" delete jobs -l 'dynamos/gateway!=idle' --cascade=orphan --wait=true --timeout=60s >/dev/null \
		|| fail "cannot remove the first run's Job in $ns"
done
asked_ns=$(date +%s%N)
rid=$(trigger "$CYCLES") || exit 1
job2=""
for i in $(seq 1 90); do
	job2=$(chain_job server)
	[ -n "$job2" ] && break
	sleep 1
done
[ -n "$job2" ] || fail "no second chain Job in server after 90s"
kubectl -n server get pod "$pod1" >/dev/null 2>&1 || fail "the first job's pod $pod1 was gone when the second Job was created"
pod2=""
for i in $(seq 1 90); do
	pod2=$(chain_pod server "$job2")
	[ -n "$pod2" ] && kubectl logs -n server "$pod2" --all-containers 2>/dev/null \
		| grep -q 'Gateway connected, state-event listener started' && break
	sleep 1
done
[ -n "$pod2" ] || fail "no pod for the second chain Job in server"
handed2=""
for ns in "${STEWARD_NS[@]}"; do
	line=""
	for i in $(seq 1 60); do
		line=$(agent_log "$ns" | grep "$HANDED_OVER state-$ns-" | tail -1)
		[ -n "$line" ] && [ "$(nanos "${line%% *}")" -ge "$asked_ns" ] && break
		sleep 1
	done
	[ -n "$line" ] && [ "$(nanos "${line%% *}")" -ge "$asked_ns" ] \
		|| fail "the agent in $ns logged no hand-over for the second deploy"
	agent_log "$ns" | grep -q "$NOT_STOPPED" && fail "the agent in $ns logged $NOT_STOPPED"
	[ "$ns" = server ] && handed2=$(nanos "${line%% *}")
done
for ns in server clienttwo; do
	[ "$(job_uid "$ns" "idle-${PVC[$ns]}")" != "${UID_OF[$ns]}" ] || fail "the idle Job in $ns is still there after the second deploy"
done
gateway_log=$(kubectl logs -n server "$pod2" -c "$GATEWAY" 2>&1)
echo "$gateway_log" | grep -q 'Serving on' || fail "the enforcement point in server/$pod2 did not serve"
echo "$gateway_log" | grep -q "$LOCK_MARKER" && fail "the enforcement point in server/$pod2 printed $LOCK_MARKER"
kubectl logs -n server "$pod2" --all-containers 2>&1 | grep -q 'Gateway connected, state-event listener started' \
	|| fail "no service in server/$pod2 connected to the enforcement point within 90s"
echo "OK: the completed idle Job in server and the running one in clienttwo went at the hand-over; the second job's enforcement point serves beside $pod1"

step "S8: over two periods no idle process is started under the second job"
t0=$(date +%s)
while :; do
	[ -z "$(idle_jobs server)" ] || fail "server has an idle Job while the second job's enforcement point runs: $(idle_jobs server)"
	kubectl -n server get pod "$pod1" >/dev/null 2>&1 || fail "the first job's pod $pod1 is gone"
	running=$(kubectl -n server get pod "$pod2" -o json | jq -r --arg c "$GATEWAY" \
		'.status.containerStatuses[] | select(.name == $c) | (.state.running != null and .restartCount == 0)')
	[ "$running" = true ] || fail "the second job's enforcement point in server/$pod2 no longer runs, or was restarted"
	[ $(( $(date +%s) - t0 )) -ge $(( 2 * PERIOD + 5 )) ] && break
	sleep 5
done
while read -r at _; do
	[ -n "$at" ] || continue
	[ "$(nanos "$at")" -le "$handed2" ] || fail "the agent started an idle process on $pvc at $at, after the second hand-over"
done <<< "$(agent_log server | grep "$STARTED $pvc")"
echo "OK: $(( $(date +%s) - t0 ))s on, the second job's enforcement point runs beside $pod1 and the agent has started no idle process on $pvc"

step "S5: once the second job is gone, an idle Job follows on every claim"
for ns in "${STEWARD_NS[@]}"; do
	delete_chain_jobs "$ns"
	# The first run's pod has no Job any more and would hold its claim.
	[ -n "${POD1[$ns]}" ] || continue
	kubectl -n "$ns" delete pod "${POD1[$ns]}" --ignore-not-found --wait=true --timeout=90s >/dev/null \
		|| fail "the first run's pod ${POD1[$ns]} in $ns was not gone after 90s"
done
for ns in "${STEWARD_NS[@]}"; do
	PVC[$ns]=$(state_pvc_of "$ns")
	[ -n "${PVC[$ns]}" ] || fail "the second deploy left no state claim in $ns"
	uid=""
	for i in $(seq 1 60); do
		uid=$(job_uid "$ns" "idle-${PVC[$ns]}")
		[ -n "$uid" ] && break
		sleep 1
	done
	[ -n "$uid" ] || fail "no idle Job on $ns/${PVC[$ns]} 60s after the second job was removed"
	one_idle_job "$ns" "${PVC[$ns]}"
done
[ "$(job_uid server "idle-${PVC[server]}")" != "${UID_OF[server]}" ] || fail "the idle Job in server is the one from before the second deploy"
wait_idle_up clienttwo "${PVC[clienttwo]}" 90 >/dev/null \
	|| fail "no idle process holds the lock on clienttwo/${PVC[clienttwo]}, whose state was not deleted"
echo "OK: each of the four claims has its one idle Job again, and clienttwo's holds the lock"

step "S2: clienttwo's agent is restarted while its idle Job runs"
# The request of the second deploy is still pending, and an agent that is
# restarted alone deploys it again. The reset ends it; the restarted agents
# then put an idle Job on every claim, and clienttwo's finds state.
reset_and_seed
ns=clienttwo
pvc=${PVC[$ns]}
wait_idle_up "$ns" "$pvc" 90 >/dev/null || fail "no idle process holds the lock on $ns/$pvc 90s after the reset"
uid=$(job_uid "$ns" "idle-$pvc")
idle_pod=$(idle_pod_of "$ns" "idle-$pvc")
[ -n "$uid" ] && [ -n "$idle_pod" ] || fail "no running idle Job in $ns before the restart"
pod_uid=$(kubectl -n "$ns" get pod "$idle_pod" -o jsonpath='{.metadata.uid}')
old_agent=$(kubectl -n "$ns" get pods -l type=agent -o jsonpath='{.items[0].metadata.name}')
kubectl -n "$ns" rollout restart "deployment/$ns" >/dev/null || fail "cannot restart the agent in $ns"
kubectl -n "$ns" rollout status "deployment/$ns" --timeout=120s >/dev/null || fail "the agent in $ns did not come back"
passes=0
for i in $(seq 1 90); do
	passes=$(agent_log "$ns" | grep -c 'Supervision pass done')
	[ "$passes" -ge 2 ] && ! kubectl -n "$ns" get pod "$old_agent" >/dev/null 2>&1 && break
	sleep 1
done
[ "$passes" -ge 2 ] || fail "the new agent in $ns logged $passes supervision passes in 90s, expected two"
kubectl -n "$ns" get pod "$old_agent" >/dev/null 2>&1 && fail "the old agent pod $old_agent is still there"
one_idle_job "$ns" "$pvc"
[ "$(job_uid "$ns" "idle-$pvc")" = "$uid" ] || fail "the idle Job in $ns was replaced by the restarted agent"
[ "$(kubectl -n "$ns" get pod "$idle_pod" -o jsonpath='{.metadata.uid}' 2>/dev/null)" = "$pod_uid" ] \
	|| fail "the idle pod in $ns was replaced by the restarted agent"
restarts=$(kubectl -n "$ns" get pod "$idle_pod" -o jsonpath='{.status.containerStatuses[0].restartCount}')
[ "$restarts" = 0 ] || fail "the idle process in $ns was restarted ${restarts:-an unknown number of} times"
agent_log "$ns" | grep -q "$STARTED" && fail "the restarted agent in $ns started an idle process"
echo "OK: after $passes passes of the new agent, idle-$pvc and its pod are the same and not restarted"

step "delete_state_pvcs with idle pods up"
up=0
for ns in "${STEWARD_NS[@]}"; do
	[ -n "$(idle_jobs "$ns")" ] && up=$((up + 1))
done
[ "$up" -ge 3 ] || fail "expected idle Jobs in three namespaces before the deletion, found $up"
for ns in "${STEWARD_NS[@]}"; do
	delete_chain_jobs "$ns"
done
t0=$(date +%s)
delete_state_pvcs
took=$(( $(date +%s) - t0 ))
[ "$took" -le 60 ] || fail "delete_state_pvcs took ${took}s with idle pods up, more than 60"
for ns in "${STEWARD_NS[@]}"; do
	[ -z "$(state_pvc_of "$ns")" ] || fail "$ns still has a state claim after delete_state_pvcs"
done
echo "OK: delete_state_pvcs returned after ${took}s with $up idle Jobs up, and no state claim is left"
