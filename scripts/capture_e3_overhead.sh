#!/usr/bin/env bash
set -u

# E3 overhead capture, one config per invocation. Measures per-round VFL chain
# latency and the r2 curve in three configurations:
#   a  no gateway (requiresGateway flipped off in etcd, no persistence)
#   b  pass-through (gateway present; decisions and audit run, state writes
#      skipped via GATEWAY_PASSTHROUGH on the steward agents)
#   c  full enforcement (per-round write-through, clean state PVCs first)
#
# Per-round latency comes from the api-gateway's own round markers ("Running
# VFL training round N" to "Intermediate accuracy achieved ... for round N"),
# read with kubectl logs --timestamps. The api-gateway sits outside the
# gateway path, so the instrument is identical in every config.
#
# Every artifact records the same way: config evidence, the full training
# status JSON with the r2 series, FULL logs (api-gateway container, both VFL
# MS containers on all four stewards, and the policy-checkpoint-gateway
# container where the config has one), then the per-round table. Sidecar and
# idle test-MS containers are excluded. Config c adds the payload sizes read
# off the server state PVC through a throwaway inspector pod.
#
# Run order across sessions is a, then b, then c: config a needs the gateway
# absent, and its etcd flip is ephemeral (the orchestrator re-applies the
# canonical microservices config on every boot, so any reset restores
# requiresGateway:true).
#
# Usage: capture_e3_overhead.sh <a|b|c> [cycles]   (cycles default 10)

root="$(cd "$(dirname "$0")/.." && pwd)"
results_dir="${E3_RESULTS_DIR:-$root/results/e3-overhead}"

CONFIG="${1:-}"
CYCLES="${2:-10}"
case "$CONFIG" in
	a) subdir="config-a-no-gateway" ;;
	b) subdir="config-b-passthrough" ;;
	c) subdir="config-c-enforced" ;;
	*) echo "usage: $0 <a|b|c> [cycles]" >&2; exit 2 ;;
esac

USER_NAME="jake.jongejans@student.uva.nl"
STEWARD_NS=(server clientone clienttwo clientthree)
APIPORT="${APIPORT:-8080}"
ORCHPORT="${ORCHPORT:-8082}"
POLL_MAX="${POLL_MAX:-36}"   # x5s
GATEWAY_MS=(vfl-train-model-demo vfl-train-demo)
INSPECTOR_IMAGE="${INSPECTOR_IMAGE:-tamjiyan/vfl-train-demo:latest}"
INSPECTOR=e3-inspector

PIDS=()
cleanup() {
	# A failed b run must not leave pass-through armed for a later config.
	[ "$CONFIG" = b ] && disable_passthrough
	for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done
}
trap cleanup EXIT

step() { echo; echo "=== $*"; }
fail() { echo "E3 FAIL: $*" >&2; exit 1; }

provenance() {
	echo "\$ date"; date; echo
	echo "\$ git rev-parse HEAD"; git -C "$root" rev-parse HEAD; echo
	echo "\$ git status --short"; git -C "$root" status --short; echo
	echo "\$ kubectl config current-context"; kubectl config current-context; echo
	echo "\$ uptime"; uptime; echo
	echo "\$ nproc"; nproc; echo
}

# --- shared helpers -------------------------------------------------------

reset_and_seed() {
	"$root/reset.sh" || fail "reset.sh failed"
	pkill -f "port-forward.*${ORCHPORT}:8080" 2>/dev/null
	kubectl -n orchestrator rollout status deploy/orchestrator --timeout=90s >/dev/null 2>&1
	local i
	for i in 1 2 3 4; do
		"$root/scripts/seed_state_aware.sh" && return 0
		echo "[e3] seed attempt $i failed; retrying in 5s"
		sleep 5
	done
	fail "seed failed after 4 attempts"
}

# Delete the four state PVCs so a run starts stateless (they are recreated at
# job deploy). Same clean-slate step the E1 allow-resume block uses.
delete_state_pvcs() {
	local ns
	for ns in "${STEWARD_NS[@]}"; do
		kubectl get pvc -n "$ns" -o name 2>/dev/null | grep 'persistentvolumeclaim/state-' \
			| xargs -r kubectl delete -n "$ns" --wait=true
	done
}

# Pass-through is armed by an env var on the steward agent deployments, which
# the agent propagates into every gateway container it deploys. kubectl set
# env survives resets, so enabling and disabling are explicit steps. Arm
# BEFORE the reset: setting the env rolls the agents, and a rollout after the
# reset's settle window re-races the AMQP rebind the settle exists to absorb.
enable_passthrough() {
	local ns
	for ns in "${STEWARD_NS[@]}"; do
		kubectl set env "deployment/${ns}" -n "$ns" GATEWAY_PASSTHROUGH=true >/dev/null \
			|| fail "could not set GATEWAY_PASSTHROUGH on $ns"
	done
	echo "[passthrough] GATEWAY_PASSTHROUGH=true on all four steward agents"
}

disable_passthrough() {
	local ns
	for ns in "${STEWARD_NS[@]}"; do
		kubectl set env "deployment/${ns}" -n "$ns" GATEWAY_PASSTHROUGH- >/dev/null 2>&1
	done
}

etcdctl_pod() {
	kubectl exec ${1:+-i} -n core etcd-0 -c etcd -- sh -c \
		"ETCDCTL_API=3 /usr/local/bin/etcdctl --endpoints=localhost:2379 $2"
}

# Drop requiresGateway from the chain MS metadata in etcd. Must run AFTER the
# reset: the orchestrator re-applies the canonical microservices config on
# every boot, which also means any later reset restores requiresGateway:true.
flip_requires_gateway_off() {
	local ms key cur
	for ms in "${GATEWAY_MS[@]}"; do
		key="/microservices/${ms}/chainMetadata"
		cur=$(etcdctl_pod "" "get $key --print-value-only")
		[ -n "$cur" ] || fail "no chainMetadata in etcd for $ms"
		echo "$cur" | python3 -c "
import sys, json
m = json.load(sys.stdin)
m.pop('requiresGateway', None)
print(json.dumps(m))" | etcdctl_pod -i "put $key \"\$(cat)\"" >/dev/null \
			|| fail "etcd put failed for $ms"
		cur=$(etcdctl_pod "" "get $key --print-value-only")
		echo "$cur" | grep -q '"requiresGateway":true' \
			&& fail "requiresGateway still true for $ms after flip"
		echo "[flip] $ms: requiresGateway off: $cur"
	done
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

must_grep() { # $1 = description, $2 = text, remaining = grep args
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

# --- shared recording core (identical across configs) ---------------------

# Assert the chain pods carry (or do not carry) the gateway container and
# state volume. $1 = with-gateway | no-gateway.
config_evidence() {
	local mode="$1" ns pod containers volumes
	step "config evidence: gateway container and state volume ($mode)"
	for ns in "${STEWARD_NS[@]}"; do
		pod=""
		for _ in $(seq 1 30); do pod=$(steward_pod "$ns"); [ -n "$pod" ] && break; sleep 2; done
		[ -n "$pod" ] || fail "no chain pod in $ns"
		containers=$(kubectl get pod "$pod" -n "$ns" -o jsonpath='{.spec.containers[*].name}')
		volumes=$(kubectl get pod "$pod" -n "$ns" -o jsonpath='{.spec.volumes[*].name}')
		echo "[$ns] $pod containers: $containers"
		if [ "$mode" = no-gateway ]; then
			echo "$containers" | grep -q policy-checkpoint-gateway \
				&& fail "$ns still has a gateway container"
			echo "$volumes" | grep -q gateway-state \
				&& fail "$ns still mounts the gateway state volume"
		else
			echo "$containers" | grep -q policy-checkpoint-gateway \
				|| fail "$ns is missing the gateway container"
			echo "$volumes" | grep -q gateway-state \
				|| fail "$ns is missing the gateway state volume"
		fi
	done
	echo "OK: all four steward pods match the $mode config"
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

# Dump the full logs into the artifact: the api-gateway container, both VFL
# MS containers on all four stewards, and the gateway container where the
# config has one. Sets GW_LOG, SERVER_MS_LOG, SERVER_GW_LOG for the asserts.
# $1 = with-gateway | no-gateway.
full_logs() {
	local mode="$1" ns pod c log
	# The api-gateway pod is multi-container (linkerd-proxy first); without
	# -c, kubectl logs silently defaults to the proxy.
	GW_LOG=$(kubectl logs -n api-gateway deploy/api-gateway -c api-gateway --timestamps 2>/dev/null)
	step "full log: api-gateway (api-gateway container)"
	echo "$GW_LOG"
	SERVER_MS_LOG=""
	SERVER_GW_LOG=""
	for ns in "${STEWARD_NS[@]}"; do
		pod=$(steward_pod "$ns")
		[ -n "$pod" ] || fail "no chain pod in $ns for the full-log dump"
		for c in "${GATEWAY_MS[@]}"; do
			log=$(kubectl logs -n "$ns" "$pod" -c "$c" --timestamps 2>&1)
			step "full log: $ns/$pod $c"
			echo "$log"
			[ "$ns" = server ] && [ "$c" = vfl-train-model-demo ] && SERVER_MS_LOG="$log"
		done
		if [ "$mode" = with-gateway ]; then
			log=$(kubectl logs -n "$ns" "$pod" -c policy-checkpoint-gateway --timestamps 2>&1)
			step "full log: $ns/$pod policy-checkpoint-gateway"
			echo "$log"
			[ "$ns" = server ] && SERVER_GW_LOG="$log"
		fi
	done
}

# Per-round latency from the api-gateway round markers, paired by round
# number, plus a summary line. Fails if any of the $1 expected rounds is
# missing a marker.
round_latency_table() { # $1 = cycles, $2 = api-gateway log (--timestamps)
	local lines_tmp
	lines_tmp=$(mktemp)
	echo "$2" > "$lines_tmp"
	python3 - "$1" "$lines_tmp" <<'PY'
import re, sys
from datetime import datetime

cycles = int(sys.argv[1])
starts, ends, trains = {}, {}, {}

def ts(line):
    raw = line.split()[0]
    raw = re.sub(r'(\.\d{6})\d*', r'\1', raw).replace('Z', '+00:00')
    return datetime.fromisoformat(raw)

# "Sending training request" carries no round number; attribute it to the
# round whose open marker was seen last.
cur = None
for line in open(sys.argv[2]):
    m = re.search(r'Running VFL training round (\d+)', line)
    if m:
        cur = int(m.group(1))
        starts[cur] = ts(line)
        continue
    if '- Sending training request' in line and cur is not None and cur not in trains:
        trains[cur] = ts(line)
        continue
    m = re.search(r'Intermediate accuracy achieved: .* for round (\d+)', line)
    if m:
        ends[int(m.group(1))] = ts(line)

# duration = open marker to accuracy line; reverify = open marker to the
# training dispatch (the baseline's own per-round policy re-verification sits
# in this segment, in every config); train = dispatch to accuracy.
print("round,start,end,duration_ms,reverify_ms,train_ms")
durs = []
for r in range(cycles):
    if r not in starts or r not in ends or r not in trains:
        print(f"E3 FAIL: round {r} missing marker "
              f"(start={r in starts} train={r in trains} end={r in ends})")
        sys.exit(1)
    d = (ends[r] - starts[r]).total_seconds() * 1000
    rev = (trains[r] - starts[r]).total_seconds() * 1000
    tr = (ends[r] - trains[r]).total_seconds() * 1000
    durs.append(d)
    print(f"{r},{starts[r].isoformat()},{ends[r].isoformat()},{d:.1f},{rev:.1f},{tr:.1f}")

def summary(xs):
    xs = sorted(xs)
    pct = lambda p: xs[min(len(xs) - 1, int(p * len(xs)))]
    return (f"min={xs[0]:.1f} ms  p50={pct(0.50):.1f} ms  p90={pct(0.90):.1f} ms  "
            f"max={xs[-1]:.1f} ms  mean={sum(xs)/len(xs):.1f} ms")

print(f"round0={durs[0]:.1f} ms (first round, startup-inflated; kept out of steady state)")
if len(durs) > 1:
    print(f"steady state (rounds 1..{cycles - 1}, n={len(durs) - 1}): {summary(durs[1:])}")
print(f"all rounds (n={len(durs)}): {summary(durs)}")
total = (ends[cycles - 1] - starts[0]).total_seconds() * 1000
print(f"run total (round 0 open to last close): {total:.1f} ms")
PY
	local rc=$?
	rm -f "$lines_tmp"
	return "$rc"
}

measure_rounds() {
	step "per-round latency from the api-gateway round markers"
	must_grep "cycle count in the round loop" "$GW_LOG" -F "Running VFL for ${CYCLES} rounds"
	local round_lines
	round_lines=$(echo "$GW_LOG" | grep -E "Running VFL training round|- Sending training request|Intermediate accuracy achieved")
	echo "$round_lines"
	echo
	round_latency_table "$CYCLES" "$round_lines" || fail "round marker parse failed"
}

# Payload sizes off the server state PVC via a throwaway inspector pod.
# Frees the RWO claim first by dropping the lingering chain Jobs (the same
# thing reset.sh does; state survives), so this must run AFTER the full-log
# dump, which still needs those pods.
payload_sizes_server() {
	step "payload size: persisted checkpoints on the server state PVC"
	local ns=server pvc i
	pvc=$(kubectl get pvc -n "$ns" -o name 2>/dev/null | grep 'persistentvolumeclaim/state-' | head -1 | cut -d/ -f2)
	[ -n "$pvc" ] || fail "no server state PVC found"
	echo "[server] state PVC: $pvc"
	kubectl -n "$ns" delete jobs --all --ignore-not-found=true --wait=true >/dev/null 2>&1
	kubectl -n "$ns" delete pod "$INSPECTOR" --ignore-not-found=true --wait=true >/dev/null 2>&1
	for i in $(seq 1 30); do
		kubectl get pods -n "$ns" -o name 2>/dev/null | grep -q jake || break
		sleep 2
	done
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
		|| fail "payload inspector pod did not become ready"
	PAYLOAD_LISTING=$(kubectl exec -n "$ns" "$INSPECTOR" -c inspector -- sh -c \
		'ls -lR /state; du -sb /state/data /state/audit; echo "state files: $(find /state/data -type f | wc -l)"') \
		|| fail "payload listing failed"
	echo "$PAYLOAD_LISTING"
	kubectl -n "$ns" delete pod "$INSPECTOR" --ignore-not-found=true --wait=false >/dev/null 2>&1
}

# --- config blocks --------------------------------------------------------

do_config_a() {
	step "reset + canonical seed, then drop requiresGateway from the chain metadata"
	reset_and_seed
	flip_requires_gateway_off

	step "trigger the chain (cycles=${CYCLES}) without a gateway"
	local rid
	rid=$(trigger "$CYCLES") || exit 1

	config_evidence no-gateway

	step "wait for training to finish"
	local status
	status=$(wait_done "$rid") || exit 1
	r2_series "$status"

	full_logs no-gateway

	step "microservice evidence: gateway degrade line, no checkpoint writes"
	must_grep "server MS degraded to no-gateway mode" "$SERVER_MS_LOG" \
		-F "No policy gateway reachable, continuing without one"
	must_not_grep "no checkpoint write in no-gateway mode" "$SERVER_MS_LOG" -F "Checkpoint write allowed"
	must_not_grep "no gateway connection in no-gateway mode" "$SERVER_MS_LOG" -F "Successfully connected to gateway"

	# The dial-retry lands inside round 0's span: the api-gateway opens the
	# round while the MS is still retrying, so round 0 absorbs the wait. Prove
	# the retry never reaches steady state: the degrade must precede round 0's
	# close.
	local degrade_ts round0_close_ts
	degrade_ts=$(echo "$SERVER_MS_LOG" | grep -F "No policy gateway reachable" | head -1 | awk '{print $1}')
	round0_close_ts=$(echo "$GW_LOG" | grep -F "Intermediate accuracy achieved" \
		| grep -F "for round 0" | head -1 | awk '{print $1}')
	[ -n "$degrade_ts" ] || fail "no timestamped degrade line in the server MS log"
	[ -n "$round0_close_ts" ] || fail "no round 0 close marker in the api-gateway log"
	python3 -c "
import re, sys
from datetime import datetime
def p(raw):
    raw = re.sub(r'(\.\d{6})\d*', r'\1', raw).replace('Z', '+00:00')
    return datetime.fromisoformat(raw)
sys.exit(0 if p(sys.argv[1]) < p(sys.argv[2]) else 1)" "$degrade_ts" "$round0_close_ts" \
		&& echo "OK: dial-retry degrade ($degrade_ts) absorbed inside round 0 (closed $round0_close_ts)" \
		|| fail "the MS degraded after round 0 closed; steady-state rounds may contain the dial-retry"

	measure_rounds
	echo "note: the flip is ephemeral; the next reset restores requiresGateway:true"
}

do_config_b() {
	step "arm pass-through, then reset + canonical seed + clean slate"
	enable_passthrough
	reset_and_seed
	delete_state_pvcs

	step "trigger the chain (cycles=${CYCLES}) in pass-through"
	local rid
	rid=$(trigger "$CYCLES") || exit 1

	config_evidence with-gateway

	step "wait for training to finish"
	local status
	status=$(wait_done "$rid") || exit 1
	r2_series "$status"

	full_logs with-gateway

	step "pass-through evidence: mode banner, governed decisions, no persistence"
	must_grep "gateway booted in pass-through mode" "$SERVER_GW_LOG" \
		-F "Pass-through mode: decisions and audit only, state writes skipped"
	must_grep "server MS connected to its gateway" "$SERVER_MS_LOG" \
		-F "Successfully connected to gateway"
	local ckpt_n allow_n
	ckpt_n=$(echo "$SERVER_MS_LOG" | grep -cF "Checkpoint write allowed: round_index=")
	[ "$ckpt_n" -eq "$CYCLES" ] || fail "expected $CYCLES allowed checkpoint writes in the server MS log, got $ckpt_n"
	echo "OK: $ckpt_n allowed checkpoint writes, one per round"
	must_grep "clean-slate startup read DENY 'not found'" \
		"$(echo "$SERVER_GW_LOG" | grep '"op":"read"')" -F '"reason":"not found"'
	allow_n=$(echo "$SERVER_GW_LOG" | grep -c '"op":"write","decision":"ALLOW"')
	[ "$allow_n" -eq "$CYCLES" ] || fail "expected $CYCLES ALLOW write audit lines on the server gateway, got $allow_n"
	echo "OK: $allow_n ALLOW write audit lines, one per round"

	measure_rounds
	payload_sizes_server
	must_grep "no state files persisted in pass-through" "$PAYLOAD_LISTING" -F "state files: 0"

	step "disarm pass-through"
	disable_passthrough
	echo "[passthrough] GATEWAY_PASSTHROUGH removed from all four steward agents"
}

do_config_c() {
	step "reset + canonical seed, then delete the state PVCs (clean slate)"
	reset_and_seed
	delete_state_pvcs

	step "trigger the chain (cycles=${CYCLES}) with full enforcement"
	local rid
	rid=$(trigger "$CYCLES") || exit 1

	config_evidence with-gateway

	step "wait for training to finish"
	local status
	status=$(wait_done "$rid") || exit 1
	r2_series "$status"

	full_logs with-gateway

	step "enforcement evidence: connect, per-round governed writes, clean-slate read"
	must_not_grep "no pass-through banner under full enforcement" "$SERVER_GW_LOG" \
		-F "Pass-through mode:"
	must_grep "server MS connected to its gateway" "$SERVER_MS_LOG" \
		-F "Successfully connected to gateway"
	local ckpt_n allow_n
	ckpt_n=$(echo "$SERVER_MS_LOG" | grep -cF "Checkpoint write allowed: round_index=")
	[ "$ckpt_n" -eq "$CYCLES" ] || fail "expected $CYCLES checkpoint writes in the server MS log, got $ckpt_n"
	echo "OK: $ckpt_n checkpoint writes, one per round"
	must_grep "clean-slate startup read DENY 'not found'" \
		"$(echo "$SERVER_GW_LOG" | grep '"op":"read"')" -F '"reason":"not found"'
	allow_n=$(echo "$SERVER_GW_LOG" | grep -c '"op":"write","decision":"ALLOW"')
	[ "$allow_n" -eq "$CYCLES" ] || fail "expected $CYCLES ALLOW write audit lines on the server gateway, got $allow_n"
	echo "OK: $allow_n ALLOW write audit lines, one per round"

	measure_rounds
	payload_sizes_server
	must_grep "persisted state files on the PVC" "$PAYLOAD_LISTING" -E "state files: [1-9]"
}

# --- capture plumbing -----------------------------------------------------

capture() {
	local ts out rc commit note
	ts="$(date +%Y%m%d-%H%M%S)"
	out="$results_dir/${subdir}/${ts}_overhead-run.txt"
	mkdir -p "$(dirname "$out")"
	{ provenance; "do_config_${CONFIG}"; } 2>&1 | tee "$out"
	rc=${PIPESTATUS[0]}
	commit="$(git -C "$root" rev-parse --short HEAD)"
	note="E3 config ${CONFIG} (${subdir#config-?-}): per-round latency + r2 + full logs, cycles=${CYCLES}"
	[ "$rc" -ne 0 ] && note="$note; FAILED (exit=$rc)"
	echo "\`e3-overhead/${subdir}/${ts}_overhead-run.txt | $ts | scripts/capture_e3_overhead.sh ${CONFIG} ${CYCLES} | $commit | $note\`" \
		>> "$results_dir/captures.md"
	echo
	echo "captured: $out (exit=$rc)"
	exit "$rc"
}

capture
