import os
import sys
import json
import time
import socket
import threading

import pandas as pd

from google.protobuf.struct_pb2 import Struct
from google.protobuf.empty_pb2 import Empty
from dynamos.ms_init import NewConfiguration
from dynamos.signal_flow import signal_continuation, signal_wait
from dynamos.logger import InitLogger
from dynamos.gateway_lifecycle import connect_gateway, shutdown_gateway
import rabbitMQ_pb2 as rabbitTypes
import microserviceCommunication_pb2 as msCommTypes
from opentelemetry.context.context import Context

# --- DYNAMOS Interface code At the TOP ---------------------------
if os.getenv('ENV') == 'PROD':
    import config_prod as config
else:
    import config_local as config

logger = InitLogger()

# Events to start the shutdown of this Microservice, can be used to call 'signal_shutdown'
stop_event = threading.Event()
stop_microservice_condition = threading.Condition()

# Events to make sure all services have started before starting to process a message
wait_for_setup_event = threading.Event()
wait_for_setup_condition = threading.Condition()

ms_config = None
gateway = None

# --- END DYNAMOS Interface code At the TOP ----------------------

STATE_CLASS = "aggregate_result"
STATE_KEY = "latest"


# Was necessary in all microservices I used since services would try to connect to sidecar instantly, resulting in crash
def wait_for_port(host, port, wait_time):
    deadline = time.time() + wait_time
    last_err = None
    while time.time() < deadline:
        try:
            with socket.create_connection((host, port), timeout=1):
                return
        except OSError as e:
            last_err = e
            time.sleep(1)
    raise RuntimeError(f"Timed out waiting for {host}:{port} to open. Last error: {last_err}")


# Deterministic demo computation: row count and per-column mean over the
# steward's dataset. The result bytes are stable for a given input file.
def compute_aggregate(csv_path):
    df = pd.read_csv(csv_path, delimiter=",")
    means = df.mean(numeric_only=True)
    result = {
        "count": int(df.shape[0]),
        "means": {col: float(means[col]) for col in sorted(means.index)},
    }
    return json.dumps(result, sort_keys=True, separators=(",", ":")).encode("utf-8")


# Gateway-mediated reuse: anything but an ALLOW with a payload means recompute.
def read_persisted_result():
    if gateway is None:
        return None
    try:
        logger.info("Result read requested")
        resp = gateway.validate_state_read(STATE_CLASS, STATE_KEY)
    except Exception as e:
        logger.warning(f"Result read failed ({e}); recomputing")
        return None
    if not resp.allowed:
        logger.info(f"Result read denied ({resp.reason}); recomputing")
        return None
    logger.info(f"Reusing persisted result: written_unix_seconds={resp.written_unix_seconds}")
    return resp.payload


# A denied or failed write never disturbs the response: the result is still
# returned, persistence stops.
def write_result(payload):
    if gateway is None:
        return
    try:
        logger.info("Result write requested")
        decision = gateway.request_state_write(STATE_CLASS, STATE_KEY, payload)
        if decision.allowed:
            logger.info("Result write allowed")
        else:
            logger.warning(f"Result write denied ({decision.reason}); continuing without persistence")
    except Exception as e:
        logger.warning(f"Result write failed ({e}); continuing without persistence")


def request_handler(msComm: msCommTypes.MicroserviceCommunication,
                    ctx: Context = None):
    global ms_config
    logger.info(f"Received original request type: {msComm.request_type}")

    # Ensure all connections have finished setting up before processing data
    signal_wait(wait_for_setup_event, wait_for_setup_condition)

    try:
        request = rabbitTypes.Request()
        msComm.original_request.Unpack(request)
    except Exception as e:
        logger.error(f"Unexpected original request received: {e}")
        ms_config.next_client.ms_comm.send_data(msComm, msComm.data, {})
        return Empty()

    if request.type == "aggregateRequest":
        data = Struct()
        payload = read_persisted_result()
        if payload is not None:
            data.update({"result": payload.decode("utf-8"), "resultSource": "reused"})
        else:
            steward = os.getenv("DATA_STEWARD_NAME", "").lower()
            csv_path = os.path.join(config.dataset_filepath, f"{steward}Data.csv")
            try:
                payload = compute_aggregate(csv_path)
            except Exception as e:
                logger.error(f"Failed to compute aggregate from {csv_path}: {e}")
                ms_config.next_client.ms_comm.send_data(msComm, data, dict(msComm.metadata))
                signal_continuation(stop_event, stop_microservice_condition)
                return Empty()
            write_result(payload)
            data.update({"result": payload.decode("utf-8"), "resultSource": "computed"})

        ms_config.next_client.ms_comm.send_data(msComm, data, dict(msComm.metadata))
        # One request per job: answering completes the chain and ends the pod.
        signal_continuation(stop_event, stop_microservice_condition)
        return Empty()

    logger.error(f"An unknown request_type: {request.type}")
    ms_config.next_client.ms_comm.send_data(msComm, msComm.data, {})
    return Empty()


# ---  DYNAMOS Interface code At the Bottom --------

def main():
    global ms_config
    global gateway

    sidecar_port = int(os.getenv("SIDECAR_PORT", "50051"))
    logger.info(f"Waiting for sidecar gRPC on localhost:{sidecar_port} ...")
    wait_for_port("127.0.0.1", sidecar_port, wait_time=90)

    ms_config = NewConfiguration(
        config.service_name, config.grpc_addr, request_handler)

    gateway = connect_gateway(config.service_name, None)

    signal_continuation(wait_for_setup_event, wait_for_setup_condition)

    try:
        signal_wait(stop_event, stop_microservice_condition)
    except KeyboardInterrupt:
        logger.debug("KeyboardInterrupt received, stopping server...")
        signal_continuation(stop_event, stop_microservice_condition)

    shutdown_gateway(gateway, "ms_exit")
    ms_config.stop(2)
    logger.debug(f"Exiting {config.service_name}")
    sys.exit(0)


# ---  END DYNAMOS Interface code At the Bottom -----------------


if __name__ == "__main__":
    main()
