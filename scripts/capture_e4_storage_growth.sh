#!/usr/bin/env bash
set -u

# E4 storage growth + governed training curve, saving raw output under
# results/e4-storage-growth/ and appending to that experiment's captures.md.
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
#            the bound, re-trigger; the boot sweep must destroy the aged
#            checkpoint under confirmed-fresh policy (op=expired DELETED),
#            the startup read then DENYs "not found", and the model
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

root="$(cd "$(dirname "$0")/.." && pwd)"
# Override for shakedown runs that must not land in the evidence tree.
results_dir="${E4_RESULTS_DIR:-$root/results/e4-storage-growth}"

STEWARD_NS=(server clientone clienttwo clientthree)
USER_NAME="jake.jongejans@student.uva.nl"
APIPORT="${APIPORT:-8080}"
ORCHPORT="${ORCHPORT:-8082}"
GROWTH_CYCLES="${GROWTH_CYCLES:-20}"
FLIP_CYCLES="${FLIP_CYCLES:-24}"
FLIP_AFTER="${FLIP_AFTER:-8}"        # completed rounds before the flip lands
CYCLES_RESUME="${CYCLES_RESUME:-3}"
RETENTION_SHORT="${RETENTION_SHORT:-120}"
POLL_MAX="${POLL_MAX:-60}"           # x5s
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

step() { echo; echo "=== $*"; }
fail() { echo "E4 FAIL: $*" >&2; exit 1; }

provenance() {
	echo "\$ date"; date; echo
	echo "\$ git rev-parse HEAD"; git -C "$root" rev-parse HEAD; echo
	echo "\$ git status --short"; git -C "$root" status --short; echo
	echo "\$ kubectl config current-context"; kubectl config current-context; echo
}

# --- shared helpers -------------------------------------------------------

reset_cluster() {
	"$root/reset.sh" || fail "reset.sh failed"
}

delete_state_pvcs() {
	local ns
	for ns in "${STEWARD_NS[@]}"; do
		kubectl get pvc -n "$ns" -o name 2>/dev/null | grep 'persistentvolumeclaim/state-' \
			| xargs -r kubectl delete -n "$ns" --wait=true
	done
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
verify_directive_field() { # $1 field, $2 expected python repr
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

wait_done() { # $1 = request_id; prints final status JSON
	local i out st
	for i in $(seq 1 "$POLL_MAX"); do
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
	fail "training not done after $POLL_MAX polls"
}

steward_pod() { kubectl get pods -n "$1" -o name 2>/dev/null | grep jake | head -1 | cut -d/ -f2; }

api_gw_log() { kubectl logs -n api-gateway deploy/api-gateway -c api-gateway --timestamps 2>/dev/null; }

gw_log() { kubectl logs -n "$1" "$(steward_pod "$1")" -c policy-checkpoint-gateway --timestamps 2>/dev/null; }

ms_log() { kubectl logs -n "$1" "$(steward_pod "$1")" -c "$2" --timestamps 2>/dev/null; }

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

r2_series() { # $1 = status JSON
	echo "$1" | python3 -m json.tool
	echo "$1" | python3 -c "
import sys, json
rs = [r['accuracy'] for r in json.load(sys.stdin)['results']]
print('r2 series (the payload field is named accuracy; the demo chain computes r2):')
print(' '.join('%.4f' % v for v in rs))
print('first r2: %.4f  last r2: %.4f' % (rs[0], rs[-1]))"
}

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
	local ns="$1" pvc i
	pvc=$(kubectl get pvc -n "$ns" -o name 2>/dev/null | grep 'persistentvolumeclaim/state-' | head -1 | cut -d/ -f2)
	[ -n "$pvc" ] || fail "no state PVC found in $ns"
	echo "[$ns] state PVC: $pvc"
	kubectl -n "$ns" get jobs -o name 2>/dev/null | grep jake | xargs -r kubectl -n "$ns" delete --wait=true >/dev/null 2>&1
	kubectl -n "$ns" delete pod "$INSPECTOR" --ignore-not-found=true --wait=true >/dev/null 2>&1
	kubectl apply -f - >/dev/null <<-YAML
	apiVersion: v1
	kind: Pod
	metadata: { name: $INSPECTOR, namespace: $ns }
	spec:
	  restartPolicy: Never
	  containers:
	  - name: inspector
	    image: $INSPECTOR_IMAGE
	    imagePullPolicy: IfNotPresent
	    command: ["python3", "-c", "import time; time.sleep(3600)"]
	    volumeMounts:
	    - { name: state, mountPath: /state, readOnly: true }
	  volumes:
	  - name: state
	    persistentVolumeClaim: { claimName: $pvc }
	YAML
	kubectl -n "$ns" wait --for=condition=Ready "pod/$INSPECTOR" --timeout=120s >/dev/null 2>&1 \
		|| fail "inspector pod in $ns did not become ready"
	PVC_LISTING=$(kubectl exec -n "$ns" "$INSPECTOR" -c inspector -- sh -c \
		'ls -lR /state; du -sb /state/data /state/audit; echo "state files: $(find /state/data -type f | wc -l)"') \
		|| fail "listing failed for $ns"
	echo "$PVC_LISTING"
	kubectl -n "$ns" delete pod "$INSPECTOR" --ignore-not-found=true --wait=false >/dev/null 2>&1
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

	local rid2 status2
	rid2=$(trigger "$CYCLES_RESUME") || exit 1
	status2=$(wait_done "$rid2") || exit 1
	echo "$status2" | python3 -m json.tool

	local aud2 ms2 cms2
	aud2=$(gw_log server)
	ms2=$(ms_log server vfl-train-model-demo | grep -iE "resum|checkpoint")
	cms2=$(ms_log clientone vfl-train-demo | grep -iE "resum|checkpoint")
	echo; echo "--- server gateway audit (run 2) ---"; echo "$aud2"
	echo; echo "--- server MS lines (run 2) ---"; echo "$ms2"
	echo "--- clientone MS lines (run 2) ---"; echo "$cms2"

	must_grep "aged checkpoint destroyed under confirmed-fresh policy" "$(echo "$aud2" | grep '"op":"expired"')" \
		-e '"decision":"DELETED".*"policySource":"fresh"'
	must_grep "expired record carries 'retention exceeded' and the state class" "$(echo "$aud2" | grep '"op":"expired"')" \
		-e '"reason":"retention exceeded".*"stateClass":"vfl_server_model"'
	must_grep "startup read DENY 'not found' (the sweep already destroyed the state)" "$(echo "$aud2" | grep '"op":"read"')" \
		-e '"decision":"DENY".*"reason":"not found"'
	must_not_grep "no resume past retention" "$ms2" -e "Resumed server model"
	must_grep "the model restarted from init" "$ms2" -e "Checkpoint write allowed: round_index=1"
	must_grep "clientone's aged state destroyed too" "$(gw_log clientone | grep '"op":"expired"')" \
		-e '"decision":"DELETED"'
	must_not_grep "clientone did not resume either" "$cms2" -e "Resuming client model"
	echo "note: run 2's expired record is also run 1's retain proof: the flip left a blob to destroy"
}

block_growth() {
	local ts out rc commit note
	ts="$(date +%Y%m%d-%H%M%S)"
	out="$results_dir/growth/${ts}_growth-per-round.txt"
	mkdir -p "$(dirname "$out")"
	{ provenance; do_growth; } 2>&1 | tee "$out"
	rc=${PIPESTATUS[0]}
	commit="$(git -C "$root" rev-parse --short HEAD)"
	note="E4 growth: per-round audit and PVC bytes over ${GROWTH_CYCLES} enforced rounds (sampler + audit-record bytes), final listings on all four steward PVCs"
	[ "$rc" -ne 0 ] && note="$note; FAILED (exit=$rc)"
	echo "\`e4-storage-growth/growth/${ts}_growth-per-round.txt | $ts | scripts/capture_e4_storage_growth.sh growth ${GROWTH_CYCLES} | $commit | $note\`" \
		>> "$results_dir/captures.md"
	echo
	echo "captured: $out (exit=$rc)"
	[ "$rc" -ne 0 ] && exit "$rc"
	return 0
}

block_flip() {
	local ts out rc commit note
	ts="$(date +%Y%m%d-%H%M%S)"
	out="$results_dir/flip-curve/${ts}_allow-flip-deny-curve.txt"
	mkdir -p "$(dirname "$out")"
	{ provenance; do_flip; } 2>&1 | tee "$out"
	rc=${PIPESTATUS[0]}
	commit="$(git -C "$root" rev-parse --short HEAD)"
	note="E4 flip curve: allowed=false after ${FLIP_AFTER} of ${FLIP_CYCLES} rounds (onRevocation retain) -> training continues, persistence stops; aged checkpoint expires, no resume"
	[ "$rc" -ne 0 ] && note="$note; FAILED (exit=$rc)"
	echo "\`e4-storage-growth/flip-curve/${ts}_allow-flip-deny-curve.txt | $ts | scripts/capture_e4_storage_growth.sh flip ${FLIP_CYCLES} ${FLIP_AFTER} | $commit | $note\`" \
		>> "$results_dir/captures.md"
	echo
	echo "captured: $out (exit=$rc)"
	[ "$rc" -ne 0 ] && exit "$rc"
	return 0
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
