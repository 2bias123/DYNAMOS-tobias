#!/usr/bin/env bash
set -u

# Seed the state-aware agreements (stateDirectives on each VFL steward) into
# etcd through the orchestrator's /policyEnforcer PUT. That's the operator
# path, so checkJobs fires like it would for a real policy change. Idempotent.
#
# NOTE: the orchestrator re-applies the PVC's agreements.json on every boot,
# which OVERWRITES these keys. Re-run this after any reset.sh.

PORT="${PORT:-8082}"
FILES=(state_aware_server.json state_aware_clientone.json state_aware_clienttwo.json state_aware_clientthree.json)

script_dir="$(cd "$(dirname "$0")" && pwd)"
cfg_dir="${script_dir}/../configuration/etcd_launch_files"

PF_PID=""
kill_forward() {
	[ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null
	PF_PID=""
}
trap kill_forward EXIT

# Transport mirrors capture_lib.sh: portforward (default, the kind path) or
# nodeport (the FABRIC path — kubectl port-forward is broken on the testbed
# VMs; the service is patched to NodePort and curled at a node IP).
if [ "${E3_TRANSPORT:-portforward}" = "nodeport" ]; then
	if [ "$(kubectl -n orchestrator get svc orchestrator -o jsonpath='{.spec.type}')" != "NodePort" ]; then
		kubectl -n orchestrator patch svc orchestrator -p '{"spec":{"type":"NodePort"}}' >/dev/null
	fi
	np=$(kubectl -n orchestrator get svc orchestrator -o jsonpath='{.spec.ports[0].nodePort}')
	ip="${E3_NODE_IP:-$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')}"
	[ -n "$np" ] && [ -n "$ip" ] || { echo "[seed] cannot resolve orchestrator NodePort endpoint" >&2; exit 1; }
	BASE="http://${ip}:${np}/api/v1"
else
	kubectl port-forward -n orchestrator svc/orchestrator "${PORT}:8080" >/dev/null 2>&1 &
	PF_PID=$!
	sleep "${PF_SETTLE:-3}"
	BASE="http://localhost:${PORT}/api/v1"
fi

fail=0
for f in "${FILES[@]}"; do
	code=$(curl -s -o /dev/null -w '%{http_code}' -X PUT "${BASE}/policyEnforcer" \
		-H 'Content-Type: application/json' --data-binary @"${cfg_dir}/${f}")
	if [ "$code" = "200" ]; then
		echo "[seed] ${f}: OK"
	else
		echo "[seed] ${f}: FAILED (http ${code})"
		fail=$((fail + 1))
	fi
done

echo "[seed] verifying stateDirectives present in etcd"
for s in server clientone clienttwo clientthree; do
	if kubectl exec -n core etcd-0 -c etcd -- sh -c \
		"ETCDCTL_API=3 /usr/local/bin/etcdctl --endpoints=localhost:2379 get /policyEnforcer/agreements/${s} --print-value-only" \
		| grep -q stateDirectives; then
		echo "[seed] ${s}: stateDirectives in etcd"
	else
		echo "[seed] ${s}: stateDirectives MISSING"
		fail=$((fail + 1))
	fi
done

[ "$fail" = 0 ] && echo "[seed] OK" || echo "[seed] ${fail} FAILURES"
exit "$fail"
