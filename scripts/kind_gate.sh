#!/usr/bin/env bash
# Kind-level gate for this branch: bring up a dedicated cluster, build and
# load the branch's images, deploy the request path, run the unit commands
# and every check under scripts/kind_gate/checks/, collect logs on failure,
# and tear the cluster down again.
#
#   KEEP=1   leave the cluster up; the next run reuses it
#
# The cluster is "stayup" and is reached only through its own kubeconfig
# file: ~/.kube/config and cluster "kind" are never used. Every image built
# here carries the tag stay-up-enforcement and no other, nothing is pushed,
# and nothing is pulled outside docker build. Logs and build contexts go to
# a scratch directory outside the repository.

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
gate_dir="$root/scripts/kind_gate"

CLUSTER=stayup
NODE="${CLUSTER}-control-plane"
NODE_IMAGE="kindest/node:v1.31.0@sha256:53df588e04085fd41ae12de0c3fe4c72f7013bba32a20e7325357a1ac94ba865"
TAG=stay-up-enforcement
ACCOUNT=tamjiyan
GO_IMAGES=(sidecar policy-enforcer orchestrator agent api-gateway policy-checkpoint-gateway)
PY_IMAGES=(vfl-train-model-demo anonymize-test vfl-train-demo differential-p-test)
# Any image with setuptools builds the library wheel; it runs without network.
WHEEL_BUILDER="tamjiyan/vfl-train-demo:latest"
KEEP="${KEEP:-0}"

SCRATCH="${KIND_GATE_SCRATCH:-$HOME/stay-up-scratch}"
run_dir="$SCRATCH/gate/$(date +%Y%m%d-%H%M%S)"
work="$run_dir/work"
mkdir -p "$work"
exec > >(tee "$run_dir/gate.log") 2>&1

export KUBECONFIG="$SCRATCH/kubeconfig"
export KIND_CLUSTER_NAME="$CLUSTER"

STEP="start"
step() { STEP="$*"; echo; echo "=== [gate] $*"; }
die() { echo "[gate] FAIL: $*" >&2; exit 1; }

# The image IDs behind every tag of the three accounts except this branch's
# own. They must be the same after the run as before it.
frozen_tags() {
	docker images --no-trunc --format '{{.Repository}}:{{.Tag}} {{.ID}}' \
		| grep -E '^(dynamos1|tamjiyan|2bias123)/' | grep -v ":${TAG} " | LC_ALL=C sort
}

assert_context() {
	local ctxs cur
	ctxs=$(kubectl config get-contexts -o name)
	cur=$(kubectl config current-context)
	[ "$ctxs" = "kind-$CLUSTER" ] && [ "$cur" = "kind-$CLUSTER" ] \
		|| die "$KUBECONFIG must hold exactly one context, kind-$CLUSTER, and it must be current (contexts: ${ctxs}; current: ${cur})"
}

node_has() { docker exec "$NODE" crictl inspecti -q "$1" >/dev/null 2>&1; }

collect_failure() {
	local out="$run_dir/failure" ns pod ready status c
	mkdir -p "$out"
	kubectl get events -A --sort-by=.lastTimestamp > "$out/events.txt" 2>&1
	kubectl get pods -A -o wide > "$out/pods.txt" 2>&1
	kubectl get pods -A --no-headers 2>/dev/null | while read -r ns pod ready status _; do
		[ "$status" = Completed ] && continue
		[ "$status" = Running ] && [ "${ready%/*}" = "${ready#*/}" ] && continue
		kubectl -n "$ns" describe pod "$pod" > "$out/describe-$ns-$pod.txt" 2>&1
	done
	for ns in api-gateway orchestrator server clientone clienttwo clientthree; do
		for pod in $(kubectl -n "$ns" get pods -o name 2>/dev/null); do
			pod="${pod#pod/}"
			for c in $(kubectl -n "$ns" get pod "$pod" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null); do
				kubectl -n "$ns" logs "$pod" -c "$c" > "$out/log-$ns-$pod-$c.txt" 2>&1
				kubectl -n "$ns" logs "$pod" -c "$c" --previous > "$out/log-$ns-$pod-$c.previous.txt" 2>/dev/null \
					|| rm -f "$out/log-$ns-$pod-$c.previous.txt"
			done
		done
		kubectl -n "$ns" get jobs,pvc -o yaml > "$out/jobs-pvc-$ns.yaml" 2>&1
	done
	docker exec "$NODE" sh -c 'for f in /var/local-path-provisioner/*_state-*/audit/*; do [ -f "$f" ] || continue; echo "== $f"; cat "$f"; done' \
		> "$out/audit-logs.txt" 2>&1
	echo "[gate] failure bundle: $out"
}

teardown() {
	kind delete cluster --name "$CLUSTER" --kubeconfig "$KUBECONFIG"
	rm -f "$KUBECONFIG"
}

finish() {
	local rc=$?
	trap - EXIT
	if [ "$rc" != 0 ]; then
		echo "[gate] FAILED in step: $STEP"
		[ -s "$KUBECONFIG" ] && collect_failure || true
	fi
	if [ "$KEEP" = 1 ]; then
		echo "[gate] KEEP=1: cluster $CLUSTER left up"
	else
		teardown || rc=1
	fi
	rm -rf "$work"
	if [ -f "$run_dir/frozen-tags.before" ]; then
		frozen_tags > "$run_dir/frozen-tags.after"
		if ! cmp -s "$run_dir/frozen-tags.before" "$run_dir/frozen-tags.after"; then
			echo "[gate] FAIL: a tag outside $TAG moved during the run:" >&2
			diff "$run_dir/frozen-tags.before" "$run_dir/frozen-tags.after" >&2 || true
			rc=1
		fi
	fi
	[ "$rc" = 0 ] && echo "[gate] OK" || echo "[gate] FAILED (log: $run_dir/gate.log)"
	exit "$rc"
}
trap finish EXIT

step "guards"
branch=$(git -C "$root" rev-parse --abbrev-ref HEAD)
case "$branch" in
	fabric-port|fabric-campaign|main) die "refusing to run on branch $branch" ;;
esac
if pgrep -fa '^([^ ]*/)?bash ([^ ]*/)?(capture_e[0-9a-z_]*|run_e3_[0-9a-z_]*|smoke_batch)\.sh' | grep -v fakeworld | grep -q .; then
	die "a capture is running on this machine"
fi
frozen_tags > "$run_dir/frozen-tags.before"
echo "[gate] branch $branch at $(git -C "$root" rev-parse --short HEAD), run directory $run_dir"

step "cluster"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
	echo "[gate] reusing cluster $CLUSTER"
	[ -s "$KUBECONFIG" ] || kind export kubeconfig --name "$CLUSTER" --kubeconfig "$KUBECONFIG"
else
	rm -f "$KUBECONFIG"
	docker image inspect "$NODE_IMAGE" >/dev/null 2>&1 \
		|| die "the node image is not in the host's docker store: $NODE_IMAGE"
	kind create cluster --name "$CLUSTER" --kubeconfig "$KUBECONFIG" --image "$NODE_IMAGE" --wait 180s
fi
assert_context
kubectl wait --for=condition=Ready node --all --timeout=180s

step "images: build"
build_go() {
	local ctx="$work/$1"
	mkdir -p "$ctx"
	cp "$root/go/cmd/$1/"*.go "$ctx/"
	cp "$root/go/Dockerfile" "$root/go/go.mod" "$root/go/go.sum" "$ctx/"
	cp -r "$root/go/pkg" "$ctx/"
	docker build --build-arg NAME="$1" -t "$ACCOUNT/$1:$TAG" "$ctx" > "$run_dir/build-$1.log" 2>&1 \
		|| die "docker build failed for $1 (see $run_dir/build-$1.log)"
	echo "[gate] built $ACCOUNT/$1:$TAG"
}
build_py() {
	local ctx="$work/$1" wheel
	cp -r "$root/python/$1" "$ctx"
	cp "$root/python/Dockerfile" "$ctx/"
	cp "$work/wheel/"*.whl "$ctx/"
	cp -r "$root/python/dynamos-python-lib/protofiles" "$ctx/"
	mkdir -p "$ctx/data"
	wheel=$(basename "$ctx"/*.whl)
	docker build --build-arg NAME="$1" --build-arg WHEEL_NAME="$wheel" -t "$ACCOUNT/$1:$TAG" "$ctx" > "$run_dir/build-$1.log" 2>&1 \
		|| die "docker build failed for $1 (see $run_dir/build-$1.log)"
	echo "[gate] built $ACCOUNT/$1:$TAG"
}
for name in "${GO_IMAGES[@]}"; do build_go "$name"; done
# A fixed timestamp keeps the wheel identical between runs, so the image
# layers after it stay cached.
mkdir -p "$work/wheel"
docker run --rm --pull=never --network=none --user "$(id -u):$(id -g)" -e HOME=/tmp -e SOURCE_DATE_EPOCH=315532800 \
	-v "$root/python/dynamos-python-lib:/src:ro" -v "$work/wheel:/out" "$WHEEL_BUILDER" \
	sh -c 'cp -r /src /tmp/lib && cd /tmp/lib && python setup.py -q bdist_wheel -d /out' > "$run_dir/build-wheel.log" 2>&1 \
	|| die "wheel build failed (see $run_dir/build-wheel.log)"
for name in "${PY_IMAGES[@]}"; do build_py "$name"; done

step "images: load"
for name in "${GO_IMAGES[@]}" "${PY_IMAGES[@]}"; do
	kind load docker-image "$ACCOUNT/$name:$TAG" --name "$CLUSTER"
done
missing=()
while read -r ref; do
	case "$ref" in ''|\#*) continue ;; esac
	node_has "$ref" && continue
	if docker image inspect "$ref" >/dev/null 2>&1; then
		kind load docker-image "$ref" --name "$CLUSTER"
	else
		missing+=("$ref")
	fi
done < "$gate_dir/thirdparty-images.txt"
[ "${#missing[@]}" -eq 0 ] \
	|| die "not on the node and not in the host's docker store: ${missing[*]}"

# Every image a manifest names must already be on the node: the cluster
# never pulls.
require_images() { # $1 = file of rendered manifests
	local ref absent=()
	for ref in $(grep -E '^[[:space:]]*(- )?image: ' "$1" | sed -E 's/^[[:space:]]*(- )?image: *//; s/["'\'']//g' | sort -u); do
		node_has "$ref" || absent+=("$ref")
	done
	[ "${#absent[@]}" -eq 0 ] || die "$(basename "$1") names images that are not on the node: ${absent[*]}"
	if grep -q 'imagePullPolicy: Always' "$1"; then
		die "$(basename "$1") has a container with imagePullPolicy Always"
	fi
}
mesh() { # $1 = name, rest = linkerd arguments
	local name="$1"
	shift
	linkerd "$@" | sed 's/imagePullPolicy: Always/imagePullPolicy: IfNotPresent/' > "$work/$name.yaml"
	require_images "$work/$name.yaml"
	kubectl apply -f "$work/$name.yaml" > "$run_dir/apply-$name.log" 2>&1 \
		|| die "kubectl apply failed for $name (see $run_dir/apply-$name.log)"
}
release() { # $1 = release, $2 = chart, rest = helm arguments
	local name="$1" chart="$root/charts/$2"
	shift 2
	helm template "$name" "$chart" -f "$chart/values.yaml" "$@" --post-renderer "$gate_dir/post-render.sh" > "$work/$name.yaml"
	require_images "$work/$name.yaml"
	helm upgrade -i -f "$chart/values.yaml" "$name" "$chart" "$@" --post-renderer "$gate_dir/post-render.sh"
}

assert_context
step "deploy: mesh"
if kubectl get namespace linkerd >/dev/null 2>&1; then
	echo "[gate] mesh already installed"
else
	# The heartbeat job reports to the vendor once a day; this cluster stays offline.
	mesh linkerd-crds install --crds
	mesh linkerd install --set proxyInit.runAsRoot=true --set disableHeartBeat=true
	kubectl -n linkerd wait --for=condition=Available deployment --all --timeout=300s
	# The core chart puts objects in linkerd-jaeger, and every service exports
	# its traces to the collector there.
	mesh linkerd-jaeger jaeger install
fi
kubectl -n linkerd wait --for=condition=Available deployment --all --timeout=300s
kubectl -n linkerd-jaeger wait --for=condition=Available deployment --all --timeout=300s

assert_context
step "deploy: namespaces and launch files"
rabbit_pw=$(kubectl -n orchestrator get secret rabbit -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
[ -n "$rabbit_pw" ] || rabbit_pw=$(openssl rand -hex 16)
release namespaces namespaces --set secret.password="$rabbit_pw"
# The fill runs from a copy, so the tracked tarball and definitions.json in
# configuration/ are not rewritten.
cfg="$work/configuration"
mkdir -p "$cfg"
cp -r "$root/configuration/k8s_service_files" "$root/configuration/etcd_launch_files" "$cfg/"
cp "$root/configuration/fill-rabbit-pvc.sh" "$cfg/"
sed 's/^\( *\)image: busybox$/&\n\1imagePullPolicy: IfNotPresent/' "$root/configuration/temp-pod.yaml" > "$cfg/temp-pod.yaml"
require_images "$cfg/temp-pod.yaml"
rabbit_hash=$(python3 -c 'import base64,hashlib,os,sys; pw=sys.argv[1].encode(); salt=os.urandom(4); print(base64.b64encode(salt+hashlib.sha256(salt+pw).digest()).decode())' "$rabbit_pw")
sed "s|%PASSWORD%|${rabbit_hash}|g" "$cfg/k8s_service_files/definitions_example.json" > "$cfg/k8s_service_files/definitions.json"
(cd "$cfg" && bash ./fill-rabbit-pvc.sh) > "$run_dir/fill.log" 2>&1 || die "the fill step failed (see $run_dir/fill.log)"

assert_context
step "deploy: core"
release core core --set hostPath="$HOME"
kubectl -n core rollout status statefulset/etcd --timeout=300s
kubectl -n core rollout status deployment/rabbitmq --timeout=300s

assert_context
step "deploy: request path"
release orchestrator orchestrator --set branchNameTag="$TAG"
release agents agents --set branchNameTag="$TAG" --set chainImageTag="$TAG"
release surf thirdparty --set branchNameTag="$TAG"
release api-gateway api-gateway --set branchNameTag="$TAG"
for entry in api-gateway/api-gateway orchestrator/policy-enforcer orchestrator/orchestrator \
	server/server clientone/clientone clienttwo/clienttwo clientthree/clientthree; do
	kubectl -n "${entry%%/*}" rollout status "deployment/${entry##*/}" --timeout=300s
done
kubectl -n orchestrator exec deploy/orchestrator -c orchestrator -- ls /app/etcd/agreements.json >/dev/null \
	|| die "the launch files did not reach the orchestrator's volume (see $run_dir/fill.log)"
# The API server forgets events after an hour, so the pulls of the deploy
# are looked for now as well as at the end.
"$gate_dir/checks/90-no-pull.sh" || die "the cluster pulled an image during the deploy"

step "unit: go"
(
	cd "$root/go"
	GOPROXY=off go build ./...
	GOPROXY=off go vet ./...
)
# pkg/lib has three tests whose expected order comes from map iteration. A
# failure of only those is rerun; anything else fails the gate.
ORDER_DEPENDENT=" TestGetNotMatchedElements TestSliceIntersectAndDifference2 TestSliceIntersectAndDifferenceNoIntersection "
go_log="$run_dir/go-test.log"
if (cd "$root/go" && GOPROXY=off go test -count=1 ./...) > "$go_log" 2>&1; then
	grep -E '^(ok|FAIL|---)' "$go_log" || true
else
	failed=$(grep -E '^--- FAIL: ' "$go_log" | sed -E 's/^--- FAIL: ([^ ]+).*/\1/' | sort -u | tr '\n' ' ')
	other=""
	for name in $failed; do
		case "$ORDER_DEPENDENT" in *" $name "*) ;; *) other="$other$name " ;; esac
	done
	other_pkg=$(grep -E '^FAIL[[:space:]]+[^[:space:]]' "$go_log" | grep -v '/pkg/lib[[:space:]]' || true)
	if [ -z "$failed" ] || [ -n "$other" ] || [ -n "$other_pkg" ]; then
		tail -n 40 "$go_log"
		die "go test failed: ${other:-${other_pkg:-no test named, see $go_log}}"
	fi
	echo "[gate] order-dependent pkg/lib tests failed (${failed}); rerunning pkg/lib"
	rerun=1
	for try in 1 2 3 4 5 6 7 8 9 10; do
		if (cd "$root/go" && GOPROXY=off go test -count=1 ./pkg/lib) >> "$go_log" 2>&1; then
			rerun=0
			break
		fi
	done
	[ "$rerun" = 0 ] || die "pkg/lib still fails after 10 reruns (see $go_log)"
	echo "[gate] pkg/lib passed on rerun $try"
fi

step "unit: python"
docker run --rm --pull=never --network=none -v "$root/python:/mnt:ro" -e PYTHONDONTWRITEBYTECODE=1 \
	-e PYTHONPATH=/mnt/dynamos-python-lib:/mnt/dynamos-python-lib/protofiles -w /mnt/dynamos-python-lib \
	"$WHEEL_BUILDER" python -m unittest discover -s tests -v > "$run_dir/python-test.log" 2>&1 \
	|| { tail -n 40 "$run_dir/python-test.log"; die "python tests failed (see $run_dir/python-test.log)"; }
tail -n 4 "$run_dir/python-test.log"

for check in "$gate_dir"/checks/*.sh; do
	assert_context
	step "check: $(basename "$check")"
	"$check" || die "check $(basename "$check") failed"
done
