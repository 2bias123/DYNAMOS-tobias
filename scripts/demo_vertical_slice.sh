#!/usr/bin/env bash
set -u

# Vertical slice: live ALLOW -> operator policy flip -> DENY on the server
# gateway, with agreement-hash provenance in the audit trail.
#
# Assumes: reset.sh has run, seed_state_aware.sh has run AFTER it (orchestrator
# boot clobbers seeded agreements), and the gateway image in kind is current.
# The chain does not write state on its own yet, so the writes are driven
# explicitly against the live gateway with the pod's own identity.

APIPORT="${APIPORT:-8080}"
GWPORT="${GWPORT:-50050}"
ORCHPORT="${ORCHPORT:-8082}"
NS=server
# Training must outlive the flip: the MS shuts the gateway down when the chain
# finishes, and cycles=3 completes in seconds.
CYCLES="${CYCLES:-300}"

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="${script_dir}/.."
cfg="${repo_root}/configuration/etcd_launch_files/state_aware_server.json"

PIDS=()
cleanup() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; }
trap cleanup EXIT

step() { echo; echo "=== $*"; }
fail() { echo "DEMO FAIL: $*" >&2; exit 1; }

step "0. trigger a vflTrainModelRequest so a governed chain is live"
kubectl port-forward -n api-gateway svc/api-gateway "${APIPORT}:8080" >/dev/null 2>&1 &
PIDS+=($!)
sleep 3
resp=$(curl -s -X POST "http://localhost:${APIPORT}/api/v1/requestApproval" \
	-H 'Content-Type: application/json' -d '{
  "type": "vflTrainModelRequest",
  "user": { "id": "1234", "userName": "jake.jongejans@student.uva.nl" },
  "dataProviders": ["server", "clientone", "clienttwo", "clientthree"],
  "data_request": { "type": "vflTrainModelRequest",
    "data": { "learning_rate": 0.1, "cycles": '"${CYCLES}"',
      "policy_removal": -1, "policy_reintroduction": -1, "training_backtrack": 0 },
    "requestMetadata": {} } }')
echo "trigger: ${resp}"
echo "$resp" | grep -q request_id || fail "trigger not accepted"

POD=""
for _ in $(seq 1 30); do
	POD=$(kubectl get pods -n "$NS" -o name 2>/dev/null | grep jake | head -1 | cut -d/ -f2)
	[ -n "$POD" ] && break
	sleep 2
done
[ -n "$POD" ] || fail "no job pod appeared in ${NS}"
for _ in $(seq 1 30); do
	kubectl get pod "$POD" -n "$NS" -o jsonpath='{.status.containerStatuses[?(@.name=="policy-checkpoint-gateway")].state}' 2>/dev/null \
		| grep -q running && break
	sleep 2
done
echo "gateway pod: ${POD}"

identity=$(kubectl get pod "$POD" -n "$NS" -o json | python3 -c '
import json, sys
env = {e["name"]: e.get("value", "") for c in json.load(sys.stdin)["spec"]["containers"]
       if c["name"] == "policy-checkpoint-gateway" for e in c["env"]}
print(json.dumps({
    "steward": env["DATA_STEWARD_NAME"], "user": env["REQUEST_USER"],
    "request_type": env["REQUEST_TYPE"], "job_id": env["JOB_NAME"],
    "local_job_name": env["LOCAL_JOB_NAME"]}))')
echo "identity: ${identity}"

kubectl port-forward -n "$NS" "$POD" "${GWPORT}:${GWPORT}" >/dev/null 2>&1 &
PIDS+=($!)
sleep 3

gw_write() {
	grpcurl -plaintext -import-path "${repo_root}/proto-files" -proto policyCheckpointGateway.proto \
		-d "{\"identity\":${identity},\"state_key\":\"$1\",\"state_class\":\"demo\",\"payload\":\"AQID\"}" \
		"localhost:${GWPORT}" dynamos.PolicyCheckpointGateway/RequestStateWrite 2>&1
}

step "1. RequestStateWrite under the seeded (allowing) agreement"
out1=$(gw_write k-allow)
echo "$out1"
echo "$out1" | grep -q '"allowed": true' || fail "step 1 expected ALLOW"
H1=$(echo "$out1" | grep agreementHash | sed 's/.*: "\(.*\)".*/\1/')
echo "H1=${H1}"

step "2. operator flips stateDirectives.allowed=false via /policyEnforcer"
kubectl port-forward -n orchestrator svc/orchestrator "${ORCHPORT}:8080" >/dev/null 2>&1 &
PIDS+=($!)
sleep 3
python3 -c "
import json
a = json.load(open('${cfg}'))
a['relations']['jake.jongejans@student.uva.nl']['stateDirectives']['allowed'] = False
print(json.dumps(a))" > /tmp/state_aware_server_flipped.json
code=$(curl -s -o /dev/null -w '%{http_code}' -X PUT "http://localhost:${ORCHPORT}/api/v1/policyEnforcer" \
	-H 'Content-Type: application/json' --data-binary @/tmp/state_aware_server_flipped.json)
[ "$code" = "200" ] || fail "policy flip PUT returned http ${code}"
echo "flip accepted; waiting for the gateway watch to pick it up"
for _ in $(seq 1 20); do
	kubectl logs -n "$NS" "$POD" -c policy-checkpoint-gateway 2>/dev/null | grep -q "Agreement changed" && break
	sleep 1
done
kubectl logs -n "$NS" "$POD" -c policy-checkpoint-gateway | grep "Agreement changed" || fail "no agreement change observed"

step "3. RequestStateWrite again: expect DENY, different hash"
out3=$(gw_write k-deny)
echo "$out3"
echo "$out3" | grep -q '"allowed": true' && fail "step 3 expected DENY, got ALLOW"
echo "$out3" | grep -q 'allowed = false' || fail "step 3 expected reason 'allowed = false'"
H2=$(echo "$out3" | grep agreementHash | sed 's/.*: "\(.*\)".*/\1/')
echo "H2=${H2}"
[ -n "$H1" ] && [ -n "$H2" ] && [ "$H1" != "$H2" ] || fail "hashes must differ (H1=${H1} H2=${H2})"

step "4. denied payload never reached /state"
files=$(kubectl exec -n "$NS" "$POD" -c policy-checkpoint-gateway -- ls /state/data/demo/ 2>/dev/null)
echo "state files: ${files}"
echo "$files" | grep -q "k-allow.bin" || fail "allowed write missing from /state"
echo "$files" | grep -q "k-deny" && fail "denied write reached /state"

step "5. audit trail (op=write lines)"
kubectl logs -n "$NS" "$POD" -c policy-checkpoint-gateway | grep '"op":"write"'

echo
echo "DEMO PASS: ALLOW(${H1}) -> flip -> DENY(${H2}), denied payload absent"
