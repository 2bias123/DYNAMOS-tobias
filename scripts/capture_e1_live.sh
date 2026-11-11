#!/usr/bin/env bash
set -u

# Runs the E1 live rows against a real VFL chain and saves the raw output
# under results/campaign-n50/e1-decision-correctness/, adding a line to that experiment's
# captures.md.
#
# Each block resets, seeds, triggers, asserts, then captures. Pick one or
# run all:
#   allow-resume    empty-PVC "not found" read, ALLOW write path, then a
#                   second run to prove resume-allowed read
#   resume-disabled seed resumeAllowed=false, startup read should DENY
#   expired         seed a short retention; the idle gateway destroys the aged
#                   state under confirmed-fresh policy (op=expired DELETED,
#                   no job fields), the next run's startup read then DENYs
#                   "not found"
#   adversarial     long chain + grpcurl: identity mismatch PermissionDenied,
#                   concurrent same-slot writes, a direct write the completeness
#                   check catches, then completeness PASS on all four stewards
#   idle-nothing-due  clean PVCs, one run; the idle gateways that follow the
#                   job hold the state over three polls: no audit record, no
#                   state file changed
#   idle-handover   a second run while idle gateways hold the state: each
#                   agent stops its idle gateway before the job's gateway
#                   starts, and the stored state is read back
#   idle-revocation revocation while idle: the idle gateways purge the state
#                   within 30s of the request
#   idle-expiry     a run under a short retention: the idle gateways delete
#                   each state file within retention + 30s of its last write
#
# The idle blocks read the audit log on the state PVC, where records written
# while idle carry no job fields. After every job they also assert that an
# idle gateway is up within 60s of the job's gateway ending.
#
# Usage: capture_e1_live.sh [allow-resume|resume-disabled|expired|adversarial|
#                            idle-nothing-due|idle-handover|idle-revocation|idle-expiry|idle|all]
# Default is all; idle runs the four idle blocks in order. A block takes a few
# minutes; the polls allow for that.
#
# Needs the fork images loaded in kind (see the dev-loop.md imageID check).
# It grabs local ports APIPORT/ORCHPORT/GWPORT and kills any stale forward on
# them. allow-resume and idle-nothing-due DELETE the four state PVCs to start
# clean; expired needs state left on the PVCs by an earlier block, and so do
# idle-handover and idle-revocation.

EXP=E1
root="$(cd "$(dirname "$0")/.." && pwd)"
# Override for shakedown runs that must not land in the evidence tree.
results_dir="${E1_RESULTS_DIR:-$root/results/campaign-n50/e1-decision-correctness}"
. "$root/scripts/capture_lib.sh"

STEWARD_NS=(server clientone clienttwo clientthree)
USER_NAME="jake.jongejans@student.uva.nl"
APIPORT="${APIPORT:-8080}"
ORCHPORT="${ORCHPORT:-8082}"
GWPORT="${GWPORT:-50050}"
CYCLES_SHORT="${CYCLES_SHORT:-$CAMPAIGN_N}"
CYCLES_LONG="${CYCLES_LONG:-300}"
RETENTION_SHORT="${RETENTION_SHORT:-30}"
# Long enough for the idle gateway to be up before the state is due.
RETENTION_IDLE="${RETENTION_IDLE:-120}"
IDLE_POLL="${IDLE_POLL:-30}"  # the idle gateway's agreement poll, seconds
# A node-present image with python3 and a shell, as in capture_e1_completeness.sh.
INSPECTOR_IMAGE="${INSPECTOR_IMAGE:-tamjiyan/vfl-train-demo:latest}"
INSPECTOR=e1-idle-inspector
CONCURRENT_N="${CONCURRENT_N:-8}"
POLL_MAX="${POLL_MAX:-$(poll_max_for_cycles "$CYCLES_SHORT")}"  # x5s, short-chain runs
POLL_MAX_LONG="${POLL_MAX_LONG:-120}"  # x5s = 10 min, the cycles=300 run

PIDS=()
cleanup() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; }
trap cleanup EXIT

# --- shared helpers -------------------------------------------------------

steward_job() { kubectl get jobs -n "$1" -l 'dynamos/gateway!=idle' -o jsonpath='{.items[0].metadata.name}'; }

audit_log() { kubectl logs -n "$1" "job/$(steward_job "$1")" -c policy-checkpoint-gateway 2>/dev/null; }

ms_log() { kubectl logs -n "$1" "job/$(steward_job "$1")" -c "$2" 2>/dev/null; }

agent_log() { kubectl logs -n "$1" -l type=agent -c "$1" --tail=-1 --timestamps 2>/dev/null; }

micros() { date -d "$1" +%s%6N; }

# Bound helper on two unix-microsecond stamps: $3 must lie $4 to $5 seconds
# after $2. Prints both stamps and the difference into the artifact.
must_follow_within() { # $1 = description, $2 = from, $3 = at, $4 = min s, $5 = max s
	local d=$(( $3 - $2 ))
	{ [ "$d" -ge $(( $4 * 1000000 )) ] && [ "$d" -le $(( $5 * 1000000 )) ]; } \
		|| fail "$1: $(( d / 1000 )) ms (from $2 to $3), outside ${4}s..${5}s"
	echo "OK: $1: $(( d / 1000 )) ms (from $2 to $3; bound ${4}s..${5}s)"
}

# The pod of $1's idle gateway once it runs and has loaded the agreement,
# which it does only while it holds the state lock. Waits up to $2 seconds.
idle_pod() { # $1 = ns, $2 = deadline in seconds
	local pvc i pod
	pvc=$(state_pvc_of "$1")
	for i in $(seq 1 "$2"); do
		pod=$(kubectl get pods -n "$1" -l "job-name=idle-$pvc" --field-selector=status.phase=Running \
			-o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
		if [ -n "$pod" ] && kubectl logs -n "$1" "$pod" 2>/dev/null | grep -q 'Agreement loaded'; then
			echo "$pod"
			return 0
		fi
		sleep 1
	done
	return 1
}

# After a job: the idle gateway on $1's state PVC must be up within 60s of
# the job's gateway ending, read from the two pods' container timestamps.
idle_follows_job() { # $1 = ns
	local pod ended="" idle started i
	pod=$(steward_pod "$1")
	[ -n "$pod" ] || fail "no chain pod in $1"
	for i in $(seq 1 60); do
		ended=$(kubectl get pod "$pod" -n "$1" \
			-o jsonpath='{.status.containerStatuses[?(@.name=="policy-checkpoint-gateway")].state.terminated.finishedAt}' 2>/dev/null)
		[ -n "$ended" ] && break
		sleep 2
	done
	[ -n "$ended" ] || fail "the gateway in $1/$pod had not ended 120s after the run"
	idle=$(idle_pod "$1" 90) || fail "no idle gateway holds the state PVC in $1 90s after the job's gateway ended"
	started=$(kubectl get pod "$idle" -n "$1" -o jsonpath='{.status.containerStatuses[0].state.running.startedAt}')
	[ -n "$started" ] || fail "the idle pod $1/$idle has no start time"
	must_follow_within "$1: idle gateway up after the job's gateway ended" "$(micros "$ended")" "$(micros "$started")" 0 60
}

# The audit log on $1's state PVC, then one sha256sum line per state file,
# read through an inspector pod that mounts the PVC read-only beside whatever
# holds it. Audit lines start with "{".
claim_snapshot() { # $1 = ns
	local out rc
	start_state_inspector "$1" "$INSPECTOR" "$INSPECTOR_IMAGE" >&2
	rc=$?
	if [ "$rc" -eq 0 ]; then
		out=$(kubectl exec -n "$1" "$INSPECTOR" -c inspector -- sh -c \
			'cat /state/audit/audit.log && find /state/data -type f -exec sha256sum {} + | sort -k2')
		rc=$?
	fi
	kubectl -n "$1" delete pod "$INSPECTOR" --ignore-not-found=true --grace-period=1 --wait=true --timeout=60s >/dev/null 2>&1
	[ "$rc" -eq 0 ] || return 1
	echo "$out"
}

# Audit records on stdin decided at or after $1 with op $2 and decision $3,
# one per line as "decidedUnixMicros jobId policySource stateClass/stateKey";
# jobId is "-" on a record without job fields.
records_since() {
	python3 -c "
import sys, json
for l in sys.stdin:
    if not l.startswith('{'):
        continue
    r = json.loads(l)
    if r['decidedUnixMicros'] >= $1 and r['op'] == '$2' and r.get('decision') == '$3':
        i = r['identity']
        print(r['decidedUnixMicros'], i.get('jobId') or i.get('localJobName') or '-',
              r.get('policySource', '-'), r.get('stateClass', '') + '/' + r.get('stateKey', ''))"
}

# PUT a variant of $1's agreement as seed_agreements does, and print the host
# time in unix microseconds taken immediately before curl sends the request.
# $2 is the python statement applied to each relation's stateDirectives. The
# stamp is compared with the gateway's decision time, so the host and the
# node must share a clock, as they do on kind.
put_agreement_stamped() {
	local f tmp sent code
	f="$root/configuration/etcd_launch_files/state_aware_$1.json"
	tmp=$(mktemp)
	python3 -c "
import json
a = json.load(open('$f'))
for rel in a['relations'].values():
    sd = rel.get('stateDirectives')
    if sd is None:
        continue
    $2
print(json.dumps(a))" > "$tmp" || return 1
	sent=$(date +%s%6N)
	code=$(curl -s -o /dev/null -w '%{http_code}' -X PUT "${ORCH_BASE}/api/v1/policyEnforcer" \
		-H 'Content-Type: application/json' --data-binary @"$tmp")
	rm -f "$tmp"
	[ "$code" = "200" ] || return 1
	echo "$sent"
}

# --- blocks ---------------------------------------------------------------

do_allow_resume() {
	step "clean slate: reset, then delete the four state PVCs"
	reset_cluster
	delete_state_pvcs
	local ns

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
	run_capture live-chain allow-write-and-resume "scripts/capture_e1_live.sh allow-resume" do_allow_resume \
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
	run_capture live-chain resume-disabled-deny "scripts/capture_e1_live.sh resume-disabled" do_resume_disabled \
		"E1 live row: resumeAllowed=false -> startup read DENY 'resume disabled'; writes still ALLOW"
}

# Requires prior state on the PVCs (run after allow-resume / resume-disabled):
# on an empty PVC there would be nothing for the idle gateway to destroy and
# the "not found" DENY would not be the retention row.
do_expired() {
	step "reset + seed variant retentionSeconds=${RETENTION_SHORT}"
	reset_cluster
	local t0
	t0=$(date +%s%6N)
	seed_agreements "sd['retentionSeconds'] = ${RETENTION_SHORT}"
	verify_directive_field retentionSeconds "$RETENTION_SHORT"
	echo "note: the previous run's checkpoints are older than ${RETENTION_SHORT}s by now (the reset alone settles 45s)"

	step "expiry while idle: the server's idle gateway must destroy the aged state and exit"
	local pvc i succeeded="" snap recs n exp
	pvc=$(state_pvc_of server)
	for i in $(seq 1 90); do
		succeeded=$(kubectl get job "idle-$pvc" -n server -o jsonpath='{.status.succeeded}' 2>/dev/null)
		[ "$succeeded" = 1 ] && break
		sleep 1
	done
	[ "$succeeded" = 1 ] || fail "the idle Job in server did not complete within 90s of the seed"
	snap=$(claim_snapshot server) || fail "cannot read the state PVC in server"
	recs=$(echo "$snap" | records_since "$t0" expired DELETED)
	n=$(echo "$recs" | grep -c .)
	[ "$n" -ge 1 ] || fail "no expiry record on the server's state PVC after the seed; this block needs state left by an earlier block"
	[ "$(echo "$recs" | grep -c ' - fresh ')" -eq "$n" ] \
		|| fail "an expiry after the seed carries job fields or was not decided on fresh terms: $recs"
	echo "OK: $n expired DELETED record(s) decided after the seed was sent ($t0), without job fields, on fresh terms"
	exp=$(echo "$snap" | grep '"op":"expired"' | grep '"decision":"DELETED"' | tail -n "$n")
	echo; echo "--- server state PVC audit, expired records since the seed ---"; echo "$exp"
	must_grep "expired state destroyed while idle (no job fields) under confirmed-fresh policy" "$exp" -e '"decision":"DELETED".*"policySource":"fresh"'
	must_grep "expired record carries 'retention exceeded'" "$exp" -e '"reason":"retention exceeded"'

	step "run: cycles=${CYCLES_SHORT}; startup read must DENY 'not found', the run starts anew"
	local id st aud ms wcount
	id=$(trigger "$CYCLES_SHORT") || fail "trigger failed"
	st=$(wait_done "$id" "$POLL_MAX")
	echo "$st"

	aud=$(audit_log server)
	echo; echo "--- server gateway audit ---"; echo "$aud"
	must_grep "startup read DENY" "$(echo "$aud" | grep '"op":"read"')" -e '"decision":"DENY"'
	must_grep "read deny reason is 'not found' (the idle gateway already destroyed the state)" "$(echo "$aud" | grep '"op":"read"')" -e '"reason":"not found"'
	wcount=$(echo "$aud" | grep '"op":"write"' | grep -c '"decision":"ALLOW"')
	[ "$wcount" -ge "$CYCLES_SHORT" ] || fail "expected >=${CYCLES_SHORT} ALLOW writes, got $wcount"
	echo "OK: $wcount ALLOW write audit lines (a fresh write restarts the retention clock)"

	ms=$(ms_log server vfl-train-model-demo | grep -iE "resum|checkpoint")
	echo; echo "--- server MS lines ---"; echo "$ms"
	must_not_grep "no resume from expired state" "$ms" -e "Resumed server model"
}

block_expired() {
	run_capture live-chain retention-expired-deny "scripts/capture_e1_live.sh expired" do_expired \
		"E1 live row: retention exceeded -> the idle gateway destroys under confirmed-fresh policy (op=expired DELETED without job fields), the next run's read DENY not-found, writes still ALLOW"
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
	run_capture adversarial adversarial-battery "scripts/capture_e1_live.sh adversarial" do_adversarial \
		"E1 adversarial rows: identity mismatch PermissionDenied, ${CONCURRENT_N:-8} concurrent same-slot writes, bypass write flagged then removed, completeness PASS x4"
}

do_idle_nothing_due() {
	step "clean slate: reset, then delete the four state PVCs"
	reset_cluster
	delete_state_pvcs

	step "seed canonical state-aware agreements; run: cycles=${CYCLES_SHORT}"
	seed_agreements ""
	verify_directive_field allowed True
	local id st ns
	id=$(trigger "$CYCLES_SHORT") || fail "trigger failed"
	st=$(wait_done "$id" "$POLL_MAX") || fail "the run did not reach done"
	echo "$st"

	step "after the job: an idle gateway on each state PVC"
	for ns in "${STEWARD_NS[@]}"; do
		idle_follows_job "$ns"
	done

	step "nothing due: three polls (${IDLE_POLL}s each) with the idle gateways up"
	local -A before pod
	for ns in "${STEWARD_NS[@]}"; do
		pod[$ns]=$(idle_pod "$ns" 30) || fail "no idle gateway holds the state PVC in $ns"
		before[$ns]=$(claim_snapshot "$ns") || fail "cannot read the state PVC in $ns"
	done
	echo "snapshots taken by $(date +%s%6N); waiting $(( 3 * IDLE_POLL + 5 ))s"
	sleep $(( 3 * IDLE_POLL + 5 ))
	local after restarts
	for ns in "${STEWARD_NS[@]}"; do
		after=$(claim_snapshot "$ns") || fail "cannot read the state PVC in $ns"
		[ "$after" = "${before[$ns]}" ] || fail "$ns: the audit log or a state file changed while nothing was due"
		[ "$(echo "$after" | grep -vc '^{')" -ge 1 ] || fail "$ns: no state file on the PVC, so nothing could have been due"
		[ "$(idle_pod "$ns" 5)" = "${pod[$ns]}" ] || fail "$ns: the idle gateway is not the one from before the three polls"
		restarts=$(kubectl get pod "${pod[$ns]}" -n "$ns" -o jsonpath='{.status.containerStatuses[0].restartCount}')
		[ "$restarts" = 0 ] || fail "$ns: the idle gateway was restarted ${restarts:-an unknown number of} times"
		echo "OK: $ns: $(echo "$after" | grep -c '^{') audit records and $(echo "$after" | grep -vc '^{') state files, unchanged; ${pod[$ns]} still holds the state"
	done
}

block_idle_nothing_due() {
	run_capture live-idle idle-nothing-due "scripts/capture_e1_live.sh idle-nothing-due" do_idle_nothing_due \
		"E1 idle row: nothing due -> over three polls the idle gateways record nothing and every state file is intact; idle gateway up within 60s of the job's gateway ending"
}

# Requires state on the PVCs (run after idle-nothing-due or any block that
# leaves state): on an empty PVC an idle gateway exits at once and there is
# nothing to hand over.
do_idle_handover() {
	step "reset + canonical seed; the agents put an idle gateway back on each state PVC"
	reset_cluster
	seed_agreements ""
	verify_directive_field resumeAllowed True
	local ns pvc
	local -A idle_uid
	for ns in "${STEWARD_NS[@]}"; do
		idle_pod "$ns" 90 >/dev/null || fail "no idle gateway holds the state PVC in $ns; this block needs state left by an earlier block"
		idle_uid[$ns]=$(kubectl get job "idle-$(state_pvc_of "$ns")" -n "$ns" -o jsonpath='{.metadata.uid}')
	done
	local snap w1
	snap=$(claim_snapshot server) || fail "cannot read the state PVC in server"
	w1=$(echo "$snap" | grep '"op":"write"' | grep '"decision":"ALLOW"' | tail -1 \
		| python3 -c "import sys, json; print(json.load(sys.stdin)['writtenUnixSeconds'])")
	[ -n "$w1" ] || fail "no ALLOW write record on the server's state PVC"
	echo "last write on the server's state PVC before the run: writtenUnixSeconds=$w1"

	step "run: cycles=${CYCLES_SHORT} while the idle gateways hold the state"
	local id st
	id=$(trigger "$CYCLES_SHORT") || fail "trigger failed"
	st=$(wait_done "$id" "$POLL_MAX") || fail "the run did not reach done"
	echo "$st"

	step "hand-over: each agent stopped its idle gateway before the job's gateway started"
	local line handed started first pod_log
	for ns in "${STEWARD_NS[@]}"; do
		pvc=$(state_pvc_of "$ns")
		line=$(agent_log "$ns" | grep "No idle gateway left on PVC $pvc ")
		[ "$(echo "$line" | grep -c .)" -eq 1 ] || fail "expected one hand-over line from the agent in $ns, got: ${line:-none}"
		agent_log "$ns" | grep -q IDLE_GATEWAY_NOT_STOPPED && fail "the agent in $ns logged IDLE_GATEWAY_NOT_STOPPED"
		[ "$(kubectl get job "idle-$pvc" -n "$ns" -o jsonpath='{.metadata.uid}' 2>/dev/null)" != "${idle_uid[$ns]}" ] \
			|| fail "the idle Job from before the run is still in $ns"
		handed=$(micros "${line%% *}")
		# A container's start time has whole seconds only; the gateway may
		# still run or have ended by now.
		started=$(kubectl get pod "$(steward_pod "$ns")" -n "$ns" -o jsonpath='{range .status.containerStatuses[?(@.name=="policy-checkpoint-gateway")]}{.state.running.startedAt}{.state.terminated.startedAt}{end}')
		[ -n "$started" ] || fail "the job's gateway in $ns has no start time"
		[ "$(micros "$started")" -ge $(( handed / 1000000 * 1000000 )) ] \
			|| fail "$ns: the job's gateway started at $started, before the hand-over was logged at ${line%% *}"
		first=$(audit_log "$ns" | grep -m1 '^{"op":' | python3 -c "import sys, json; print(json.load(sys.stdin)['decidedUnixMicros'])")
		[ -n "$first" ] || fail "no audit record from the job's gateway in $ns"
		[ "$first" -ge "$handed" ] || fail "$ns: the job's gateway decided at $first, before the hand-over was logged at $handed"
		echo "OK: $ns: idle gateway gone after ${line##* after } (logged at $handed); the job's gateway started $started and decided first at $first"
		pod_log=$(kubectl logs -n "$ns" "$(steward_pod "$ns")" --all-containers 2>&1)
		must_not_grep "$ns: the job's gateway failed to get the state lock" "$pod_log" -e STATE_LOCK_NOT_ACQUIRED
		must_not_grep "$ns: a service ran without the gateway" "$pod_log" -e "No policy gateway reachable"
	done

	step "the stored state is read back and every round persists"
	local aud r2 wcount ms
	aud=$(audit_log server)
	must_grep "resume-allowed read ALLOW" "$(echo "$aud" | grep '"op":"read"')" -e '"decision":"ALLOW"'
	r2=$(echo "$aud" | grep '"op":"read"' | grep '"decision":"ALLOW"' | head -1 \
		| python3 -c "import sys, json; print(json.load(sys.stdin)['writtenUnixSeconds'])")
	[ "$r2" = "$w1" ] || fail "read writtenUnixSeconds ($r2) != the last write before the run ($w1)"
	echo "OK: read timestamp matches the last write before the run ($w1)"
	wcount=$(echo "$aud" | grep '"op":"write"' | grep -c '"decision":"ALLOW"')
	[ "$wcount" -ge "$CYCLES_SHORT" ] || fail "expected >=${CYCLES_SHORT} ALLOW writes, got $wcount"
	echo "OK: $wcount ALLOW write audit lines"
	ms=$(ms_log server vfl-train-model-demo | grep -iE "resum|checkpoint")
	must_grep "server resumed from the stored checkpoint" "$ms" -e "Resumed server model from checkpoint"

	step "after the job: an idle gateway on each state PVC again"
	for ns in "${STEWARD_NS[@]}"; do
		idle_follows_job "$ns"
	done
}

block_idle_handover() {
	run_capture live-idle idle-handover-resume "scripts/capture_e1_live.sh idle-handover" do_idle_handover \
		"E1 idle row: second run while idle gateways hold the state -> idle gateway stopped before the job's gateway decides, stored state read back, every round persists; idle gateway up within 60s of the job's gateway ending"
}

# Requires state and idle gateways on the PVCs, as idle-nothing-due and
# idle-handover leave them.
do_idle_revocation() {
	step "the idle gateways hold the state"
	local ns
	for ns in "${STEWARD_NS[@]}"; do
		idle_pod "$ns" 90 >/dev/null || fail "no idle gateway holds the state PVC in $ns; this block needs state left by an earlier block"
	done

	step "revocation (allowed=false) sent to each steward, host stamp immediately before the request"
	ensure_orch_base
	local -A sent
	for ns in "${STEWARD_NS[@]}"; do
		sent[$ns]=$(put_agreement_stamped "$ns" "sd['allowed'] = False") || fail "revocation PUT for $ns failed"
		echo "[$ns] request sent at ${sent[$ns]}"
	done
	verify_directive_field allowed False

	step "each idle gateway purges the state within 30s of the request, and exits"
	local snap n at job src file
	for ns in "${STEWARD_NS[@]}"; do
		kubectl -n "$ns" wait --for=condition=complete "job/idle-$(state_pvc_of "$ns")" --timeout=60s >/dev/null \
			|| fail "the idle Job in $ns did not complete within 60s of the revocation"
		snap=$(claim_snapshot "$ns") || fail "cannot read the state PVC in $ns"
		[ "$(echo "$snap" | grep -vc '^{')" -eq 0 ] || fail "$ns: state files left after the revocation"
		n=0
		while read -r at job src file; do
			[ -n "$at" ] || continue
			[ "$job" = "-" ] || fail "$ns: the purge of $file carries job fields ($job)"
			[ "$src" = fresh ] || fail "$ns: the purge of $file was decided on $src terms"
			must_follow_within "$ns: $file purged while idle, after the request" "${sent[$ns]}" "$at" 0 30
			n=$((n + 1))
		done <<< "$(echo "$snap" | records_since "${sent[$ns]}" purge PURGED)"
		[ "$n" -ge 1 ] || fail "$ns: no purge record on the state PVC after the revocation"
		echo "$snap" | grep '"op":"purge"' | tail -n "$n" | sed 's/^/    /'
	done
}

block_idle_revocation() {
	run_capture live-idle idle-revocation-purge "scripts/capture_e1_live.sh idle-revocation" do_idle_revocation \
		"E1 idle row: revocation while idle -> op=purge PURGED without job fields on fresh terms, decided within 30s of the request; no state file left"
}

do_idle_expiry() {
	step "reset + seed variant retentionSeconds=${RETENTION_IDLE}"
	reset_cluster
	seed_agreements "sd['retentionSeconds'] = ${RETENTION_IDLE}"
	verify_directive_field retentionSeconds "$RETENTION_IDLE"

	step "run: cycles=${CYCLES_SHORT}"
	local t0 id st ns
	t0=$(date +%s%6N)
	id=$(trigger "$CYCLES_SHORT") || fail "trigger failed"
	st=$(wait_done "$id" "$POLL_MAX") || fail "the run did not reach done"
	echo "$st"
	local -A last
	for ns in "${STEWARD_NS[@]}"; do
		last[$ns]=$(audit_log "$ns" | records_since "$t0" write ALLOW | tail -1 | cut -d' ' -f1)
		[ -n "${last[$ns]}" ] || fail "the run wrote no state in $ns"
	done

	step "after the job: an idle gateway on each state PVC"
	for ns in "${STEWARD_NS[@]}"; do
		idle_follows_job "$ns"
	done

	step "expiry while idle: each state file deleted within ${RETENTION_IDLE}s + 30s of its last write"
	local snap n at job src file w
	for ns in "${STEWARD_NS[@]}"; do
		kubectl -n "$ns" wait --for=condition=complete "job/idle-$(state_pvc_of "$ns")" --timeout="$(( RETENTION_IDLE + 90 ))s" >/dev/null \
			|| fail "the idle Job in $ns did not complete within $(( RETENTION_IDLE + 90 ))s"
		snap=$(claim_snapshot "$ns") || fail "cannot read the state PVC in $ns"
		[ "$(echo "$snap" | grep -vc '^{')" -eq 0 ] || fail "$ns: state files left after the retention passed"
		n=0
		while read -r at job src file; do
			[ -n "$at" ] || continue
			[ "$job" = "-" ] || fail "$ns: the deletion of $file carries job fields ($job)"
			[ "$src" = fresh ] || fail "$ns: the deletion of $file was decided on $src terms"
			w=$(echo "$snap" | records_since 0 write ALLOW | grep " $file\$" | tail -1 | cut -d' ' -f1)
			[ -n "$w" ] || fail "$ns: no write record for $file"
			must_follow_within "$ns: $file deleted while idle, after its last write" "$w" "$at" "$RETENTION_IDLE" "$(( RETENTION_IDLE + 30 ))"
			n=$((n + 1))
		done <<< "$(echo "$snap" | records_since "${last[$ns]}" expired DELETED)"
		[ "$n" -ge 1 ] || fail "$ns: no expiry record on the state PVC after the run's last write"
		echo "$snap" | grep '"op":"expired"' | tail -n "$n" | sed 's/^/    /'
	done
}

block_idle_expiry() {
	run_capture live-idle idle-expiry-delete "scripts/capture_e1_live.sh idle-expiry" do_idle_expiry \
		"E1 idle row: retention exceeded while idle -> op=expired DELETED without job fields on fresh terms, decided within retention + 30s of the last write; idle gateway up within 60s of the job's gateway ending"
}

# --- main -----------------------------------------------------------------

which="${1:-all}"
case "$which" in
allow-resume) block_allow_resume ;;
resume-disabled) block_resume_disabled ;;
expired) block_expired ;;
adversarial) block_adversarial ;;
idle-nothing-due) block_idle_nothing_due ;;
idle-handover) block_idle_handover ;;
idle-revocation) block_idle_revocation ;;
idle-expiry) block_idle_expiry ;;
idle)
	block_idle_nothing_due
	block_idle_handover
	block_idle_revocation
	block_idle_expiry
	;;
all)
	block_allow_resume
	block_resume_disabled
	block_expired
	block_adversarial
	block_idle_nothing_due
	block_idle_handover
	block_idle_revocation
	block_idle_expiry
	;;
*) echo "usage: $0 [allow-resume|resume-disabled|expired|adversarial|idle-nothing-due|idle-handover|idle-revocation|idle-expiry|idle|all]" >&2; exit 2 ;;
esac
