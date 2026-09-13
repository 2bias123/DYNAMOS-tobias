#!/usr/bin/env bash
set -u

# E3 30-triplet frozen-build session. Wraps
# run_e3_replication.sh with the one gate the driver's env snapshot does not
# provide: digest EQUALITY with the e3-frozen build, not just
# kind-import origin — the gap the 2026-08-27 branch-build session fell
# through. Then runs 30 interleaved a,b,c triplets of 50-round runs into
# results/e3-frozen-30triplets/.
#
# Fully offline: the gate reads the kind node via docker exec, the driver
# talks to the cluster via kubectl and localhost port-forwards only, and
# every image on the run path is IfNotPresent. No network needed.
#
# Usage: run_e3_frozen_30triplets.sh [start_triplet]
#   start_triplet resumes a stopped session (failed triplet reruns in full).
#   TRIPLETS / CYCLES / E3_RESULTS_DIR pass through for uncounted dry runs,
#   e.g.: E3_RESULTS_DIR=/tmp/e3-dryrun TRIPLETS=1 CYCLES=5 $0

root="$(cd "$(dirname "$0")/.." && pwd)"

# The four decisive fork images at their e3-frozen IDs (re-freeze
# 2026-09-04): the frozen campaign build plus the gateway-state
# storage-class rename in the agent (commit 5659239); gateway and both
# VFL images stay the campaign originals. Record:
# results/e3-frozen-30triplets/env/20260904_e3-frozen-freeze-record.txt
FROZEN_REFS=(
	"docker.io/dynamos1/agent:main da0affc99c9d3"
	"docker.io/tamjiyan/policy-checkpoint-gateway:latest 3e5d9e025f000"
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

TRIPLETS="${TRIPLETS:-30}"
CYCLES="${CYCLES:-50}"
E3_RESULTS_DIR="${E3_RESULTS_DIR:-$root/results/e3-frozen-30triplets}"
export TRIPLETS CYCLES E3_RESULTS_DIR

exec "$root/scripts/run_e3_replication.sh" "$@"
