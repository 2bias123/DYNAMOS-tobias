#!/usr/bin/env bash
set -u

# E4 storage growth + governed training curve, saving raw output under
# results/campaign-n50/e4-storage-growth/ and appending to that experiment's captures.md.
#
#   growth   audit-log and PVC growth per round on a full-enforcement run.
#            A sampler pod co-mounts the server state PVC read-only and
#            records du every second; the per-round table merges those
#            samples with the api-gateway round markers, the byte length
#            of each audit record, and the r2 series. Final sizes and
#            listings for all four steward PVCs close the block.
#   flip     the ALLOW -> flip -> DENY training curve on the live chain.
#            Run 1 seeds the state relations with onRevocation="" (deny but
#            retain): a mid-run purge advisory makes the MS drop its
#            in-memory model and the api-gateway then shuts the chain down,
#            so the retain variant is what lets training continue past the
#            flip. After FLIP_AFTER completed rounds the server agreement
#            flips to allowed=false via the /policyEnforcer operator path:
#            training must still run to completion, the server gateway's
#            write decisions must transition ALLOW -> DENY once and never
#            back, and the client stewards (never revoked) must keep
#            persisting. Run 2 is the resume-impossible-past-retention leg:
#            reset, re-seed with a short retentionSeconds variant, wait out
#            the bound; the idle gateways must destroy the aged checkpoints
#            under confirmed-fresh policy (op=expired DELETED on the PVC's
#            audit log, no job fields) and exit. Then re-trigger: the
#            startup read DENYs "not found", and the model
#            restarts from init (round_index=1, no resume line). The
#            expired record is also the proof that the flip retained: there
#            was still a blob to destroy. A per-round curve table (round,
#            r2, persisted) is the plot input.
#
# Usage: capture_e4_storage_growth.sh [growth [cycles]|flip [cycles [flip_after]]|all]
# Default is all (growth, then flip). Blocks reset and seed themselves.
#
# Assertions are on decisions, audit records, and byte counts, not timings,
# so background load does not invalidate a capture (per-round durations in
# the tables are context, not claims). The one timing constraint is inside
# flip: run 1's post-flip tail must stay inside the canonical 900s server
# retention so the retained blob survives to run 2; minutes of margin at
# the default cycles.
#
# Needs the fork images loaded in kind (dev-loop.md imageID check).

EXP=E4
root="$(cd "$(dirname "$0")/.." && pwd)"
# Override for shakedown runs that must not land in the evidence tree.
results_dir="${E4_RESULTS_DIR:-$root/results/campaign-n50/e4-storage-growth}"
. "$root/scripts/capture_lib.sh"

STEWARD_NS=(server clientone clienttwo clientthree)
USER_NAME="jake.jongejans@student.uva.nl"
APIPORT="${APIPORT:-8080}"
ORCHPORT="${ORCHPORT:-8082}"
GROWTH_CYCLES="${GROWTH_CYCLES:-$CAMPAIGN_N}"
FLIP_CYCLES="${FLIP_CYCLES:-$CAMPAIGN_N}"
FLIP_AFTER="${FLIP_AFTER:-10}"       # completed rounds before the flip lands
CYCLES_RESUME="${CYCLES_RESUME:-3}"
RETENTION_SHORT="${RETENTION_SHORT:-120}"
POLL_MAX="${POLL_MAX:-$(poll_max_for_cycles "$CAMPAIGN_N")}"  # x5s
INSPECTOR_IMAGE="${INSPECTOR_IMAGE:-tamjiyan/vfl-train-demo:latest}"
SAMPLER=e4-sampler
INSPECTOR=e4-inspector

PIDS=()
cleanup() {
	for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done
	kubectl delete pod "$SAMPLER" -n server --ignore-not-found=true --wait=false 2>/dev/null
	for ns in "${STEWARD_NS[@]}"; do
		kubectl delete pod "$INSPECTOR" -n "$ns" --ignore-not-found=true --wait=false 2>/dev/null
	done
}
trap cleanup EXIT

# --- shared helpers -------------------------------------------------------

# PUT the server agreement with allowed=$1 (true|false), keeping the
# deny-but-retain variant (onRevocation="") the flip arm seeds with, so the
# flip never carries a purge prescription. Echoes the HTTP code.
flip_server_retain() {
	local want="$1" tmp code
	tmp=$(mktemp)
	python3 -c "
import json
a = json.load(open('$root/configuration/etcd_launch_files/state_aware_server.json'))
sd = a['relations']['$USER_NAME']['stateDirectives']
sd['allowed'] = ('$want' == 'true')
sd['onRevocation'] = ''
print(json.dumps(a))" > "$tmp" || { rm -f "$tmp"; fail "flip json build failed"; }
	code=$(curl -s -o /dev/null -w '%{http_code}' -X PUT "http://localhost:${ORCHPORT}/api/v1/policyEnforcer" \
		-H 'Content-Type: application/json' --data-binary @"$tmp")
	rm -f "$tmp"
	echo "$code"
}

api_gw_log() { kubectl logs -n api-gateway deploy/api-gateway -c api-gateway --timestamps 2>/dev/null; }

gw_log() { kubectl logs -n "$1" "$(steward_pod "$1")" -c policy-checkpoint-gateway --timestamps 2>/dev/null; }

ms_log() { kubectl logs -n "$1" "$(steward_pod "$1")" -c "$2" --timestamps 2>/dev/null; }

# Wait until the api-gateway has closed round $1 (its accuracy marker is the
# round's end), so a following flip lands after that round completed.
wait_round_closed() { # $1 = round number, $2 = timeout seconds
	local i
	for i in $(seq 1 "$2"); do
		api_gw_log | grep -qE "Intermediate accuracy achieved: .* for round $1\b" && return 0
		sleep 1
	done
	fail "round $1 did not close within $2 s (api-gateway markers)"
}

# --- blocks ---------------------------------------------------------------

# Start the sampler pod on the server state PVC (read-only co-mount; RWO
# binds at node scope, and this cluster is single-node, so the running
# gateway does not block it). One line per second: epoch, du bytes of data/
# and audit/, state-file count.
start_sampler() {
	local pvc i
	for i in $(seq 1 60); do
		pvc=$(kubectl get pvc -n server -o name 2>/dev/null | grep 'persistentvolumeclaim/state-' | head -1 | cut -d/ -f2)
		[ -n "$pvc" ] && break
		sleep 2
	done
	[ -n "$pvc" ] || fail "no server state PVC appeared for the sampler"
	echo "[sampler] server state PVC: $pvc"
	kubectl delete pod "$SAMPLER" -n server --ignore-not-found=true --wait=true >/dev/null 2>&1
	kubectl apply -f - >/dev/null <<-YAML
	apiVersion: v1
	kind: Pod
	metadata: { name: $SAMPLER, namespace: server }
	spec:
	  restartPolicy: Never
	  containers:
	  - name: sampler
	    image: $INSPECTOR_IMAGE
	    imagePullPolicy: IfNotPresent
	    command: ["sh", "-c", "while true; do echo \"\$(date +%s) \$(du -sb /state/data 2>/dev/null | cut -f1) \$(du -sb /state/audit 2>/dev/null | cut -f1) \$(find /state/data -type f 2>/dev/null | wc -l)\"; sleep 1; done"]
	    volumeMounts:
	    - { name: state, mountPath: /state, readOnly: true }
	  volumes:
	  - name: state
	    persistentVolumeClaim: { claimName: $pvc }
	YAML
	local phase
	for i in $(seq 1 60); do
		phase=$(kubectl get pod "$SAMPLER" -n server -o jsonpath='{.status.phase}' 2>/dev/null)
		[ "$phase" = Running ] && return 0
		sleep 2
	done
	fail "sampler pod did not reach Running (phase=$phase)"
}

# Sizes and listing for one steward's state PVC via a throwaway inspector
# pod. Drops this user's finished Jobs first so the pod name space is clean;
# state survives. Sets PVC_LISTING.
pvc_listing() { # $1 = ns
	local ns="$1"
	kubectl -n "$ns" get jobs -o name 2>/dev/null | grep jake | xargs -r kubectl -n "$ns" delete --wait=true >/dev/null 2>&1
	kubectl -n "$ns" delete pod "$INSPECTOR" --ignore-not-found=true --wait=true >/dev/null 2>&1
	start_state_inspector "$ns" "$INSPECTOR" "$INSPECTOR_IMAGE" \
		|| fail "inspector pod in $ns did not become ready"
	PVC_LISTING=$(kubectl exec -n "$ns" "$INSPECTOR" -c inspector -- sh -c \
		'ls -lR /state; du -sb /state/data /state/audit; echo "state files: $(find /state/data -type f | wc -l)"') \
		|| fail "listing failed for $ns"
	echo "$PVC_LISTING"
	kubectl -n "$ns" delete pod "$INSPECTOR" --ignore-not-found=true --wait=false >/dev/null 2>&1
}

# The expired records in the audit log on $1's state PVC, read through a
# throwaway inspector pod beside whatever holds the PVC.
claim_expired() { # $1 = ns
	local ns="$1" out rc
	start_state_inspector "$ns" "$INSPECTOR" "$INSPECTOR_IMAGE" >&2 || return 1
	out=$(kubectl exec -n "$ns" "$INSPECTOR" -c inspector -- cat /state/audit/audit.log)
	rc=$?
	kubectl -n "$ns" delete pod "$INSPECTOR" --ignore-not-found=true --grace-period=1 --wait=true --timeout=60s >/dev/null 2>&1
	[ "$rc" -eq 0 ] || return 1
	echo "$out" | grep '"op":"expired"'
	return 0
}

# The per-round growth table: cumulative audit records and bytes at each
# round close (from the audit records themselves), and the nearest du sample
# at or after the close (from the sampler). Fails if any round adds no audit
# record.
growth_table() { # $1 = status JSON, $2 = sampler log file
	local gw_tmp aud_tmp st_tmp
	gw_tmp=$(mktemp); aud_tmp=$(mktemp); st_tmp=$(mktemp)
	echo "$GW_LOG" | grep -E "Intermediate accuracy achieved: .* for round " > "$gw_tmp"
	echo "$SERVER_GW_LOG" | grep '"op":' > "$aud_tmp"
	printf '%s' "$1" > "$st_tmp"
	python3 - "$GROWTH_CYCLES" "$gw_tmp" "$aud_tmp" "$2" "$st_tmp" <<'PY'
import re, sys, json
from datetime import datetime, timezone

cycles = int(sys.argv[1])
status = json.load(open(sys.argv[5]))
r2 = [r['accuracy'] for r in status['results']]

def ts(raw):
    raw = re.sub(r'(\.\d{6})\d*', r'\1', raw).replace('Z', '+00:00')
    return datetime.fromisoformat(raw).timestamp()

closed = {}
for line in open(sys.argv[2]):
    m = re.search(r'for round (\d+)', line)
    if m:
        closed[int(m.group(1))] = ts(line.split()[0])

# (epoch, json byte length incl. newline) per audit record, in log order.
audit = []
for line in open(sys.argv[3]):
    stamp, _, rec = line.partition(' ')
    rec = rec.strip()
    if rec:
        audit.append((ts(stamp), len(rec) + 1))

samples = []
for line in open(sys.argv[4]):
    p = line.split()
    if len(p) == 4 and p[0].isdigit():
        samples.append((int(p[0]), p[1], p[2], p[3]))

if samples:
    first = datetime.fromtimestamp(samples[0][0], tz=timezone.utc).isoformat()
    print(f"sampler: {len(samples)} samples, first at {first}")
else:
    print("sampler: no samples")

print("round,r2,audit_records_cum,audit_bytes_cum,audit_bytes_delta,du_data,du_audit,state_files,round_closed_utc")
prev_n, prev_b = 0, 0
for r in range(cycles):
    if r not in closed:
        print(f"E4 FAIL: round {r} has no close marker in the api-gateway log")
        sys.exit(1)
    n = sum(1 for t, _ in audit if t <= closed[r])
    b = sum(l for t, l in audit if t <= closed[r])
    if r > 0 and n <= prev_n:
        print(f"E4 FAIL: round {r} added no audit record (cum {n})")
        sys.exit(1)
    du = next(((d, a, f) for t, d, a, f in samples if t >= closed[r]), ('', '', ''))
    iso = datetime.fromtimestamp(closed[r], tz=timezone.utc).isoformat()
    print(f"{r},{r2[r]:.4f},{n},{b},{b - prev_b},{du[0]},{du[1]},{du[2]},{iso}")
    prev_n, prev_b = n, b

total_b = sum(l for _, l in audit)
print(f"audit records total: {len(audit)}, json bytes total: {total_b} (boot records before round 0 close are in round 0's cum)")
print("du columns are the first sample at or after the round close; blank where the sampler was not up yet")
PY
	local rc=$?
	rm -f "$gw_tmp" "$aud_tmp" "$st_tmp"
	return "$rc"
}

do_growth() {
	step "clean slate: reset, then delete the four state PVCs"
	reset_cluster
	delete_state_pvcs

	step "seed canonical state-aware agreements"
	seed_agreements ""
	verify_directive_field retentionSeconds 900

	step "run: cycles=${GROWTH_CYCLES} under full enforcement, sampler on the server PVC"
	local rid
	rid=$(trigger "$GROWTH_CYCLES") || exit 1
	start_sampler

	local status
	status=$(wait_done "$rid") || exit 1
	must_have_gateway "${STEWARD_NS[@]}"
	local sampler_log
	sampler_log=$(mktemp)
	kubectl logs -n server "$SAMPLER" 2>/dev/null > "$sampler_log"
	kubectl delete pod "$SAMPLER" -n server --ignore-not-found=true --wait=false >/dev/null 2>&1
	r2_series "$status"

	full_logs

	step "enforcement evidence: one governed write per round, clean-slate boot read"
	local allow_n
	allow_n=$(echo "$SERVER_GW_LOG" | grep '"op":"write"' | grep -c '"decision":"ALLOW"')
	[ "$allow_n" -eq "$GROWTH_CYCLES" ] || fail "expected ${GROWTH_CYCLES} ALLOW writes on the server gateway, got $allow_n"
	echo "OK: $allow_n ALLOW write audit lines, one per round"
	must_grep "clean-slate startup read DENY 'not found'" "$(echo "$SERVER_GW_LOG" | grep '"op":"read"')" -e '"reason":"not found"'
	must_not_grep "no destruction records in a plain enforced run" "$SERVER_GW_LOG" -e '"op":"purge"' -e '"op":"expired"'

	step "growth table (plot input)"
	growth_table "$status" "$sampler_log" || { rm -f "$sampler_log"; fail "growth table build failed"; }
	echo
	echo "--- raw sampler series (epoch du_data du_audit state_files) ---"
	cat "$sampler_log"
	rm -f "$sampler_log"

	step "audit record breakdown (server gateway)"
	local op
	for op in read write purge expired; do
		echo "op=$op: $(echo "$SERVER_GW_LOG" | grep -c "\"op\":\"$op\"")"
	done

	step "final sizes and listings, all four steward PVCs"
	local ns
	for ns in "${STEWARD_NS[@]}"; do
		pvc_listing "$ns"
		[ "$ns" = server ] && must_grep "persisted state on the server PVC" "$PVC_LISTING" -E "state files: [1-9]"
	done
	echo "note: the checkpoint slot is overwritten in place; data bytes plateau while audit bytes grow per round"
}

# Dump the full logs into the artifact: the api-gateway container, both VFL
# MS containers on all four stewards, and each gateway container. Sets
# GW_LOG, SERVER_GW_LOG, SERVER_MS_LOG, CLIENT_GW_LOG, CLIENT_MS_LOG.
full_logs() {
	local ns pod c log
	GW_LOG=$(api_gw_log)
	step "full log: api-gateway (api-gateway container)"
	echo "$GW_LOG"
	SERVER_GW_LOG=""; SERVER_MS_LOG=""; CLIENT_GW_LOG=""; CLIENT_MS_LOG=""
	for ns in "${STEWARD_NS[@]}"; do
		pod=$(steward_pod "$ns")
		[ -n "$pod" ] || fail "no chain pod in $ns for the full-log dump"
		for c in vfl-train-model-demo vfl-train-demo; do
			log=$(kubectl logs -n "$ns" "$pod" -c "$c" --timestamps 2>&1)
			step "full log: $ns/$pod $c"
			echo "$log"
			[ "$ns" = server ] && [ "$c" = vfl-train-model-demo ] && SERVER_MS_LOG="$log"
			[ "$ns" = clientone ] && [ "$c" = vfl-train-demo ] && CLIENT_MS_LOG="$log"
		done
		log=$(kubectl logs -n "$ns" "$pod" -c policy-checkpoint-gateway --timestamps 2>&1)
		step "full log: $ns/$pod policy-checkpoint-gateway"
		echo "$log"
		[ "$ns" = server ] && SERVER_GW_LOG="$log"
		[ "$ns" = clientone ] && CLIENT_GW_LOG="$log"
	done
}

# The per-round curve table: r2 per round, whether the server checkpoint for
# that round persisted (from the MS round_index lines; round_index=k closes
# chain round k-1), and where the flip landed relative to the round windows.
curve_table() { # $1 = status JSON, $2 = t_flip epoch
	local ms_tmp gw_tmp st_tmp
	ms_tmp=$(mktemp); gw_tmp=$(mktemp); st_tmp=$(mktemp)
	echo "$SERVER_MS_LOG" | grep -E "Checkpoint write (allowed|denied)" > "$ms_tmp"
	echo "$GW_LOG" | grep -E "Intermediate accuracy achieved: .* for round " > "$gw_tmp"
	printf '%s' "$1" > "$st_tmp"
	python3 - "$FLIP_CYCLES" "$2" "$ms_tmp" "$gw_tmp" "$st_tmp" <<'PY'
import re, sys, json
from datetime import datetime, timezone

cycles, t_flip = int(sys.argv[1]), float(sys.argv[2])
status = json.load(open(sys.argv[5]))
r2 = [r['accuracy'] for r in status['results']]

def ts(line):
    raw = line.split()[0]
    raw = re.sub(r'(\.\d{6})\d*', r'\1', raw).replace('Z', '+00:00')
    return datetime.fromisoformat(raw).timestamp()

persisted, closed = {}, {}
for line in open(sys.argv[3]):
    m = re.search(r'Checkpoint write (allowed|denied).*round_index=(\d+)', line)
    if m:
        persisted[int(m.group(2)) - 1] = 'allow' if m.group(1) == 'allowed' else 'deny'
for line in open(sys.argv[4]):
    m = re.search(r'for round (\d+)', line)
    if m:
        closed[int(m.group(1))] = ts(line)

print("round,r2,persisted,round_closed_utc")
for r in range(cycles):
    if r not in closed:
        print(f"E4 FAIL: round {r} has no close marker in the api-gateway log")
        sys.exit(1)
    iso = datetime.fromtimestamp(closed[r], tz=timezone.utc).isoformat()
    print(f"{r},{r2[r]:.4f},{persisted.get(r, 'none')},{iso}")

flip_round = max((r for r, t in closed.items() if t < t_flip), default=-1)
iso = datetime.fromtimestamp(t_flip, tz=timezone.utc).isoformat()
print(f"flip: t_flip={t_flip:.6f} ({iso}), after round {flip_round} closed")
n_allow = sum(1 for v in persisted.values() if v == 'allow')
n_deny = sum(1 for v in persisted.values() if v == 'deny')
print(f"persisted rounds: {n_allow} allow, {n_deny} deny, {cycles - n_allow - n_deny} none")
PY
	local rc=$?
	rm -f "$ms_tmp" "$gw_tmp" "$st_tmp"
	return "$rc"
}

# Audit lines are kubelet-timestamped; strip the prefix before JSON parsing.
audit_json_field() { # $1 = audit line, $2 = field
	echo "$1" | python3 -c "
import sys, json
line = sys.stdin.read().split(' ', 1)[1]
print(json.loads(line)['$2'])"
}

do_flip() {
	step "clean slate: reset, then delete the four state PVCs"
	reset_cluster
	delete_state_pvcs

	step "seed the deny-but-retain variant (onRevocation='') so the flip cannot prescribe a purge"
	seed_agreements "sd['onRevocation'] = ''"
	verify_directive_field onRevocation ""

	step "run 1: cycles=${FLIP_CYCLES}, flip to allowed=false after ${FLIP_AFTER} completed rounds"
	local rid
	rid=$(trigger "$FLIP_CYCLES") || exit 1
	wait_round_closed $((FLIP_AFTER - 1)) 300
	echo "round $((FLIP_AFTER - 1)) closed; flipping the server agreement"

	local t_flip t_ret code
	t_flip=$(date +%s.%N)
	code=$(flip_server_retain false)
	t_ret=$(date +%s.%N)
	[ "$code" = 200 ] || fail "flip PUT returned $code"
	echo "flip PUT: 200 (initiated $t_flip, returned $t_ret)"

	step "wait for training to finish: the chain must survive the flip"
	local status
	status=$(wait_done "$rid") || exit 1
	local t_run1_done
	t_run1_done=$(date +%s)
	must_have_gateway "${STEWARD_NS[@]}"
	r2_series "$status"
	local n_r2
	n_r2=$(echo "$status" | python3 -c "import sys, json; print(len(json.load(sys.stdin)['results']))")
	[ "$n_r2" -eq "$FLIP_CYCLES" ] || fail "expected ${FLIP_CYCLES} r2 entries, got $n_r2"
	echo "OK: training completed all ${FLIP_CYCLES} rounds across the flip"

	full_logs

	step "persistence evidence: ALLOW -> DENY once on the server, clients unaffected"
	local writes allow_n deny_n
	writes=$(echo "$SERVER_GW_LOG" | grep '"op":"write"')
	allow_n=$(echo "$writes" | grep -c '"decision":"ALLOW"')
	deny_n=$(echo "$writes" | grep -c '"decision":"DENY"')
	echo "server write decisions: $allow_n ALLOW, $deny_n DENY"
	[ "$allow_n" -ge "$FLIP_AFTER" ] || fail "only $allow_n ALLOW writes before the flip (expected >= ${FLIP_AFTER})"
	[ "$allow_n" -lt "$FLIP_CYCLES" ] || fail "all $allow_n writes ALLOWed; the flip did not stop persistence"
	[ "$deny_n" -ge 1 ] || fail "no DENY writes after the flip"
	must_grep "post-flip write DENY 'allowed = false'" "$writes" -e '"decision":"DENY".*"reason":"allowed = false"'
	echo "$writes" | python3 -c "
import sys
denied = False
for line in sys.stdin:
    if '\"decision\":\"DENY\"' in line:
        denied = True
    elif denied and '\"decision\":\"ALLOW\"' in line:
        print('E4 FAIL: ALLOW write after the first DENY; the transition is not monotone')
        sys.exit(1)
" || fail "monotone ALLOW -> DENY check"
	echo "OK: no ALLOW write after the first DENY (single transition)"

	local ms_denied
	ms_denied=$(echo "$SERVER_MS_LOG" | grep -cE "Checkpoint write denied \(allowed = false\)")
	[ "$ms_denied" -eq "$deny_n" ] || fail "MS denied lines ($ms_denied) != audit DENY writes ($deny_n)"
	echo "OK: every denied MS attempt has its audit DENY record ($deny_n)"
	must_grep "the MS continues past the denial" "$SERVER_MS_LOG" -e "continuing without persistence"

	local c_allow
	c_allow=$(echo "$CLIENT_GW_LOG" | grep '"op":"write"' | grep -c '"decision":"ALLOW"')
	[ "$c_allow" -eq "$FLIP_CYCLES" ] || fail "clientone ALLOW writes ($c_allow) != ${FLIP_CYCLES}; the flip leaked past the server relation"
	echo "OK: clientone persisted every round ($c_allow ALLOW writes); the revocation stayed on the server relation"
	must_not_grep "no destruction records under deny-but-retain" "$SERVER_GW_LOG" -e '"op":"purge"' -e '"op":"expired"'

	local w1
	w1=$(audit_json_field "$(echo "$writes" | grep '"decision":"ALLOW"' | tail -1)" writtenUnixSeconds)
	echo "last persisted checkpoint: writtenUnixSeconds=$w1 (the retained blob run 2 must find expired)"

	step "curve table (plot input)"
	curve_table "$status" "$t_flip" || fail "curve table build failed"

	step "run 2: reset + re-seed retentionSeconds=${RETENTION_SHORT}; the aged checkpoint must be unresumable"
	reset_cluster
	seed_agreements "sd['retentionSeconds'] = ${RETENTION_SHORT}"
	verify_directive_field retentionSeconds "$RETENTION_SHORT"
	while [ $(( $(date +%s) - t_run1_done )) -le "$RETENTION_SHORT" ]; do sleep 5; done
	echo "youngest blob now $(( $(date +%s) - t_run1_done ))s old (> ${RETENTION_SHORT}s)"

	step "expiry while idle: the idle gateways must destroy the aged checkpoints and exit"
	local ns exp cexp
	for ns in "${STEWARD_NS[@]}"; do
		kubectl -n "$ns" wait --for=condition=complete "job/idle-$(state_pvc_of "$ns")" --timeout=90s >/dev/null \
			|| fail "the idle Job in $ns did not complete within 90s of the retention passing"
	done
	exp=$(claim_expired server) || fail "cannot read the state PVC in server"
	cexp=$(claim_expired clientone) || fail "cannot read the state PVC in clientone"
	echo; echo "--- server state PVC audit, expired records ---"; echo "$exp"
	echo "--- clientone state PVC audit, expired records ---"; echo "$cexp"
	must_grep "aged checkpoint destroyed while idle under confirmed-fresh policy" "$exp" \
		-e '"decision":"DELETED".*"policySource":"fresh"'
	must_grep "expired record carries 'retention exceeded' and the state class" "$exp" \
		-e '"reason":"retention exceeded".*"stateClass":"vfl_server_model"'
	must_not_grep "job fields on the server's expired record" "$exp" -e '"jobId"' -e '"localJobName"'
	must_grep "clientone's aged state destroyed while idle too" "$cexp" -e '"decision":"DELETED".*"policySource":"fresh"'
	must_not_grep "job fields on clientone's expired record" "$cexp" -e '"jobId"' -e '"localJobName"'

	step "run 2: cycles=${CYCLES_RESUME}; nothing to resume from"
	local rid2 status2
	rid2=$(trigger "$CYCLES_RESUME") || exit 1
	status2=$(wait_done "$rid2") || exit 1
	must_have_gateway "${STEWARD_NS[@]}"
	echo "$status2" | python3 -m json.tool

	local aud2 ms2 cms2
	aud2=$(gw_log server)
	ms2=$(ms_log server vfl-train-model-demo | grep -iE "resum|checkpoint")
	cms2=$(ms_log clientone vfl-train-demo | grep -iE "resum|checkpoint")
	echo; echo "--- server gateway audit (run 2) ---"; echo "$aud2"
	echo; echo "--- server MS lines (run 2) ---"; echo "$ms2"
	echo "--- clientone MS lines (run 2) ---"; echo "$cms2"

	must_grep "startup read DENY 'not found' (the idle gateway already destroyed the state)" "$(echo "$aud2" | grep '"op":"read"')" \
		-e '"decision":"DENY".*"reason":"not found"'
	must_not_grep "no resume past retention" "$ms2" -e "Resumed server model"
	must_grep "the model restarted from init" "$ms2" -e "Checkpoint write allowed: round_index=1"
	must_not_grep "clientone did not resume either" "$cms2" -e "Resuming client model"
	echo "note: the expired record before run 2 is also run 1's retain proof: the flip left a blob to destroy"
}

block_growth() {
	run_capture growth growth-per-round "scripts/capture_e4_storage_growth.sh growth ${GROWTH_CYCLES}" do_growth \
		"E4 growth: per-round audit and PVC bytes over ${GROWTH_CYCLES} enforced rounds (sampler + audit-record bytes), final listings on all four steward PVCs"
}

block_flip() {
	run_capture flip-curve allow-flip-deny-curve "scripts/capture_e4_storage_growth.sh flip ${FLIP_CYCLES} ${FLIP_AFTER}" do_flip \
		"E4 flip curve: allowed=false after ${FLIP_AFTER} of ${FLIP_CYCLES} rounds (onRevocation retain) -> training continues, persistence stops; aged checkpoint expires while idle, no resume"
}

# --- main -----------------------------------------------------------------

which="${1:-all}"
case "$which" in
growth)
	GROWTH_CYCLES="${2:-$GROWTH_CYCLES}"
	block_growth
	;;
flip)
	FLIP_CYCLES="${2:-$FLIP_CYCLES}"
	FLIP_AFTER="${3:-$FLIP_AFTER}"
	block_flip
	;;
all)
	block_growth
	block_flip
	;;
*) echo "usage: $0 [growth [cycles]|flip [cycles [flip_after]]|all]" >&2; exit 2 ;;
esac
