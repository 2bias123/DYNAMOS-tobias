# Shared plumbing for the capture_e*.sh scripts. Not executable; source it
# after setting the script's context:
#
#   EXP=E1                       # experiment tag for fail messages
#   root=...                     # repo root
#   results_dir=...              # artifact tree (captures.md lives here)
#   . "$root/scripts/capture_lib.sh"
#
# The chain helpers (seed/trigger/wait/reset) additionally expect the
# caller's STEWARD_NS, USER_NAME, APIPORT, ORCHPORT, POLL_MAX and PIDS.
# Experiment-specific instruments (writers, samplers, flip variants) stay in
# the scripts; only the shared skeleton lives here.

# One campaign-wide iteration count: rounds per training run, trials per
# latency session, hits per reuse block. Scripts default their counts from
# it so every experiment reports distributions at the same n.
CAMPAIGN_N="${CAMPAIGN_N:-50}"

# HTTP transport to the orchestrator and api-gateway services.
#   portforward (default) — localhost port-forwards, the kind path.
#   nodeport — patch the service to NodePort and curl a node IP directly;
#   the FABRIC path (kubectl port-forward is broken on the testbed VMs).
# PF_SETTLE is the post-port-forward settle; nodeport needs none.
E3_TRANSPORT="${E3_TRANSPORT:-portforward}"
PF_SETTLE="${PF_SETTLE:-3}"
export E3_TRANSPORT PF_SETTLE

cluster_node_ip() {
	if [ -n "${E3_NODE_IP:-}" ]; then
		echo "$E3_NODE_IP"
		return 0
	fi
	kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}'
}

# Ensure $1/$2 (ns/svc) is reachable without a port-forward; echo its base
# URL. Patches the service to NodePort on first use (idempotent; a rollout
# restart never resets the service type).
nodeport_base() { # $1 ns, $2 svc
	local ns="$1" svc="$2" ip port
	if [ "$(kubectl -n "$ns" get svc "$svc" -o jsonpath='{.spec.type}')" != "NodePort" ]; then
		kubectl -n "$ns" patch svc "$svc" -p '{"spec":{"type":"NodePort"}}' >/dev/null \
			|| { echo "cannot patch $ns/$svc to NodePort" >&2; return 1; }
	fi
	port=$(kubectl -n "$ns" get svc "$svc" -o jsonpath='{.spec.ports[0].nodePort}')
	ip=$(cluster_node_ip)
	[ -n "$port" ] && [ -n "$ip" ] || { echo "cannot resolve NodePort endpoint for $ns/$svc" >&2; return 1; }
	echo "http://${ip}:${port}"
}

# Set ORCH_BASE / API_BASE for the configured transport, starting a
# port-forward only in portforward mode.
ensure_orch_base() {
	if [ "$E3_TRANSPORT" = "nodeport" ]; then
		ORCH_BASE=$(nodeport_base orchestrator orchestrator) || fail "orchestrator NodePort endpoint"
	else
		pkill -f "port-forward.*${ORCHPORT}:8080" 2>/dev/null
		kubectl port-forward -n orchestrator svc/orchestrator "${ORCHPORT}:8080" >/dev/null 2>&1 &
		PIDS+=($!)
		sleep "$PF_SETTLE"
		ORCH_BASE="http://localhost:${ORCHPORT}"
	fi
}

ensure_api_base() {
	if [ "$E3_TRANSPORT" = "nodeport" ]; then
		API_BASE=$(nodeport_base api-gateway api-gateway) || fail "api-gateway NodePort endpoint"
	else
		pkill -f "port-forward.*${APIPORT}:8080" 2>/dev/null
		kubectl port-forward -n api-gateway svc/api-gateway "${APIPORT}:8080" >/dev/null 2>&1 &
		PIDS+=($!)
		sleep "$PF_SETTLE"
		API_BASE="http://localhost:${APIPORT}"
	fi
}

step() { echo; echo "=== $*"; }
fail() { echo "${EXP} FAIL: $*" >&2; exit 1; }

provenance() {
	echo "\$ date"; date; echo
	echo "\$ git rev-parse HEAD"; git -C "$root" rev-parse HEAD; echo
	echo "\$ git status --short"; git -C "$root" status --short; echo
	echo "\$ kubectl config current-context"; kubectl config current-context; echo
}

# Assert helper: $1 = description, $2 = text, remaining args = grep args that
# must all match. Prints the matching line(s) into the artifact.
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

# One number per line on stdin -> the campaign summary line. $1 = unit label.
summarize_series() {
	python3 -c "
import sys, statistics
xs = sorted(float(x) for x in sys.stdin if x.strip())
n = len(xs)
pct = lambda p: xs[min(n - 1, int(p * n))]
print('n=%d  min=%.1f $1  p50=%.1f $1  p90=%.1f $1  max=%.1f $1  mean=%.1f $1' % (
    n, xs[0], statistics.median(xs), pct(0.90), xs[-1], statistics.mean(xs)))"
}

# Status-poll cap (x5s) sized for a run of $1 rounds: boot + round 0 + ~1s a
# round, with slack.
poll_max_for_cycles() { echo $(( 24 + $1 )); }

# Retention seed for a repeated-reuse block of $1 hits at ~60s a hit, with
# 2x margin and a 7200s floor.
retention_for_hits() {
	local want=$(( $1 * 120 ))
	echo $(( want > 7200 ? want : 7200 ))
}

reset_cluster() {
	"$root/reset.sh" || fail "reset.sh failed"
}

# reset.sh, then seed via seed_state_aware.sh. The orchestrator's HTTP
# endpoint can lag its readiness by a few seconds after a reset, so the
# seeder's one-shot port-forward sometimes gets http 000: wait for the
# rollout, clear any stale forward, then retry.
reset_and_seed() {
	reset_cluster
	[ "$E3_TRANSPORT" = "portforward" ] && pkill -f "port-forward.*${ORCHPORT}:8080" 2>/dev/null
	kubectl -n orchestrator rollout status deploy/orchestrator --timeout=90s >/dev/null 2>&1
	local i
	for i in 1 2 3 4; do
		"$root/scripts/seed_state_aware.sh" && return 0
		echo "[${EXP,,}] seed attempt $i failed; retrying in 5s"
		sleep 5
	done
	fail "seed failed after 4 attempts"
}

# Seed the four state-aware agreements via the orchestrator /policyEnforcer
# operator path. $1 is an optional python statement applied to each relation's
# stateDirectives dict (variable `sd`) before the PUT; empty seeds canonical.
seed_agreements() {
	local transform="${1:-}"
	ensure_orch_base
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
		code=$(curl -s -o /dev/null -w '%{http_code}' -X PUT "${ORCH_BASE}/api/v1/policyEnforcer" \
			-H 'Content-Type: application/json' --data-binary @"$tmp")
		rm -f "$tmp"
		[ "$code" = "200" ] || fail "seed PUT for $s returned http $code"
		echo "[seed] $s: OK${transform:+ (variant: $transform)}"
	done
}

# Assert a stateDirectives field landed in etcd for every steward.
verify_directive_field() { # $1 field, $2 expected python repr (True/False/30)
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

trigger() { # $1 = cycles; echoes request_id (logs go to stderr)
	ensure_api_base
	local resp
	resp=$(curl -s -X POST "${API_BASE}/api/v1/requestApproval" \
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

wait_done() { # $1 = request_id, $2 = max polls (5s each, default POLL_MAX); prints final status JSON
	[ -n "${API_BASE:-}" ] || ensure_api_base
	local max="${2:-$POLL_MAX}" i out st
	for i in $(seq 1 "$max"); do
		sleep 5
		out=$(curl -s "${API_BASE}/api/v1/getTrainingStatus?id=$1")
		st=$(echo "$out" | python3 -c "import sys, json; print(json.load(sys.stdin).get('status', ''))" 2>/dev/null)
		echo "poll $i: ${st:-no-response}" >&2
		if [ "$st" = "done" ]; then
			echo "$out"
			return 0
		fi
		[ "$st" = "failed" ] && fail "training status=failed: $out"
	done
	fail "training not done after $max polls"
}

steward_pod() { kubectl get pods -n "$1" -o name 2>/dev/null | grep jake | head -1 | cut -d/ -f2; }

# Delete the four state PVCs so a run starts stateless (they are recreated at
# job deploy).
delete_state_pvcs() {
	local ns
	for ns in "${STEWARD_NS[@]}"; do
		kubectl get pvc -n "$ns" -o name 2>/dev/null | grep 'persistentvolumeclaim/state-' \
			| xargs -r kubectl delete -n "$ns" --wait=true
	done
}

state_pvc_of() { kubectl get pvc -n "$1" -o name 2>/dev/null | grep 'persistentvolumeclaim/state-' | head -1 | cut -d/ -f2; }

# Mount $1's state PVC read-only in inspector pod $2 (image $3) and wait for
# it to become Ready. The caller frees the PVC first and deletes the pod when
# done. Prints its own failure reason; returns nonzero on failure.
start_state_inspector() { # $1 ns, $2 pod name, $3 image
	local ns="$1" name="$2" image="$3" pvc
	pvc=$(state_pvc_of "$ns")
	[ -n "$pvc" ] || { echo "[$ns] no state PVC found"; return 1; }
	echo "[$ns] state PVC: $pvc"
	kubectl apply -f - >/dev/null <<-YAML
	apiVersion: v1
	kind: Pod
	metadata: { name: $name, namespace: $ns }
	spec:
	  restartPolicy: Never
	  containers:
	  - name: inspector
	    image: $image
	    imagePullPolicy: IfNotPresent
	    command: ["python3", "-c", "import time; time.sleep(3600)"]
	    volumeMounts:
	    - { name: state, mountPath: /state, readOnly: true }
	  volumes:
	  - name: state
	    persistentVolumeClaim: { claimName: $pvc }
	YAML
	if ! kubectl -n "$ns" wait --for=condition=Ready "pod/$name" --timeout=120s >/dev/null 2>&1; then
		echo "[$ns] inspector pod $name did not become ready"
		return 1
	fi
}

r2_series() { # $1 = status JSON
	echo "$1" | python3 -m json.tool
	echo "$1" | python3 -c "
import sys, json, statistics
rs = [r['accuracy'] for r in json.load(sys.stdin)['results']]
print('r2 series (the payload field is named accuracy; the demo chain computes r2):')
print(' '.join('%.4f' % v for v in rs))
print('first r2: %.4f  last r2: %.4f  mean r2: %.4f  median r2: %.4f  (n=%d)' % (
    rs[0], rs[-1], statistics.mean(rs), statistics.median(rs), len(rs)))"
}

# Run a block function, tee provenance + its output into a timestamped
# artifact, append the generated captures.md line. Aborts the script if the
# block failed; returns 0 otherwise so multi-block scripts continue.
run_capture() { # $1 = subdir, $2 = slug, $3 = command for the captures line, $4 = fn, $5 = note
	local subdir="$1" slug="$2" cmdline="$3" fn="$4" note="$5"
	local ts out rc commit
	ts="$(date +%Y%m%d-%H%M%S)"
	out="$results_dir/${subdir}/${ts}_${slug}.txt"
	mkdir -p "$(dirname "$out")"
	{ provenance; "$fn"; } 2>&1 | tee "$out"
	rc=${PIPESTATUS[0]}
	commit="$(git -C "$root" rev-parse --short HEAD)"
	[ "$rc" -ne 0 ] && note="$note; FAILED (exit=$rc)"
	echo "\`$(basename "$results_dir")/${subdir}/${ts}_${slug}.txt | $ts | ${cmdline} | $commit | $note\`" \
		>> "$results_dir/captures.md"
	echo
	echo "captured: $out (exit=$rc)"
	[ "$rc" -ne 0 ] && exit "$rc"
	return 0
}
