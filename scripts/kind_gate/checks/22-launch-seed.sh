#!/usr/bin/env bash
# The launch file's terms and the seeder's own check.
#   After a reset with no seed, the policy store holds for each of the four
#   VFL stewards a relation that lists vflTrainModelRequest and denies state:
#   not allowed, retention 900 s, no resume, nothing on revocation.
#   A seed in which one steward's PUT never reaches the orchestrator leaves
#   that steward at the launch-file terms: the seeder fails and names it, and
#   names no other.
#   A normal seed passes.

set -u

EXP=GATE
root="$(cd "$(dirname "$0")/../../.." && pwd)"
. "$root/scripts/kind_gate/context.sh"
. "$root/scripts/capture_lib.sh"

USER_NAME="jake.jongejans@student.uva.nl"
STEWARD_NS=(server clientone clienttwo clientthree)
ORCHPORT=18082
export PORT="$ORCHPORT"
DENY='{"allowed":false,"retentionSeconds":900,"resumeAllowed":false,"onRevocation":""}'
LEFT_OUT=clientone

stored() { # $1 = steward; its agreement as the policy store holds it
	kubectl exec -n core etcd-0 -c etcd -- sh -c \
		"ETCDCTL_API=3 /usr/local/bin/etcdctl --endpoints=localhost:2379 get /policyEnforcer/agreements/$1 --print-value-only"
}

# The seeder with the PUT of one steward swallowed and reported as accepted.
seed_without() { # $1 = steward
	(
		SKIP_FILE="state_aware_$1.json"
		curl() {
			case "$*" in
				*"$SKIP_FILE"*) printf 200 ;;
				*) command curl "$@" ;;
			esac
		}
		export SKIP_FILE
		export -f curl
		"$root/scripts/seed_state_aware.sh"
	)
}

step "reset, no seed: the policy store holds the launch file's deny values"
reset_cluster
kubectl -n orchestrator rollout status deploy/orchestrator --timeout=90s >/dev/null 2>&1
for ns in "${STEWARD_NS[@]}"; do
	agreement=$(stored "$ns") || fail "cannot read the agreement of $ns from the policy store"
	relation=$(echo "$agreement" | jq -c --arg u "$USER_NAME" '.relations[$u] | {ID, requestTypes, stateDirectives}') \
		|| fail "the stored agreement of $ns is not JSON"
	echo "$relation" | jq -e --argjson deny "$DENY" '
		.ID == "GUID" and (.requestTypes | index("vflTrainModelRequest") != null) and .stateDirectives == $deny' >/dev/null \
		|| fail "$ns does not hold the launch file's deny values after a reset with no seed: $relation"
	echo "    $ns: $relation"
done
echo "OK: the four stewards deny state under vflTrainModelRequest, relation GUID"

step "a seed that never reaches $LEFT_OUT: the seeder fails and names it"
# As in reset_and_seed: the orchestrator's HTTP endpoint can lag its
# readiness, and a PUT that got no answer says nothing about the seeder's
# check.
for try in 1 2 3 4; do
	out=$(seed_without "$LEFT_OUT" 2>&1)
	rc=$?
	echo "$out" | grep -q 'FAILED (http' || break
	echo "    a PUT got no answer from the orchestrator (attempt $try); retrying in 5s"
	sleep 5
done
echo "$out" | sed 's/^/    /'
echo "$out" | grep -q 'FAILED (http' && fail "the seeder's PUTs did not reach the orchestrator in 4 attempts"
[ "$rc" -ne 0 ] || fail "the seeder passed although $LEFT_OUT was left at the launch-file values"
echo "$out" | grep -q "^\[seed\] ${LEFT_OUT}: etcd DIFFERS from the seed" \
	|| fail "the seeder failed without naming $LEFT_OUT as differing from its seed"
[ "$(echo "$out" | grep -c 'DIFFERS')" -eq 1 ] || fail "the seeder names a steward other than $LEFT_OUT as differing"
[ "$rc" -eq 1 ] || fail "the seeder counted $rc failures, expected 1"
echo "OK: the seeder exited $rc and named $LEFT_OUT only"

step "a normal seed passes"
for try in 1 2 3 4; do
	out=$("$root/scripts/seed_state_aware.sh" 2>&1)
	rc=$?
	echo "$out" | grep -q 'FAILED (http' || break
	sleep 5
done
echo "$out" | sed 's/^/    /'
[ "$rc" -eq 0 ] || fail "a normal seed exited $rc"
echo "OK: a normal seed exited 0"
