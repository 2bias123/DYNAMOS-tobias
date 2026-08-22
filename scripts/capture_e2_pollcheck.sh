#!/usr/bin/env bash
set -u

# E2 degraded poll-only regime: N trials with the gateway's watch disabled,
# timing each agreement flip to the first enforced DENY. The regime is argued
# from the bound (ticker interval + Get timeout); the trials show how the
# interval distributes over the tick phase. The probe writer runs at 1s
# cadence, so each interval carries up to ~1s of probe lag on top of the
# phase; the gateway's own observation of the flip (its Agreement-changed
# line) is the pure bound check.
#
# The watch is disabled by AGREEMENT_WATCH_DISABLED=true, so the only path from
# an agreement flip to enforcement is the gateway's periodic re-Get. To set that
# env without touching a chain Job, the script runs a locally-built (-tags local)
# gateway against the cluster etcd (port-forwarded to localhost:30005, the
# address config_local.go expects), with the server aggregator's identity and a
# scratch state dir. A grpcurl writer drives the aggregator's RequestStateWrite.
#
# Fully self-contained and reproducible: it builds the gateway, seeds the server
# agreement (allowed=true) via the /policyEnforcer operator path, port-forwards
# etcd and the orchestrator, runs the gateway, drives the trial, and tears
# everything down. Assumes the kind cluster and orchestrator are up.
#
# Usage: capture_e2_pollcheck.sh [trials]   (default CAMPAIGN_N)

EXP=E2
root="$(cd "$(dirname "$0")/.." && pwd)"
results_dir="${E2_RESULTS_DIR:-$root/results/campaign-n50/e2-policy-latency}"
. "$root/scripts/capture_lib.sh"

USER_NAME="jake.jongejans@student.uva.nl"
GWPORT=50060
ETCD_LOCAL_PORT=30005          # fixed: config_local.go points the gateway at localhost:30005
ORCHPORT="${ORCHPORT:-8082}"
POLL_INTERVAL="${POLL_INTERVAL:-30}"
DENY_TIMEOUT="${DENY_TIMEOUT:-45}"   # a bit over the poll bound so a late tick is still caught
TRIALS="${1:-$CAMPAIGN_N}"
cfg_server="$root/configuration/etcd_launch_files/state_aware_server.json"

IDENTITY='{"steward":"SERVER","user":"'"$USER_NAME"'","request_type":"vflTrainModelRequest","job_id":"e2-pollcheck","local_job_name":"e2-pollcheck"}'

PIDS=()
GWPID=""
scratch=""
cleanup() {
	[ -n "$GWPID" ] && kill "$GWPID" 2>/dev/null
	for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done
	pkill -f "port-forward.*${ETCD_LOCAL_PORT}:2379" 2>/dev/null
	[ -n "$scratch" ] && rm -rf "$scratch"
}
trap cleanup EXIT

gw_write() {
	grpcurl -plaintext -import-path "$root/proto-files" -proto policyCheckpointGateway.proto \
		-d "{\"identity\":${IDENTITY},\"state_key\":\"probe\",\"state_class\":\"e2_probe\",\"payload\":\"AQID\"}" \
		"localhost:${GWPORT}" dynamos.PolicyCheckpointGateway/RequestStateWrite 2>&1
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

do_pollcheck() {
	scratch=$(mktemp -d)
	local gw_bin="$scratch/gw" state_dir="$scratch/state" gw_log="$scratch/gw.log"
	mkdir -p "$state_dir"

	step "build the gateway (-tags local) and wire up etcd + orchestrator"
	( cd "$root/go" && go build -tags local -o "$gw_bin" ./cmd/policy-checkpoint-gateway/ ) || fail "gateway build failed"
	kubectl port-forward -n core etcd-0 "${ETCD_LOCAL_PORT}:2379" >/dev/null 2>&1 &
	PIDS+=($!)
	pkill -f "port-forward.*${ORCHPORT}:8080" 2>/dev/null
	kubectl port-forward -n orchestrator svc/orchestrator "${ORCHPORT}:8080" >/dev/null 2>&1 &
	PIDS+=($!)
	sleep 4

	step "seed the server agreement allowed=true via /policyEnforcer"
	[ "$(flip_server true)" = 200 ] || fail "seed PUT failed"

	step "run the local gateway with the watch disabled (poll interval ${POLL_INTERVAL}s)"
	DATA_STEWARD_NAME=SERVER REQUEST_USER="$USER_NAME" REQUEST_TYPE=vflTrainModelRequest \
		JOB_NAME=e2-pollcheck LOCAL_JOB_NAME=e2-pollcheck GATEWAY_PORT="$GWPORT" \
		STATE_DIR="$state_dir" AGREEMENT_POLL_INTERVAL_SECONDS="$POLL_INTERVAL" \
		AGREEMENT_WATCH_DISABLED=true "$gw_bin" > "$gw_log" 2>&1 &
	GWPID=$!
	local i
	for i in $(seq 1 30); do grep -q "Serving on ${GWPORT}" "$gw_log" 2>/dev/null && break; sleep 1; done
	grep -q "Serving on ${GWPORT}" "$gw_log" || { echo "--- gateway log ---"; cat "$gw_log"; fail "gateway did not start serving"; }
	grep -q "watch disabled" "$gw_log" || fail "gateway did not report the poll-only regime"
	echo "gateway up (poll-only):"
	grep -E "Serving on|Agreement loaded|watch disabled" "$gw_log" | sed 's/^/    /'

	step "baseline write must ALLOW (allowed=true, agreement loaded)"
	local base
	base=$(gw_write)
	echo "$base" | grep -q '"allowed": true' || { echo "$base"; fail "baseline write did not ALLOW"; }
	echo "baseline: ALLOW"

	step "${TRIALS} trials: flip allowed=false, time the first enforced DENY under the ${POLL_INTERVAL}s poll bound"
	echo "trial,t_reenable,t_allow,t_flip,t_deny,interval_ms,observe_ms"
	local k code ttrue tallow tput tflip tdeny out ms gwmark tobs obs_ms
	local intervals=() observes=()
	for k in $(seq 1 "$TRIALS"); do
		# Independence: re-enable and wait for a poll tick to redeliver ALLOW.
		ttrue=$(date +%s.%N)
		[ "$(flip_server true)" = 200 ] || fail "re-enable PUT failed (trial $k)"
		while :; do
			out=$(gw_write)
			echo "$out" | grep -q '"allowed": true' && break
			python3 -c "import sys; sys.exit(0 if ($(date +%s.%N) - $ttrue) > $DENY_TIMEOUT else 1)" \
				&& fail "no ALLOW after re-enable within ${DENY_TIMEOUT}s (trial $k)"
			sleep 1
		done
		tallow=$(date +%s.%N)

		gwmark=$(wc -l < "$gw_log")
		tput=$(date +%s.%N)
		code=$(flip_server false)
		tflip=$(date +%s.%N)
		[ "$code" = 200 ] || fail "flip PUT returned $code (trial $k)"
		tdeny=""
		while :; do
			out=$(gw_write)
			if echo "$out" | grep -q 'allowed = false'; then
				tdeny=$(date +%s.%N)
				break
			fi
			python3 -c "import sys; sys.exit(0 if ($(date +%s.%N) - $tflip) > $DENY_TIMEOUT else 1)" \
				&& fail "no enforced DENY within ${DENY_TIMEOUT}s (trial $k: the poll did not pick up the flip)"
			sleep 1
		done
		ms=$(python3 -c "print('%.1f' % (($tdeny - $tflip) * 1000))")
		# The writer's probe cadence rides on top of the tick phase, so the
		# interval check carries probe slack; the gateway-side observation
		# below is the strict bound.
		python3 -c "import sys; sys.exit(0 if $ms <= $POLL_INTERVAL * 1000 + 2000 else 1)" \
			|| fail "DENY outside the poll bound plus probe slack (trial $k: ${ms} ms)"
		tobs=$(tail -n +$((gwmark + 1)) "$gw_log" | grep "Agreement changed" \
			| awk -v t="$tput" '$1 >= t {print $1; exit}')
		obs_ms=""
		if [ -n "$tobs" ]; then
			obs_ms=$(python3 -c "print('%.1f' % (($tobs - $tflip) * 1000))")
			python3 -c "import sys; sys.exit(0 if $obs_ms <= $POLL_INTERVAL * 1000 + 2500 else 1)" \
				|| fail "gateway observed the flip outside the poll bound (trial $k: ${obs_ms} ms)"
			observes+=("$obs_ms")
		fi
		echo "$k,$ttrue,$tallow,$tflip,$tdeny,$ms,$obs_ms"
		intervals+=("$ms")
	done

	echo
	echo "flip -> first enforced DENY (bound ${POLL_INTERVAL}s + 1s probe cadence):"
	printf '%s\n' "${intervals[@]}" | summarize_series ms
	if [ "${#observes[@]}" -gt 0 ]; then
		echo "flip -> poll-observed (Agreement changed line, strict bound), ${#observes[@]}/${TRIALS} trials:"
		printf '%s\n' "${observes[@]}" | summarize_series ms
	fi
	echo "regime: poll-only (watch disabled); the interval is the phase of the ${POLL_INTERVAL}s tick plus probe lag"

	step "raw gateway decision records (audit leg on the local state volume)"
	local audit="$state_dir/audit/audit.log"
	echo "-- every e2_probe write decision, raw (per-trial ALLOW probes then the DENY; cacheAgeMs climbs toward the poll interval) --"
	grep '"op":"write"' "$audit" 2>/dev/null | grep '"stateClass":"e2_probe"'

	# Leave the agreement enabled.
	flip_server true >/dev/null
}

run_capture poll-regime poll-only-deny "scripts/capture_e2_pollcheck.sh ${TRIALS}" do_pollcheck \
	"E2 poll-only regime (watch disabled): flip to first enforced DENY, ${TRIALS} trials under the ${POLL_INTERVAL}s poll bound"
