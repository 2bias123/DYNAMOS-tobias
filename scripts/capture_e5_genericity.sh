#!/usr/bin/env bash
set -u

# Runs the E5 genericity scenes against the live aggregateRequest chain and
# saves the raw output under results/e5-genericity/, adding a line to that
# experiment's captures.md. The five scenes map onto four blocks; every
# asserted record must carry the aggregate_result state class.
#
#   miss-hit         scenes 1+2: clean-slate miss -> compute -> governed write,
#                    then a repeat request answered by a NEW pod via a gateway
#                    read, no recompute. No reset between the two runs: the
#                    read must land inside the seeded 120s retention bound, and
#                    a full reset outlasts it. The pinned-jobName wedge is
#                    broken by deleting this user's finished Jobs instead.
#   denial           scene 3: allowed=false with onRevocation="" (deny but
#                    retain) -> read and write DENY "allowed = false"; the MS
#                    recomputes and answers unpersisted; no destruction
#                    records. The variant raises retentionSeconds to 3600
#                    because the retention sweep also runs under allowed=false
#                    and would otherwise destroy the blob scene 4 must purge.
#   revocation-purge scene 4: allowed=false with onRevocation="purge" -> the
#                    boot sweep destroys the retained blob under the
#                    confirmed-fresh gate: op=purge PURGED, reason
#                    "revoked; onRevocation=purge", policySource fresh, one
#                    record per removal.
#   retention        scene 5: canonical seed, so the 120s bound is the
#                    agreement's own term -> fresh write, then a second run
#                    after the blob ages past the bound: op=expired DELETED
#                    "retention exceeded" at the boot sweep, read DENY
#                    "not found", recompute and fresh write.
#
# Usage: capture_e5_genericity.sh [miss-hit|denial|revocation-purge|retention|all]
# Default is all. Blocks reset and seed themselves; ~25 min for all four.
# Ordering: revocation-purge destroys the blob the earlier blocks left on the
# PVC, so standalone it needs state from a prior miss-hit; the other blocks
# are self-contained (retention writes its own blob in run 1).
#
# Assertions are on decisions and audit records, not timings, so background
# load does not invalidate a capture. The one timing constraint is inside
# miss-hit: the second run must read within the 120s retention bound, so
# avoid heavy parallel load during that block; a blown window fails visibly
# and the block is rerun.
#
# Needs the fork images loaded in kind (dev-loop.md imageID check), including
# tamjiyan/aggregate-demo. The orchestrator re-applies the PVC launch files
# on every boot, so each block re-seeds after its reset.

EXP=E5
root="$(cd "$(dirname "$0")/.." && pwd)"
# Override for shakedown runs that must not land in the evidence tree.
results_dir="${E5_RESULTS_DIR:-$root/results/e5-genericity}"
. "$root/scripts/capture_lib.sh"

NS=clientone
USER_NAME="jorrit.stutterheim@cloudnation.nl"
APIPORT="${APIPORT:-8080}"
ORCHPORT="${ORCHPORT:-8082}"
RETENTION_CANONICAL=120
RETENTION_LONG=3600
POD_POLL_MAX="${POD_POLL_MAX:-60}"   # x2s: job pod appear/complete

PIDS=()
cleanup() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; }
trap cleanup EXIT

# Seed the aggregateRequest chain config: request type and chain metadata via
# their canonical keys, then the clientone agreement through the operator
# /policyEnforcer path. $1 is an optional python statement applied to the
# aggregate relation's stateDirectives dict (variable `sd`) before the PUT;
# empty seeds canonical. The VFL relation on the same steward is never
# touched.
seed_aggregate() {
	local transform="${1:-}"
	local cfg_dir="$root/configuration/etcd_launch_files"
	pkill -f "port-forward.*${ORCHPORT}:8080" 2>/dev/null
	kubectl port-forward -n orchestrator svc/orchestrator "${ORCHPORT}:8080" >/dev/null 2>&1 &
	PIDS+=($!)
	sleep 3

	local tmp code
	tmp=$(mktemp)
	python3 -c "
import json
for o in json.load(open('${cfg_dir}/requestType.json')):
    if o['name'] == 'aggregateRequest':
        print(json.dumps(o))" > "$tmp"
	code=$(curl -s -o /dev/null -w '%{http_code}' -X PUT "http://localhost:${ORCHPORT}/api/v1/requestTypes" \
		-H 'Content-Type: application/json' --data-binary @"$tmp")
	rm -f "$tmp"
	[ "$code" = "200" ] || fail "requestType PUT returned http $code"

	# The /microservices PUT stores under /microservices/<name>, but the agent
	# reads /microservices/<name>/chainMetadata (the boot loader's key). Write
	# the loader's key directly.
	local metadata
	metadata=$(python3 -c "
import json
for o in json.load(open('${cfg_dir}/microservices.json')):
    if o['name'] == 'aggregate-demo':
        print(json.dumps(o))")
	kubectl exec -n core etcd-0 -c etcd -- sh -c \
		"ETCDCTL_API=3 /usr/local/bin/etcdctl --endpoints=localhost:2379 put /microservices/aggregate-demo/chainMetadata '${metadata}'" \
		| grep -q OK || fail "chainMetadata etcd put failed"

	tmp=$(mktemp)
	python3 -c "
import json
a = json.load(open('${cfg_dir}/state_aware_clientone.json'))
sd = a['relations']['${USER_NAME}']['stateDirectives']
${transform:-pass}
print(json.dumps(a))" > "$tmp" || fail "variant transform failed"
	code=$(curl -s -o /dev/null -w '%{http_code}' -X PUT "http://localhost:${ORCHPORT}/api/v1/policyEnforcer" \
		-H 'Content-Type: application/json' --data-binary @"$tmp")
	rm -f "$tmp"
	[ "$code" = "200" ] || fail "agreement PUT returned http $code"
	echo "[seed] aggregateRequest config seeded${transform:+ (variant: $transform)}"
}

# Assert a stateDirectives field landed in etcd on the aggregate relation.
verify_sd_field() { # $1 field, $2 expected python repr (True/False/120)
	local got
	got=$(kubectl exec -n core etcd-0 -c etcd -- sh -c \
		"ETCDCTL_API=3 /usr/local/bin/etcdctl --endpoints=localhost:2379 get /policyEnforcer/agreements/clientone --print-value-only" \
		| python3 -c "
import sys, json
a = json.load(sys.stdin)
print(a['relations']['${USER_NAME}']['stateDirectives']['$1'])")
	[ "$got" = "$2" ] || fail "etcd aggregate relation: $1=$got, expected $2"
	echo "[seed] verified in etcd: $1=$2"
}

clear_user_jobs() {
	kubectl -n "$NS" get jobs -o name 2>/dev/null | grep jorrit \
		| xargs -r kubectl -n "$NS" delete --wait=true
}

trigger_aggregate() { # echoes nothing; retries while the api-gateway active-job lock drains
	pkill -f "port-forward.*${APIPORT}:8080" 2>/dev/null
	kubectl port-forward -n api-gateway svc/api-gateway "${APIPORT}:8080" >/dev/null 2>&1 &
	PIDS+=($!)
	sleep 3
	local resp i
	for i in $(seq 1 30); do
		resp=$(curl -s -X POST "http://localhost:${APIPORT}/api/v1/requestApproval" \
			-H 'Content-Type: application/json' -d '{
  "type": "aggregateRequest",
  "user": { "id": "4321", "userName": "'"${USER_NAME}"'" },
  "dataProviders": ["clientone"],
  "data_request": { "type": "aggregateRequest", "data": {}, "requestMetadata": {} } }')
		echo "trigger: $resp" >&2
		echo "$resp" | grep -q request_id && return 0
		sleep 2
	done
	fail "trigger not accepted after retries: $resp"
}

newest_pod() {
	kubectl get pods -n "$NS" --sort-by=.metadata.creationTimestamp -o name 2>/dev/null \
		| grep jorrit | tail -1 | cut -d/ -f2
}

wait_new_pod_done() { # $1 = pod name that must NOT match; prints the new pod name
	local prev="$1" pod="" i phase
	for i in $(seq 1 "$POD_POLL_MAX"); do
		pod=$(newest_pod)
		[ -n "$pod" ] && [ "$pod" != "$prev" ] && break
		sleep 2
	done
	[ -n "$pod" ] && [ "$pod" != "$prev" ] || fail "no new job pod appeared in ${NS}"
	for i in $(seq 1 "$POD_POLL_MAX"); do
		phase=$(kubectl get pod "$pod" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)
		[ "$phase" = "Succeeded" ] && { echo "$pod"; return 0; }
		sleep 2
	done
	fail "job pod $pod did not complete"
}

gw_log() { kubectl logs -n "$NS" "$1" -c policy-checkpoint-gateway 2>/dev/null; }
ms_log() { kubectl logs -n "$NS" "$1" -c aggregate-demo 2>/dev/null; }

# --- blocks ---------------------------------------------------------------

do_miss_hit() {
	step "reset, then delete the aggregate PVC for a deterministic clean-slate miss"
	reset_cluster
	kubectl get pvc -n "$NS" -o name 2>/dev/null | grep aggregaterequest \
		| xargs -r kubectl delete -n "$NS" --wait=true

	step "seed canonical (retentionSeconds=${RETENTION_CANONICAL})"
	seed_aggregate ""
	verify_sd_field retentionSeconds "$RETENTION_CANONICAL"

	step "run 1: expect miss -> compute -> governed write"
	local t0 pod1 aud1 ms1
	t0=$(date +%s)
	trigger_aggregate
	pod1=$(wait_new_pod_done "")
	echo "job pod: $pod1"
	aud1=$(gw_log "$pod1"); ms1=$(ms_log "$pod1")
	echo; echo "--- gateway audit (run 1) ---"; echo "$aud1"
	echo; echo "--- MS log (run 1) ---"; echo "$ms1"
	must_grep "clean-slate read DENY 'not found'" "$(echo "$aud1" | grep '"op":"read"')" -e '"reason":"not found"'
	must_grep "governed write ALLOW on the new state class" "$(echo "$aud1" | grep '"op":"write"')" \
		-e '"decision":"ALLOW".*"stateClass":"aggregate_result"'
	must_grep "write record names the aggregate relation" "$(echo "$aud1" | grep '"op":"write"')" \
		-e '"relationId":"GUID-state-aware-aggregate"'
	must_grep "MS computed and persisted" "$ms1" -e "Result write allowed"
	must_not_grep "no reuse on a clean slate" "$ms1" -e "Reusing persisted result"

	local w1
	w1=$(echo "$aud1" | grep '"op":"write"' | grep '"decision":"ALLOW"' | tail -1 \
		| python3 -c "import sys, json; print(json.load(sys.stdin)['writtenUnixSeconds'])")
	echo "run 1 write: writtenUnixSeconds=$w1"

	step "run 2: repeat request, no reset (inside the retention bound); clear this user's Jobs to break the pinned-jobName wedge"
	clear_user_jobs
	local pod2 aud2 ms2
	trigger_aggregate
	pod2=$(wait_new_pod_done "$pod1")
	echo "job pod: $pod2"
	aud2=$(gw_log "$pod2"); ms2=$(ms_log "$pod2")
	echo; echo "--- gateway audit (run 2) ---"; echo "$aud2"
	echo; echo "--- MS log (run 2) ---"; echo "$ms2"
	must_grep "gateway-mediated read ALLOW on the new state class" "$(echo "$aud2" | grep '"op":"read"')" \
		-e '"decision":"ALLOW".*"stateClass":"aggregate_result"'
	local r2
	r2=$(echo "$aud2" | grep '"op":"read"' | grep '"decision":"ALLOW"' | head -1 \
		| python3 -c "import sys, json; print(json.load(sys.stdin)['writtenUnixSeconds'])")
	[ "$r2" = "$w1" ] || fail "read writtenUnixSeconds ($r2) != run 1 write ($w1); not the same blob"
	echo "OK: read returned run 1's blob (writtenUnixSeconds=$r2), across pods and PVC remounts"
	must_grep "MS reused, no recompute" "$ms2" -e "Reusing persisted result"
	must_not_grep "no fresh write on the hit" "$ms2" -e "Result write allowed"
	echo "write-to-hit window: $(( $(date +%s) - t0 ))s (bound ${RETENTION_CANONICAL}s)"
}

block_miss_hit() {
	run_capture scenes miss-then-hit "scripts/capture_e5_genericity.sh miss-hit" do_miss_hit \
		"E5 scenes 1+2: clean-slate miss -> governed write, then a new pod reuses via gateway read (writtenUnixSeconds matches), no recompute; records carry aggregate_result"
}

do_denial() {
	step "reset + seed variant allowed=false, onRevocation='' (deny but retain), retention=${RETENTION_LONG}"
	reset_cluster
	seed_aggregate "sd['allowed'] = False; sd['onRevocation'] = ''; sd['retentionSeconds'] = ${RETENTION_LONG}"
	verify_sd_field allowed False

	step "run: expect read and write DENY 'allowed = false', answer served unpersisted, no destruction"
	local pod aud ms
	trigger_aggregate
	pod=$(wait_new_pod_done "")
	echo "job pod: $pod"
	aud=$(gw_log "$pod"); ms=$(ms_log "$pod")
	echo; echo "--- gateway audit ---"; echo "$aud"
	echo; echo "--- MS log ---"; echo "$ms"
	must_grep "read DENY 'allowed = false'" "$(echo "$aud" | grep '"op":"read"')" \
		-e '"decision":"DENY".*"reason":"allowed = false"'
	must_grep "write DENY 'allowed = false'" "$(echo "$aud" | grep '"op":"write"')" \
		-e '"decision":"DENY".*"reason":"allowed = false"'
	must_grep "deny records carry the state class" "$(echo "$aud" | grep '"op":"write"')" \
		-e '"stateClass":"aggregate_result"'
	must_grep "MS answered without persistence" "$ms" -e "Result write denied"
	must_not_grep "no purge under deny-but-retain" "$aud" -e '"op":"purge"'
	must_not_grep "no retention destruction in this variant" "$aud" -e '"op":"expired"'
	echo "note: the blob survives this scene; the next block's purge record is the proof"
}

block_denial() {
	run_capture scenes denial-after-flip "scripts/capture_e5_genericity.sh denial" do_denial \
		"E5 scene 3: allowed=false (onRevocation retain) -> read+write DENY 'allowed = false', unpersisted answer, no destruction records"
}

do_revocation_purge() {
	step "reset + seed variant allowed=false, onRevocation='purge', retention=${RETENTION_LONG}"
	reset_cluster
	seed_aggregate "sd['allowed'] = False; sd['onRevocation'] = 'purge'; sd['retentionSeconds'] = ${RETENTION_LONG}"
	verify_sd_field onRevocation purge

	step "run: the boot sweep must destroy the retained blob under the confirmed-fresh gate"
	local pod aud ms
	trigger_aggregate
	pod=$(wait_new_pod_done "")
	echo "job pod: $pod"
	aud=$(gw_log "$pod"); ms=$(ms_log "$pod")
	echo; echo "--- gateway audit ---"; echo "$aud"
	echo; echo "--- MS log ---"; echo "$ms"
	must_grep "purge record per removal, confirmed fresh" "$(echo "$aud" | grep '"op":"purge"')" \
		-e '"decision":"PURGED".*"policySource":"fresh"'
	must_grep "purge reason names the revocation" "$(echo "$aud" | grep '"op":"purge"')" \
		-e '"reason":"revoked; onRevocation=purge"'
	must_grep "purge record names the blob" "$(echo "$aud" | grep '"op":"purge"')" \
		-e '"stateClass":"aggregate_result"'
	must_grep "gateway counted the removal" "$aud" -e "Purged 1 state files under revoked agreement"
	must_grep "read after the purge still DENYs on policy" "$(echo "$aud" | grep '"op":"read"')" \
		-e '"decision":"DENY".*"reason":"allowed = false"'
	must_grep "MS answered without persistence" "$ms" -e "Result write denied"
}

block_revocation_purge() {
	run_capture scenes revocation-purge "scripts/capture_e5_genericity.sh revocation-purge" do_revocation_purge \
		"E5 scene 4: onRevocation=purge -> blob destroyed at the boot sweep under the confirmed-fresh gate (op=purge PURGED, policySource fresh), record per removal"
}

do_retention() {
	step "reset + seed canonical; the ${RETENTION_CANONICAL}s bound is the agreement's own term"
	reset_cluster
	seed_aggregate ""
	verify_sd_field retentionSeconds "$RETENTION_CANONICAL"

	step "run 1: establish a fresh blob"
	local pod1 aud1 w1
	trigger_aggregate
	pod1=$(wait_new_pod_done "")
	echo "job pod: $pod1"
	aud1=$(gw_log "$pod1")
	echo; echo "--- gateway audit (run 1) ---"; echo "$aud1"
	must_grep "governed write ALLOW" "$(echo "$aud1" | grep '"op":"write"')" \
		-e '"decision":"ALLOW".*"stateClass":"aggregate_result"'
	w1=$(echo "$aud1" | grep '"op":"write"' | grep '"decision":"ALLOW"' | tail -1 \
		| python3 -c "import sys, json; print(json.load(sys.stdin)['writtenUnixSeconds'])")
	echo "run 1 write: writtenUnixSeconds=$w1"

	step "age the blob past the bound (reset + re-seed take care of most of it)"
	reset_cluster
	seed_aggregate ""
	verify_sd_field retentionSeconds "$RETENTION_CANONICAL"
	while [ $(( $(date +%s) - w1 )) -le "$RETENTION_CANONICAL" ]; do sleep 5; done
	echo "blob age now $(( $(date +%s) - w1 ))s (> ${RETENTION_CANONICAL}s)"

	step "run 2: the boot sweep must destroy the aged blob; read misses; recompute restarts the clock"
	local pod2 aud2 ms2
	trigger_aggregate
	pod2=$(wait_new_pod_done "$pod1")
	echo "job pod: $pod2"
	aud2=$(gw_log "$pod2"); ms2=$(ms_log "$pod2")
	echo; echo "--- gateway audit (run 2) ---"; echo "$aud2"
	echo; echo "--- MS log (run 2) ---"; echo "$ms2"
	must_grep "expired blob destroyed under confirmed-fresh policy" "$(echo "$aud2" | grep '"op":"expired"')" \
		-e '"decision":"DELETED".*"policySource":"fresh"'
	must_grep "expired record carries 'retention exceeded' and the state class" "$(echo "$aud2" | grep '"op":"expired"')" \
		-e '"reason":"retention exceeded".*"stateClass":"aggregate_result"'
	must_grep "read after the sweep DENYs 'not found'" "$(echo "$aud2" | grep '"op":"read"')" \
		-e '"decision":"DENY".*"reason":"not found"'
	must_grep "recompute writes fresh, restarting the clock" "$(echo "$aud2" | grep '"op":"write"')" \
		-e '"decision":"ALLOW"'
	must_grep "MS recomputed" "$ms2" -e "Result write allowed"
	must_not_grep "no reuse of destroyed state" "$ms2" -e "Reusing persisted result"
}

block_retention() {
	run_capture scenes retention-expiry "scripts/capture_e5_genericity.sh retention" do_retention \
		"E5 scene 5: the agreement's own 120s bound -> op=expired DELETED at the boot sweep (confirmed fresh), read DENY not-found, recompute"
}

# --- main -----------------------------------------------------------------

which="${1:-all}"
case "$which" in
miss-hit) block_miss_hit ;;
denial) block_denial ;;
revocation-purge) block_revocation_purge ;;
retention) block_retention ;;
all)
	block_miss_hit
	block_denial
	block_revocation_purge
	block_retention
	;;
*) echo "usage: $0 [miss-hit|denial|revocation-purge|retention|all]" >&2; exit 2 ;;
esac
