#!/usr/bin/env bash
set -u

# E2 policy-update latency (watch regime). Measures the interval from the moment
# an agreement flip lands via the /policyEnforcer operator path to the first
# enforced DENY on the aggregator's next RequestStateWrite.
#
# Two timestamps per trial, both on the host clock (kind shares it, so there is
# no skew):
#   t_flip: host time right after the PUT that sets allowed=false returns 200.
#   t_deny: the aggregator-side time of the first write the gateway DENYs with
#           reason "allowed = false".
# interval = t_deny - t_flip.
#
# The aggregator's writes are driven by a small persistent-channel writer run
# INSIDE the server pod's vfl-train-model-demo container: it reads the same
# identity env the MS uses and dials the in-pod gateway on localhost, so from
# the gateway's view these are the aggregator's own RequestStateWrites. A
# dedicated state class (e2_probe) keeps them off the real model checkpoint;
# the allowed flag is agreement-level, so the probe sees the same decision.
#
# One boot, N trials: each trial re-enables (PUT allowed=true), waits for the
# watch to redeliver ALLOW, then flips to allowed=false and times the first
# DENY. cycles is high enough that the gateway outlives all trials.
#
# Usage: capture_e2_latency.sh [trials]   (default CAMPAIGN_N)

EXP=E2
root="$(cd "$(dirname "$0")/.." && pwd)"
results_dir="${E2_RESULTS_DIR:-$root/results/campaign-n50/e2-policy-latency}"
. "$root/scripts/capture_lib.sh"

USER_NAME="jake.jongejans@student.uva.nl"
NS=server
MS_CONTAINER=vfl-train-model-demo
APIPORT="${APIPORT:-8080}"
ORCHPORT="${ORCHPORT:-8082}"
TRIALS="${1:-$CAMPAIGN_N}"
CYCLES="${CYCLES:-$(( TRIALS * 24 > 600 ? TRIALS * 24 : 600 ))}"  # chain lifetime: outlives all trials
DENY_TIMEOUT="${DENY_TIMEOUT:-35}"   # seconds to wait for the DENY (watch is sub-second; poll bound is 30s)
ALLOW_TIMEOUT="${ALLOW_TIMEOUT:-35}"
cfg_server="$root/configuration/etcd_launch_files/state_aware_server.json"

PIDS=()
WPID=""
writer_py=""
writer_log=""
# run_capture pipes the capture body through tee, so WPID/PIDS/writer_py are
# set in a subshell and are empty here: kill by pattern, not by pid.
cleanup() {
	[ -n "$WPID" ] && kill "$WPID" 2>/dev/null
	pkill -f "kubectl exec -i -n ${NS} .* -c ${MS_CONTAINER} --" 2>/dev/null
	local pod; pod=$(server_pod)
	[ -n "$pod" ] && kubectl exec -n "$NS" "$pod" -c "$MS_CONTAINER" -- pkill -f 'python3 -u -' 2>/dev/null
	for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done
	pkill -f "port-forward.*${ORCHPORT}:8080" 2>/dev/null
	pkill -f "port-forward.*${APIPORT}:8080" 2>/dev/null
	[ -n "$writer_py" ] && rm -f "$writer_py"
}
trap cleanup EXIT

server_pod() { kubectl get pods -n "$NS" -o name 2>/dev/null | grep jake | head -1 | cut -d/ -f2; }

# ---- boot + flip helpers -------------------------------------------------

wait_gateway_up() {
	local pod="" i
	for i in $(seq 1 30); do pod=$(server_pod); [ -n "$pod" ] && break; sleep 2; done
	[ -n "$pod" ] || fail "no server chain pod"
	for i in $(seq 1 40); do
		kubectl get pod "$pod" -n "$NS" -o jsonpath='{.status.containerStatuses[?(@.name=="policy-checkpoint-gateway")].state}' 2>/dev/null | grep -q running && break
		sleep 2
	done
	for i in $(seq 1 40); do
		kubectl get pod "$pod" -n "$NS" -o jsonpath='{.status.containerStatuses[?(@.name=="'"$MS_CONTAINER"'")].state}' 2>/dev/null | grep -q running && break
		sleep 2
	done
	echo "server pod: $pod" >&2
}

start_orch_forward() {
	pkill -f "port-forward.*${ORCHPORT}:8080" 2>/dev/null
	kubectl port-forward -n orchestrator svc/orchestrator "${ORCHPORT}:8080" >/dev/null 2>&1 &
	PIDS+=($!)
	sleep 3
}

# PUT the server agreement with allowed=$1 (true|false). Echoes the HTTP code.
flip_server() {
	local want="$1" tmp code
	tmp=$(mktemp)
	python3 -c "
import json
a = json.load(open('$cfg_server'))
a['relations']['$USER_NAME']['stateDirectives']['allowed'] = ('$want' == 'true')
print(json.dumps(a))" > "$tmp" || { rm -f "$tmp"; fail "flip json build failed"; }
	code=$(curl -s -o /dev/null -w '%{http_code}' -X PUT "http://localhost:${ORCHPORT}/api/v1/policyEnforcer" \
		-H 'Content-Type: application/json' --data-binary @"$tmp")
	rm -f "$tmp"
	echo "$code"
}

# ---- writer + parsing ----------------------------------------------------

start_writer() {
	writer_py=$(mktemp --suffix=.py)
	cat > "$writer_py" <<'PY'
import grpc, os, time, sys
import policyCheckpointGateway_pb2 as pb
import policyCheckpointGateway_pb2_grpc as pbg
port = os.environ.get("GATEWAY_PORT", "50050")
ch = grpc.insecure_channel("localhost:%s" % port)
try:
    grpc.channel_ready_future(ch).result(timeout=20)
except Exception as e:
    print("0 DIALFAIL %s" % e, flush=True); sys.exit(1)
stub = pbg.PolicyCheckpointGatewayStub(ch)
ident = pb.Identity(
    steward=os.environ["DATA_STEWARD_NAME"],
    user=os.environ["REQUEST_USER"],
    request_type=os.environ["REQUEST_TYPE"],
    job_id=os.environ["JOB_NAME"],
    local_job_name=os.environ["LOCAL_JOB_NAME"],
)
print("0 READY", flush=True)
while True:
    try:
        d = stub.RequestStateWrite(pb.StateWriteRequest(
            identity=ident, state_class="e2_probe", state_key="probe",
            payload=b"\x01\x02\x03"), timeout=10)
        t = time.time()
        print("%.6f %s %s" % (t, "ALLOW" if d.allowed else "DENY", d.reason), flush=True)
    except grpc.RpcError as e:
        t = time.time()
        print("%.6f ERR %s" % (t, e.code()), flush=True)
    time.sleep(0.01)
PY
	writer_log=$(mktemp)
	kubectl exec -i -n "$NS" "$(server_pod)" -c "$MS_CONTAINER" -- python3 -u - < "$writer_py" > "$writer_log" 2>&1 &
	WPID=$!
	local i
	for i in $(seq 1 30); do grep -q ' READY' "$writer_log" 2>/dev/null && return 0; sleep 1; done
	echo "--- writer log ---"; cat "$writer_log"
	fail "in-pod writer did not become READY"
}

# First epoch in $writer_log with the given decision ($1) at or after $2. Empty if none yet.
first_after() {
	python3 -c "
import sys
want, tmin, path = sys.argv[1], float(sys.argv[2]), sys.argv[3]
for line in open(path):
    p = line.split()
    if len(p) >= 2 and p[1] == want:
        ts = float(p[0])
        if ts >= tmin:
            print('%.6f' % ts); break
" "$1" "$2" "$writer_log"
}

wait_for() { # $1 decision, $2 tmin, $3 timeout -> echoes epoch or fails
	local want="$1" tmin="$2" to="$3" i n hit
	n=$((to * 5))
	for i in $(seq 1 "$n"); do
		hit=$(first_after "$want" "$tmin")
		[ -n "$hit" ] && { echo "$hit"; return 0; }
		sleep 0.2
	done
	return 1
}

# ---- measurement ---------------------------------------------------------

do_e2() {
	step "boot a governed chain (cycles=${CYCLES}) with allowed=true"
	reset_and_seed
	trigger "$CYCLES" >/dev/null
	wait_gateway_up
	start_orch_forward

	local pod
	pod=$(server_pod)

	step "start the in-pod aggregator writer (state_class=e2_probe)"
	start_writer
	local t0
	t0=$(date +%s.%N)
	wait_for ALLOW "$t0" "$ALLOW_TIMEOUT" >/dev/null || fail "writer never saw an ALLOW at allowed=true"
	echo "writer steady: ALLOW flowing"

	echo
	echo "trial,t_reenable,t_allow_confirmed,t_flip,t_deny,interval_ms,observe_ms,enforce_ms"
	local k code tput tflip ttrue tallow tdeny ms gwmark denyline tobs obs_ms enf_ms
	local intervals=() observes=()
	for k in $(seq 1 "$TRIALS"); do
		# Independence: re-enable (PUT allowed=true) and wait for a confirmed ALLOW
		# from the writer before this trial's flip. Trial 1 is already at true.
		ttrue=$(date +%s.%N)
		code=$(flip_server true)
		[ "$code" = 200 ] || fail "re-enable PUT returned $code (trial $k)"
		tallow=$(wait_for ALLOW "$ttrue" "$ALLOW_TIMEOUT") || fail "no confirmed ALLOW after re-enable (trial $k)"
		sleep 1

		# Mark the gateway audit stream so we can pull this trial's DENY record.
		gwmark=$(kubectl logs -n "$NS" "$pod" -c policy-checkpoint-gateway 2>/dev/null | wc -l)

		# Flip to allowed=false; t_flip is the moment the PUT lands. The watch
		# can deliver before the PUT returns, so the observation lookup below
		# thresholds at PUT initiation instead of t_flip.
		tput=$(date +%s.%N)
		code=$(flip_server false)
		tflip=$(date +%s.%N)
		[ "$code" = 200 ] || fail "flip PUT returned $code (trial $k)"

		tdeny=$(wait_for DENY "$tflip" "$DENY_TIMEOUT") || fail "no enforced DENY within ${DENY_TIMEOUT}s (trial $k)"
		ms=$(python3 -c "print('%.1f' % (($tdeny - $tflip) * 1000))")

		# Split the interval at the gateway's own observation of the flip (the
		# zap "Agreement changed" line, epoch-stamped on the shared host clock).
		tobs=$(kubectl logs -n "$NS" "$pod" -c policy-checkpoint-gateway 2>/dev/null \
			| tail -n +$((gwmark + 1)) | grep "Agreement changed" \
			| awk -v t="$tput" '$1 >= t {print $1; exit}')
		obs_ms=""; enf_ms=""
		if [ -n "$tobs" ]; then
			obs_ms=$(python3 -c "print('%.1f' % (($tobs - $tflip) * 1000))")
			enf_ms=$(python3 -c "print('%.1f' % (($tdeny - $tobs) * 1000))")
			observes+=("$obs_ms")
		fi
		echo "$k,$ttrue,$tallow,$tflip,$tdeny,$ms,$obs_ms,$enf_ms"
		intervals+=("$ms")

		# Raw gateway decision record for this trial's first probe DENY: the audit
		# NDJSON carries agreementHash, policySource, cacheAgeMs. --timestamps adds
		# the kubelet time; tail past the mark keeps earlier trials' DENYs out.
		denyline=$(kubectl logs -n "$NS" "$pod" -c policy-checkpoint-gateway --timestamps 2>/dev/null \
			| tail -n +$((gwmark + 1)) | grep '"decision":"DENY"' | grep '"stateClass":"e2_probe"' | head -1)
		echo "  gateway DENY record: ${denyline:-<not found>}"
	done

	# Leave the agreement enabled.
	flip_server true >/dev/null

	echo
	echo "flip -> first enforced DENY:"
	printf '%s\n' "${intervals[@]}" | summarize_series ms
	if [ "${#observes[@]}" -gt 0 ]; then
		echo "flip -> watch-observed (Agreement changed line), ${#observes[@]}/${TRIALS} trials:"
		printf '%s\n' "${observes[@]}" | summarize_series ms
	fi
	echo "regime: watch-delivered (gateway watch on /policyEnforcer/agreements/server active)"
	echo "note: writer cadence 10ms bounds the resolution; state_class=e2_probe does not touch vfl_server_model"
	echo "note: observe_ms is flip to the gateway's Agreement-changed log line; enforce_ms is that line to the first DENY"
	echo "note: observe_ms can be negative: t_flip is stamped after the PUT returns, and the watch can deliver inside the PUT round trip"
}

run_capture watch-regime flip-to-first-deny "scripts/capture_e2_latency.sh ${TRIALS}" do_e2 \
	"E2 watch-regime: flip via /policyEnforcer PUT to first enforced DENY on the aggregator's next write, ${TRIALS} trials"
