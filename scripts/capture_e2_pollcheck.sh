#!/usr/bin/env bash
set -u

# E2 degraded poll-only regime: ONE confirming trial with the gateway's watch
# disabled, showing the enforced DENY arrives within the 30s poll bound. This
# regime is argued from the bound (ticker interval + Get timeout); the single
# trial is confirmation, not a dataset.
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
# Usage: capture_e2_pollcheck.sh

root="$(cd "$(dirname "$0")/.." && pwd)"
results_dir="${E2_RESULTS_DIR:-$root/results/e2-policy-latency}"

USER_NAME="jake.jongejans@student.uva.nl"
GWPORT=50060
ETCD_LOCAL_PORT=30005          # fixed: config_local.go points the gateway at localhost:30005
ORCHPORT="${ORCHPORT:-8082}"
POLL_INTERVAL="${POLL_INTERVAL:-30}"
DENY_TIMEOUT="${DENY_TIMEOUT:-45}"   # a bit over the poll bound so a late tick is still caught
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

step() { echo; echo "=== $*"; }
fail() { echo "E2 FAIL: $*" >&2; exit 1; }

provenance() {
	echo "\$ date"; date; echo
	echo "\$ git rev-parse HEAD"; git -C "$root" rev-parse HEAD; echo
	echo "\$ git status --short"; git -C "$root" status --short; echo
	echo "\$ kubectl config current-context"; kubectl config current-context; echo
}

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

	step "flip allowed=false via /policyEnforcer; time the first enforced DENY"
	local code tflip tdeny attempt out ms
	code=$(flip_server false)
	tflip=$(date +%s.%N)
	[ "$code" = 200 ] || fail "flip PUT returned $code"
	echo "t_flip=$tflip (PUT allowed=false landed)"

	tdeny=""
	attempt=0
	while :; do
		out=$(gw_write)
		if echo "$out" | grep -q 'allowed = false'; then
			tdeny=$(date +%s.%N)
			break
		fi
		attempt=$((attempt + 1))
		# stop well after the poll bound so a miss is a real failure, not a short wait
		if python3 -c "import sys; sys.exit(0 if ($(date +%s.%N) - $tflip) > $DENY_TIMEOUT else 1)"; then
			fail "no enforced DENY within ${DENY_TIMEOUT}s (watch-disabled poll did not pick up the flip)"
		fi
		sleep 1
	done
	echo "t_deny=$tdeny (first write DENYd 'allowed = false' after $attempt ALLOW probes)"

	ms=$(python3 -c "print('%.1f' % (($tdeny - $tflip) * 1000))")
	echo
	echo "interval_ms=$ms   poll_bound_ms=$((POLL_INTERVAL * 1000))"
	python3 -c "
iv = $ms; bound = $POLL_INTERVAL * 1000
print('WITHIN POLL BOUND' if iv <= bound else 'EXCEEDED POLL BOUND')
import sys; sys.exit(0 if iv <= bound else 1)" || fail "DENY exceeded the poll bound"
	echo "regime: poll-only (watch disabled); argued from the ${POLL_INTERVAL}s bound, this single trial confirms it"

	step "raw gateway decision records (audit leg on the local state volume)"
	local audit="$state_dir/audit/audit.log"
	echo "baseline ALLOW: $(grep '"decision":"ALLOW"' "$audit" 2>/dev/null | grep '"stateClass":"e2_probe"' | head -1)"
	echo "enforced DENY:  $(grep '"decision":"DENY"' "$audit" 2>/dev/null | grep '"stateClass":"e2_probe"' | head -1)"
	echo "-- every e2_probe write decision, raw (ALLOW probes then the DENY; cacheAgeMs climbs toward the poll interval) --"
	grep '"op":"write"' "$audit" 2>/dev/null | grep '"stateClass":"e2_probe"'

	# Leave the agreement enabled.
	flip_server true >/dev/null
}

capture() {
	local ts out rc commit note
	ts="$(date +%Y%m%d-%H%M%S)"
	out="$results_dir/poll-spotcheck/${ts}_poll-only-deny.txt"
	mkdir -p "$(dirname "$out")"
	{ provenance; do_pollcheck; } 2>&1 | tee "$out"
	rc=${PIPESTATUS[0]}
	commit="$(git -C "$root" rev-parse --short HEAD)"
	note="E2 poll-only spot-check (watch disabled): flip to first enforced DENY within the ${POLL_INTERVAL}s poll bound, one confirming trial"
	[ "$rc" -ne 0 ] && note="$note; FAILED (exit=$rc)"
	echo "\`e2-policy-latency/poll-spotcheck/${ts}_poll-only-deny.txt | $ts | scripts/capture_e2_pollcheck.sh | $commit | $note\`" \
		>> "$results_dir/captures.md"
	echo
	echo "captured: $out (exit=$rc)"
	exit "$rc"
}

capture
