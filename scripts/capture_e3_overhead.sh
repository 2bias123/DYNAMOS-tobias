#!/usr/bin/env bash
set -u

# E3 overhead capture, one config per invocation. Measures per-round VFL chain
# latency and the r2 curve in three configurations:
#   a  no gateway (requiresGateway flipped off in etcd, no persistence)
#   b  pass-through (gateway present; decisions and audit run, state writes
#      skipped via GATEWAY_PASSTHROUGH on the steward agents)
#   c  full enforcement (per-round write-through, clean state PVCs first)
#   d  roundtrip variant (config c plus STATE_ROUNDTRIP on the steward
#      agents: the server MS rehydrates from the governed checkpoint every
#      round and drops its in-memory model after the checkpoint write)
#   e  chain roundtrip (config d plus STATE_ROUNDTRIP_CLIENT: the three
#      client MSs also rehydrate every round, holding state only across the
#      train/gradient RPC pair, and drop it after the round's write)
#   f  store-only chain roundtrip (config e with GATEWAY_STORE_ONLY on the
#      gateways: identity, decisions, and audit are skipped, only the PVC
#      I/O remains — the governed-minus-ungoverned delta prices governance)
#   g  inert gateway (container present and fully booted via GATEWAY_INERT
#      on the steward agents, but its listener never binds: the MSs degrade
#      exactly as in config a — isolates the container's presence cost from
#      its interaction cost; needs images built with the GATEWAY_INERT flag)
#   h  store-only write-through (config c's topology with GATEWAY_STORE_ONLY:
#      identity, decision, and audit skipped, only the PVC write I/O remains.
#      NOT the arm-f chain roundtrip — no STATE_ROUNDTRIP flags; h is c minus
#      governance. The counted E3 redo's fourth arm: c-h prices governance on
#      the write path at the counted tier.)
#
# Configs d, e, and f belong to their own experiment: they tag failures E7
# and default their artifacts to results/e7-pvc-roundtrip, so a forgotten
# E3_RESULTS_DIR override can never touch the frozen campaign tree. Config g
# is a diagnostic probe and defaults to results/e3-inert-probe for the same
# reason — it can never land in a counted tree by accident. Config h is an E3
# arm and defaults to results/e3-balanced (its own redo tree), so a bare
# invocation can never land in campaign-n50 either.
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
# Usage: capture_e3_overhead.sh <a|b|c|d|e|f|g|h> [cycles]   (cycles default CAMPAIGN_N)

EXP=E3
root="$(cd "$(dirname "$0")/.." && pwd)"
results_dir="${E3_RESULTS_DIR:-$root/results/campaign-n50/e3-overhead}"
. "$root/scripts/capture_lib.sh"

CONFIG="${1:-}"
CYCLES="${2:-$CAMPAIGN_N}"
case "$CONFIG" in
	a) subdir="config-a-no-gateway" ;;
	b) subdir="config-b-passthrough" ;;
	c) subdir="config-c-enforced" ;;
	d) subdir="config-d-roundtrip"; EXP=E7; results_dir="${E3_RESULTS_DIR:-$root/results/e7-pvc-roundtrip}" ;;
	e) subdir="config-e-chain-roundtrip"; EXP=E7; results_dir="${E3_RESULTS_DIR:-$root/results/e7-pvc-roundtrip}" ;;
	f) subdir="config-f-store-only"; EXP=E7; results_dir="${E3_RESULTS_DIR:-$root/results/e7-pvc-roundtrip}" ;;
	g) subdir="config-g-inert"; results_dir="${E3_RESULTS_DIR:-$root/results/e3-inert-probe}" ;;
	h) subdir="config-h-store-only"; results_dir="${E3_RESULTS_DIR:-$root/results/e3-balanced}" ;;
	*) echo "usage: $0 <a|b|c|d|e|f|g|h> [cycles]" >&2; exit 2 ;;
esac
export EXP

USER_NAME="jake.jongejans@student.uva.nl"
STEWARD_NS=(server clientone clienttwo clientthree)
APIPORT="${APIPORT:-8080}"
ORCHPORT="${ORCHPORT:-8082}"
POLL_MAX="${POLL_MAX:-$(poll_max_for_cycles "$CYCLES")}"   # x5s
GATEWAY_MS=(vfl-train-model-demo vfl-train-demo)
INSPECTOR_IMAGE="${INSPECTOR_IMAGE:-tamjiyan/vfl-train-demo:latest}"
INSPECTOR=e3-inspector

PIDS=()
cleanup() {
	# A failed b, d, e, f, or g run must not leave its env flags armed for a later config.
	[ "$CONFIG" = b ] && disable_passthrough
	[ "$CONFIG" = d ] && disable_roundtrip
	[ "$CONFIG" = e ] && { disable_roundtrip; disable_roundtrip_client; }
	[ "$CONFIG" = f ] && { disable_roundtrip; disable_roundtrip_client; disable_store_only; }
	[ "$CONFIG" = g ] && disable_inert
	[ "$CONFIG" = h ] && disable_store_only
	for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done
}
trap cleanup EXIT

# Timing runs also record load context on top of the shared provenance.
provenance() {
	echo "\$ date"; date; echo
	echo "\$ git rev-parse HEAD"; git -C "$root" rev-parse HEAD; echo
	echo "\$ git status --short"; git -C "$root" status --short; echo
	echo "\$ kubectl config current-context"; kubectl config current-context; echo
	echo "\$ uptime"; uptime; echo
	echo "\$ nproc"; nproc; echo
}

# --- shared helpers -------------------------------------------------------

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

# The roundtrip variant is armed the same way as pass-through: an env var on
# the steward agents, which the agent mirrors into every job MS container it
# deploys. Same rule: arm BEFORE the reset so the agent rollout is absorbed.
enable_roundtrip() {
	local ns
	for ns in "${STEWARD_NS[@]}"; do
		kubectl set env "deployment/${ns}" -n "$ns" STATE_ROUNDTRIP=true >/dev/null \
			|| fail "could not set STATE_ROUNDTRIP on $ns"
	done
	echo "[roundtrip] STATE_ROUNDTRIP=true on all four steward agents"
}

disable_roundtrip() {
	local ns
	for ns in "${STEWARD_NS[@]}"; do
		kubectl set env "deployment/${ns}" -n "$ns" STATE_ROUNDTRIP- >/dev/null 2>&1
	done
}

enable_roundtrip_client() {
	local ns
	for ns in "${STEWARD_NS[@]}"; do
		kubectl set env "deployment/${ns}" -n "$ns" STATE_ROUNDTRIP_CLIENT=true >/dev/null \
			|| fail "could not set STATE_ROUNDTRIP_CLIENT on $ns"
	done
	echo "[roundtrip] STATE_ROUNDTRIP_CLIENT=true on all four steward agents"
}

disable_roundtrip_client() {
	local ns
	for ns in "${STEWARD_NS[@]}"; do
		kubectl set env "deployment/${ns}" -n "$ns" STATE_ROUNDTRIP_CLIENT- >/dev/null 2>&1
	done
}

enable_store_only() {
	local ns
	for ns in "${STEWARD_NS[@]}"; do
		kubectl set env "deployment/${ns}" -n "$ns" GATEWAY_STORE_ONLY=true >/dev/null \
			|| fail "could not set GATEWAY_STORE_ONLY on $ns"
	done
	echo "[store-only] GATEWAY_STORE_ONLY=true on all four steward agents"
}

disable_store_only() {
	local ns
	for ns in "${STEWARD_NS[@]}"; do
		kubectl set env "deployment/${ns}" -n "$ns" GATEWAY_STORE_ONLY- >/dev/null 2>&1
	done
}

# Inert mode is armed like pass-through: an env var on the steward agents,
# mirrored into every gateway container they deploy. Same rule: arm BEFORE
# the reset so the agent rollout is absorbed by the settle window.
enable_inert() {
	local ns
	for ns in "${STEWARD_NS[@]}"; do
		kubectl set env "deployment/${ns}" -n "$ns" GATEWAY_INERT=true >/dev/null \
			|| fail "could not set GATEWAY_INERT on $ns"
	done
	echo "[inert] GATEWAY_INERT=true on all four steward agents"
}

disable_inert() {
	local ns
	for ns in "${STEWARD_NS[@]}"; do
		kubectl set env "deployment/${ns}" -n "$ns" GATEWAY_INERT- >/dev/null 2>&1
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

# Dump the full logs into the artifact: the api-gateway container, both VFL
# MS containers on all four stewards, and the gateway container where the
# config has one. Sets GW_LOG, SERVER_MS_LOG, SERVER_GW_LOG for the asserts,
# plus CLIENT_MS_LOG_<ns> / CLIENT_GW_LOG_<ns> (the vfl-train-demo container
# and gateway on the client stewards). $1 = with-gateway | no-gateway.
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
			[ "$ns" != server ] && [ "$c" = vfl-train-demo ] && eval "CLIENT_MS_LOG_${ns}=\$log"
		done
		if [ "$mode" = with-gateway ]; then
			log=$(kubectl logs -n "$ns" "$pod" -c policy-checkpoint-gateway --timestamps 2>&1)
			step "full log: $ns/$pod policy-checkpoint-gateway"
			echo "$log"
			[ "$ns" = server ] && SERVER_GW_LOG="$log"
			[ "$ns" != server ] && eval "CLIENT_GW_LOG_${ns}=\$log"
		fi
	done
}

# Per-round latency from the api-gateway round markers, paired by round
# number, plus a summary line. Fails if any of the $1 expected rounds is
# missing a marker. The checkpoint and span columns come from the server MS
# and gateway logs and stay blank where the config has no gateway; MS
# round_index=k closes chain round k-1.
round_latency_table() { # $1 = cycles, $2 = api-gateway round lines, $3 = server MS checkpoint lines, $4 = server gateway Write-timing lines, $5 = server gateway Read-timing lines, $6 = server MS leg-timing lines
	local lines_tmp ckpt_tmp span_tmp rspan_tmp mst_tmp
	lines_tmp=$(mktemp); ckpt_tmp=$(mktemp); span_tmp=$(mktemp); rspan_tmp=$(mktemp); mst_tmp=$(mktemp)
	echo "$2" > "$lines_tmp"
	echo "$3" > "$ckpt_tmp"
	echo "$4" > "$span_tmp"
	echo "${5:-}" > "$rspan_tmp"
	echo "${6:-}" > "$mst_tmp"
	python3 - "$1" "$lines_tmp" "$ckpt_tmp" "$span_tmp" "$rspan_tmp" "$mst_tmp" <<'PY'
import json, os, re, sys
from datetime import datetime

EXP = os.environ.get("EXP", "E3")
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

req, alw = {}, {}
for line in open(sys.argv[3]):
    m = re.search(r'Checkpoint write (requested|allowed): round_index=(\d+)', line)
    if m:
        d = req if m.group(1) == 'requested' else alw
        d.setdefault(int(m.group(2)) - 1, ts(line))

spans = []
for line in open(sys.argv[4]):
    i = line.find('{')
    if i >= 0:
        try:
            spans.append(json.loads(line[i:]))
        except ValueError:
            pass

rspans = []
for line in open(sys.argv[5]):
    i = line.find('{')
    if i >= 0:
        try:
            rspans.append(json.loads(line[i:]))
        except ValueError:
            pass

# MS-side leg timers: write legs are keyed like the checkpoint pair (MS
# round_index=k closes chain round k-1); a restore runs at the top of the
# chain round whose number equals the restored round_index.
wlegs, rlegs = {}, {}
for line in open(sys.argv[6]):
    m = re.search(r'Checkpoint write timing: round_index=(\d+) serialize_ms=([\d.]+) write_rpc_ms=([\d.]+)', line)
    if m:
        wlegs[int(m.group(1)) - 1] = (float(m.group(2)), float(m.group(3)))
        continue
    m = re.search(r'Roundtrip restore timing: round_index=(\d+) read_rpc_ms=([\d.]+) construct_ms=([\d.]+) deserialize_ms=([\d.]+)', line)
    if m:
        rlegs[int(m.group(1))] = (float(m.group(2)), float(m.group(3)), float(m.group(4)))

# duration = open marker to accuracy line; reverify = open marker to the
# training dispatch (the baseline's own per-round policy re-verification sits
# in this segment, in every config); train = dispatch to accuracy;
# ckpt_wait = the MS's requested-to-allowed gateway round trip; the gw_*
# columns are the gateway's own spans for that round's write.
print("round,start,end,duration_ms,reverify_ms,train_ms,ckpt_wait_ms,gw_decide_us,gw_audit_us,gw_persist_us,gw_total_us,"
      "serialize_ms,write_rpc_ms,read_rpc_ms,construct_ms,deserialize_ms,"
      "gw_read_decide_us,gw_read_audit_us,gw_read_read_us,gw_read_total_us")
durs = []
for r in range(cycles):
    if r not in starts or r not in ends or r not in trains:
        print(f"{EXP} FAIL: round {r} missing marker "
              f"(start={r in starts} train={r in trains} end={r in ends})")
        sys.exit(1)
    d = (ends[r] - starts[r]).total_seconds() * 1000
    rev = (trains[r] - starts[r]).total_seconds() * 1000
    tr = (ends[r] - trains[r]).total_seconds() * 1000
    durs.append(d)
    wait = f"{(alw[r] - req[r]).total_seconds() * 1000:.1f}" if r in req and r in alw else ''
    g = spans[r] if r < len(spans) else None
    gcols = (f"{g['decideMicros']},{g['auditMicros']},{g['persistMicros']},{g['totalMicros']}"
             if g else ',,,')
    w = wlegs.get(r)
    wcols = f"{w[0]:.3f},{w[1]:.3f}" if w else ','
    rl = rlegs.get(r)
    rcols = f"{rl[0]:.3f},{rl[1]:.3f},{rl[2]:.3f}" if rl else ',,'
    # Read span i belongs to round i+1: round 0's clean-slate read denies
    # before the gateway logs a span.
    rg = rspans[r - 1] if 0 < r <= len(rspans) else None
    rgcols = (f"{rg['decideMicros']},{rg['auditMicros']},{rg['readMicros']},{rg['totalMicros']}"
              if rg else ',,,')
    print(f"{r},{starts[r].isoformat()},{ends[r].isoformat()},{d:.1f},{rev:.1f},{tr:.1f},{wait},{gcols},{wcols},{rcols},{rgcols}")

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
waits = [(alw[r] - req[r]).total_seconds() * 1000 for r in range(cycles) if r in req and r in alw]
if waits:
    print(f"server ckpt wait (MS requested -> allowed, n={len(waits)}): {summary(waits)}")
if spans:
    tot = [g['totalMicros'] for g in spans[:cycles]]
    aud = [g['auditMicros'] for g in spans[:cycles]]
    print(f"server gateway write spans (n={len(tot)}): mean total={sum(tot)/len(tot):.0f} us  mean audit={sum(aud)/len(aud):.0f} us")
if rspans:
    tot = [g['totalMicros'] for g in rspans[:cycles]]
    aud = [g['auditMicros'] for g in rspans[:cycles]]
    rd = [g['readMicros'] for g in rspans[:cycles]]
    print(f"server gateway read spans (n={len(tot)}): mean total={sum(tot)/len(tot):.0f} us  mean audit={sum(aud)/len(aud):.0f} us  mean read={sum(rd)/len(rd):.0f} us")
for name, xs in (('serialize leg', [w[0] for w in wlegs.values()]),
                 ('write RPC leg', [w[1] for w in wlegs.values()]),
                 ('read RPC leg', [v[0] for v in rlegs.values()]),
                 ('construct leg', [v[1] for v in rlegs.values()]),
                 ('deserialize leg', [v[2] for v in rlegs.values()])):
    if xs:
        print(f"server MS {name} (n={len(xs)}): {summary(xs)}")
PY
	local rc=$?
	rm -f "$lines_tmp" "$ckpt_tmp" "$span_tmp" "$rspan_tmp" "$mst_tmp"
	return "$rc"
}

measure_rounds() {
	step "per-round latency from the api-gateway round markers"
	must_grep "cycle count in the round loop" "$GW_LOG" -F "Running VFL for ${CYCLES} rounds"
	local round_lines ckpt_lines span_lines rspan_lines mst_lines
	round_lines=$(echo "$GW_LOG" | grep -E "Running VFL training round|- Sending training request|Intermediate accuracy achieved")
	echo "$round_lines"
	echo
	ckpt_lines=$(echo "${SERVER_MS_LOG:-}" | grep -E "Checkpoint write (requested|allowed): round_index=")
	span_lines=$(echo "${SERVER_GW_LOG:-}" | grep -F "Write timing")
	rspan_lines=$(echo "${SERVER_GW_LOG:-}" | grep -F "Read timing")
	mst_lines=$(echo "${SERVER_MS_LOG:-}" | grep -E "Checkpoint write timing:|Roundtrip restore timing:")
	round_latency_table "$CYCLES" "$round_lines" "$ckpt_lines" "$span_lines" "$rspan_lines" "$mst_lines" || fail "round marker parse failed"
}

# Pair each restore's payload sha and state fingerprint with the write that
# produced it (write round_index k -> restore round_index k). Any unmatched
# pair means the rehydration was not faithful. $1 = MS label, $2 = its log.
verify_roundtrip_fidelity() {
	local label="$1" timing_tmp
	timing_tmp=$(mktemp)
	echo "${2:-}" | grep -E "Checkpoint write timing:|Roundtrip restore timing:" > "$timing_tmp"
	python3 - "$CYCLES" "$timing_tmp" <<'PY'
import os, re, sys

EXP = os.environ.get("EXP", "E7")
cycles = int(sys.argv[1])
writes, restores = {}, {}
for line in open(sys.argv[2]):
    m = re.search(r'Checkpoint write timing: round_index=(\d+) .*sha256=(\w+) state_fp=(\w+)', line)
    if m:
        writes[int(m.group(1))] = (m.group(2), m.group(3))
        continue
    m = re.search(r'Roundtrip restore timing: round_index=(\d+) .*sha256=(\w+) state_fp=(\w+)', line)
    if m:
        restores[int(m.group(1))] = (m.group(2), m.group(3))

expected = set(range(1, cycles))
if set(restores) != expected:
    missing = sorted(expected - set(restores))[:5]
    extra = sorted(set(restores) - expected)[:5]
    print(f"{EXP} FAIL: restore round_index set wrong (missing={missing} extra={extra})")
    sys.exit(1)
bad = 0
for k in sorted(restores):
    if k not in writes:
        print(f"{EXP} FAIL: restore round_index={k} has no matching write")
        bad += 1
        continue
    if writes[k] != restores[k]:
        print(f"{EXP} FAIL: round_index={k} write sha/fp {writes[k]} != restore sha/fp {restores[k]}")
        bad += 1
sys.exit(1 if bad else 0)
PY
	local rc=$?
	rm -f "$timing_tmp"
	[ "$rc" -eq 0 ] || fail "roundtrip fidelity check failed on $label"
	echo "OK: $label: all $((CYCLES - 1)) restores match their writes (payload sha256 and state fingerprint)"
}

# Leg summaries for one MS: write and restore timing lines from its log plus
# the read spans from its gateway. $1 = label, $2 = MS log, $3 = gateway log.
client_leg_summary() {
	local label="$1" ms_tmp gw_tmp
	ms_tmp=$(mktemp); gw_tmp=$(mktemp)
	echo "${2:-}" | grep -E "Checkpoint write timing:|Roundtrip restore timing:" > "$ms_tmp"
	echo "${3:-}" | grep -F "Read timing" > "$gw_tmp"
	python3 - "$label" "$ms_tmp" "$gw_tmp" <<'PY'
import json, re, sys

label = sys.argv[1]
legs = {"serialize": [], "write RPC": [], "read RPC": [], "construct": [], "deserialize": []}
for line in open(sys.argv[2]):
    m = re.search(r'Checkpoint write timing: round_index=\d+ serialize_ms=([\d.]+) write_rpc_ms=([\d.]+)', line)
    if m:
        legs["serialize"].append(float(m.group(1)))
        legs["write RPC"].append(float(m.group(2)))
        continue
    m = re.search(r'Roundtrip restore timing: round_index=\d+ read_rpc_ms=([\d.]+) construct_ms=([\d.]+) deserialize_ms=([\d.]+)', line)
    if m:
        legs["read RPC"].append(float(m.group(1)))
        legs["construct"].append(float(m.group(2)))
        legs["deserialize"].append(float(m.group(3)))

spans = []
for line in open(sys.argv[3]):
    i = line.find('{')
    if i >= 0:
        try:
            spans.append(json.loads(line[i:]))
        except ValueError:
            pass

def summary(xs):
    xs = sorted(xs)
    pct = lambda p: xs[min(len(xs) - 1, int(p * len(xs)))]
    return (f"min={xs[0]:.1f} ms  p50={pct(0.50):.1f} ms  p90={pct(0.90):.1f} ms  "
            f"max={xs[-1]:.1f} ms  mean={sum(xs)/len(xs):.1f} ms")

for name, xs in legs.items():
    if xs:
        print(f"{label} MS {name} leg (n={len(xs)}): {summary(xs)}")
if spans:
    tot = [g['totalMicros'] for g in spans]
    aud = [g['auditMicros'] for g in spans]
    rd = [g['readMicros'] for g in spans]
    print(f"{label} gateway read spans (n={len(tot)}): mean total={sum(tot)/len(tot):.0f} us  mean audit={sum(aud)/len(aud):.0f} us  mean read={sum(rd)/len(rd):.0f} us")
PY
	rm -f "$ms_tmp" "$gw_tmp"
}

# Payload sizes off a steward's state PVC via a throwaway inspector pod.
# Frees the RWO claim first by dropping the lingering chain Jobs (the same
# thing reset.sh does; state survives), so this must run AFTER the full-log
# dump, which still needs those pods. $1 = namespace (default server).
payload_sizes_server() {
	local ns="${1:-server}" i
	step "payload size: persisted checkpoints on the $ns state PVC"
	kubectl -n "$ns" delete jobs --all --ignore-not-found=true --wait=true >/dev/null 2>&1
	kubectl -n "$ns" delete pod "$INSPECTOR" --ignore-not-found=true --wait=true >/dev/null 2>&1
	for i in $(seq 1 30); do
		kubectl get pods -n "$ns" -o name 2>/dev/null | grep -q jake || break
		sleep 2
	done
	start_state_inspector "$ns" "$INSPECTOR" "$INSPECTOR_IMAGE" \
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

do_config_d() {
	step "arm state roundtrip, then reset + canonical seed + clean slate"
	enable_roundtrip
	reset_and_seed
	delete_state_pvcs

	step "trigger the chain (cycles=${CYCLES}) with per-round rehydration"
	local rid
	rid=$(trigger "$CYCLES") || exit 1

	config_evidence with-gateway

	step "wait for training to finish"
	local status
	status=$(wait_done "$rid") || exit 1
	r2_series "$status"

	full_logs with-gateway

	step "roundtrip evidence: variant banner, per-round governed reads and writes"
	must_not_grep "no pass-through banner under full enforcement" "$SERVER_GW_LOG" \
		-F "Pass-through mode:"
	must_grep "server MS connected to its gateway" "$SERVER_MS_LOG" \
		-F "Successfully connected to gateway"
	must_grep "variant banner in the server MS log" "$SERVER_MS_LOG" \
		-F "State roundtrip mode enabled"
	local ckpt_n allow_n read_allow_n read_deny_n restore_n rspan_n
	ckpt_n=$(echo "$SERVER_MS_LOG" | grep -cF "Checkpoint write allowed: round_index=")
	[ "$ckpt_n" -eq "$CYCLES" ] || fail "expected $CYCLES checkpoint writes in the server MS log, got $ckpt_n"
	allow_n=$(echo "$SERVER_GW_LOG" | grep -c '"op":"write","decision":"ALLOW"')
	[ "$allow_n" -eq "$CYCLES" ] || fail "expected $CYCLES ALLOW write audit lines on the server gateway, got $allow_n"
	read_allow_n=$(echo "$SERVER_GW_LOG" | grep -c '"op":"read","decision":"ALLOW"')
	[ "$read_allow_n" -eq "$((CYCLES - 1))" ] || fail "expected $((CYCLES - 1)) ALLOW read audit lines, got $read_allow_n"
	read_deny_n=$(echo "$SERVER_GW_LOG" | grep '"op":"read"' | grep -c '"reason":"not found"')
	[ "$read_deny_n" -eq 1 ] || fail "expected exactly 1 clean-slate read DENY 'not found', got $read_deny_n"
	echo "OK: $allow_n write ALLOWs, $read_allow_n read ALLOWs, 1 clean-slate read DENY"
	must_not_grep "no fresh-Get storm: every read decided from the cached agreement" \
		"$(echo "$SERVER_GW_LOG" | grep '"op":"read"')" -F '"policySource":"fresh"'
	restore_n=$(echo "$SERVER_MS_LOG" | grep -cF "Roundtrip restore timing: round_index=")
	[ "$restore_n" -eq "$((CYCLES - 1))" ] || fail "expected $((CYCLES - 1)) roundtrip restores, got $restore_n"
	rspan_n=$(echo "$SERVER_GW_LOG" | grep -cF "Read timing")
	[ "$rspan_n" -eq "$((CYCLES - 1))" ] || fail "expected $((CYCLES - 1)) gateway read spans, got $rspan_n"
	echo "OK: $restore_n restores with $rspan_n gateway read spans"
	must_not_grep "no pre-shrink stash interleaved with the per-round writes" "$SERVER_MS_LOG" \
		-F "Saving server state before shrinking"

	step "rehydration fidelity: payload sha and state fingerprint pairing"
	verify_roundtrip_fidelity server "$SERVER_MS_LOG"

	measure_rounds
	payload_sizes_server
	must_grep "persisted state files on the PVC" "$PAYLOAD_LISTING" -E "state files: [1-9]"

	step "disarm state roundtrip"
	disable_roundtrip
	echo "[roundtrip] STATE_ROUNDTRIP removed from all four steward agents"
}

do_config_e() {
	step "arm chain roundtrip (server + client flags), then reset + canonical seed + clean slate"
	enable_roundtrip
	enable_roundtrip_client
	reset_and_seed
	delete_state_pvcs

	step "trigger the chain (cycles=${CYCLES}) with whole-chain per-round rehydration"
	local rid
	rid=$(trigger "$CYCLES") || exit 1

	config_evidence with-gateway

	step "wait for training to finish"
	local status
	status=$(wait_done "$rid") || exit 1
	r2_series "$status"

	full_logs with-gateway

	step "roundtrip evidence on server: variant banner, per-round governed reads and writes"
	must_not_grep "no pass-through banner under full enforcement" "$SERVER_GW_LOG" \
		-F "Pass-through mode:"
	must_grep "server MS connected to its gateway" "$SERVER_MS_LOG" \
		-F "Successfully connected to gateway"
	must_grep "variant banner in the server MS log" "$SERVER_MS_LOG" \
		-F "State roundtrip mode enabled"
	local ckpt_n allow_n read_allow_n read_deny_n restore_n rspan_n
	ckpt_n=$(echo "$SERVER_MS_LOG" | grep -cF "Checkpoint write allowed: round_index=")
	[ "$ckpt_n" -eq "$CYCLES" ] || fail "expected $CYCLES checkpoint writes in the server MS log, got $ckpt_n"
	allow_n=$(echo "$SERVER_GW_LOG" | grep -c '"op":"write","decision":"ALLOW"')
	[ "$allow_n" -eq "$CYCLES" ] || fail "expected $CYCLES ALLOW write audit lines on the server gateway, got $allow_n"
	read_allow_n=$(echo "$SERVER_GW_LOG" | grep -c '"op":"read","decision":"ALLOW"')
	[ "$read_allow_n" -eq "$((CYCLES - 1))" ] || fail "expected $((CYCLES - 1)) ALLOW read audit lines, got $read_allow_n"
	read_deny_n=$(echo "$SERVER_GW_LOG" | grep '"op":"read"' | grep -c '"reason":"not found"')
	[ "$read_deny_n" -eq 1 ] || fail "expected exactly 1 clean-slate read DENY 'not found', got $read_deny_n"
	echo "OK: server: $allow_n write ALLOWs, $read_allow_n read ALLOWs, 1 clean-slate read DENY"
	must_not_grep "no fresh-Get storm: every server read decided from the cached agreement" \
		"$(echo "$SERVER_GW_LOG" | grep '"op":"read"')" -F '"policySource":"fresh"'
	restore_n=$(echo "$SERVER_MS_LOG" | grep -cF "Roundtrip restore timing: round_index=")
	[ "$restore_n" -eq "$((CYCLES - 1))" ] || fail "expected $((CYCLES - 1)) roundtrip restores on the server, got $restore_n"
	rspan_n=$(echo "$SERVER_GW_LOG" | grep -cF "Read timing")
	[ "$rspan_n" -eq "$((CYCLES - 1))" ] || fail "expected $((CYCLES - 1)) server gateway read spans, got $rspan_n"
	echo "OK: server: $restore_n restores with $rspan_n gateway read spans"
	must_not_grep "no pre-shrink stash interleaved with the per-round writes" "$SERVER_MS_LOG" \
		-F "Saving server state before shrinking"
	verify_roundtrip_fidelity server "$SERVER_MS_LOG"

	local ns v ms_log gw_log
	for ns in clientone clienttwo clientthree; do
		step "roundtrip evidence on $ns: variant banner, per-round governed reads and writes"
		v="CLIENT_MS_LOG_${ns}"; ms_log="${!v}"
		v="CLIENT_GW_LOG_${ns}"; gw_log="${!v}"
		[ -n "$ms_log" ] || fail "no retained MS log for $ns"
		[ -n "$gw_log" ] || fail "no retained gateway log for $ns"
		must_grep "variant banner in the $ns MS log" "$ms_log" \
			-F "State roundtrip mode enabled"
		ckpt_n=$(echo "$ms_log" | grep -cF "Checkpoint write allowed: round_index=")
		[ "$ckpt_n" -eq "$CYCLES" ] || fail "expected $CYCLES checkpoint writes in the $ns MS log, got $ckpt_n"
		allow_n=$(echo "$gw_log" | grep -c '"op":"write","decision":"ALLOW"')
		[ "$allow_n" -eq "$CYCLES" ] || fail "expected $CYCLES ALLOW write audit lines on the $ns gateway, got $allow_n"
		read_allow_n=$(echo "$gw_log" | grep -c '"op":"read","decision":"ALLOW"')
		[ "$read_allow_n" -eq "$((CYCLES - 1))" ] || fail "expected $((CYCLES - 1)) ALLOW read audit lines on $ns, got $read_allow_n"
		read_deny_n=$(echo "$gw_log" | grep '"op":"read"' | grep -c '"reason":"not found"')
		[ "$read_deny_n" -eq 1 ] || fail "expected exactly 1 clean-slate read DENY 'not found' on $ns, got $read_deny_n"
		echo "OK: $ns: $allow_n write ALLOWs, $read_allow_n read ALLOWs, 1 clean-slate read DENY"
		must_not_grep "no fresh-Get storm: every $ns read decided from the cached agreement" \
			"$(echo "$gw_log" | grep '"op":"read"')" -F '"policySource":"fresh"'
		restore_n=$(echo "$ms_log" | grep -cF "Roundtrip restore timing: round_index=")
		[ "$restore_n" -eq "$((CYCLES - 1))" ] || fail "expected $((CYCLES - 1)) roundtrip restores on $ns, got $restore_n"
		rspan_n=$(echo "$gw_log" | grep -cF "Read timing")
		[ "$rspan_n" -eq "$((CYCLES - 1))" ] || fail "expected $((CYCLES - 1)) gateway read spans on $ns, got $rspan_n"
		echo "OK: $ns: $restore_n restores with $rspan_n gateway read spans"
		must_not_grep "no column-drift reinit on $ns" "$ms_log" -F "Column order changed"
		must_not_grep "no width-mismatch reinit on $ns" "$ms_log" -F "does not match dataframe width"
		must_not_grep "no optimiser restore failure on $ns" "$ms_log" \
			-F "Persisted optimiser state could not be applied"
		verify_roundtrip_fidelity "$ns" "$ms_log"
		client_leg_summary "$ns" "$ms_log" "$gw_log"
	done

	step "pooled client leg summary"
	client_leg_summary "clients-pooled" \
		"${CLIENT_MS_LOG_clientone}"$'\n'"${CLIENT_MS_LOG_clienttwo}"$'\n'"${CLIENT_MS_LOG_clientthree}" \
		"${CLIENT_GW_LOG_clientone}"$'\n'"${CLIENT_GW_LOG_clienttwo}"$'\n'"${CLIENT_GW_LOG_clientthree}"

	measure_rounds
	payload_sizes_server
	must_grep "persisted state files on the server PVC" "$PAYLOAD_LISTING" -E "state files: [1-9]"
	payload_sizes_server clientone
	must_grep "persisted state files on the clientone PVC" "$PAYLOAD_LISTING" -E "state files: [1-9]"

	step "disarm chain roundtrip"
	disable_roundtrip
	disable_roundtrip_client
	echo "[roundtrip] STATE_ROUNDTRIP and STATE_ROUNDTRIP_CLIENT removed from all four steward agents"
}

do_config_f() {
	step "arm store-only chain roundtrip (both MS flags + gateway store-only), then reset + canonical seed + clean slate"
	enable_roundtrip
	enable_roundtrip_client
	enable_store_only
	reset_and_seed
	delete_state_pvcs

	step "trigger the chain (cycles=${CYCLES}) with ungoverned per-round rehydration"
	local rid
	rid=$(trigger "$CYCLES") || exit 1

	config_evidence with-gateway

	step "wait for training to finish"
	local status
	status=$(wait_done "$rid") || exit 1
	r2_series "$status"

	full_logs with-gateway

	local ns v ms_log gw_log ckpt_n wspan_n rspan_n zero_n restore_n
	for ns in "${STEWARD_NS[@]}"; do
		if [ "$ns" = server ]; then
			ms_log="$SERVER_MS_LOG"
			gw_log="$SERVER_GW_LOG"
		else
			v="CLIENT_MS_LOG_${ns}"; ms_log="${!v}"
			v="CLIENT_GW_LOG_${ns}"; gw_log="${!v}"
		fi
		[ -n "$ms_log" ] || fail "no retained MS log for $ns"
		[ -n "$gw_log" ] || fail "no retained gateway log for $ns"
		step "store-only evidence on $ns: banner, ungoverned spans, no decision audit"
		must_grep "store-only banner on the $ns gateway" "$gw_log" \
			-F "Store-only mode: governance and audit skipped, state I/O only"
		must_not_grep "no pass-through banner on $ns" "$gw_log" -F "Pass-through mode:"
		must_grep "variant banner in the $ns MS log" "$ms_log" \
			-F "State roundtrip mode enabled"
		ckpt_n=$(echo "$ms_log" | grep -cF "Checkpoint write allowed: round_index=")
		[ "$ckpt_n" -eq "$CYCLES" ] || fail "expected $CYCLES checkpoint writes in the $ns MS log, got $ckpt_n"
		[ "$(echo "$gw_log" | grep -c '"op":"write"')" -eq 0 ] || fail "write audit records present on $ns despite store-only"
		[ "$(echo "$gw_log" | grep -c '"op":"read"')" -eq 0 ] || fail "read audit records present on $ns despite store-only"
		echo "OK: $ns: zero read/write decision audit records"
		wspan_n=$(echo "$gw_log" | grep -cF "Write timing")
		[ "$wspan_n" -eq "$CYCLES" ] || fail "expected $CYCLES write spans on $ns, got $wspan_n"
		rspan_n=$(echo "$gw_log" | grep -cF "Read timing")
		[ "$rspan_n" -eq "$((CYCLES - 1))" ] || fail "expected $((CYCLES - 1)) read spans on $ns, got $rspan_n"
		zero_n=$(echo "$gw_log" | grep -E "Write timing|Read timing" | grep -c '"decideMicros": 0, "auditMicros": 0')
		[ "$zero_n" -eq "$((CYCLES * 2 - 1))" ] || fail "expected $((CYCLES * 2 - 1)) zero-governance spans on $ns, got $zero_n"
		echo "OK: $ns: $wspan_n write + $rspan_n read spans, all with zero decide/audit"
		restore_n=$(echo "$ms_log" | grep -cF "Roundtrip restore timing: round_index=")
		[ "$restore_n" -eq "$((CYCLES - 1))" ] || fail "expected $((CYCLES - 1)) roundtrip restores on $ns, got $restore_n"
		echo "OK: $ns: $restore_n restores"
		if [ "$ns" = server ]; then
			must_grep "server MS connected to its gateway" "$ms_log" \
				-F "Successfully connected to gateway"
			must_not_grep "no pre-shrink stash interleaved with the per-round writes" "$ms_log" \
				-F "Saving server state before shrinking"
		else
			must_not_grep "no column-drift reinit on $ns" "$ms_log" -F "Column order changed"
			must_not_grep "no width-mismatch reinit on $ns" "$ms_log" -F "does not match dataframe width"
			must_not_grep "no optimiser restore failure on $ns" "$ms_log" \
				-F "Persisted optimiser state could not be applied"
		fi
		verify_roundtrip_fidelity "$ns" "$ms_log"
		[ "$ns" = server ] || client_leg_summary "$ns" "$ms_log" "$gw_log"
	done

	step "pooled client leg summary"
	client_leg_summary "clients-pooled" \
		"${CLIENT_MS_LOG_clientone}"$'\n'"${CLIENT_MS_LOG_clienttwo}"$'\n'"${CLIENT_MS_LOG_clientthree}" \
		"${CLIENT_GW_LOG_clientone}"$'\n'"${CLIENT_GW_LOG_clienttwo}"$'\n'"${CLIENT_GW_LOG_clientthree}"

	measure_rounds
	payload_sizes_server
	must_grep "persisted state files on the server PVC" "$PAYLOAD_LISTING" -E "state files: [1-9]"
	payload_sizes_server clientone
	must_grep "persisted state files on the clientone PVC" "$PAYLOAD_LISTING" -E "state files: [1-9]"

	step "disarm store-only chain roundtrip"
	disable_roundtrip
	disable_roundtrip_client
	disable_store_only
	echo "[store-only] all three variant env vars removed from the steward agents"
}

do_config_g() {
	step "arm inert gateway, then reset + canonical seed + clean slate"
	enable_inert
	reset_and_seed
	delete_state_pvcs

	step "trigger the chain (cycles=${CYCLES}) with an inert gateway"
	local rid
	rid=$(trigger "$CYCLES") || exit 1

	config_evidence with-gateway

	step "wait for training to finish"
	local status
	status=$(wait_done "$rid") || exit 1
	r2_series "$status"

	full_logs with-gateway

	step "inert evidence: banner on all four gateways, degrade like config a, zero interaction"
	must_grep "server MS degraded to no-gateway mode" "$SERVER_MS_LOG" \
		-F "No policy gateway reachable, continuing without one"
	local ns v ms_log gw_log
	for ns in "${STEWARD_NS[@]}"; do
		if [ "$ns" = server ]; then
			ms_log="$SERVER_MS_LOG"
			gw_log="$SERVER_GW_LOG"
		else
			v="CLIENT_MS_LOG_${ns}"; ms_log="${!v}"
			v="CLIENT_GW_LOG_${ns}"; gw_log="${!v}"
		fi
		[ -n "$ms_log" ] || fail "no retained MS log for $ns"
		[ -n "$gw_log" ] || fail "no retained gateway log for $ns"
		must_grep "inert banner on the $ns gateway" "$gw_log" \
			-F "Inert mode: gRPC listener not bound, serving nothing"
		must_not_grep "listener never bound on the $ns gateway" "$gw_log" -F "Serving on"
		must_not_grep "no MS-gateway connection on $ns" "$ms_log" -F "Successfully connected to gateway"
		must_not_grep "no checkpoint write on $ns" "$ms_log" -F "Checkpoint write allowed"
		must_not_grep "no write audit records on the $ns gateway" "$gw_log" -F '"op":"write"'
		must_not_grep "no read audit records on the $ns gateway" "$gw_log" -F '"op":"read"'
	done
	echo "OK: all four gateways inert, no MS interaction anywhere"

	# Same proof as config a: the dial-retry must be absorbed inside round 0,
	# so steady-state rounds never contain it.
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

	# Presence-cost mechanism evidence: cumulative CPU of each inert gateway
	# container over the run. Non-fatal — a missing snapshot never voids the run.
	step "inert gateway cumulative CPU (crictl stats, per steward)"
	docker exec kind-control-plane sh -c \
		'crictl ps --name policy-checkpoint-gateway; for id in $(crictl ps --name policy-checkpoint-gateway -q); do crictl stats -o json "$id"; done' \
		|| echo "note: crictl stats unavailable; CPU evidence missing from this artifact"

	measure_rounds
	payload_sizes_server
	must_grep "no state files persisted with an inert gateway" "$PAYLOAD_LISTING" -F "state files: 0"

	step "disarm inert gateway"
	disable_inert
	echo "[inert] GATEWAY_INERT removed from all four steward agents"
}

do_config_h() {
	step "arm store-only write-through (gateway store-only, no roundtrip), then reset + canonical seed + clean slate"
	enable_store_only
	reset_and_seed
	delete_state_pvcs

	step "trigger the chain (cycles=${CYCLES}) with store-only write-through"
	local rid
	rid=$(trigger "$CYCLES") || exit 1

	config_evidence with-gateway

	step "wait for training to finish"
	local status
	status=$(wait_done "$rid") || exit 1
	r2_series "$status"

	full_logs with-gateway

	# Store-only is armed on all four steward agents, so all four gateways
	# boot with the banner. The write-count and span depth stay on the server,
	# matching config c's server-focused enforcement asserts; read spans and
	# restores are deliberately not asserted — without STATE_ROUNDTRIP there
	# are no per-round reads, and the one clean-slate startup read carries no
	# governance decision in store-only, so pinning a read-span count would be
	# a fragile assertion the measurement does not need.
	local ns v gw_log
	step "store-only banner on all four gateways"
	for ns in "${STEWARD_NS[@]}"; do
		if [ "$ns" = server ]; then gw_log="$SERVER_GW_LOG"; else v="CLIENT_GW_LOG_${ns}"; gw_log="${!v}"; fi
		[ -n "$gw_log" ] || fail "no retained gateway log for $ns"
		must_grep "store-only banner on the $ns gateway" "$gw_log" \
			-F "Store-only mode: governance and audit skipped, state I/O only"
		must_not_grep "no pass-through banner on $ns" "$gw_log" -F "Pass-through mode:"
	done

	step "store-only evidence on server: per-round writes, ungoverned spans, zero decision audit"
	must_grep "server MS connected to its gateway" "$SERVER_MS_LOG" \
		-F "Successfully connected to gateway"
	local ckpt_n wspan_n zero_n
	ckpt_n=$(echo "$SERVER_MS_LOG" | grep -cF "Checkpoint write allowed: round_index=")
	[ "$ckpt_n" -eq "$CYCLES" ] || fail "expected $CYCLES checkpoint writes in the server MS log, got $ckpt_n"
	echo "OK: $ckpt_n checkpoint writes, one per round"
	[ "$(echo "$SERVER_GW_LOG" | grep -c '"op":"write"')" -eq 0 ] || fail "write audit records present on the server despite store-only"
	[ "$(echo "$SERVER_GW_LOG" | grep -c '"op":"read"')" -eq 0 ] || fail "read audit records present on the server despite store-only"
	echo "OK: server: zero read/write decision audit records"
	wspan_n=$(echo "$SERVER_GW_LOG" | grep -cF "Write timing")
	[ "$wspan_n" -eq "$CYCLES" ] || fail "expected $CYCLES write spans on the server, got $wspan_n"
	zero_n=$(echo "$SERVER_GW_LOG" | grep -F "Write timing" | grep -c '"decideMicros": 0, "auditMicros": 0')
	[ "$zero_n" -eq "$CYCLES" ] || fail "expected $CYCLES zero-governance write spans on the server, got $zero_n"
	echo "OK: server: $wspan_n write spans, all with zero decide/audit"

	measure_rounds
	payload_sizes_server
	must_grep "persisted state files on the PVC" "$PAYLOAD_LISTING" -E "state files: [1-9]"

	step "disarm store-only"
	disable_store_only
	echo "[store-only] GATEWAY_STORE_ONLY removed from all four steward agents"
}

run_capture "$subdir" overhead-run "scripts/capture_e3_overhead.sh ${CONFIG} ${CYCLES}" "do_config_${CONFIG}" \
	"${EXP} config ${CONFIG} (${subdir#config-?-}): per-round latency + r2 + full logs, cycles=${CYCLES}"
