#!/usr/bin/env bash
# Pin: the agents chart with its default values renders as the hash under
# goldens/ records. The hash is changed by hand, never by GOLDEN_UPDATE.

set -u

root="$(cd "$(dirname "$0")/../../.." && pwd)"
golden="$root/scripts/kind_gate/goldens/agents-render.sha256"

got=$(helm template "$root/charts/agents" | sha256sum | cut -d' ' -f1)
if [ "$got" != "$(cat "$golden" 2>/dev/null)" ]; then
	echo "GATE FAIL: the agents chart's default render changed (sha256 now $got)" >&2
	exit 1
fi
echo "OK: the agents chart's default render is unchanged"
