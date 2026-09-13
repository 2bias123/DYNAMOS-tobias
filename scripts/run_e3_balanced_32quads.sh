#!/usr/bin/env bash
set -u

# E3 balanced-order 32-quadruplet session. Sibling to
# run_e3_frozen_30triplets.sh, left intact as the frozen three-arm session's
# record. Wraps run_e3_balanced.sh with the one gate the driver's env snapshot
# does not provide: digest EQUALITY with the e3-frozen build, not just
# kind-import origin — the gap the 2026-08-27 branch-build session fell
# through. Then runs 32 Williams-rotated a,b,c,h quadruplets of 50-round runs
# into results/e3-balanced/.
#
# Fully offline: the gate reads the kind node via docker exec, the driver
# talks to the cluster via kubectl and localhost port-forwards only, and every
# image on the run path is IfNotPresent. No network needed.
#
# Usage: run_e3_balanced_32quads.sh [start_quad]
#   start_quad resumes a stopped session (failed quadruplet reruns in full).
#   QUADS / CYCLES / E3_RESULTS_DIR pass through for uncounted dry runs,
#   e.g.: E3_RESULTS_DIR=/tmp/e3-dryrun QUADS=2 CYCLES=5 $0

root="$(cd "$(dirname "$0")/.." && pwd)"

# The four decisive fork images at their e3-balanced IDs (re-freeze
# 2026-09-13). Diverges from the e3-frozen pin on the gateway only: the h arm
# needs store-only, a gateway feature (commit 3caaf82/a9f4542, 2026-08-25) that
# postdates the frozen campaign gateway by two days, so that binary silently
# ran full enforcement under GATEWAY_STORE_ONLY (caught by the 13.09 dry run).
# The gateway is rebuilt from HEAD, which for the gateway binary is exactly the
# campaign source plus the store-only additions (107 insertions, 0 deletions,
# no shared-pkg or go.mod drift — verified campaign 22bf60e..HEAD), so a/b/c
# run on a behaviourally identical gateway with store-only dormant, and h gets
# it. Agent (storage-class rename) and both VFL images stay the e3-frozen IDs.
# Record: results/e3-balanced/env/20260913_e3-balanced-freeze-record.txt
FROZEN_REFS=(
	"docker.io/dynamos1/agent:main da0affc99c9d3"
	"docker.io/tamjiyan/policy-checkpoint-gateway:latest 8902cbf351be6"
	"docker.io/tamjiyan/vfl-train-demo:latest f5c6d1a94dead"
	"docker.io/tamjiyan/vfl-train-model-demo:latest f77074962ecc5"
)

echo "=== frozen-build gate: node canonical tags vs the campaign record"
imgs=$(docker exec kind-control-plane crictl images 2>/dev/null | awk '{print $1":"$2" "$3}') \
	|| { echo "cannot read node images (is the kind cluster up?)" >&2; exit 1; }
bad=0
for entry in "${FROZEN_REFS[@]}"; do
	ref="${entry% *}"
	want="${entry#* }"
	got=$(echo "$imgs" | awk -v r="$ref" '$1==r{print $2}')
	if [ "$got" = "$want" ]; then
		echo "OK    $ref -> $got"
	else
		echo "DRIFT $ref -> ${got:-absent}, frozen campaign = $want"
		bad=1
	fi
done
if [ "$bad" -ne 0 ]; then
	echo "node has drifted off the frozen campaign build; force-tag the frozen images back onto the canonical tags (ctr -n k8s.io images tag --force ... on the kind node) and roll the stewards before any counted run" >&2
	exit 1
fi

QUADS="${QUADS:-32}"
CYCLES="${CYCLES:-50}"
E3_RESULTS_DIR="${E3_RESULTS_DIR:-$root/results/e3-balanced}"
export QUADS CYCLES E3_RESULTS_DIR

exec "$root/scripts/run_e3_balanced.sh" "$@"
