#!/usr/bin/env bash
set -u

# Runs the E1 live rows against a real VFL chain and saves the raw output
# under results/e1-decision-correctness/, adding a line to that experiment's
# captures.md.
#
# Each block resets, seeds, triggers, asserts, then captures. Pick one or
# run all:
#   allow-resume    empty-PVC "not found" read, ALLOW write path, then a
#                   second run to prove resume-allowed read
#   resume-disabled seed resumeAllowed=false, startup read should DENY
#   expired         seed a short retention; the boot sweep destroys the aged
#                   state under confirmed-fresh policy (op=expired DELETED),
#                   the startup read then DENYs "not found"
#   adversarial     long chain + grpcurl: identity mismatch PermissionDenied,
#                   concurrent same-slot writes, a direct write the completeness
#                   check catches, then completeness PASS on all four stewards
#
# Usage: capture_e1_live.sh [allow-resume|resume-disabled|expired|adversarial|all]
# Default is all. A block takes a few minutes; the polls allow for that.
#
# Needs the fork images loaded in kind (see the dev-loop.md imageID check).
# It grabs local ports APIPORT/ORCHPORT/GWPORT and kills any stale forward on
# them. allow-resume DELETES the four state PVCs to start clean; expired needs
# state left on the PVCs by an earlier block.

root="$(cd "$(dirname "$0")/.." && pwd)"
# Override for shakedown runs that must not land in the evidence tree.
results_dir="${E1_RESULTS_DIR:-$root/results/e1-decision-correctness}"

STEWARD_NS=(server clientone clienttwo clientthree)
USER_NAME="jake.jongejans@student.uva.nl"
APIPORT="${APIPORT:-8080}"
ORCHPORT="${ORCHPORT:-8082}"
GWPORT="${GWPORT:-50050}"
CYCLES_SHORT="${CYCLES_SHORT:-3}"
CYCLES_LONG="${CYCLES_LONG:-300}"
RETENTION_SHORT="${RETENTION_SHORT:-30}"
CONCURRENT_N="${CONCURRENT_N:-8}"
POLL_MAX="${POLL_MAX:-36}"        # x5s = 3 min, short-chain runs
POLL_MAX_LONG="${POLL_MAX_LONG:-120}"  # x5s = 10 min, the cycles=300 run

PIDS=()
cleanup() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; }
trap cleanup EXIT

step() { echo; echo "=== $*"; }
fail() { echo "E1 FAIL: $*" >&2; exit 1; }

# --- shared helpers -------------------------------------------------------

provenance() {
	echo "\$ date"
	date
	echo
	echo "\$ git rev-parse HEAD"
	git -C "$root" rev-parse HEAD
	echo
	echo "\$ git status --short"
	git -C "$root" status --short
	echo
	echo "\$ kubectl config current-context"
	kubectl config current-context
	echo
}

reset_cluster() {
	"$root/reset.sh" || fail "reset.sh failed"
}

# Seed the four state-aware agreements via the orchestrator /policyEnforcer
# operator path. $1 is an optional python statement applied to each relation's
# stateDirectives dict (variable `sd`) before the PUT; empty seeds canonical.
seed_agreements() {
	local transform="${1:-}"
	pkill -f "port-forward.*${ORCHPORT}:8080" 2>/dev/null
	kubectl port-forward -n orchestrator svc/orchestrator "${ORCHPORT}:8080" >/dev/null 2>&1 &
	PIDS+=($!)
	sleep 3
	local s f code tmp
	for s in "${STEWARD_NS[@]}"; do
		f="$root/configuration/etcd_launch_files/state_aware_${s}.json"
		tmp=$(mktemp)
		python3 -c "
import json
a = json.load(open('$f'))
for rel in a['relations'].values():
    sd = rel.get('stateDirectives')
    if sd is None:
        continue
    ${transform:-pass}
print(json.dumps(a))" > "$tmp" || fail "variant transform failed for $s"
		code=$(curl -s -o /dev/null -w '%{http_code}' -X PUT "http://localhost:${ORCHPORT}/api/v1/policyEnforcer" \
			-H 'Content-Type: application/json' --data-binary @"$tmp")
		rm -f "$tmp"
		[ "$code" = "200" ] || fail "seed PUT for $s returned http $code"
		echo "[seed] $s: OK${transform:+ (variant: $transform)}"
	done
}

# Assert a stateDirectives field landed in etcd for every steward.
verify_directive_field() { # $1 field, $2 expected python repr (True/False/30)
	local s got
	for s in "${STEWARD_NS[@]}"; do
		got=$(kubectl exec -n core etcd-0 -c etcd -- sh -c \
			"ETCDCTL_API=3 /usr/local/bin/etcdctl --endpoints=localhost:2379 get /policyEnforcer/agreements/${s} --print-value-only" \
			| python3 -c "
import sys, json
a = json.load(sys.stdin)
print(a['relations']['${USER_NAME}']['stateDirectives']['$1'])")
		[ "$got" = "$2" ] || fail "etcd agreement for $s: $1=$got, expected $2"
	done
	echo "[seed] verified in etcd for all stewards: $1=$2"
}

trigger() { # $1 = cycles; echoes request_id (logs go to stderr)
	pkill -f "port-forward.*${APIPORT}:8080" 2>/dev/null
	kubectl port-forward -n api-gateway svc/api-gateway "${APIPORT}:8080" >/dev/null 2>&1 &
	PIDS+=($!)
	sleep 3
	local resp
	resp=$(curl -s -X POST "http://localhost:${APIPORT}/api/v1/requestApproval" \
		-H 'Content-Type: application/json' -d '{
  "type": "vflTrainModelRequest",
  "user": { "id": "1234", "userName": "'"${USER_NAME}"'" },
  "dataProviders": ["server", "clientone", "clienttwo", "clientthree"],
  "data_request": { "type": "vflTrainModelRequest",
    "data": { "learning_rate": 0.1, "cycles": '"$1"',
      "policy_removal": -1, "policy_reintroduction": -1, "training_backtrack": 0 },
    "requestMetadata": {} } }')
	echo "trigger: $resp" >&2
	echo "$resp" | python3 -c "import sys, json; print(json.load(sys.stdin)['request_id'])" \
		|| fail "trigger not accepted: $resp"
}

wait_done() { # $1 = request_id, $2 = max polls (5s each); prints final status JSON
	local i out st
	for i in $(seq 1 "$2"); do
		sleep 5
		out=$(curl -s "http://localhost:${APIPORT}/api/v1/getTrainingStatus?id=$1")
		st=$(echo "$out" | python3 -c "import sys, json; print(json.load(sys.stdin).get('status', ''))" 2>/dev/null)
		echo "poll $i: ${st:-no-response}" >&2
		if [ "$st" = "done" ]; then
			echo "$out"
			return 0
		fi
		[ "$st" = "failed" ] && fail "training status=failed: $out"
	done
	fail "training not done after $2 polls"
}

steward_job() { kubectl get jobs -n "$1" -o jsonpath='{.items[0].metadata.name}'; }

steward_pod() { kubectl get pods -n "$1" -o name 2>/dev/null | grep jake | head -1 | cut -d/ -f2; }

audit_log() { kubectl logs -n "$1" "job/$(steward_job "$1")" -c policy-checkpoint-gateway 2>/dev/null; }

ms_log() { kubectl logs -n "$1" "job/$(steward_job "$1")" -c "$2" 2>/dev/null; }

# Assert helper: $1 = description, $2 = text, remaining args = grep args that
# must all match. Prints the matching line(s) into the artifact.
must_grep() {
	local desc="$1" text="$2"
	shift 2
	local hit
	hit=$(echo "$text" | grep "$@")
	[ -n "$hit" ] || fail "expected: $desc"
	echo "OK: $desc"
	echo "$hit" | head -5 | sed 's/^/    /'
}

must_not_grep() {
	local desc="$1" text="$2"
	shift 2
	if echo "$text" | grep -q "$@"; then
		fail "unexpected: $desc"
	fi
	echo "OK: absent as expected: $desc"
}

# Run a block function, tee its output to a timestamped artifact, append the
# generated captures.md line. Aborts the script if the block failed.
capture() { # $1 = subdir, $2 = slug, $3 = block arg for the captures line, $4 = fn, $5 = note
	local subdir="$1" slug="$2" blockarg="$3" fn="$4" note="$5"
	local ts out rc commit
	ts="$(date +%Y%m%d-%H%M%S)"
	out="$results_dir/${subdir}/${ts}_${slug}.txt"
	mkdir -p "$(dirname "$out")"
	{ provenance; "$fn"; } 2>&1 | tee "$out"
	rc=${PIPESTATUS[0]}
	commit="$(git -C "$root" rev-parse --short HEAD)"
	[ "$rc" -ne 0 ] && note="$note; FAILED (exit=$rc)"
	echo "\`e1-decision-correctness/${subdir}/${ts}_${slug}.txt | $ts | scripts/capture_e1_live.sh ${blockarg} | $commit | $note\`" \
		>> "$results_dir/captures.md"
	echo
	echo "captured: $out (exit=$rc)"
	[ "$rc" -ne 0 ] && exit "$rc"
	return 0
}

# --- blocks ---------------------------------------------------------------

do_allow_resume() {
	step "clean slate: reset, then delete the four state PVCs"
	reset_cluster
	local ns
	for ns in "${STEWARD_NS[@]}"; do
		kubectl get pvc -n "$ns" -o name 2>/dev/null | grep 'persistentvolumeclaim/state-' \
			| xargs -r kubectl delete -n "$ns" --wait=true
	done

	step "seed canonical state-aware agreements"
	seed_agreements ""
	verify_directive_field resumeAllowed True

	step "run 1: cycles=${CYCLES_SHORT} against empty PVCs"
	local id1 status1
	id1=$(trigger "$CYCLES_SHORT") || fail "trigger 1 failed"
	status1=$(wait_done "$id1" "$POLL_MAX")
	echo "$status1"

	local aud1
	aud1=$(audit_log server)
	echo; echo "--- server gateway audit (run 1) ---"; echo "$aud1"
	must_grep "empty-PVC startup read DENY" "$(echo "$aud1" | grep '"op":"read"')" -e '"decision":"DENY"'
	must_grep "read deny reason is 'not found'" "$(echo "$aud1" | grep '"op":"read"')" -e '"reason":"not found"'
	local wcount
	wcount=$(echo "$aud1" | grep '"op":"write"' | grep -c '"decision":"ALLOW"')
	[ "$wcount" -ge "$CYCLES_SHORT" ] || fail "expected >=${CYCLES_SHORT} ALLOW writes in run 1, got $wcount"
	echo "OK: $wcount ALLOW write audit lines in run 1"

	local ms1
	ms1=$(ms_log server vfl-train-model-demo | grep -i checkpoint)
	echo; echo "--- server MS checkpoint lines (run 1) ---"; echo "$ms1"
	must_grep "server wrote round_index=${CYCLES_SHORT}" "$ms1" -e "Checkpoint write allowed: round_index=${CYCLES_SHORT}"
	must_not_grep "no resume on an empty PVC" "$ms1" -e "Resumed server model"

	local w1
	w1=$(echo "$aud1" | grep '"op":"write"' | grep '"decision":"ALLOW"' | tail -1 \
		| python3 -c "import sys, json; print(json.load(sys.stdin)['writtenUnixSeconds'])")
	echo "last write of run 1: writtenUnixSeconds=$w1"

	step "run 2: reset + re-seed + re-fire inside the retention window"
	reset_cluster
	seed_agreements ""
	verify_directive_field resumeAllowed True
	local id2 status2
	id2=$(trigger "$CYCLES_SHORT") || fail "trigger 2 failed"
	status2=$(wait_done "$id2" "$POLL_MAX")
	echo "$status2"

	local aud2
	aud2=$(audit_log server)
	echo; echo "--- server gateway audit (run 2) ---"; echo "$aud2"
	must_grep "resume-allowed read ALLOW" "$(echo "$aud2" | grep '"op":"read"')" -e '"decision":"ALLOW"'
	local r2
	r2=$(echo "$aud2" | grep '"op":"read"' | grep '"decision":"ALLOW"' | head -1 \
		| python3 -c "import sys, json; print(json.load(sys.stdin)['writtenUnixSeconds'])")
	echo "run 2 read ALLOW writtenUnixSeconds=$r2 (run 1 last write was $w1)"
	[ "$r2" = "$w1" ] || fail "read writtenUnixSeconds ($r2) != run 1 last write ($w1); mtime did not survive the remount"
	echo "OK: read timestamp matches run 1's last write (mtime survived the PVC remount)"

	local ms2 cms2
	ms2=$(ms_log server vfl-train-model-demo | grep -iE "resum|checkpoint")
	cms2=$(ms_log clientone vfl-train-demo | grep -iE "resum|checkpoint")
	echo; echo "--- server MS lines (run 2) ---"; echo "$ms2"
	echo "--- clientone MS lines (run 2) ---"; echo "$cms2"
	must_grep "server resumed at round_index=${CYCLES_SHORT}" "$ms2" -e "Resumed server model from checkpoint: round_index=${CYCLES_SHORT}"
	must_grep "server wrote round_index=$((CYCLES_SHORT * 2)) (monotonic across runs)" "$ms2" -e "Checkpoint write allowed: round_index=$((CYCLES_SHORT * 2))"
	must_grep "clientone resumed at round_index=${CYCLES_SHORT}" "$cms2" -e "Resuming client model from checkpoint: round_index=${CYCLES_SHORT}"

	echo; echo "--- client steward audits (run 2, read+write decisions) ---"
	for ns in clientone clienttwo clientthree; do
		echo "[$ns]"
		audit_log "$ns" | grep -E '"op":"(read|write)"'
	done
}

block_allow_resume() {
	capture live-chain allow-write-and-resume allow-resume do_allow_resume \
		"E1 live rows: empty-PVC read DENY not-found, ALLOW write path, resume-allowed read (writtenAt matches across remount)"
}

do_resume_disabled() {
	step "reset + seed variant resumeAllowed=false"
	reset_cluster
	seed_agreements "sd['resumeAllowed'] = False"
	verify_directive_field resumeAllowed False

	step "run: cycles=${CYCLES_SHORT}; startup read must DENY 'resume disabled', writes still ALLOW"
	local id st aud ms wcount
	id=$(trigger "$CYCLES_SHORT") || fail "trigger failed"
	st=$(wait_done "$id" "$POLL_MAX")
	echo "$st"

	aud=$(audit_log server)
	echo; echo "--- server gateway audit ---"; echo "$aud"
	must_grep "startup read DENY" "$(echo "$aud" | grep '"op":"read"')" -e '"decision":"DENY"'
	must_grep "read deny reason is 'resume disabled'" "$(echo "$aud" | grep '"op":"read"')" -e '"reason":"resume disabled"'
	wcount=$(echo "$aud" | grep '"op":"write"' | grep -c '"decision":"ALLOW"')
	[ "$wcount" -ge "$CYCLES_SHORT" ] || fail "expected >=${CYCLES_SHORT} ALLOW writes, got $wcount"
	echo "OK: $wcount ALLOW write audit lines (persistence continues, only resume is denied)"

	ms=$(ms_log server vfl-train-model-demo | grep -iE "resum|checkpoint")
	echo; echo "--- server MS lines ---"; echo "$ms"
	must_not_grep "no resume under resumeAllowed=false" "$ms" -e "Resumed server model"
	must_grep "fresh model still checkpoints round_index=1" "$ms" -e "Checkpoint write allowed: round_index=1"
}

block_resume_disabled() {
	capture live-chain resume-disabled-deny resume-disabled do_resume_disabled \
		"E1 live row: resumeAllowed=false -> startup read DENY 'resume disabled'; writes still ALLOW"
}

# Requires prior state on the PVCs (run after allow-resume / resume-disabled):
# on an empty PVC there would be nothing for the sweep to destroy and the
# "not found" DENY would not be the retention row.
do_expired() {
	step "reset + seed variant retentionSeconds=${RETENTION_SHORT}"
	reset_cluster
	seed_agreements "sd['retentionSeconds'] = ${RETENTION_SHORT}"
	verify_directive_field retentionSeconds "$RETENTION_SHORT"
	echo "note: the previous run's checkpoints are older than ${RETENTION_SHORT}s by now (the reset alone settles 45s)"

	step "run: cycles=${CYCLES_SHORT}; boot sweep must destroy the aged state, startup read then DENYs 'not found'"
	local id st aud ms wcount
	id=$(trigger "$CYCLES_SHORT") || fail "trigger failed"
	st=$(wait_done "$id" "$POLL_MAX")
	echo "$st"

	aud=$(audit_log server)
	echo; echo "--- server gateway audit ---"; echo "$aud"
	must_grep "expired state destroyed under confirmed-fresh policy" "$(echo "$aud" | grep '"op":"expired"')" -e '"decision":"DELETED"'
	must_grep "expired record carries 'retention exceeded'" "$(echo "$aud" | grep '"op":"expired"')" -e '"reason":"retention exceeded"'
	must_grep "startup read DENY" "$(echo "$aud" | grep '"op":"read"')" -e '"decision":"DENY"'
	must_grep "read deny reason is 'not found' (the sweep already destroyed the state)" "$(echo "$aud" | grep '"op":"read"')" -e '"reason":"not found"'
	wcount=$(echo "$aud" | grep '"op":"write"' | grep -c '"decision":"ALLOW"')
	[ "$wcount" -ge "$CYCLES_SHORT" ] || fail "expected >=${CYCLES_SHORT} ALLOW writes, got $wcount"
	echo "OK: $wcount ALLOW write audit lines (a fresh write restarts the retention clock)"

	ms=$(ms_log server vfl-train-model-demo | grep -iE "resum|checkpoint")
	echo; echo "--- server MS lines ---"; echo "$ms"
	must_not_grep "no resume from expired state" "$ms" -e "Resumed server model"
}

block_expired() {
	capture live-chain retention-expired-deny expired do_expired \
		"E1 live row: retention exceeded -> boot sweep destroys under confirmed-fresh policy (op=expired DELETED), read DENY not-found, writes still ALLOW"
}

gw_rpc() { # $1 = identity json, $2 = state_key; writes payload AQID to class "adversarial"
	grpcurl -plaintext -import-path "$root/proto-files" -proto policyCheckpointGateway.proto \
		-d "{\"identity\":$1,\"state_key\":\"$2\",\"state_class\":\"adversarial\",\"payload\":\"AQID\"}" \
		"localhost:${GWPORT}" dynamos.PolicyCheckpointGateway/RequestStateWrite 2>&1
}

do_adversarial() {
	step "reset + canonical seed + long chain (cycles=${CYCLES_LONG}) so the gateway outlives the battery"
	reset_cluster
	seed_agreements ""
	verify_directive_field allowed True
	local id
	id=$(trigger "$CYCLES_LONG") || fail "trigger failed"

	step "wait for the server gateway container"
	local pod="" i
	for i in $(seq 1 30); do
		pod=$(steward_pod server)
		[ -n "$pod" ] && break
		sleep 2
	done
	[ -n "$pod" ] || fail "no job pod appeared in server"
	for i in $(seq 1 30); do
		kubectl get pod "$pod" -n server -o jsonpath='{.status.containerStatuses[?(@.name=="policy-checkpoint-gateway")].state}' 2>/dev/null \
			| grep -q running && break
		sleep 2
	done
	echo "gateway pod: $pod"

	local identity
	identity=$(kubectl get pod "$pod" -n server -o json | python3 -c '
import json, sys
env = {e["name"]: e.get("value", "") for c in json.load(sys.stdin)["spec"]["containers"]
       if c["name"] == "policy-checkpoint-gateway" for e in c["env"]}
print(json.dumps({
    "steward": env["DATA_STEWARD_NAME"], "user": env["REQUEST_USER"],
    "request_type": env["REQUEST_TYPE"], "job_id": env["JOB_NAME"],
    "local_job_name": env["LOCAL_JOB_NAME"]}))')
	echo "pod identity: $identity"

	pkill -f "port-forward.*${GWPORT}:${GWPORT}" 2>/dev/null
	kubectl port-forward -n server "$pod" "${GWPORT}:${GWPORT}" >/dev/null 2>&1 &
	PIDS+=($!)
	sleep 3

	step "(a) identity mismatch -> strict PermissionDenied + identity_mismatch audit"
	local tampered out_a
	tampered=$(echo "$identity" | python3 -c \
		"import sys, json; d = json.load(sys.stdin); d['steward'] = 'TAMPERED'; print(json.dumps(d))")
	echo "tampered identity: $tampered"
	out_a=$(gw_rpc "$tampered" mismatch-probe)
	echo "$out_a"
	echo "$out_a" | grep -q "PermissionDenied" || fail "expected PermissionDenied on tampered identity"
	must_grep "identity_mismatch audited" "$(kubectl logs -n server "$pod" -c policy-checkpoint-gateway)" \
		-e '"op":"identity_mismatch"'
	kubectl exec -n server "$pod" -c policy-checkpoint-gateway -- ls /state/data/adversarial/ 2>/dev/null \
		| grep -q mismatch-probe && fail "tampered write reached /state"
	echo "OK: no state file from the tampered write"

	step "(c) ${CONCURRENT_N} concurrent writes to one slot through the single mediator"
	local tmpdir pids=() n p okc audc
	tmpdir=$(mktemp -d)
	for n in $(seq 1 "$CONCURRENT_N"); do
		gw_rpc "$identity" concurrent-slot > "$tmpdir/$n.out" 2>&1 &
		pids+=($!)
	done
	for p in "${pids[@]}"; do wait "$p"; done
	grep -H '"allowed"' "$tmpdir"/*.out
	okc=$(grep -l '"allowed": true' "$tmpdir"/*.out | wc -l)
	rm -rf "$tmpdir"
	[ "$okc" -eq "$CONCURRENT_N" ] || fail "expected $CONCURRENT_N ALLOW responses, got $okc"
	kubectl exec -n server "$pod" -c policy-checkpoint-gateway -- ls -l /state/data/adversarial/concurrent-slot.bin \
		|| fail "slot file missing after concurrent writes"
	audc=$(kubectl logs -n server "$pod" -c policy-checkpoint-gateway \
		| grep '"op":"write"' | grep '"stateKey":"concurrent-slot"' | grep -c '"decision":"ALLOW"')
	[ "$audc" -eq "$CONCURRENT_N" ] || fail "expected $CONCURRENT_N ALLOW audit lines for the slot, got $audc"
	echo "OK: $okc/$CONCURRENT_N ALLOW responses, one intact slot file, $audc audit lines"

	step "(b) direct write bypassing the gateway; the completeness check must flag it"
	kubectl exec -n server "$pod" -c policy-checkpoint-gateway -- sh -c \
		'mkdir -p /state/data/adversarial && printf rogue > /state/data/adversarial/rogue.bin'
	local chk rc
	chk=$("$root/scripts/check_audit_completeness.sh" server "$pod")
	rc=$?
	echo "$chk"
	[ "$rc" -ne 0 ] || fail "completeness check must FAIL on the planted file"
	echo "$chk" | grep -q "rogue.bin" || fail "planted file not named by the check"
	echo "OK: bypass write detected (exit=$rc)"
	kubectl exec -n server "$pod" -c policy-checkpoint-gateway -- rm /state/data/adversarial/rogue.bin
	echo "planted file removed"

	step "closing invariant: completeness PASS on all four stewards"
	local ns cpod
	for ns in "${STEWARD_NS[@]}"; do
		cpod=$(steward_pod "$ns")
		[ -n "$cpod" ] || fail "no chain pod in $ns"
		echo "[$ns / $cpod]"
		"$root/scripts/check_audit_completeness.sh" "$ns" "$cpod" || fail "completeness FAIL in $ns"
	done

	step "wait for the long chain to finish"
	local st
	st=$(wait_done "$id" "$POLL_MAX_LONG")
	echo "$st" | python3 -c "
import sys, json
d = json.load(sys.stdin)
rs = d.get('results', [])
print('status:', d.get('status'), 'rounds:', len(rs))
if rs:
    print('first r2:', rs[0]['accuracy'], 'last r2:', rs[-1]['accuracy'])"
}

block_adversarial() {
	capture adversarial adversarial-battery adversarial do_adversarial \
		"E1 adversarial rows: identity mismatch PermissionDenied, ${CONCURRENT_N:-8} concurrent same-slot writes, bypass write flagged then removed, completeness PASS x4"
}

# --- main -----------------------------------------------------------------

which="${1:-all}"
case "$which" in
allow-resume) block_allow_resume ;;
resume-disabled) block_resume_disabled ;;
expired) block_expired ;;
adversarial) block_adversarial ;;
all)
	block_allow_resume
	block_resume_disabled
	block_expired
	block_adversarial
	;;
*) echo "usage: $0 [allow-resume|resume-disabled|expired|adversarial|all]" >&2; exit 2 ;;
esac
