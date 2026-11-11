#!/usr/bin/env bash
# Helm post-renderer for the dedicated kind cluster, which gets every image
# by kind load and must never pull: Always becomes IfNotPresent, the
# untagged busybox pods get the same policy, and the Job that downloads the
# upstream launch files is dropped (the gate's fill step writes that volume).

set -euo pipefail

awk '
function flush() {
	if (doc != "" && doc !~ /\n  name: init-etcd-pvc\n/) printf "%s", doc
	doc = ""
}
/^---/ { flush() }
{ doc = doc $0 "\n" }
END { flush() }
' | sed -e 's/imagePullPolicy: Always/imagePullPolicy: IfNotPresent/' \
	-e 's/^\( *\)image: busybox$/&\n\1imagePullPolicy: IfNotPresent/'
