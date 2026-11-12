#!/usr/bin/env bash
set -u

# E6 revocation-to-purge latency, both arms, saving raw output under
# results/campaign-n50/e6-purge-latency/ and appending to that experiment's captures.md.
#
#   latency    flip -> purge-complete against a standalone long-lived gateway
#              pod (the frozen chain-gateway image, in-cluster etcd path,
#              watch regime), N trials (default 10). The live VFL chain
#              cannot host these trials: the purge advisory makes the MS drop
#              its in-memory model mid-round, the round aborts, and the
#              api-gateway then shuts the whole chain down (observed on the
#              first shakedown, three trials in). A grpcurl probe write per
#              trial confirms the re-enable and recreates the purge target.
#              Timing: a trial starts when curl sends the flip PUT (a host
#              stamp immediately before curl plus curl's pre-transfer time;
#              the body is built before the stamp) and ends at the decision
#              time of the probe blob's PURGED record (decidedUnixMicros, set
#              when the record is appended, so before the unlink; the pod's
#              clock, which kind shares with the host). The purge completes
#              faster than the PUT's HTTP round trip returns, so the PUT's
#              return is stamped and its round-trip time reported per trial.
#              The flip -> first-DENY side is E2's capture; cited, not
#              re-measured here. Each trial also splits the interval at the
#              gateway's Agreement-changed line (delivery vs sweep) and
#              prints the Purge-sweep-timing spans (confirm vs unlink).
#   poll-control  the same trials with the watch disabled at a short poll
#              interval (CONTROL_POLL_INTERVAL, default 5s): the
#              interval-tracking control for the latency-clustering
#              question — if clustering follows the update interval, it
#              must show here as spread over the tick phase.
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
#              op=purge PURGED policySource=fresh. Five episodes per run,
#              each with its own gateway and state dir. The time from
#              recovery to the purge is reported per episode and not
#              asserted; an episode without a purge within 120s ends as
#              failed. Each episode's gateway log and audit log are kept
#              beside the artifact.
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
# Usage: capture_e6_purge_latency.sh [latency [trials]|poll-control [trials]|staleness|all]
# Default is all (latency, then poll-control, CAMPAIGN_N trials each, then
# staleness).
#
# E6 measures latency: run it on a QUIET machine (no builds, no heavy loads),
# like E2/E3 and unlike the correctness experiments.
#
# Needs the fork images in kind (dev-loop.md imageID check) and grpcurl.
# Neither arm needs a running chain; both leave the server agreement seeded
# canonical (allowed=true). Every arm DELETES the four state PVCs first, so
# its flips cannot act on state an idle gateway holds; run reset.sh before
# if a finished chain job's pod still holds one.

EXP=E6
root="$(cd "$(dirname "$0")/.." && pwd)"
results_dir="${E6_RESULTS_DIR:-$root/results/campaign-n50/e6-purge-latency}"
. "$root/scripts/capture_lib.sh"

USER_NAME="jake.jongejans@student.uva.nl"
NS=server
STEWARD_NS=(server clientone clienttwo clientthree)
ORCHPORT="${ORCHPORT:-8082}"
TRIALS=$CAMPAIGN_N
PURGE_TIMEOUT="${PURGE_TIMEOUT:-35}"   # watch is sub-second; 30s poll is the fallback bound
ALLOW_TIMEOUT="${ALLOW_TIMEOUT:-35}"
cfg_server="$root/configuration/etcd_launch_files/state_aware_server.json"

# latency-arm knobs (standalone gateway pod)
GW_POD=e6-gateway
GW_IMAGE="${GW_IMAGE:-docker.io/tamjiyan/policy-checkpoint-gateway:latest}"
GWPORT_POD=50062
CONTROL_POLL_INTERVAL="${CONTROL_POLL_INTERVAL:-5}"

# staleness-arm knobs (local gateway)
GWPORT_LOCAL=50061
ETCD_LOCAL_PORT=30005                # fixed: config_local.go points the gateway here
POLL_INTERVAL="${POLL_INTERVAL:-5}"
MAX_STALE="${MAX_STALE:-20}"
EPISODES=5
RECOVERY_STOP=120                    # ends an episode without a purge; keeps the script finite, not a bound
IDENTITY_POD='{"steward":"SERVER","user":"'"$USER_NAME"'","request_type":"vflTrainModelRequest","job_id":"e6-latency","local_job_name":"e6-latency"}'
IDENTITY_LOCAL='{"steward":"SERVER","user":"'"$USER_NAME"'","request_type":"vflTrainModelRequest","job_id":"e6-staleness","local_job_name":"e6-staleness"}'

PIDS=()
GWPID=""
ETCD_PF_PID=""
scratch=""
# run_capture pipes the capture body through tee, so GWPID/ETCD_PF_PID/PIDS/
# scratch are set in a subshell and are empty here: kill by pattern, not by
# pid (the same pid-only cleanup left E2's local gateway holding its port).
cleanup() {
	[ -n "$GWPID" ] && kill "$GWPID" 2>/dev/null
	[ -n "$ETCD_PF_PID" ] && kill "$ETCD_PF_PID" 2>/dev/null
	for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done
	pkill -f '^/tmp/e6-staleness\.[^/]+/gw$' 2>/dev/null
	pkill -f "port-forward.*${ETCD_LOCAL_PORT}:2379" 2>/dev/null
	pkill -f "port-forward.*${ORCHPORT}:8080" 2>/dev/null
	pkill -f "port-forward.*${GWPORT_POD}:50050" 2>/dev/null
	kubectl delete pod "$GW_POD" -n "$NS" --ignore-not-found=true --wait=false 2>/dev/null
	local i
	for i in 1 2 3 4 5 6; do ss -ltn 2>/dev/null | grep -q ":${GWPORT_LOCAL} " || break; sleep 0.5; done
	ss -ltn 2>/dev/null | grep -q ":${GWPORT_LOCAL} " && pkill -9 -f '^/tmp/e6-staleness\.[^/]+/gw$' 2>/dev/null
	[ -n "$scratch" ] && rm -rf "$scratch"
	rm -rf /tmp/e6-staleness.* 2>/dev/null
}
trap cleanup EXIT

start_orch_forward() {
	pkill -f "port-forward.*${ORCHPORT}:8080" 2>/dev/null
	kubectl port-forward -n orchestrator svc/orchestrator "${ORCHPORT}:8080" >/dev/null 2>&1 &
	PIDS+=($!)
	sleep 3
}

# PUT the server agreement with allowed=$1 (true|false). Echoes the HTTP code
# and when the request was sent, in unix microseconds: a host stamp taken
# immediately before curl plus curl's own pre-transfer time. The body is
# built before the stamp.
# The canonical seed already carries onRevocation=purge, so allowed=false IS
# the revocation that prescribes destruction.
flip_server() {
	local want="$1" tmp t0 out pre
	tmp=$(mktemp)
	python3 -c "
import json
a = json.load(open('$cfg_server'))
a['relations']['$USER_NAME']['stateDirectives']['allowed'] = ('$want' == 'true')
print(json.dumps(a))" > "$tmp" || { rm -f "$tmp"; fail "flip json build failed"; }
	t0=$(date +%s%6N)
	out=$(curl -s -o /dev/null -w '%{http_code} %{time_pretransfer}' -X PUT "http://localhost:${ORCHPORT}/api/v1/policyEnforcer" \
		-H 'Content-Type: application/json' --data-binary @"$tmp")
	rm -f "$tmp"
	pre=${out#* }
	echo "${out% *} $(( t0 + 10#${pre/./} ))"
}

# ---- latency arm: standalone gateway pod ---------------------------------

gw_pod_log() { kubectl logs -n "$NS" "$GW_POD" -c "$GW_POD" 2>/dev/null; }

# decidedUnixMicros of the probe blob's first PURGED record past line-mark $1,
# decided at or after $2 (unix microseconds). Empty if there is none yet.
purge_record_after_mark() {
	gw_pod_log | tail -n +"$(($1 + 1))" | python3 -c "
import sys, json
for l in sys.stdin:
    if not l.startswith('{'):
        continue
    r = json.loads(l)
    if (r.get('op') == 'purge' and r.get('decision') == 'PURGED' and r.get('stateClass') == 'e6_probe'
            and r.get('stateKey') == 'probe' and r['decidedUnixMicros'] >= $2):
        print(r['decidedUnixMicros'])
        break"
}

wait_for_purge() { # $1 mark, $2 sent (unix microseconds), $3 timeout -> decidedUnixMicros or fail
	local i hit
	for i in $(seq 1 $(( $3 * 5 ))); do
		hit=$(purge_record_after_mark "$1" "$2")
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

do_latency() { # $1 = watch | poll
	local regime="${1:-watch}"
	step "delete the four state PVCs: the flips must not act on state an idle gateway holds"
	delete_state_pvcs

	step "standalone gateway pod (${GW_IMAGE}): in-cluster etcd path, no chain to disturb"
	kubectl delete pod "$GW_POD" -n "$NS" --ignore-not-found=true --wait=true
	start_orch_forward
	[ "$(flip_server true | cut -d' ' -f1)" = 200 ] || fail "seed PUT failed"

	local extra_env=()
	if [ "$regime" = poll ]; then
		extra_env+=(--env=AGREEMENT_WATCH_DISABLED=true --env=AGREEMENT_POLL_INTERVAL_SECONDS="$CONTROL_POLL_INTERVAL")
	fi
	# IfNotPresent: kubectl run defaults :latest to Always, which would pull
	# from the registry instead of using the kind-loaded image.
	kubectl run "$GW_POD" -n "$NS" --image="$GW_IMAGE" --restart=Never \
		--image-pull-policy=IfNotPresent \
		--env=DATA_STEWARD_NAME=SERVER --env=REQUEST_USER="$USER_NAME" \
		--env=REQUEST_TYPE=vflTrainModelRequest --env=JOB_NAME=e6-latency \
		--env=LOCAL_JOB_NAME=e6-latency --env=GATEWAY_PORT=50050 \
		--env=STATE_DIR=/tmp "${extra_env[@]}" || fail "gateway pod create failed"
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
	if [ "$regime" = poll ]; then
		gw_pod_log | grep -q "Agreement watch disabled" || fail "gateway did not report the poll-only regime"
		echo "regime: poll-only, interval ${CONTROL_POLL_INTERVAL}s"
	fi

	pkill -f "port-forward.*${GWPORT_POD}:50050" 2>/dev/null
	kubectl port-forward -n "$NS" "pod/$GW_POD" "${GWPORT_POD}:50050" >/dev/null 2>&1 &
	PIDS+=($!)
	sleep 3

	step "baseline: probe write must ALLOW and create the purge target"
	wait_probe_allow || fail "baseline probe write never ALLOWed"
	echo "baseline: ALLOW, blob present"

	echo
	echo "trial,t_sent_us,t_put_returned_us,t_decided_us,flip_to_purge_ms,put_rtt_ms,observe_ms,sweep_ms,purge_records"
	local k code tsent tret tdecided p_ms rtt_ms gwmark nrec out tobs obs_ms sweep_ms
	local purge_ms=() observes=()
	for k in $(seq 1 "$TRIALS"); do
		# Independence: re-enable and confirm via an ALLOWed probe write, which
		# also recreates the blob this trial's flip will destroy.
		read -r code _ <<< "$(flip_server true)"
		[ "$code" = 200 ] || fail "re-enable PUT returned $code (trial $k)"
		wait_probe_allow || fail "no confirmed ALLOW after re-enable (trial $k)"
		sleep 0.5

		gwmark=$(gw_pod_log | wc -l)

		read -r code tsent <<< "$(flip_server false)"
		tret=$(date +%s%6N)
		[ "$code" = 200 ] || fail "flip PUT returned $code (trial $k)"

		tdecided=$(wait_for_purge "$gwmark" "$tsent" "$PURGE_TIMEOUT") || fail "no PURGED record of the probe blob within ${PURGE_TIMEOUT}s (trial $k)"
		p_ms=$(python3 -c "print('%.1f' % (($tdecided - $tsent) / 1000))")
		rtt_ms=$(python3 -c "print('%.1f' % (($tret - $tsent) / 1000))")
		# Split the interval at the gateway's own observation of the flip.
		tobs=$(gw_pod_log | tail -n +$((gwmark + 1)) | grep "Agreement changed" \
			| awk -v t="$tsent" '$1 * 1000000 >= t {print $1; exit}')
		obs_ms=""; sweep_ms=""
		if [ -n "$tobs" ]; then
			obs_ms=$(python3 -c "print('%.1f' % (($tobs * 1000000 - $tsent) / 1000))")
			sweep_ms=$(python3 -c "print('%.1f' % (($tdecided - $tobs * 1000000) / 1000))")
			observes+=("$obs_ms")
		fi
		nrec=$(gw_pod_log | tail -n +$((gwmark + 1)) | grep -c '"op":"purge".*"decision":"PURGED"')
		echo "$k,$tsent,$tret,$tdecided,$p_ms,$rtt_ms,$obs_ms,$sweep_ms,$nrec"
		purge_ms+=("$p_ms")
		echo "  purge records this trial:"
		gw_pod_log | tail -n +$((gwmark + 1)) | grep '"op":"purge"' | head -3 | sed 's/^/    /'
		gw_pod_log | tail -n +$((gwmark + 1)) | grep "Purge sweep timing" | head -1 | sed 's/^/    /'
		# Post-purge sanity, not a latency claim: the next write must DENY.
		out=$(gw_probe_write)
		echo "$out" | grep -q 'allowed = false' || { echo "$out"; fail "post-purge write did not DENY (trial $k)"; }
		echo "  post-purge probe write: DENY 'allowed = false'"
	done

	flip_server true >/dev/null

	echo
	echo "request sent -> the blob's PURGED record (the PUT's return is shown per trial):"
	printf '%s\n' "${purge_ms[@]}" | summarize_series ms
	if [ "${#observes[@]}" -gt 0 ]; then
		echo "request sent -> observed (Agreement changed line), ${#observes[@]}/${TRIALS} trials:"
		printf '%s\n' "${observes[@]}" | summarize_series ms
	fi
	if [ "$regime" = poll ]; then
		echo "regime: poll-only (watch disabled, interval ${CONTROL_POLL_INTERVAL}s); observe_ms is the tick phase — the interval-tracking control for the clustering question"
	else
		echo "regime: watch-delivered; the flip -> first-DENY side is E2's capture"
	fi
	echo "note: t_sent_us is a host stamp immediately before curl plus curl's pre-transfer time; t_decided_us is the PURGED record's decidedUnixMicros, set before the unlink; the state dir is pod-local"
	echo "note: purge-record count covers the probe blob (and nothing else in this pod)"
	echo "note: observe_ms/sweep_ms split delivery from sweep; the Purge-sweep-timing line splits confirm from unlink"

	kubectl delete pod "$GW_POD" -n "$NS" --ignore-not-found=true --wait=false
}

do_latency_watch() { do_latency watch; }
do_latency_poll() { do_latency poll; }

block_latency() {
	run_capture watch-regime flip-to-purge-complete "scripts/capture_e6_purge_latency.sh latency ${TRIALS}" do_latency_watch \
		"E6 watch-regime: flip via /policyEnforcer PUT (stamped when curl sends it) to the probe blob's PURGED record on a standalone gateway pod, ${TRIALS} trials"
}

block_poll_control() {
	run_capture poll-control flip-to-purge-complete-poll "scripts/capture_e6_purge_latency.sh poll-control ${TRIALS}" do_latency_poll \
		"E6 poll-only control: watch disabled at a ${CONTROL_POLL_INTERVAL}s interval, flip to the probe blob's PURGED record, ${TRIALS} trials; interval-tracking control for the latency clustering"
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

# One episode, with its own gateway, state dir and gateway log under $2. Run
# in a subshell: a failed assertion ends the episode, not the capture. The
# time from recovery to the purge goes to $2/recovery_ms.
staleness_episode() { # $1 = episode, $2 = episode dir
	local gw_bin="$scratch/gw" state_dir="$2/state" gw_log="$2/gw.log"
	local blob="$state_dir/data/e6_probe/probe.bin" audit="$state_dir/audit/audit.log"
	mkdir -p "$state_dir"
	start_etcd_forward

	step "episode $1: seed the server agreement allowed=true (canonical carries onRevocation=purge)"
	[ "$(flip_server true | cut -d' ' -f1)" = 200 ] || fail "seed PUT failed"

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
	[ "$(flip_server false | cut -d' ' -f1)" = 200 ] || fail "flip PUT failed (cluster etcd should be unaffected)"
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

	step "recovery: restore the etcd forward; the deferred purge must complete fresh, the time it takes is reported"
	local t_recover t_purge
	start_etcd_forward
	t_recover=$(date +%s.%N)
	t_purge=""
	for i in $(seq 1 $((RECOVERY_STOP * 5))); do
		if grep -q "Purged .* state files under revoked agreement" "$gw_log"; then
			t_purge=$(grep "Purged .* state files under revoked agreement" "$gw_log" | head -1 \
				| python3 -c "import sys; print('%.6f' % float(sys.stdin.read().split()[0]))")
			break
		fi
		sleep 0.2
	done
	[ -n "$t_purge" ] || { echo "--- gateway log tail ---"; tail -20 "$gw_log"; fail "no purge within the stop time of ${RECOVERY_STOP}s after recovery"; }
	python3 -c "print('%.1f' % (($t_purge - $t_recover) * 1000))" > "$2/recovery_ms"
	echo "recovery -> purge-complete: $(cat "$2/recovery_ms") ms (reported, not asserted)"

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

do_staleness() {
	scratch=$(mktemp -d /tmp/e6-staleness.XXXXXX)
	local gw_bin="$scratch/gw"

	step "delete the four state PVCs: the flips must not act on state an idle gateway holds"
	delete_state_pvcs

	step "build the gateway (-tags local); etcd through a killable port-forward"
	( cd "$root/go" && go build -tags local -o "$gw_bin" ./cmd/policy-checkpoint-gateway/ ) || fail "gateway build failed"
	start_orch_forward

	local keep k dir i failed=0
	local -A result
	keep="$results_dir/induced-staleness/$(date +%Y%m%d-%H%M%S)"
	for k in $(seq 1 "$EPISODES"); do
		dir="$scratch/episode$k"
		result[$k]=ok
		( staleness_episode "$k" "$dir" ) || { result[$k]=FAILED; failed=$((failed + 1)); echo "episode $k FAILED"; }
		# The episode's gateway and forward go before the next episode starts.
		pkill -f '^/tmp/e6-staleness\.[^/]+/gw$' 2>/dev/null
		stop_etcd_forward
		for i in 1 2 3 4 5 6; do ss -ltn 2>/dev/null | grep -q ":${GWPORT_LOCAL} " || break; sleep 0.5; done
		ss -ltn 2>/dev/null | grep -q ":${GWPORT_LOCAL} " && pkill -9 -f '^/tmp/e6-staleness\.[^/]+/gw$' 2>/dev/null
		# Each episode's gateway log and audit log are kept; cleanup removes the scratch dir.
		cp "$dir/gw.log" "${keep}_episode${k}_gateway.log" && cp "$dir/state/audit/audit.log" "${keep}_episode${k}_audit.log" \
			&& echo "episode $k logs kept: ${keep}_episode${k}_gateway.log, ${keep}_episode${k}_audit.log"
	done

	step "recovery -> purge-complete per episode (reported, not asserted)"
	echo "episode,recovery_to_purge_ms,result"
	for k in $(seq 1 "$EPISODES"); do
		echo "$k,$(cat "$scratch/episode$k/recovery_ms" 2>/dev/null),${result[$k]}"
	done
	echo "note: t_recover is stamped after the forward's 3s settle, so about 3s after the forward was relaunched"

	flip_server true >/dev/null
	[ "$failed" -eq 0 ] || fail "$failed of $EPISODES episodes failed"
}

block_staleness() {
	run_capture induced-staleness outage-defer-recover-purge "scripts/capture_e6_purge_latency.sh staleness" do_staleness \
		"E6 induced staleness, ${EPISODES} episodes: outage -> stale fail-closed writes, no destruction on non-fresh, flip unobserved; recovery -> confirmed-fresh purge, its time reported per episode; gateway and audit logs kept"
}

# --- main -----------------------------------------------------------------

which="${1:-all}"
case "$which" in
latency)
	TRIALS="${2:-$CAMPAIGN_N}"
	block_latency
	;;
poll-control)
	TRIALS="${2:-$CAMPAIGN_N}"
	block_poll_control
	;;
staleness) block_staleness ;;
all)
	block_latency
	block_poll_control
	block_staleness
	;;
*) echo "usage: $0 [latency [trials]|poll-control [trials]|staleness|all]" >&2; exit 2 ;;
esac
