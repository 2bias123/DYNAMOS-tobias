#!/usr/bin/env bash
# Decision time: after the baseline run, every record in the server claim's
# audit.log carries decidedUnixMicros, and no value is lower than the one on
# the line before.

set -u

EXP=GATE
root="$(cd "$(dirname "$0")/../../.." && pwd)"
. "$root/scripts/kind_gate/context.sh"
. "$root/scripts/capture_lib.sh"

NODE=stayup-control-plane

step "the server claim's audit.log"
pvc=$(state_pvc_of server)
[ -n "$pvc" ] || fail "no state claim in server"
vol=$(kubectl get pvc -n server "$pvc" -o jsonpath='{.spec.volumeName}')
[ -n "$vol" ] || fail "the claim $pvc is not bound"
log=$(docker exec "$NODE" cat "/var/local-path-provisioner/${vol}_server_${pvc}/audit/audit.log") \
	|| fail "cannot read audit.log of $pvc on the node"
n=$(echo "$log" | grep -c .)
[ "$n" -gt 0 ] || fail "audit.log of $pvc is empty"

step "every record carries decidedUnixMicros, none lower than the one before"
times=$(echo "$log" | jq -r '.decidedUnixMicros') || fail "audit.log of $pvc is not NDJSON"
bad=$(echo "$times" | grep -cvxE '[1-9][0-9]{15}')
[ "$bad" -eq 0 ] || fail "$bad of $n records carry no decision time"
echo "$times" | sort -n -c 2>/dev/null || fail "decision times decrease in audit.log of $pvc"
echo "OK: $n records, each with a decision time, none lower than the one before"
