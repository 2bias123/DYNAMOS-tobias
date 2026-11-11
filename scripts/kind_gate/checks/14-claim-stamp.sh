#!/usr/bin/env bash
# The claim's stamp: after the baseline run every state claim carries, as
# annotations, the identity its job's enforcement point was given, and the
# node on it was named by the scheduler, since jobs are not pinned on this
# cluster. A claim planted under the right name with another user's stamp is
# refused: that steward's agent names the annotation in its log and creates
# no Job.

set -u

EXP=GATE
root="$(cd "$(dirname "$0")/../../.." && pwd)"
. "$root/scripts/kind_gate/context.sh"
. "$root/scripts/capture_lib.sh"

CYCLES=1
USER_NAME="jake.jongejans@student.uva.nl"
OTHER_USER="someone.else@example.org"
STEWARD_NS=(server clientone clienttwo clientthree)
REFUSER=clientthree
APIPORT=18080
ORCHPORT=18082
export PORT="$ORCHPORT"
WAIT=90

PIDS=()
planted=""
cleanup() {
	local p
	for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done
	pkill -f "port-forward.*${APIPORT}:8080" 2>/dev/null
	# A planted claim left behind would make every later run fail in $REFUSER.
	[ -n "$planted" ] && kubectl -n "$REFUSER" delete pvc "$planted" --ignore-not-found --timeout=120s >/dev/null 2>&1
}
trap cleanup EXIT

annotation() { # $1 ns, $2 claim, $3 key
	kubectl -n "$1" get pvc "$2" -o json | jq -r --arg k "$3" '.metadata.annotations[$k] // "<absent>"'
}

gateway_env() { # $1 ns, $2 pod, $3 variable
	kubectl -n "$1" get pod "$2" -o json | jq -r --arg n "$3" \
		'.spec.containers[] | select(.name == "policy-checkpoint-gateway") | .env[] | select(.name == $n) | .value'
}

step "every state claim carries the identity its enforcement point was given"
for ns in "${STEWARD_NS[@]}"; do
	pvc=$(state_pvc_of "$ns")
	[ -n "$pvc" ] || fail "no state claim in $ns"
	pod=$(steward_pod "$ns")
	[ -n "$pod" ] || fail "no chain pod in $ns"
	for pair in dynamos/data-steward=DATA_STEWARD_NAME dynamos/request-user=REQUEST_USER dynamos/request-type=REQUEST_TYPE; do
		want=$(gateway_env "$ns" "$pod" "${pair#*=}")
		[ -n "$want" ] || fail "the enforcement point in $ns/$pod has no ${pair#*=}"
		got=$(annotation "$ns" "$pvc" "${pair%%=*}")
		[ "$got" = "$want" ] || fail "$ns/$pvc: ${pair%%=*} is '$got', the enforcement point was given '$want'"
	done
	echo "OK: $ns/$pvc: $(annotation "$ns" "$pvc" dynamos/data-steward), $(annotation "$ns" "$pvc" dynamos/request-user), $(annotation "$ns" "$pvc" dynamos/request-type)"
done

step "jobs are not pinned here: the scheduler named the node, and every claim is bound"
for ns in "${STEWARD_NS[@]}"; do
	pvc=$(state_pvc_of "$ns")
	phase=$(kubectl -n "$ns" get pvc "$pvc" -o jsonpath='{.status.phase}')
	[ "$phase" = Bound ] || fail "$ns/$pvc is ${phase:-in no phase}, not Bound"
	writer=$(kubectl -n "$ns" get pvc "$pvc" -o json --show-managed-fields | jq -r '
		[.metadata.managedFields[]
			| select(.fieldsV1["f:metadata"]["f:annotations"]["f:volume.kubernetes.io/selected-node"] != null)
			| .manager] | unique | join(",")')
	[ "$writer" = kube-scheduler ] \
		|| fail "$ns/$pvc: volume.kubernetes.io/selected-node was written by '${writer}', not by the scheduler"
	echo "OK: $ns/$pvc Bound on $(annotation "$ns" "$pvc" volume.kubernetes.io/selected-node), named by $writer"
done

step "plant ${REFUSER}'s claim with another user's stamp"
name=$(state_pvc_of "$REFUSER")
steward=$(annotation "$REFUSER" "$name" dynamos/data-steward)
request_type=$(annotation "$REFUSER" "$name" dynamos/request-type)
reset_and_seed
kubectl -n "$REFUSER" delete pvc "$name" --wait=true --timeout=120s >/dev/null \
	|| fail "cannot delete $REFUSER/$name"
planted="$name"
kubectl apply -f - >/dev/null <<-YAML || fail "cannot plant $REFUSER/$name"
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $name
  namespace: $REFUSER
  annotations:
    dynamos/data-steward: "$steward"
    dynamos/request-user: "$OTHER_USER"
    dynamos/request-type: "$request_type"
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: gateway-state
  resources: { requests: { storage: 1Gi } }
YAML

step "trigger the chain: ${REFUSER}'s agent refuses the claim"
trigger "$CYCLES" >/dev/null || exit 1
line=""
for i in $(seq 1 "$WAIT"); do
	line=$(kubectl -n "$REFUSER" logs "deploy/$REFUSER" -c "$REFUSER" 2>/dev/null | grep 'failed to ensure state PVC' | head -1)
	[ -n "$line" ] && break
	sleep 1
done
[ -n "$line" ] || fail "no refusal in the log of ${REFUSER}'s agent after ${WAIT}s"
echo "    $line"
echo "$line" | grep -q "$name" || fail "the refusal does not name the claim $name"
echo "$line" | grep -q 'dynamos/request-user' || fail "the refusal does not name the annotation that differs"
echo "OK: refused after ${i}s, naming dynamos/request-user"

step "no Job in ${REFUSER}, and the planted claim is as it was"
# The server's Job shows that the request was deployed where the claim matched.
for i in $(seq 1 "$WAIT"); do
	kubectl get jobs -n server -o name 2>/dev/null | grep -q jake && break
	sleep 1
done
kubectl get jobs -n server -o name 2>/dev/null | grep -q jake \
	|| fail "no chain job in server after ${WAIT}s: the request was not deployed anywhere"
# A supervision pass refuses the planted claim as the deploy did, so the
# claim gets no idle Job either.
passed_over="PVC $name is not the one its stamp names"
for i in $(seq 1 45); do
	kubectl -n "$REFUSER" logs -l type=agent -c "$REFUSER" --tail=-1 2>/dev/null | grep -q "$passed_over" && break
	sleep 1
done
kubectl -n "$REFUSER" logs -l type=agent -c "$REFUSER" --tail=-1 2>/dev/null | grep -q "$passed_over" \
	|| fail "no supervision pass of ${REFUSER}'s agent refused the planted claim within 45s"
jobs=$(kubectl get jobs -n "$REFUSER" -o name 2>/dev/null)
[ -z "$jobs" ] || fail "$REFUSER has a Job despite the refusal: $jobs"
got=$(annotation "$REFUSER" "$name" dynamos/request-user)
[ "$got" = "$OTHER_USER" ] || fail "the planted claim's dynamos/request-user is now '$got'"
echo "OK: server has its Job, $REFUSER has none, the planted claim still names $OTHER_USER"
