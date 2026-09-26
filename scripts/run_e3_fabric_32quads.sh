#!/usr/bin/env bash
set -u

# E3 balanced-order session on the FABRIC deployment environment: the
# counted distributed-replication set (protocol inherited unchanged from
# run_e3_balanced_32quads.sh — 32 Williams-rotated a,b,c,h quadruplets of
# 50-round runs).
# Artifacts land in results/e3-fabric/.
#
# Differences from the kind wrapper, all environment not protocol:
#   - The frozen-build gate is two-stage (scripts/e3_fabric_digests.txt,
#     recorded at Hub-push time). Stage 1 checks every running fork
#     container's imageID via kubectl; the pinned agent (persistent steward
#     pods) must be running and matching. Stage 2 covers the three job-only
#     pins (injected chain gateway + the two VFL training MSs), which exist
#     only while a round runs: an absent one is verified against the Hub
#     REGISTRY — the digest its :latest tag resolves to (the ref the
#     job-deploy path pulls) must equal the pin. Fails closed on registry
#     errors. Same guarantee as the kind crictl gate: code that runs =
#     frozen build.
#   - E3_TRANSPORT defaults to nodeport (kubectl port-forward is broken on
#     the testbed VMs; services are patched to NodePort and curled at a node
#     IP).
#   - E3_CROSSLOG_ASSERT=record: the dial-retry-absorbed ordering crosses two
#     node clocks here, so it is recorded, never asserted. Marker presence
#     stays hard.
#   - POLL_MAX: set from the timing probe before the counted session
#     (round times differ from kind; the default is sized on ~1 s rounds).
#
# Run from the slice's control node (kubectl against the local admin.conf).
# Usage: run_e3_fabric_32quads.sh [start_quad]
#   start_quad resumes a stopped session (failed quadruplet reruns in full).
#   QUADS / CYCLES / E3_RESULTS_DIR / POLL_MAX pass through for uncounted
#   dry runs, e.g.: E3_RESULTS_DIR=/tmp/e3-dryrun QUADS=1 CYCLES=5 $0

root="$(cd "$(dirname "$0")/.." && pwd)"
digests_file="$root/scripts/e3_fabric_digests.txt"

echo "=== frozen-build gate: running containers vs the recorded Hub digests"
[ -f "$digests_file" ] || { echo "missing $digests_file" >&2; exit 1; }
if grep -q "PENDING" "$digests_file"; then
	echo "e3_fabric_digests.txt still carries PENDING entries; record the" >&2
	echo "registry digests from the Hub push (and mirror them into the freeze" >&2
	echo "record) before any counted run" >&2
	exit 1
fi

# No EXIT trap for the temp file: the script ends in exec, which skips
# traps — clean up explicitly on both gate outcomes instead.
pods_json=$(mktemp)
if ! kubectl get pods -A -o json > "$pods_json" 2>/dev/null; then
	rm -f "$pods_json"
	echo "cannot read pods (is kubectl pointed at the slice cluster?)" >&2
	exit 1
fi

if ! python3 - "$digests_file" "$pods_json" <<'PYEOF'
import json, sys, urllib.request

REGISTRY_AUTH = ('https://auth.docker.io/token'
                 '?service=registry.docker.io&scope=repository:%s:pull')
REGISTRY_MANIFEST = 'https://registry-1.docker.io/v2/%s/manifests/latest'
# Both docker and OCI types, single and index: Hub then answers with the
# top-level digest — for our single-arch pushes, the digest `docker push`
# printed (the :latest aliases were pushed digest-identical, 2026-09-20).
ACCEPT = ', '.join((
    'application/vnd.docker.distribution.manifest.v2+json',
    'application/vnd.docker.distribution.manifest.list.v2+json',
    'application/vnd.oci.image.manifest.v1+json',
    'application/vnd.oci.image.index.v1+json',
))

# Steward agent pods are persistent — the pinned agent must be RUNNING.
# The other pins are job-only images that exist while a round runs; when
# absent they are judged against the registry instead (stage 2 below).
MUST_RUN = ('agent',)

def registry_digest(repo):
    with urllib.request.urlopen(REGISTRY_AUTH % repo, timeout=30) as r:
        token = json.load(r)['token']
    req = urllib.request.Request(
        REGISTRY_MANIFEST % repo, method='HEAD',
        headers={'Authorization': 'Bearer ' + token, 'Accept': ACCEPT})
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.headers.get('Docker-Content-Digest', '')

pins = []
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        sub, digest = line.split()
        pins.append((sub, digest))

legacy = {'uva', 'vu', 'surf'}
seen = {sub: False for sub, _ in pins}
bad = 0
with open(sys.argv[2]) as f:
    pods = json.load(f)
for p in pods['items']:
    ns = p['metadata']['namespace']
    for cs in (p['status'].get('containerStatuses') or []):
        img = cs.get('image', '')
        # 2bias123/ is the re-pointed Hub account the FABRIC install pulls
        # from (2026-09-20); dynamos1/ and tamjiyan/ stay in the filter so
        # any leftover foreign ref still surfaces below as unpinned.
        if ('dynamos1/' not in img and 'tamjiyan/' not in img
                and '2bias123/' not in img):
            continue
        iid = cs.get('imageID', '')
        # Only the four decisive images are pinned; other fork-org images
        # (sidecar, core services) legitimately run registry builds and are
        # recorded, not judged.
        pinned = next((s for s, d in pins if s in img), None)
        if pinned is None:
            print('----  %s/%s %s -> %s (unpinned, recorded only)' % (ns, p['metadata']['name'], img, iid))
        elif dict(pins)[pinned] in iid:
            print('OK    %s/%s %s -> pinned digest (%s)' % (ns, p['metadata']['name'], img, pinned))
            seen[pinned] = True
        elif ns in legacy:
            print('LEGACY %s/%s %s -> %s' % (ns, p['metadata']['name'], img, iid))
        else:
            print('DRIFT %s/%s %s -> %s' % (ns, p['metadata']['name'], img, iid))
            bad += 1
# Stage 2: pins with no running container. The agent must be running —
# absence fails the gate. Job-only pins are verified against the Hub
# registry: the digest their :latest tag resolves to (what the job-deploy
# path pulls mid-run) must equal the pin. Any registry error fails closed.
for s in [s for s, ok in seen.items() if not ok]:
    if any(m in s for m in MUST_RUN):
        print('ABSENT pinned image must be running and is not: %s' % s)
        bad += 1
        continue
    try:
        reg = registry_digest(s)
    except Exception as e:
        print('REGISTRY-FAIL %s -> %s (no verdict, gate fails closed)' % (s, e))
        bad += 1
        continue
    if reg == dict(pins)[s]:
        print('REGISTRY-OK %s :latest resolves to the pinned digest' % s)
    else:
        print('REGISTRY-DRIFT %s :latest -> %s (pin %s)'
              % (s, reg or '(no digest header)', dict(pins)[s]))
        bad += 1
sys.exit(1 if bad else 0)
PYEOF
then
	rm -f "$pods_json"
	echo "running containers have drifted off the recorded Hub digests (or a" >&2
	echo "pinned image is not running); redeploy from the pinned images before" >&2
	echo "any counted run" >&2
	exit 1
fi
rm -f "$pods_json"

QUADS="${QUADS:-32}"
CYCLES="${CYCLES:-50}"
E3_RESULTS_DIR="${E3_RESULTS_DIR:-$root/results/e3-fabric}"
E3_ENV=fabric
E3_TRANSPORT="${E3_TRANSPORT:-nodeport}"
E3_CROSSLOG_ASSERT=record
export QUADS CYCLES E3_RESULTS_DIR E3_ENV E3_TRANSPORT E3_CROSSLOG_ASSERT

exec "$root/scripts/run_e3_balanced.sh" "$@"
