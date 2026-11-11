#!/usr/bin/env bash
# The agent's role in each steward namespace: its service account may get
# and list pods, may get, list and create claims, and holds the Job verbs.
# It may not create, change, watch or delete a pod, or change, watch or
# delete a claim.

set -u

root="$(cd "$(dirname "$0")/../../.." && pwd)"
. "$root/scripts/kind_gate/context.sh"

STEWARD_NS=(server clientone clienttwo clientthree)
ALLOWED=(get/pods list/pods get/persistentvolumeclaims list/persistentvolumeclaims create/persistentvolumeclaims
	get/jobs list/jobs create/jobs delete/jobs)
REFUSED=(create/pods update/pods patch/pods watch/pods delete/pods deletecollection/pods
	update/persistentvolumeclaims patch/persistentvolumeclaims watch/persistentvolumeclaims
	delete/persistentvolumeclaims deletecollection/persistentvolumeclaims)

can_i() { # $1 = verb/resource, $2 = namespace
	kubectl auth can-i "${1%%/*}" "${1##*/}" -n "$2" --as="system:serviceaccount:$2:job-creator-$2" 2>/dev/null
}

for ns in "${STEWARD_NS[@]}"; do
	for pair in "${ALLOWED[@]}"; do
		answer=$(can_i "$pair" "$ns")
		if [ "$answer" != yes ]; then
			echo "GATE FAIL: job-creator-$ns may not ${pair%%/*} ${pair##*/} in $ns (answer: ${answer:-none})" >&2
			exit 1
		fi
	done
	for pair in "${REFUSED[@]}"; do
		answer=$(can_i "$pair" "$ns")
		if [ "$answer" != no ]; then
			echo "GATE FAIL: job-creator-$ns may ${pair%%/*} ${pair##*/} in $ns (answer: ${answer:-none})" >&2
			exit 1
		fi
	done
	echo "OK: job-creator-$ns: ${#ALLOWED[@]} verbs allowed, ${#REFUSED[@]} refused"
done
