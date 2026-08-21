#!/usr/bin/env bash
set -u

# E6 revocation-to-purge latency, both arms, saving raw output under
# results/e6-purge-latency/ and appending to that experiment's captures.md.
#
#   latency    flip -> purge-complete against a standalone long-lived gateway
#              pod (the frozen chain-gateway image, in-cluster etcd path,
#              watch regime), N trials (default 10). The live VFL chain
#              cannot host these trials: the purge advisory makes the MS drop
#              its in-memory model mid-round, the round aborts, and the
#              api-gateway then shuts the whole chain down (observed on the
#              first shakedown, three trials in). A grpcurl probe write per
#              trial confirms the re-enable and recreates the purge target.
#              Timing: t_flip is stamped BEFORE the flip PUT is sent (the
#              purge completes faster than the PUT's HTTP round trip returns,
#              so a post-PUT stamp yields negative intervals); the interval
#              therefore measures operator-action-initiation -> destruction
#              complete and upper-bounds the etcd-commit -> purge gap. The
#              PUT round-trip time is reported per trial so the bound's slack
#              is visible. t_purge is the gateway's own sweep-completion log
#              line (zap epoch, host clock; kind shares it).
#              The flip -> first-DENY side is E2's capture; cited, not
#              re-measured here.
#   staleness  the induced-staleness arm on a locally built gateway whose
#              etcd connection runs through a killable port-forward, so the
#              outage touches nothing else. Poll-only regime for determinism.
#              Sequence: baseline ALLOW write (blob on the scratch state dir)
#              -> kill the forward (outage) -> cache ages, writes DENY
#              "cache stale; fail closed" with cache_age_ms rising -> flip
#              allowed=false while the gateway cannot see it -> hold: the
#              blob MUST survive (no destruction on a non-fresh view) ->
#              restore the forward (recovery) -> the next poll observes the
#              revocation, confirms fresh, and the purge completes:
#              op=purge PURGED policySource=fresh; recovery->purge is
#              bounded by one poll interval plus the confirming Get.
#
# What the staleness arm does NOT show, stated here so the capture is not
# over-read: the per-reconsideration DEFERRED audit line requires the
# confirming Get to fail milliseconds after a successful observation of the
# revoked view. That interleaving is not stageable from outside the process
# and is covered by the unit oracle (TestSweepDefersWhenConfirmFails in the
# counted E1 bufconn capture). The live claims here are: nothing is destroyed
# while the view is non-fresh, staleness is visible and fail-closed, and the
# deferred purge completes fresh on recovery.
#
# Usage: capture_e6_purge_latency.sh [latency [trials]|staleness|all]
# Default is all (latency CAMPAIGN_N trials, then staleness).
#
# E6 measures latency: run it on a QUIET machine (no builds, no heavy loads),
# like E2/E3 and unlike the correctness experiments.
#
# Needs the fork images in kind (dev-loop.md imageID check) and grpcurl.
# Neither arm needs reset.sh or a running chain; both leave the server
# agreement seeded canonical (allowed=true).

EXP=E6
root="$(cd "$(dirname "$0")/.." && pwd)"
results_dir="${E6_RESULTS_DIR:-$root/results/e6-purge-latency}"
. "$root/scripts/capture_lib.sh"

USER_NAME="jake.jongejans@student.uva.nl"
NS=server
ORCHPORT="${ORCHPORT:-8082}"
TRIALS=$CAMPAIGN_N
PURGE_TIMEOUT="${PURGE_TIMEOUT:-35}"   # watch is sub-second; 30s poll is the fallback bound
ALLOW_TIMEOUT="${ALLOW_TIMEOUT:-35}"
cfg_server="$root/configuration/etcd_launch_files/state_aware_server.json"

# latency-arm knobs (standalone gateway pod)
GW_POD=e6-gateway
GW_IMAGE="docker.io/tamjiyan/policy-checkpoint-gateway:latest"
GWPORT_POD=50062

# staleness-arm knobs (local gateway)
GWPORT_LOCAL=50061
ETCD_LOCAL_PORT=30005                # fixed: config_local.go points the gateway here
POLL_INTERVAL="${POLL_INTERVAL:-5}"
MAX_STALE="${MAX_STALE:-20}"
RECOVERY_TIMEOUT=$((POLL_INTERVAL + 15))
IDENTITY_POD='{"steward":"SERVER","user":"'"$USER_NAME"'","request_type":"vflTrainModelRequest","job_id":"e6-latency","local_job_name":"e6-latency"}'
IDENTITY_LOCAL='{"steward":"SERVER","user":"'"$USER_NAME"'","request_type":"vflTrainModelRequest","job_id":"e6-staleness","local_job_name":"e6-staleness"}'

PIDS=()
GWPID=""
ETCD_PF_PID=""
scratch=""
cleanup() {
	[ -n "$GWPID" ] && kill "$GWPID" 2>/dev/null
	[ -n "$ETCD_PF_PID" ] && kill "$ETCD_PF_PID" 2>/dev/null
	for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done
	pkill -f "port-forward.*${ETCD_LOCAL_PORT}:2379" 2>/dev/null
	kubectl delete pod "$GW_POD" -n "$NS" --ignore-not-found=true --wait=false 2>/dev/null
	[ -n "$scratch" ] && rm -rf "$scratch"
}
trap cleanup EXIT

start_orch_forward() {
	pkill -f "port-forward.*${ORCHPORT}:8080" 2>/dev/null
	kubectl port-forward -n orchestrator svc/orchestrator "${ORCHPORT}:8080" >/dev/null 2>&1 &
	PIDS+=($!)
	sleep 3
}

# PUT the server agreement with allowed=$1 (true|false). Echoes the HTTP code.
# The canonical seed already carries onRevocation=purge, so allowed=false IS
# the revocation that prescribes destruction.
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

# ---- latency arm: standalone gateway pod ---------------------------------

gw_pod_log() { kubectl logs -n "$NS" "$GW_POD" -c "$GW_POD" 2>/dev/null; }

# First "Purged N state files" zap line past line-mark $1; echoes its epoch.
purge_epoch_after_mark() {
	gw_pod_log | tail -n +"$(($1 + 1))" | grep "Purged .* state files under revoked agreement" | head -1 \
		| python3 -c "
import sys
line = sys.stdin.read().split()
if line:
    print('%.6f' % float(line[0]))"
}

wait_for_purge() { # $1 mark, $2 timeout -> epoch or fail
	local i hit
	for i in $(seq 1 $(( $2 * 5 ))); do
		hit=$(purge_epoch_after_mark "$1")
		[ -n "$hit" ] && { echo "$hit"; return 0; }
		sleep 0.2
	done
	return 1
}

gw_probe_write() {
	grpcurl -plaintext -import-path "$root/proto-files" -proto policyCheckpointGateway.proto \
		-d "{\"identity\":${IDENTITY_POD},\"state_key\":\"probe\",\"state_class\":\"e6_probe\",\"payload\":\"AQID\"}" \
		"localhost:${GWPORT_POD}" dynamos.PolicyCheckpointGateway/RequestStateWrite 2>&1
}

# Probe-write until the decision is ALLOW: confirms the re-grant was observed
# and recreates the purge target. Echoes nothing; fails on timeout.
wait_probe_allow() {
	local i out
	for i in $(seq 1 $((ALLOW_TIMEOUT * 2))); do
		out=$(gw_probe_write)
		echo "$out" | grep -q '"allowed": true' && return 0
		sleep 0.5
	done
	echo "$out"
	return 1
}

do_latency() {
	step "standalone gateway pod: the frozen image, in-cluster etcd path, no chain to disturb"
	kubectl delete pod "$GW_POD" -n "$NS" --ignore-not-found=true --wait=true
	start_orch_forward
	[ "$(flip_server true)" = 200 ] || fail "seed PUT failed"

	# IfNotPresent: kubectl run defaults :latest to Always, which would pull
	# from the registry instead of using the kind-loaded image.
	kubectl run "$GW_POD" -n "$NS" --image="$GW_IMAGE" --restart=Never \
		--image-pull-policy=IfNotPresent \
		--env=DATA_STEWARD_NAME=SERVER --env=REQUEST_USER="$USER_NAME" \
		--env=REQUEST_TYPE=vflTrainModelRequest --env=JOB_NAME=e6-latency \
		--env=LOCAL_JOB_NAME=e6-latency --env=GATEWAY_PORT=50050 \
		--env=STATE_DIR=/tmp/state || fail "gateway pod create failed"
	local i
	for i in $(seq 1 60); do
		kubectl get pod "$GW_POD" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Running && break
		sleep 2
	done
	for i in $(seq 1 30); do
		gw_pod_log | grep -q "Serving on 50050" && break
		sleep 1
	done
	gw_pod_log | grep -q "Serving on 50050" || { gw_pod_log | tail -5; fail "gateway pod did not start serving"; }
	echo "gateway pod up:"
	gw_pod_log | grep -E "Serving on|Agreement loaded" | sed 's/^/    /'

	pkill -f "port-forward.*${GWPORT_POD}:50050" 2>/dev/null
	kubectl port-forward -n "$NS" "pod/$GW_POD" "${GWPORT_POD}:50050" >/dev/null 2>&1 &
	PIDS+=($!)
	sleep 3

	step "baseline: probe write must ALLOW and create the purge target"
	wait_probe_allow || fail "baseline probe write never ALLOWed"
	echo "baseline: ALLOW, blob present"

	echo
	echo "trial,t_put_start,t_put_returned,t_purge,flip_to_purge_ms,put_rtt_ms,purge_records"
	local k code tstart tret tpurge p_ms rtt_ms gwmark nrec out
	local purge_ms=()
	for k in $(seq 1 "$TRIALS"); do
		# Independence: re-enable and confirm via an ALLOWed probe write, which
		# also recreates the blob this trial's flip will destroy.
		code=$(flip_server true)
		[ "$code" = 200 ] || fail "re-enable PUT returned $code (trial $k)"
		wait_probe_allow || fail "no confirmed ALLOW after re-enable (trial $k)"
		sleep 0.5

		gwmark=$(gw_pod_log | wc -l)

		tstart=$(date +%s.%N)
		code=$(flip_server false)
		tret=$(date +%s.%N)
		[ "$code" = 200 ] || fail "flip PUT returned $code (trial $k)"

		tpurge=$(wait_for_purge "$gwmark" "$PURGE_TIMEOUT") || fail "no purge completion within ${PURGE_TIMEOUT}s (trial $k)"
		p_ms=$(python3 -c "print('%.1f' % (($tpurge - $tstart) * 1000))")
		rtt_ms=$(python3 -c "print('%.1f' % (($tret - $tstart) * 1000))")
		nrec=$(gw_pod_log | tail -n +$((gwmark + 1)) | grep -c '"op":"purge".*"decision":"PURGED"')
		echo "$k,$tstart,$tret,$tpurge,$p_ms,$rtt_ms,$nrec"
		purge_ms+=("$p_ms")
		echo "  purge records this trial:"
		gw_pod_log | tail -n +$((gwmark + 1)) | grep '"op":"purge"' | head -3 | sed 's/^/    /'
		# Post-purge sanity, not a latency claim: the next write must DENY.
		out=$(gw_probe_write)
		echo "$out" | grep -q 'allowed = false' || { echo "$out"; fail "post-purge write did not DENY (trial $k)"; }
		echo "  post-purge probe write: DENY 'allowed = false'"
	done

	flip_server true >/dev/null

	echo
	echo "flip -> purge-complete (from PUT initiation; includes the PUT round trip shown per trial):"
	printf '%s\n' "${purge_ms[@]}" | summarize_series ms
	echo "regime: watch-delivered; the flip -> first-DENY side is E2's capture (watch-regime, 10 trials)"
	echo "note: t_purge is the gateway's own sweep-completion log timestamp; the state dir is pod-local"
	echo "note: purge-record count covers the probe blob (and nothing else in this pod)"

	kubectl delete pod "$GW_POD" -n "$NS" --ignore-not-found=true --wait=false
}

block_latency() {
	run_capture watch-regime flip-to-purge-complete "scripts/capture_e6_purge_latency.sh latency ${TRIALS}" do_latency \
		"E6 watch-regime: flip via /policyEnforcer PUT (stamped at initiation) to purge-complete on a standalone gateway pod, ${TRIALS} trials"
}

# ---- staleness arm: local gateway, killable etcd forward -----------------

start_etcd_forward() {
	kubectl port-forward -n core etcd-0 "${ETCD_LOCAL_PORT}:2379" >/dev/null 2>&1 &
	ETCD_PF_PID=$!
	sleep 3
}

stop_etcd_forward() {
	[ -n "$ETCD_PF_PID" ] && kill "$ETCD_PF_PID" 2>/dev/null
	ETCD_PF_PID=""
	pkill -f "port-forward.*${ETCD_LOCAL_PORT}:2379" 2>/dev/null
	sleep 1
}

gw_write_local() {
	grpcurl -plaintext -import-path "$root/proto-files" -proto policyCheckpointGateway.proto \
		-d "{\"identity\":${IDENTITY_LOCAL},\"state_key\":\"probe\",\"state_class\":\"e6_probe\",\"payload\":\"AQID\"}" \
		"localhost:${GWPORT_LOCAL}" dynamos.PolicyCheckpointGateway/RequestStateWrite 2>&1
}

do_staleness() {
	scratch=$(mktemp -d)
	local gw_bin="$scratch/gw" state_dir="$scratch/state" gw_log="$scratch/gw.log"
	local blob="$state_dir/data/e6_probe/probe.bin" audit="$state_dir/audit/audit.log"
	mkdir -p "$state_dir"

	step "build the gateway (-tags local); etcd through a killable port-forward"
	( cd "$root/go" && go build -tags local -o "$gw_bin" ./cmd/policy-checkpoint-gateway/ ) || fail "gateway build failed"
	start_etcd_forward
	start_orch_forward

	step "seed the server agreement allowed=true (canonical carries onRevocation=purge)"
	[ "$(flip_server true)" = 200 ] || fail "seed PUT failed"

	step "run the local gateway: poll-only every ${POLL_INTERVAL}s, staleness bound ${MAX_STALE}s"
	DATA_STEWARD_NAME=SERVER REQUEST_USER="$USER_NAME" REQUEST_TYPE=vflTrainModelRequest \
		JOB_NAME=e6-staleness LOCAL_JOB_NAME=e6-staleness GATEWAY_PORT="$GWPORT_LOCAL" \
		STATE_DIR="$state_dir" AGREEMENT_POLL_INTERVAL_SECONDS="$POLL_INTERVAL" \
		AGREEMENT_WATCH_DISABLED=true MAX_AGREEMENT_STALENESS_SECONDS="$MAX_STALE" \
		"$gw_bin" > "$gw_log" 2>&1 &
	GWPID=$!
	local i
	for i in $(seq 1 30); do grep -q "Serving on ${GWPORT_LOCAL}" "$gw_log" 2>/dev/null && break; sleep 1; done
	grep -q "Serving on ${GWPORT_LOCAL}" "$gw_log" || { echo "--- gateway log ---"; cat "$gw_log"; fail "gateway did not start serving"; }

	step "baseline: ALLOW write puts the blob on the state dir"
	local out
	out=$(gw_write_local)
	echo "$out" | grep -q '"allowed": true' || { echo "$out"; fail "baseline write did not ALLOW"; }
	[ -f "$blob" ] || fail "probe blob missing after ALLOW write"
	echo "baseline: ALLOW, blob present"

	step "outage: kill the etcd forward; the cache must age to stale and writes must fail closed"
	local t_outage t_stale
	t_outage=$(date +%s.%N)
	stop_etcd_forward
	t_stale=""
	while :; do
		out=$(gw_write_local)
		if echo "$out" | grep -q 'cache stale; fail closed'; then
			t_stale=$(date +%s.%N)
			break
		fi
		python3 -c "import sys; sys.exit(0 if ($(date +%s.%N) - $t_outage) > $((MAX_STALE + POLL_INTERVAL + 15)) else 1)" \
			&& fail "no stale DENY within $((MAX_STALE + POLL_INTERVAL + 15))s of the outage"
		sleep 1
	done
	echo "stale DENY after $(python3 -c "print('%.1f' % ($t_stale - $t_outage))")s of outage (bound ${MAX_STALE}s + last-poll age)"
	echo "last stale record: $(grep '"reason":"cache stale; fail closed"' "$audit" | tail -1)"

	step "flip allowed=false during the outage; the gateway cannot observe it"
	[ "$(flip_server false)" = 200 ] || fail "flip PUT failed (cluster etcd should be unaffected)"
	local t_flip
	t_flip=$(date +%s.%N)
	echo "t_flip=$t_flip (revocation pending in etcd, unobserved by the gateway)"

	step "hold through the outage: nothing may be destroyed on a non-fresh view"
	sleep $((POLL_INTERVAL * 2))
	[ -f "$blob" ] || fail "blob destroyed during the outage: non-fresh destruction is a safety violation"
	grep -q '"decision":"PURGED"' "$audit" && fail "purge record during the outage"
	grep -q "Purged" "$gw_log" && fail "purge sweep ran during the outage"
	echo "OK: blob intact through the outage; no purge records; writes failing closed stale"
	echo "cache_age_ms rising: $(grep '"reason":"cache stale; fail closed"' "$audit" | tail -1 \
		| python3 -c "import sys, json; print(json.load(sys.stdin).get('cacheAgeMs'))")"

	step "recovery: restore the etcd forward; the deferred purge must complete fresh within one poll bound"
	local t_recover t_purge
	start_etcd_forward
	t_recover=$(date +%s.%N)
	t_purge=""
	for i in $(seq 1 $((RECOVERY_TIMEOUT * 5))); do
		if grep -q "Purged .* state files under revoked agreement" "$gw_log"; then
			t_purge=$(grep "Purged .* state files under revoked agreement" "$gw_log" | head -1 \
				| python3 -c "import sys; print('%.6f' % float(sys.stdin.read().split()[0]))")
			break
		fi
		sleep 0.2
	done
	[ -n "$t_purge" ] || { echo "--- gateway log tail ---"; tail -20 "$gw_log"; fail "no purge within ${RECOVERY_TIMEOUT}s of recovery"; }
	echo "recovery -> purge-complete: $(python3 -c "print('%.1f ms' % (($t_purge - $t_recover) * 1000))") (bound: ${POLL_INTERVAL}s poll + confirming Get)"

	[ -f "$blob" ] && fail "blob still present after the recovered purge"
	local must_line
	must_line=$(grep '"op":"purge"' "$audit" | grep '"decision":"PURGED"' | head -1)
	[ -n "$must_line" ] || fail "no PURGED audit record"
	echo "$must_line" | grep -q '"policySource":"fresh"' || fail "purge record not confirmed-fresh"
	echo "purge record: $must_line"
	echo
	echo "cache_age_ms trajectory: rose through the outage (stale DENY records), closed to a confirmed-fresh purge"
	echo "note: the per-reconsideration DEFERRED line needs a confirm failure milliseconds after a"
	echo "successful observation; not stageable externally, unit-proven (TestSweepDefersWhenConfirmFails)."

	flip_server true >/dev/null
	kill "$GWPID" 2>/dev/null; GWPID=""
}

block_staleness() {
	run_capture induced-staleness outage-defer-recover-purge "scripts/capture_e6_purge_latency.sh staleness" do_staleness \
		"E6 induced staleness: outage -> stale fail-closed writes, no destruction on non-fresh, flip unobserved; recovery -> confirmed-fresh purge within one poll bound"
}

# --- main -----------------------------------------------------------------

which="${1:-all}"
case "$which" in
latency)
	TRIALS="${2:-$CAMPAIGN_N}"
	block_latency
	;;
staleness) block_staleness ;;
all)
	block_latency
	block_staleness
	;;
*) echo "usage: $0 [latency [trials]|staleness|all]" >&2; exit 2 ;;
esac
