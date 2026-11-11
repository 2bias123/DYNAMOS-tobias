#!/usr/bin/env bash
# The cluster gets every image by kind load. A pull by the kubelet means an
# image was missing on the node or a pull policy slipped through.

set -u

root="$(cd "$(dirname "$0")/../../.." && pwd)"
. "$root/scripts/kind_gate/context.sh"

pulls=$(kubectl get events -A --field-selector reason=Pulling \
	-o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.involvedObject.name}{" "}{.message}{"\n"}{end}')
if [ -n "$pulls" ]; then
	echo "GATE FAIL: the kubelet pulled or tried to pull:" >&2
	echo "$pulls" >&2
	exit 1
fi
echo "OK: no image pull on the cluster"
