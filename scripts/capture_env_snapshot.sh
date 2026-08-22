#!/usr/bin/env bash
set -u

# Environment snapshot for the evidence env/ folder: toolchain and cluster
# versions, the dynamos images loaded in kind, and a fork-image provenance
# check, as raw command output. Run at least once per experiment day, before
# the first counted capture.
#
# The provenance check: every container running a dynamos1/ or tamjiyan/
# image must show a kind-import digest (docker.io/library/import-...). A
# registry digest means the node lost the locally-loaded fork build and
# silently pulled upstream; the script then exits nonzero and the session
# must reload the image (kind load + reset) before any counted run.
#
# Usage: capture_env_snapshot.sh

root="$(cd "$(dirname "$0")/.." && pwd)"
results_dir="${ENV_RESULTS_DIR:-$root/results/campaign-n50/env}"
ts="$(date +%Y%m%d-%H%M%S)"

show() {
	echo "\$ $*"
	"$@" 2>&1
	echo
}

# uva/vu/surf are legacy upstream stewards: agents run there but no VFL
# chain ever deploys, so a registry digest there is recorded, not failed.
img_check=$(kubectl get pods -A -o json 2>/dev/null | python3 -c "
import json, sys
legacy = {'uva', 'vu', 'surf'}
bad = 0
for p in json.load(sys.stdin)['items']:
    ns = p['metadata']['namespace']
    for cs in (p['status'].get('containerStatuses') or []):
        img = cs.get('image', '')
        if 'dynamos1/' not in img and 'tamjiyan/' not in img:
            continue
        iid = cs.get('imageID', '')
        if 'import-' in iid:
            tag = 'OK    '
        elif ns in legacy:
            tag = 'LEGACY'
        else:
            tag = 'STALE '
            bad += 1
        print('%s %s/%s %s %s -> %s' % (tag, ns, p['metadata']['name'], cs['name'], img, iid))
print(('image check: %d STALE fork images' % bad) if bad
      else 'image check: all fork images on the VFL path run kind-import digests')
sys.exit(1 if bad else 0)")
img_rc=$?

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
	echo "\$ fork-image provenance (containers on dynamos1/ or tamjiyan/ images)"
	echo "$img_check"
	echo
} > "$results_dir/${ts}_env-snapshot.txt"

{
	show date
	show git -C "$root" rev-parse HEAD
	echo "\$ docker exec kind-control-plane crictl images | grep -E 'dynamos1|tamjiyan'"
	docker exec kind-control-plane crictl images 2>&1 | grep -E 'dynamos1|tamjiyan'
} > "$results_dir/${ts}_images.txt"

echo "captured: $results_dir/${ts}_env-snapshot.txt"
echo "captured: $results_dir/${ts}_images.txt"
if [ "$img_rc" -ne 0 ]; then
	echo "STALE fork images on the node; kind load the fork builds and reset before any counted run" >&2
	exit 1
fi
