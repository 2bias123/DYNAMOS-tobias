#!/usr/bin/env bash
# The enforcement point's lock and its idle form, on a claim of their own in
# a scratch namespace, without the agent:
#   F1  state on the claim and terms that prescribe deletion: the idle Job
#       writes one record per file, deletes the files and completes
#   F2  state on the claim and nothing due: the idle Job stays running with
#       no listening socket, and a stop signal makes it exit 143
#   F3  an idle process holds the lock: a serving process on the same claim
#       waits, and serves once the idle Job is deleted; the idle pod is gone
#       within 10 s of that
#   F4  the lock never frees: after 20 s a second serving process prints the
#       marker and exits non-zero, and audit.log has no new line
# Every fixture starts the binary directly, so the container's exit code is
# the binary's; the image's shell entry would hide it.

set -u

EXP=GATE
root="$(cd "$(dirname "$0")/../../.." && pwd)"
. "$root/scripts/kind_gate/context.sh"
. "$root/scripts/capture_lib.sh"

NODE=stayup-control-plane
NS=gate-fixtures
PVC=state-fixture
IDLE="idle-$PVC"
IMAGE=tamjiyan/policy-checkpoint-gateway:stay-up-enforcement
KEY=/policyEnforcer/agreements/fixture
FIXTURE_USER=fixture@example.org
FIXTURE_TYPE=fixtureRequest
MARKER=STATE_LOCK_NOT_ACQUIRED

dir=""

cleanup() {
	local rc=$? pod
	if [ "$rc" != 0 ]; then
		echo "--- the fixtures at the failure"
		kubectl -n "$NS" get jobs,pods -o wide 2>&1
		for pod in $(kubectl -n "$NS" get pods -o name 2>/dev/null); do
			echo "--- log of $pod"
			kubectl -n "$NS" logs "$pod" --tail=40 2>&1
		done
		if [ -n "$dir" ]; then
			echo "--- audit.log of $PVC"
			audit_lines
		fi
	fi
	kubectl exec -n core etcd-0 -c etcd -- sh -c \
		"ETCDCTL_API=3 /usr/local/bin/etcdctl --endpoints=localhost:2379 del $KEY" >/dev/null 2>&1
	kubectl delete namespace "$NS" --ignore-not-found --timeout=180s >/dev/null 2>&1
}
trap cleanup EXIT

put_terms() { # $1 = allowed: true | false
	printf '{"name":"fixture","relations":{"%s":{"ID":"GUID-fixture","requestTypes":["%s"],"stateDirectives":{"allowed":%s,"retentionSeconds":900,"resumeAllowed":true,"onRevocation":"purge"}}}}' \
		"$FIXTURE_USER" "$FIXTURE_TYPE" "$1" \
		| kubectl exec -i -n core etcd-0 -c etcd -- sh -c \
			"ETCDCTL_API=3 /usr/local/bin/etcdctl --endpoints=localhost:2379 put $KEY" >/dev/null \
		|| fail "cannot write the fixture's terms to the policy store"
}

# Two state files, written straight onto the claim while no enforcement
# point holds it.
seed_state() {
	kubectl -n "$NS" delete pod seed --ignore-not-found >/dev/null 2>&1
	kubectl apply -f - >/dev/null <<-YAML
	apiVersion: v1
	kind: Pod
	metadata: { name: seed, namespace: $NS }
	spec:
	  restartPolicy: Never
	  containers:
	  - name: seed
	    image: $IMAGE
	    imagePullPolicy: IfNotPresent
	    command: ["/bin/sh", "-c", "mkdir -p /state/data/kv /state/data/model && echo a > /state/data/kv/k1.bin && echo b > /state/data/model/latest.bin"]
	    volumeMounts:
	    - { name: gateway-state, mountPath: /state }
	  volumes:
	  - name: gateway-state
	    persistentVolumeClaim: { claimName: $PVC }
	YAML
	kubectl -n "$NS" wait --for=jsonpath='{.status.phase}'=Succeeded pod/seed --timeout=120s >/dev/null \
		|| fail "the seed pod did not write the state files"
	kubectl -n "$NS" delete pod seed >/dev/null
}

idle_job() {
	kubectl apply -f - >/dev/null <<-YAML
	apiVersion: batch/v1
	kind: Job
	metadata: { name: $IDLE, namespace: $NS }
	spec:
	  backoffLimit: 0
	  template:
	    spec:
	      restartPolicy: Never
	      terminationGracePeriodSeconds: 10
	      containers:
	      - name: policy-checkpoint-gateway
	        image: $IMAGE
	        imagePullPolicy: IfNotPresent
	        command: ["/app/policy-checkpoint-gateway"]
	        env:
	        - { name: GATEWAY_IDLE, value: "true" }
	        - { name: DATA_STEWARD_NAME, value: FIXTURE }
	        - { name: REQUEST_USER, value: $FIXTURE_USER }
	        - { name: REQUEST_TYPE, value: $FIXTURE_TYPE }
	        - { name: STATE_DIR, value: /state }
	        - { name: AGREEMENT_POLL_INTERVAL_SECONDS, value: "2" }
	        volumeMounts:
	        - { name: gateway-state, mountPath: /state }
	      volumes:
	      - name: gateway-state
	        persistentVolumeClaim: { claimName: $PVC }
	YAML
}

serving_pod() { # $1 = pod name
	kubectl apply -f - >/dev/null <<-YAML
	apiVersion: v1
	kind: Pod
	metadata: { name: $1, namespace: $NS }
	spec:
	  restartPolicy: Never
	  terminationGracePeriodSeconds: 10
	  containers:
	  - name: policy-checkpoint-gateway
	    image: $IMAGE
	    imagePullPolicy: IfNotPresent
	    command: ["/app/policy-checkpoint-gateway"]
	    env:
	    - { name: DATA_STEWARD_NAME, value: FIXTURE }
	    - { name: REQUEST_USER, value: $FIXTURE_USER }
	    - { name: REQUEST_TYPE, value: $FIXTURE_TYPE }
	    - { name: JOB_NAME, value: fixture-job }
	    - { name: LOCAL_JOB_NAME, value: fixture-job }
	    - { name: STATE_DIR, value: /state }
	    - { name: GATEWAY_PORT, value: "50050" }
	    volumeMounts:
	    - { name: gateway-state, mountPath: /state }
	  volumes:
	  - name: gateway-state
	    persistentVolumeClaim: { claimName: $PVC }
	YAML
}

idle_pod() { # prints the idle Job's pod once it exists
	local end=$(( $(date +%s) + 60 )) pod
	while [ "$(date +%s)" -lt "$end" ]; do
		pod=$(kubectl -n "$NS" get pods -l job-name="$IDLE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
		[ -n "$pod" ] && { echo "$pod"; return 0; }
		sleep 1
	done
	return 1
}

wait_log() { # $1 = pod, $2 = text, $3 = seconds
	local end=$(( $(date +%s) + $3 ))
	while [ "$(date +%s)" -lt "$end" ]; do
		kubectl -n "$NS" logs "$1" 2>/dev/null | grep -q "$2" && return 0
		sleep 1
	done
	return 1
}

# The idle Job's pod, once it holds the lock: the first agreement read comes
# after the lock and the store.
start_idle() {
	local pod
	idle_job
	pod=$(idle_pod) || fail "the idle Job got no pod"
	wait_log "$pod" 'Agreement loaded' 60 || fail "the idle process did not read the agreement"
	echo "$pod"
}

audit_lines() { docker exec "$NODE" sh -c "cat '$dir/audit/audit.log' 2>/dev/null"; }
audit_count() { audit_lines | grep -c .; }
state_files() { docker exec "$NODE" sh -c "find '$dir/data' -name '*.bin' 2>/dev/null | wc -l"; }
pod_phase() { kubectl -n "$NS" get pod "$1" -o jsonpath='{.status.phase}' 2>/dev/null; }
listening_sockets() { kubectl -n "$NS" exec "$1" -- cat /proc/net/tcp /proc/net/tcp6 | awk '$4 == "0A"' | grep -c .; }

step "a scratch namespace with a state claim of its own"
kubectl delete namespace "$NS" --ignore-not-found --timeout=180s >/dev/null 2>&1
kubectl create namespace "$NS" >/dev/null || fail "cannot create namespace $NS"
kubectl apply -f - >/dev/null <<YAML || fail "cannot create the claim $PVC"
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: $PVC, namespace: $NS }
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: gateway-state
  resources: { requests: { storage: 1Gi } }
YAML

step "F1: state on the claim, terms that prescribe deletion"
put_terms false
seed_state
vol=$(kubectl get pvc -n "$NS" "$PVC" -o jsonpath='{.spec.volumeName}')
[ -n "$vol" ] || fail "the claim $PVC is not bound"
dir="/var/local-path-provisioner/${vol}_${NS}_${PVC}"
[ "$(state_files)" -eq 2 ] || fail "F1: expected 2 state files on the claim before the idle Job"
idle_job
kubectl -n "$NS" wait --for=condition=Complete "job/$IDLE" --timeout=120s >/dev/null \
	|| fail "F1: the idle Job did not complete"
[ "$(audit_count)" -eq 2 ] || fail "F1: expected 2 records in audit.log, got $(audit_count)"
purged=$(audit_lines | grep '"op":"purge","decision":"PURGED"' \
	| grep -c "\"identity\":{\"steward\":\"FIXTURE\",\"user\":\"$FIXTURE_USER\",\"requestType\":\"$FIXTURE_TYPE\"}")
[ "$purged" -eq 2 ] || fail "F1: expected 2 deletion records with the claim's identity and no job fields, got $purged"
[ "$(state_files)" -eq 0 ] || fail "F1: state files are left on the claim"
kubectl -n "$NS" delete job "$IDLE" --cascade=foreground >/dev/null
echo "OK F1: 2 deletion records without job fields, no state file left, the Job completed"

step "F2: state on the claim, nothing due"
put_terms true
seed_state
pod=$(start_idle) || exit 1
sleep 8 # four polls of the fixture's 2 s
[ "$(pod_phase "$pod")" = Running ] || fail "F2: the idle pod is $(pod_phase "$pod"), expected Running"
[ "$(state_files)" -eq 2 ] || fail "F2: a state file was deleted with nothing due"
[ "$(audit_count)" -eq 2 ] || fail "F2: audit.log grew with nothing due"
listening=$(listening_sockets "$pod")
[ "$listening" -eq 0 ] || fail "F2: the idle pod has $listening listening sockets"
kubectl -n "$NS" exec "$pod" -- /bin/sh -c 'kill -TERM 1' || fail "F2: cannot signal the idle process"
kubectl -n "$NS" wait --for=jsonpath='{.status.phase}'=Failed "pod/$pod" --timeout=10s >/dev/null \
	|| fail "F2: the idle process had not exited 10 s after the stop signal (phase $(pod_phase "$pod"))"
code=$(kubectl -n "$NS" get pod "$pod" -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}')
[ "$code" = 143 ] || fail "F2: the stopped idle process exited $code, expected 143"
kubectl -n "$NS" logs "$pod" 2>&1 | grep -q 'Stop signal received' || fail "F2: the idle process did not log the stop signal"
[ "$(state_files)" -eq 2 ] || fail "F2: a state file was deleted at the stop"
[ "$(audit_count)" -eq 2 ] || fail "F2: the stop left a record in audit.log"
kubectl -n "$NS" delete job "$IDLE" --cascade=foreground >/dev/null
echo "OK F2: running over four polls with no listening socket, no record, no deletion; exit 143 on the stop signal"

step "F3: an idle process holds the lock; a serving process waits, then serves"
pod=$(start_idle) || exit 1
serving_pod serving-a
kubectl -n "$NS" wait --for=condition=Ready pod/serving-a --timeout=60s >/dev/null \
	|| fail "F3: the serving pod did not start"
sleep 3
kubectl -n "$NS" logs serving-a 2>&1 | grep -q 'Serving on' \
	&& fail "F3: the serving process served while the idle one held the lock"
[ "$(pod_phase serving-a)" = Running ] || fail "F3: the serving pod is $(pod_phase serving-a) while it should wait for the lock"
kubectl -n "$NS" delete job "$IDLE" --wait=false >/dev/null
kubectl -n "$NS" wait --for=delete "pod/$pod" --timeout=10s >/dev/null \
	|| fail "F3: the idle pod was not gone within 10 s of the Job's deletion"
wait_log serving-a 'Serving on' 20 || fail "F3: the serving process did not serve after the idle one was deleted"
kubectl -n "$NS" logs serving-a 2>&1 | grep -q "$MARKER" && fail "F3: the serving process printed $MARKER"
# the count that F2 needs to be zero does see a listener where there is one
[ "$(listening_sockets serving-a)" -ge 1 ] || fail "F3: the serving pod shows no listening socket"
echo "OK F3: the serving process waited for the lock and served once the idle Job was deleted; the idle pod was gone within 10 s"

step "F4: the lock never frees"
before=$(audit_count)
serving_pod serving-b
kubectl -n "$NS" wait --for=jsonpath='{.status.phase}'=Failed pod/serving-b --timeout=90s >/dev/null \
	|| fail "F4: the second serving process did not exit non-zero (phase $(pod_phase serving-b))"
marked=$(kubectl -n "$NS" logs serving-b 2>&1 | grep -c "$MARKER")
[ "$marked" -eq 1 ] || fail "F4: expected one line with $MARKER, got $marked"
started=$(kubectl -n "$NS" get pod serving-b -o jsonpath='{.status.containerStatuses[0].state.terminated.startedAt}')
finished=$(kubectl -n "$NS" get pod serving-b -o jsonpath='{.status.containerStatuses[0].state.terminated.finishedAt}')
waited=$(( $(date -d "$finished" +%s) - $(date -d "$started" +%s) ))
{ [ "$waited" -ge 19 ] && [ "$waited" -le 30 ]; } || fail "F4: the second serving process gave up after ${waited} s, expected about 20"
[ "$(audit_count)" -eq "$before" ] || fail "F4: audit.log has a new line"
[ "$(pod_phase serving-a)" = Running ] || fail "F4: the first serving process is $(pod_phase serving-a)"
echo "OK F4: one line with $MARKER after ${waited} s, a non-zero exit, no new line in audit.log"
