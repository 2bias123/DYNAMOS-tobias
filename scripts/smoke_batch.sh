#!/usr/bin/env bash
set -u

# Batch VFL smoke: reset -> port-forward -> fire vflTrainModelRequest -> poll.
# One clean reset per run so no stale AMQP topology carries between iterations.
#
# Env overrides:
#   RUNS       number of iterations            (default 5)
#   CYCLES     training rounds per request     (default 3)
#   PORT       local port for the forward      (default 8080)
#   POLL_MAX   max polls at 5s each            (default 18 -> ~90s)

RUNS="${RUNS:-5}"
CYCLES="${CYCLES:-3}"
PORT="${PORT:-8080}"
POLL_MAX="${POLL_MAX:-18}"
PF_PID=""

BASE="http://localhost:${PORT}/api/v1"

PAYLOAD=$(cat <<EOF
{
  "type": "vflTrainModelRequest",
  "user": { "id": "1234", "userName": "jake.jongejans@student.uva.nl" },
  "dataProviders": ["server", "clientone", "clienttwo", "clientthree"],
  "data_request": {
    "type": "vflTrainModelRequest",
    "data": {
      "learning_rate": 0.1,
      "cycles": ${CYCLES},
      "policy_removal": -1,
      "policy_reintroduction": -1,
      "training_backtrack": 0
    },
    "requestMetadata": {}
  }
}
EOF
)

# Extract a top-level JSON string field via python3 (no jq dependency).
json_field() { python3 -c "import sys,json; print(json.load(sys.stdin).get('$1',''))" 2>/dev/null; }

# Kill both our tracked forward and any stray one holding the port. A dropped
# forward (reset restarts the api-gateway) can leave a zombie on the port, which
# makes the next `port-forward` fail with "address already in use".
kill_forward() {
  [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null
  pkill -f "port-forward.*${PORT}:8080" 2>/dev/null
  PF_PID=""
}
trap kill_forward EXIT

pass=0; fail=0

for i in $(seq 1 "$RUNS"); do
  echo "=== RUN $i/$RUNS ==="

  # Drop any forward BEFORE reset (reset restarts the api-gateway anyway).
  kill_forward

  ./reset.sh || { echo "RUN $i: reset failed"; fail=$((fail+1)); continue; }

  # Fresh forward against the just-restarted pod.
  kubectl port-forward -n api-gateway "svc/api-gateway" "${PORT}:8080" >/dev/null 2>&1 &
  PF_PID=$!
  sleep 4   # let the forward establish

  resp=$(curl -s -X POST "${BASE}/requestApproval" \
    -H 'Content-Type: application/json' -d "$PAYLOAD")
  echo "response: $resp"

  run_id=$(echo "$resp" | json_field request_id)
  if [ -z "$run_id" ]; then
    echo "RUN $i: no request_id in response"; fail=$((fail+1)); continue
  fi

  ok=0
  for p in $(seq 1 "$POLL_MAX"); do
    st=$(curl -s "${BASE}/getTrainingStatus?id=${run_id}")
    sval=$(echo "$st" | json_field status)
    echo "  poll $p: status=${sval:-<none>}"
    case "$sval" in
      done|completed) ok=1; echo "$st"; break ;;
      failed)         echo "$st"; break ;;
    esac
    sleep 5
  done

  if [ "$ok" = 1 ]; then
    echo "RUN $i: PASS ($run_id)"; pass=$((pass+1))
  else
    echo "RUN $i: FAIL ($run_id)"; fail=$((fail+1))
  fi
done

echo "TOTAL: $pass PASS / $fail FAIL / $RUNS runs"
