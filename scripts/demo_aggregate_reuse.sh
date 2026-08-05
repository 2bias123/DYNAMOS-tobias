#!/usr/bin/env bash
set -u

# Governed result reuse, end to end: seed the aggregateRequest chain config,
# trigger a first request (miss: compute -> governed write), then a second
# (hit: gateway-mediated read, no recompute). Evidence comes from the MS logs,
# the gateway audit records, and the PVC name carrying the new identity tuple.
#
# Assumes the cluster is up with current images (aggregate-demo, agent,
# api-gateway). NOTE: the orchestrator re-applies the PVC's launch files on
# every boot, which OVERWRITES the seeded keys. Re-run this after any reset.sh.

APIPORT="${APIPORT:-8080}"
ORCHPORT="${ORCHPORT:-8082}"
NS=clientone
USERNAME="jorrit.stutterheim@cloudnation.nl"

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="${script_dir}/.."
cfg_dir="${repo_root}/configuration/etcd_launch_files"

PIDS=()
cleanup() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; }
trap cleanup EXIT

step() { echo; echo "=== $*"; }
fail() { echo "DEMO FAIL: $*" >&2; exit 1; }

trigger() {
	curl -s -X POST "http://localhost:${APIPORT}/api/v1/requestApproval" \
		-H 'Content-Type: application/json' -d '{
  "type": "aggregateRequest",
  "user": { "id": "4321", "userName": "'"${USERNAME}"'" },
  "dataProviders": ["clientone"],
  "data_request": { "type": "aggregateRequest", "data": {}, "requestMetadata": {} } }'
}

newest_pod() {
	kubectl get pods -n "$NS" --sort-by=.metadata.creationTimestamp -o name 2>/dev/null \
		| grep jorrit | tail -1 | cut -d/ -f2
}

wait_for_pod_done() {
	for _ in $(seq 1 60); do
		phase=$(kubectl get pod "$1" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)
		[ "$phase" = "Succeeded" ] && return 0
		sleep 2
	done
	return 1
}

step "0. seed aggregateRequest config through the orchestrator"
kubectl port-forward -n orchestrator svc/orchestrator "${ORCHPORT}:8080" >/dev/null 2>&1 &
PIDS+=($!)
sleep 3

python3 -c "
import json
for o in json.load(open('${cfg_dir}/requestType.json')):
    if o['name'] == 'aggregateRequest':
        print(json.dumps(o))" > /tmp/aggregate_request_type.json
code=$(curl -s -o /dev/null -w '%{http_code}' -X PUT "http://localhost:${ORCHPORT}/api/v1/requestTypes" \
	-H 'Content-Type: application/json' --data-binary @/tmp/aggregate_request_type.json)
[ "$code" = "200" ] || fail "requestType PUT returned http ${code}"

# The /microservices PUT stores under /microservices/<name>, but the agent
# reads /microservices/<name>/chainMetadata (the boot loader's key). Write
# the loader's key directly.
metadata=$(python3 -c "
import json
for o in json.load(open('${cfg_dir}/microservices.json')):
    if o['name'] == 'aggregate-demo':
        print(json.dumps(o))")
kubectl exec -n core etcd-0 -c etcd -- sh -c \
	"ETCDCTL_API=3 /usr/local/bin/etcdctl --endpoints=localhost:2379 put /microservices/aggregate-demo/chainMetadata '${metadata}'" \
	| grep -q OK || fail "chainMetadata etcd put failed"

code=$(curl -s -o /dev/null -w '%{http_code}' -X PUT "http://localhost:${ORCHPORT}/api/v1/policyEnforcer" \
	-H 'Content-Type: application/json' --data-binary @"${cfg_dir}/state_aware_clientone.json")
[ "$code" = "200" ] || fail "agreement PUT returned http ${code}"

kubectl exec -n core etcd-0 -c etcd -- sh -c \
	"ETCDCTL_API=3 /usr/local/bin/etcdctl --endpoints=localhost:2379 get /policyEnforcer/agreements/clientone --print-value-only" \
	| grep -q aggregateRequest || fail "aggregateRequest relation missing from etcd"
echo "seeded: requestType, microservice metadata, clientone agreement"

step "1. first aggregateRequest: expect miss -> compute -> governed write"
# Clear this user's leftover Jobs first: the pinned job name wedges any
# trigger while a Job under it still exists (see the note at step 3).
kubectl -n "$NS" get jobs -o name 2>/dev/null | grep jorrit \
	| xargs -r kubectl -n "$NS" delete --wait=true
kubectl port-forward -n api-gateway svc/api-gateway "${APIPORT}:8080" >/dev/null 2>&1 &
PIDS+=($!)
sleep 3
resp=$(trigger)
echo "trigger: ${resp}"
echo "$resp" | grep -q request_id || fail "first trigger not accepted"

POD1=""
for _ in $(seq 1 30); do
	POD1=$(newest_pod)
	[ -n "$POD1" ] && break
	sleep 2
done
[ -n "$POD1" ] || fail "no job pod appeared in ${NS}"
echo "job pod: ${POD1}"
wait_for_pod_done "$POD1" || fail "first job did not complete"

kubectl logs -n "$NS" "$POD1" -c aggregate-demo | grep -q "Result write allowed" \
	|| fail "first run expected a governed write"
kubectl logs -n "$NS" "$POD1" -c aggregate-demo | grep -q "Reusing persisted result" \
	&& fail "first run must not reuse"
out1=$(kubectl logs -n "$NS" "$POD1" -c policy-checkpoint-gateway | grep '"op":"write"')
echo "$out1"
echo "$out1" | grep -q '"stateClass":"aggregate_result"' || fail "write record missing the new state class"

step "2. PVC carries the new identity tuple"
pvcs=$(kubectl get pvc -n "$NS" -o name)
echo "$pvcs"
echo "$pvcs" | grep -q "aggregaterequest" || fail "no aggregaterequest PVC found"

step "3. clear the finished job so the pinned job name can redeploy"
# The orchestrator pins one jobName per (user, requestType) without eviction,
# and the agent skips deployment while a Job under that name still exists.
# Deleting this user's finished Jobs un-wedges the repeat request without a
# full reset.sh, which would outlast the 120s retention bound and expire the
# blob.
kubectl -n "$NS" get jobs -o name 2>/dev/null | grep jorrit \
	| xargs -r kubectl -n "$NS" delete --wait=true

step "4. second aggregateRequest: expect hit -> gateway-mediated read, no recompute"
resp=""
for _ in $(seq 1 30); do
	resp=$(trigger)
	echo "$resp" | grep -q request_id && break
	sleep 2
done
echo "trigger: ${resp}"
echo "$resp" | grep -q request_id || fail "second trigger not accepted (active-job lock still held?)"

POD2=""
for _ in $(seq 1 30); do
	POD2=$(newest_pod)
	[ -n "$POD2" ] && [ "$POD2" != "$POD1" ] && break
	sleep 2
done
[ -n "$POD2" ] && [ "$POD2" != "$POD1" ] || fail "no second job pod appeared"
echo "job pod: ${POD2}"
wait_for_pod_done "$POD2" || fail "second job did not complete"

kubectl logs -n "$NS" "$POD2" -c aggregate-demo | grep -q "Reusing persisted result" \
	|| fail "second run expected gateway-mediated reuse"
kubectl logs -n "$NS" "$POD2" -c aggregate-demo | grep -q "Result write allowed" \
	&& fail "second run must not recompute"
out2=$(kubectl logs -n "$NS" "$POD2" -c policy-checkpoint-gateway | grep '"op":"read"')
echo "$out2"
echo "$out2" | grep -q '"stateClass":"aggregate_result"' || fail "read record missing the new state class"

echo
echo "DEMO PASS: miss -> governed write, then hit -> governed read, records carry aggregate_result"
