#!/usr/bin/env bash
set -u

# Environment snapshot for the evidence env/ folder: toolchain and cluster
# versions, the dynamos images on the node(s), and a fork-image provenance
# check, as raw command output. Run at least once per experiment day, before
# the first counted capture.
#
# E3_ENV picks the environment shape:
#
#   kind (default) — the provenance check requires every container running a
#   dynamos1/, tamjiyan/, or 2bias123/ image (2bias123 = the re-pointed Hub
#   account the FABRIC install pulls from, 2026-09-20) to show a kind-import digest
#   (docker.io/library/import-...). A registry digest means the node lost the
#   locally-loaded fork build and silently pulled upstream; the script exits
#   nonzero and the session must reload the image (kind load + reset) before
#   any counted run. images.txt reads the kind node via docker exec + crictl.
#
#   fabric — images come from Docker Hub by design, so the check inverts:
#   every fork container must show a registry digest (imageID carrying
#   @sha256:...); a kind-import digest there would mean an unpinned local
#   build. Digest EQUALITY against the freeze record is the counted wrapper's
#   gate (run_e3_fabric_32quads.sh), mirroring the kind split where equality
#   lives in run_e3_balanced_32quads.sh. images.txt lists per-container
#   image -> imageID via kubectl (no node access needed), and the snapshot
#   adds the storage picture (StorageClasses + provisioner config).
#
# Usage: capture_env_snapshot.sh

root="$(cd "$(dirname "$0")/.." && pwd)"
results_dir="${ENV_RESULTS_DIR:-$root/results/campaign-n50/env}"
ts="$(date +%Y%m%d-%H%M%S)"
E3_ENV="${E3_ENV:-kind}"

show() {
	echo "\$ $*"
	"$@" 2>&1
	echo
}

# uva/vu/surf are legacy upstream stewards: agents run there but no VFL
# chain ever deploys, so a wrong-origin digest there is recorded, not failed.
img_check=$(kubectl get pods -A -o json 2>/dev/null | E3_ENV="$E3_ENV" python3 -c "
import json, os, sys
env = os.environ['E3_ENV']
legacy = {'uva', 'vu', 'surf'}
bad = 0
for p in json.load(sys.stdin)['items']:
    ns = p['metadata']['namespace']
    for cs in (p['status'].get('containerStatuses') or []):
        img = cs.get('image', '')
        if ('dynamos1/' not in img and 'tamjiyan/' not in img
                and '2bias123/' not in img):
            continue
        iid = cs.get('imageID', '')
        # kind-import digests also carry @sha256, so the fabric check must
        # exclude them explicitly, not just require a sha.
        ok = ('import-' in iid) if env == 'kind' \
             else ('@sha256:' in iid and 'import-' not in iid)
        if ok:
            tag = 'OK    '
        elif ns in legacy:
            tag = 'LEGACY'
        else:
            tag = 'STALE '
            bad += 1
        print('%s %s/%s %s %s -> %s' % (tag, ns, p['metadata']['name'], cs['name'], img, iid))
want = 'kind-import' if env == 'kind' else 'registry'
print(('image check: %d STALE fork images' % bad) if bad
      else 'image check: all fork images on the VFL path run %s digests' % want)
sys.exit(1 if bad else 0)")
img_rc=$?

mkdir -p "$results_dir"

{
	show date
	show git -C "$root" rev-parse --abbrev-ref HEAD
	show git -C "$root" rev-parse HEAD
	show git -C "$root" status --short
	if [ "$E3_ENV" = "kind" ]; then
		show go version
		show kind version
	fi
	show kubectl version --client
	show kubectl get nodes -o wide
	show kubectl get pods -A
	if [ "$E3_ENV" = "fabric" ]; then
		show kubectl get sc
		show kubectl -n local-path-storage get cm local-path-config -o yaml
	fi
	echo "\$ fork-image provenance (containers on dynamos1/, tamjiyan/, or 2bias123/ images)"
	echo "$img_check"
	echo
} > "$results_dir/${ts}_env-snapshot.txt"

if [ "$E3_ENV" = "kind" ]; then
	{
		show date
		show git -C "$root" rev-parse HEAD
		echo "\$ docker exec kind-control-plane crictl images | grep -E 'dynamos1|tamjiyan'"
		docker exec kind-control-plane crictl images 2>&1 | grep -E 'dynamos1|tamjiyan'
	} > "$results_dir/${ts}_images.txt"
else
	{
		show date
		show git -C "$root" rev-parse HEAD
		echo "\$ running fork containers: image -> imageID (registry digests, via kubectl)"
		kubectl get pods -A -o json 2>/dev/null | python3 -c "
import json, sys
seen = set()
for p in json.load(sys.stdin)['items']:
    for cs in (p['status'].get('containerStatuses') or []):
        img = cs.get('image', '')
        if ('dynamos1/' not in img and 'tamjiyan/' not in img
                and '2bias123/' not in img):
            continue
        line = '%s -> %s' % (img, cs.get('imageID', ''))
        if line not in seen:
            seen.add(line)
            print(line)"
	} > "$results_dir/${ts}_images.txt"
fi

echo "captured: $results_dir/${ts}_env-snapshot.txt"
echo "captured: $results_dir/${ts}_images.txt"
if [ "$img_rc" -ne 0 ]; then
	if [ "$E3_ENV" = "kind" ]; then
		echo "STALE fork images on the node; kind load the fork builds and reset before any counted run" >&2
	else
		echo "STALE fork images: a fork container is not running a registry digest; redeploy from the pinned Hub images before any counted run" >&2
	fi
	exit 1
fi
