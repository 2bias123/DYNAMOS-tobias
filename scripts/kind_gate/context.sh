# Sourced by every check file: a check acts on the dedicated cluster only.
if [ "$(kubectl config current-context 2>/dev/null)" != "kind-stayup" ]; then
	echo "kind gate checks run only against context kind-stayup" >&2
	exit 1
fi
