#!/usr/bin/env bash
# Prepare the kind cluster for a reproducible VFL smoke run.
#
#   1. Clear stale Jobs in every namespace that hosts a chain agent.
#   2. Clear stale /agents/jobs/ etcd keys so the api-gateway lock resets.
#   3. Coordinated rollout of the full request path (7 deployments) so no
#      sidecar↔main gRPC stream lingers in a pre-rollout state.
#   4. Settle wait for the AMQP topology to converge.
#
# Every E-experiment and smoke run assumes this script has been executed
# beforehand; skipping it leaves the request-path in a state that dev-loop.md
# calls out as the "silent stall after single-component rollout".

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"

STEWARD_NS=(server clientone clienttwo clientthree)
REQUEST_PATH=(
	"api-gateway/api-gateway"
	"orchestrator/policy-enforcer"
	"orchestrator/orchestrator"
	"server/server"
	"clientone/clientone"
	"clienttwo/clienttwo"
	"clientthree/clientthree"
)
SETTLE_SECONDS="${SETTLE_SECONDS:-45}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-120s}"

# Refuse to run if the required recovery patches aren't in the tree.
# preflight_patches.sh is a BUILD-tree guard (it greps python/ and go/). On
# FABRIC the control node is deploy-only — the upload route ships
# charts/configuration/scripts, no build tree — and image identity is
# guaranteed by the digest gate + freeze record, so the check is skipped there.
if [ "${E3_ENV:-kind}" = "fabric" ]; then
	echo "[reset] E3_ENV=fabric: skipping build-tree preflight (deploy-only node)"
else
	"$script_dir/scripts/preflight_patches.sh"
fi

echo "[reset] deleting stale Jobs in steward namespaces"
for ns in "${STEWARD_NS[@]}"; do
	kubectl -n "$ns" delete jobs --all --ignore-not-found=true --wait=false
done

echo "[reset] clearing /agents/jobs/ etcd keys"
kubectl exec -n core etcd-0 -c etcd -- sh -c \
	'ETCDCTL_API=3 /usr/local/bin/etcdctl --endpoints=localhost:2379 del "/agents/jobs/" --prefix' \
	>/dev/null

echo "[reset] coordinated rollout of request path"
for entry in "${REQUEST_PATH[@]}"; do
	ns="${entry%%/*}"
	deploy="${entry##*/}"
	kubectl -n "$ns" rollout restart "deployment/$deploy"
done
for entry in "${REQUEST_PATH[@]}"; do
	ns="${entry%%/*}"
	deploy="${entry##*/}"
	kubectl -n "$ns" rollout status "deployment/$deploy" --timeout="$ROLLOUT_TIMEOUT"
done

echo "[reset] settling ${SETTLE_SECONDS}s for AMQP topology to converge"
sleep "$SETTLE_SECONDS"

echo "[reset] OK"
