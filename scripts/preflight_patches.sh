#!/usr/bin/env bash
# Fails if any of the recovery patches known to be required for a green
# smoke run are missing from the tree. Run before any build+deploy loop.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

fail() {
	echo "PREFLIGHT FAIL: $*" >&2
	exit 1
}

# B14: python:3.12-slim must install setuptools<80 so pkg_resources stays
# importable for opentelemetry.instrumentation.dependencies.
dockerfile="$repo_root/python/Dockerfile"
if ! grep -q 'setuptools<80' "$dockerfile"; then
	fail "B14 missing: $dockerfile does not pin setuptools<80"
fi

# B15: chain MS and sidecar containers must use PullIfNotPresent, otherwise
# the kubelet re-pulls from Docker Hub and clobbers the kind-cached image.
deploy_job="$repo_root/go/cmd/agent/deploy_job.go"
if grep -q 'ImagePullPolicy: v1.PullAlways' "$deploy_job"; then
	fail "B15 missing: $deploy_job still uses v1.PullAlways"
fi

echo "PREFLIGHT OK: B14, B15 applied"
