#!/usr/bin/env bash
set -u

# Environment snapshot for the evidence env/ folder: toolchain and cluster
# versions, plus the dynamos images loaded in kind, as raw command output.
# Run at least once per experiment day, before the first counted capture.
#
# Usage: capture_env_snapshot.sh

root="$(cd "$(dirname "$0")/.." && pwd)"
results_dir="${ENV_RESULTS_DIR:-$root/results/env}"
ts="$(date +%Y%m%d-%H%M%S)"

show() {
	echo "\$ $*"
	"$@" 2>&1
	echo
}

mkdir -p "$results_dir"

{
	show date
	show git -C "$root" rev-parse --abbrev-ref HEAD
	show git -C "$root" rev-parse HEAD
	show git -C "$root" status --short
	show go version
	show kind version
	show kubectl version --client
	show kubectl get nodes -o wide
	show kubectl get pods -A
} > "$results_dir/${ts}_env-snapshot.txt"

{
	show date
	show git -C "$root" rev-parse HEAD
	echo "\$ docker exec kind-control-plane crictl images | grep -E 'dynamos1|tamjiyan'"
	docker exec kind-control-plane crictl images 2>&1 | grep -E 'dynamos1|tamjiyan'
} > "$results_dir/${ts}_images.txt"

echo "captured: $results_dir/${ts}_env-snapshot.txt"
echo "captured: $results_dir/${ts}_images.txt"
