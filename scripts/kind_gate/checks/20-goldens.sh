#!/usr/bin/env bash
# Goldens: the Job the server's agent creates for the VFL chain, as
# configured and with requiresGateway dropped from the two services, each
# compared with its file under goldens/ after the request's name, the job's
# uid, the server-side bookkeeping and the image tag are normalised.
#
#   GOLDEN_UPDATE=1   write the files instead of comparing

set -u

EXP=GATE
root="$(cd "$(dirname "$0")/../../.." && pwd)"
. "$root/scripts/kind_gate/context.sh"
. "$root/scripts/capture_lib.sh"

TAG=stay-up-enforcement
CYCLES=1
USER_NAME="jake.jongejans@student.uva.nl"
STEWARD_NS=(server clientone clienttwo clientthree)
GATEWAY_MS=(vfl-train-model-demo vfl-train-demo)
APIPORT=18080
ORCHPORT=18082
export PORT="$ORCHPORT"
POLL_MAX="$(poll_max_for_cycles "$CYCLES")"
JOB_WAIT=90
golden_dir="$root/scripts/kind_gate/goldens"
out_dir="$(mktemp -d)"

PIDS=()
cleanup() {
	local p
	for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done
	pkill -f "port-forward.*${APIPORT}:8080" 2>/dev/null
	rm -rf "$out_dir"
}
trap cleanup EXIT

etcdctl_pod() {
	kubectl exec ${1:+-i} -n core etcd-0 -c etcd -- sh -c \
		"ETCDCTL_API=3 /usr/local/bin/etcdctl --endpoints=localhost:2379 $2"
}

# The orchestrator restores requiresGateway on its next boot, so the next
# reset undoes this.
flip_requires_gateway_off() {
	local ms key cur
	for ms in "${GATEWAY_MS[@]}"; do
		key="/microservices/${ms}/chainMetadata"
		cur=$(etcdctl_pod "" "get $key --print-value-only")
		[ -n "$cur" ] || fail "no chainMetadata in etcd for $ms"
		echo "$cur" | python3 -c "
import sys, json
m = json.load(sys.stdin)
m.pop('requiresGateway', None)
print(json.dumps(m))" | etcdctl_pod -i "put $key \"\$(cat)\"" >/dev/null \
			|| fail "etcd put failed for $ms"
		cur=$(etcdctl_pod "" "get $key --print-value-only")
		echo "$cur" | jq -e '.requiresGateway == true' >/dev/null \
			&& fail "requiresGateway still true for $ms after flip"
	done
}

has_gateway() { # $1 = captured Job
	jq -e '[.spec.template.spec.containers[].name] | index("policy-checkpoint-gateway")' "$1" >/dev/null
}

# Trigger one run and print the server's Job as soon as it exists.
server_job() {
	local i job=""
	trigger "$CYCLES" >/dev/null || exit 1
	for i in $(seq 1 "$JOB_WAIT"); do
		job=$(kubectl get jobs -n server -o name 2>/dev/null | grep jake | head -1 | cut -d/ -f2)
		[ -n "$job" ] && break
		sleep 1
	done
	[ -n "$job" ] || fail "no chain job in server after ${JOB_WAIT}s"
	kubectl get job -n server "$job" -o json | jq -S --arg tag ":${TAG}" '
		.metadata.uid as $uid
		| (.metadata.name | capture("^(?<request>.*-[0-9a-f]{8})")).request as $request
		| del(.status, .metadata.creationTimestamp, .metadata.resourceVersion,
			.metadata.generation, .metadata.managedFields)
		| walk(if type == "string"
			then gsub($uid; "<uid>") | gsub($request; "<request>") | sub($tag + "$"; ":<tag>")
			else . end)'
}

compare() { # $1 = golden name
	local golden="$golden_dir/$1.json" got="$out_dir/$1.json"
	[ -s "$got" ] || fail "no Job captured for $1"
	if [ "${GOLDEN_UPDATE:-0}" = 1 ]; then
		mkdir -p "$golden_dir"
		cp "$got" "$golden"
		echo "written: $golden"
		return 0
	fi
	[ -f "$golden" ] || fail "no golden file $golden (run once with GOLDEN_UPDATE=1)"
	diff -u "$golden" "$got" || fail "the server's Job differs from $1.json"
	echo "OK: the server's Job equals $1.json"
}

step "golden: the server's Job as configured"
reset_and_seed
server_job > "$out_dir/job-server-gateway.json" || exit 1
has_gateway "$out_dir/job-server-gateway.json" || fail "the Job as configured has no enforcement point container"
compare job-server-gateway

step "golden: the server's Job with requiresGateway dropped"
reset_and_seed
flip_requires_gateway_off
delete_state_pvcs
server_job > "$out_dir/job-server-no-gateway.json" || exit 1
has_gateway "$out_dir/job-server-no-gateway.json" && fail "the Job still has an enforcement point container after the flip"
compare job-server-no-gateway

step "a chain without a stateful service: no claim, no hand-over, no idle Job"
[ -z "$(state_pvc_of server)" ] || fail "server has a state claim: $(state_pvc_of server)"
kubectl -n server logs -l type=agent -c server --tail=-1 2>/dev/null | grep -q -E 'No idle gateway left on PVC|Deploying on PVC' \
	&& fail "the agent in server went through a hand-over"
idle=$(kubectl -n server get jobs -l dynamos/gateway=idle -o name 2>/dev/null)
[ -z "$idle" ] || fail "server has an idle Job: $idle"
echo "OK: server has its chain Job, no state claim and no idle Job, and its agent logged no hand-over"
