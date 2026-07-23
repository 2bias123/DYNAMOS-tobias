import pandas as pd
import numpy as np
import sys
import os
import io
import json
import socket
import time
import base64
import hashlib
import torch
import torch.nn as nn
import torch.optim as optim
import torch.nn.functional as F
from google.protobuf.struct_pb2 import Struct
from dynamos.ms_init import NewConfiguration
from dynamos.signal_flow import signal_continuation, signal_wait
from dynamos.logger import InitLogger
from dynamos.gateway_lifecycle import connect_gateway, shutdown_gateway
import rabbitMQ_pb2 as rabbitTypes

from google.protobuf.empty_pb2 import Empty
import microserviceCommunication_pb2 as msCommTypes
import threading
from opentelemetry.context.context import Context

np.set_printoptions(threshold=sys.maxsize)

# --- DYNAMOS Interface code At the TOP ---------------------------
if os.getenv('ENV') == 'PROD':
    import config_prod as config
else:
    import config_local as config

logger = InitLogger()
# tracer = InitTracer(config.service_name, config.tracing_host)

# Events to start the shutdown of this Microservice, can be used to call 'signal_shutdown'
stop_event = threading.Event()
stop_microservice_condition = threading.Condition()

# Events to make sure all services have started before starting to process a message
# Might be overkill, but good practice
wait_for_setup_event = threading.Event()
wait_for_setup_condition = threading.Condition()

ms_config = None
vfl_server = None
gateway = None
purge_pending = threading.Event()

# --- END DYNAMOS Interface code At the TOP ----------------------

# ---- LOCAL TEST SETUP OPTIONAL!

# Go into local test code with flag '-t'
# parser = argparse.ArgumentParser()
# parser.add_argument("-t", "--test", action='store_true')
# args = parser.parse_args()
# test = args.test

# --------------------------------


DEFAULT_LEARNING_RATE = 0.1
DEFAULT_NOF_CLIENTS = 3  # TODO: make it dynamic
# Gateway state key for the pre-shrink stash; separate from the per-round
# "latest" slot so a backtrack stash never clobbers the resume checkpoint.
PRESHRINK_STATE_KEY = "preshrink"

# Just for testing, mark so I can see if it works
def fp(s):
    return hashlib.sha256(s.encode("utf-8")).hexdigest()[:8]

# Changed the data loading to be hardcoded, old way was raising issues
# Also raises an error instead of returning None now
def load_data():
    # Server dataset hardcoded to correct location
    file_name = "/app/data/outcomeData.csv"
    logger.info(f"Server dataset: {file_name} loading...")
    # If file path doesn't exist, raise error.
    if not os.path.exists(file_name):
        raise FileNotFoundError(f"Server dataset: {file_name} not found.")
    # Reads and returns serverdata csv into pandas df
    return pd.read_csv(file_name, delimiter=",")

# Was necessary in all microservices I used since services would try to connect to sidecar instantly, resulting in crash
def wait_for_port(host, port, wait_time):
    deadline = time.time() + wait_time
    last_err = None
    # While deadline has not passed keeps trying to connect to sidecar.
    while time.time() < deadline:
        try:
            with socket.create_connection((host, port), timeout=1):
                return
        except OSError as e:
            last_err = e
            time.sleep(1)
    # If time is up raises error
    raise RuntimeError(f"Timed out waiting for {host}:{port} to open. Last error: {last_err}")


def serialise_array(array):
    payload = {
        "dtype": str(array.dtype),
        "shape": list(array.shape),
        "data": base64.b64encode(array.tobytes()).decode("ascii"),
    }
    return json.dumps(payload, separators=(",", ":"))


def deserialise_array(string, hook=None):
    obj = json.loads(string, object_pairs_hook=hook)
    dtype = np.dtype(obj["dtype"])
    raw = base64.b64decode(obj["data"].encode("ascii"))
    arr = np.frombuffer(raw, dtype=dtype)
    return arr.reshape(obj["shape"])


class ServerModel(nn.Module):
    def __init__(self, input_size):
        super(ServerModel, self).__init__()
        hidden_size = 16 # A small hidden layer 

        self.fc1 = nn.Linear(input_size, hidden_size)
        self.fc2 = nn.Linear(hidden_size, 1)
        # Optional dropout 
        # self.dropout = nn.Dropout(p=0.1)

    def forward(self, x):
        x = F.relu(self.fc1(x))
        # Optional dropout
        # x = self.dropout(x)
        x = self.fc2(x)
        return x


class VFLServer():
    def __init__(self, data):
        self.intermediate_neurons = 4  # Assuming each client outputs 4 features
        self.nof_clients = DEFAULT_NOF_CLIENTS
        self.model = ServerModel(self.intermediate_neurons * self.nof_clients) 
        # self.initial_parameters = ndarrays_to_parameters(
        #     [val.cpu().numpy()
        #      for _, val in server_configuration.model.state_dict().items()]
        # )
        self.optimizer = optim.Adam(self.model.parameters(), lr=DEFAULT_LEARNING_RATE, weight_decay=1e-4)  # optim.SGD(self.model.parameters(), lr=0.01)
        self.criterion = nn.MSELoss()
        self.round_index = 0
        # Had to change this, used to only work with REL_TOTALBTU
        # Should be changed to work with any target column in the future, now just works with these two
        if "REL_TOTALBTU" in data.columns:
            label_col = "REL_TOTALBTU"
        elif "Survived" in data.columns:
            label_col = "Survived"
        else:
            raise ValueError(
                f"Could not find a label column. Expected 'REL_TOTALBTU' or 'Survived'. "
                f"Columns are: {list(data.columns)}"
            )

        self.labels = torch.tensor(data[label_col].to_numpy()).float().unsqueeze(1)
        logger.info(f"Using label column: {label_col} (rows={self.labels.shape[0]})")

    def shrink_server_model(self, new_nof_clients, backtrack):
        """
        Creates a new ServerModel with fewer input neurons and copies over the trained weights
        from the old model for the first new_input_size neurons.
        """
        if backtrack and new_nof_clients==2:  # for now hardcoded to work only when reducing size from 3 to 2 clients
            # save model state to file
            logger.info("Saving server state before shrinking...")
            self.save_state(PRESHRINK_STATE_KEY)
        self.nof_clients = new_nof_clients
        # Create the new model
        # note: this is a completely new model with random weights
        self.model = ServerModel(self.intermediate_neurons * new_nof_clients)
        self.optimizer = optim.Adam(self.model.parameters(), lr=DEFAULT_LEARNING_RATE, weight_decay=1e-4)  # optim.SGD(self.model.parameters(), lr=0.01)

    
    def expand_server_model(self, new_nof_clients, backtrack):
        """
        Creates a new ServerModel with fewer input neurons and copies over the trained weights
        from the old model for the first new_input_size neurons.
        """
        self.nof_clients = new_nof_clients
        if backtrack and self.nof_clients==3:  # for now hardcoded to work only for 3 clients
            # save model state to file
            self.model = ServerModel(self.nof_clients * self.intermediate_neurons)
            self.optimizer = optim.Adam(self.model.parameters(), lr=DEFAULT_LEARNING_RATE, weight_decay=1e-4)  # optim.SGD(self.model.parameters(), lr=0.01)
            logger.info("Loading previous server state...")
            self.load_state(PRESHRINK_STATE_KEY)
        else:
            # Create the new model
            # note: this is a completely new model with random weights
            self.model = ServerModel(self.nof_clients * self.intermediate_neurons)
            self.optimizer = optim.Adam(self.model.parameters(), lr=DEFAULT_LEARNING_RATE, weight_decay=1e-4)  # optim.SGD(self.model.parameters(), lr=0.01)
    
    def update_server_model_architecture(self, old_nof_clients, new_nof_clients, backtrack):
        if new_nof_clients == old_nof_clients:
            # No change needed
            logger.debug("Number of clients unchanged, no model architecture update needed.")
        
        if new_nof_clients < old_nof_clients:
            logger.info(f"Number of clients decreased from {old_nof_clients} to {new_nof_clients}, shrinking model.")
            self.shrink_server_model(new_nof_clients, backtrack)
        
        if new_nof_clients > old_nof_clients:
            logger.info(f"Number of clients increased from {old_nof_clients} to {new_nof_clients}, expanding model.")
            self.expand_server_model(new_nof_clients, backtrack)


    def aggregate_fit(self, results,backtrack=False):
        global server_configuration

        # infer the number of clients based on the data received
        new_nof_clients = len(results)
        if new_nof_clients != self.nof_clients:
            print(f"Number of clients in results: {new_nof_clients}")
            print(f"Current number of clients: {self.nof_clients}")
            logger.info(f"Number of clients {new_nof_clients} does not match expected {self.nof_clients}, updating server architecture...")
            # TODO: update the architecture of the model
            self.update_server_model_architecture(self.nof_clients, new_nof_clients, backtrack)


        try:
            embedding_results = [
                torch.from_numpy(embedding.copy())
                for embedding in results
            ]
        except Exception as e:
            logger.info(f"Converting the results to torch failed: {e}")

        try:
            embeddings_aggregated = torch.cat(embedding_results, dim=1)
            embedding_server = embeddings_aggregated.detach().requires_grad_()
            output = self.model(embedding_server)
            loss = self.criterion(output, self.labels)
            loss.backward()

            self.optimizer.step()
            self.optimizer.zero_grad()
        except Exception as e:
            logger.info(f"Running gradient descent failed: {e}")

        try:
            grads = embedding_server.grad.split([4]*self.nof_clients, dim=1)
            np_gradients = [serialise_array(grad.numpy()) for grad in grads]
        except Exception as e:
            logger.info(f"Converting the gradients failed: {e}")

        with torch.no_grad():
            output = self.model(embedding_server)

            mse = nn.MSELoss()(output, self.labels).item()
            rmse = torch.sqrt(torch.tensor(mse)).item()
            mae = nn.L1Loss()(output, self.labels).item()
            total_sum_of_squares = torch.sum((self.labels - self.labels.mean()) ** 2)
            residual_sum_of_squares = torch.sum((self.labels - output) ** 2)
            r2 = 1 - (residual_sum_of_squares / total_sum_of_squares)
            r2_score = r2.item()

            metrics = {
                "mse": mse,
                "rmse": rmse,
                "mae": mae,
                "r2": r2_score
            }
            # Example of printing the metrics
            # print(f"Regression Metrics - MSE: {mse:.4f}, RMSE: {rmse:.4f}, MAE: {mae:.4f}, R²: {r2_score:.4f}")
            pass 


        data = Struct()
        data.update({"accuracy": r2_score, "gradients": np_gradients})  # TODO: maybe try to rename the field
        # data = []
        # data.append({"r2": r2_score, "gradients": np_gradients})

        logger.info(f"R2 achieved: {r2_score}, MAE achieved: {mae}, RMSE achieved: {rmse}, MSE achieved {mse}")

        return data
    
    def save_state(self, state_key):
        """Stash the state dicts for both model and optimizer through the gateway."""
        if gateway is None:
            logger.warning("No gateway; skipping server state stash")
            return
        try:
            buffer = io.BytesIO()
            torch.save({
                'model_state_dict': self.model.state_dict(),
                'optimizer_state_dict': self.optimizer.state_dict()
            }, buffer)
            decision = gateway.request_state_write("vfl_server_model", state_key, buffer.getvalue())
            if decision.allowed:
                logger.info(f"Server state stashed under {state_key}")
            else:
                logger.warning(f"Server state stash denied ({decision.reason}); nothing persisted")
        except Exception as e:
            logger.warning(f"Server state stash failed ({e}); nothing persisted")

    def load_state(self, state_key):
        """Restore the state dicts from the gateway; denied or missing keeps the fresh model."""
        if gateway is None:
            logger.warning("No gateway; skipping server state restore")
            return
        try:
            resp = gateway.validate_state_read("vfl_server_model", state_key)
            if not resp.allowed:
                logger.warning(f"Server state restore denied ({resp.reason}); keeping fresh model")
                return
            state = torch.load(io.BytesIO(resp.payload))
            self.model.load_state_dict(state['model_state_dict'])
            self.optimizer.load_state_dict(state['optimizer_state_dict'])
            logger.info(f"Server state restored from {state_key}")
        except Exception as e:
            logger.warning(f"Server state restore failed ({e}); keeping fresh model")


# Policy purge from the gateway: drop the retained aggregator state. The next
# vflAggregateRequest reinitializes the server model from scratch.
def on_gateway_purge(event):
    global vfl_server
    purge_pending.set()
    vfl_server = None
    logger.warning("Policy purge: cleared in-memory server model")


# Persist the aggregator state through the gateway after a round. A denied or
# failed write never disturbs the round: training continues, persistence stops.
def write_server_checkpoint():
    if gateway is None or vfl_server is None:
        return
    try:
        buffer = io.BytesIO()
        torch.save({
            "model_state_dict": vfl_server.model.state_dict(),
            "optimizer_state_dict": vfl_server.optimizer.state_dict(),
            "round_index": vfl_server.round_index,
            "nof_clients": vfl_server.nof_clients,
        }, buffer)
        decision = gateway.request_state_write("vfl_server_model", "latest", buffer.getvalue())
        if decision.allowed:
            logger.info(f"Checkpoint write allowed: round_index={vfl_server.round_index}")
        else:
            logger.warning(f"Checkpoint write denied ({decision.reason}); continuing without persistence: round_index={vfl_server.round_index}")
    except Exception as e:
        logger.warning(f"Checkpoint write failed ({e}); continuing without persistence")


# One-shot resume read at startup. Anything but an ALLOW with an applicable
# payload leaves the fresh model in place. The persisted nof_clients rebuilds
# the aggregator at the right width before the state dicts are loaded.
def rehydrate_server():
    global vfl_server
    if gateway is None or vfl_server is None:
        return
    try:
        resp = gateway.validate_state_read("vfl_server_model", "latest")
    except Exception as e:
        logger.warning(f"Resume read failed ({e}); starting fresh")
        return
    if not resp.allowed:
        logger.info(f"Resume read denied ({resp.reason}); starting fresh")
        return
    try:
        state = torch.load(io.BytesIO(resp.payload))
        nof_clients = state["nof_clients"]
        if nof_clients != vfl_server.nof_clients:
            vfl_server.nof_clients = nof_clients
            vfl_server.model = ServerModel(vfl_server.intermediate_neurons * nof_clients)
            vfl_server.optimizer = optim.Adam(vfl_server.model.parameters(), lr=DEFAULT_LEARNING_RATE, weight_decay=1e-4)
        vfl_server.model.load_state_dict(state["model_state_dict"])
        vfl_server.optimizer.load_state_dict(state["optimizer_state_dict"])
        vfl_server.round_index = state["round_index"]
        logger.info(f"Resumed server model from checkpoint: round_index={vfl_server.round_index} nof_clients={nof_clients} written_unix_seconds={resp.written_unix_seconds}")
    except Exception as e:
        logger.warning(f"Checkpoint could not be applied ({e}); starting fresh")
        vfl_server = VFLServer(load_data())


def handleAggregateRequest(msComm):
    global ms_config
    global vfl_server

    request = rabbitTypes.Request()
    msComm.original_request.Unpack(request)

    backtrack = False
    try:
        training_backtrack_flag = request.data["trainingBacktrack"]
        logger.debug(f"Training backtrack flag: {training_backtrack_flag}")
        logger.debug(f"Training backtrack flag: {type(training_backtrack_flag)}")
        if training_backtrack_flag.number_value == 1:
            backtrack = True
            logger.debug(f"Training backtrack flag is 'True'")
    except Exception as e:
        logger.warning(f"Error when retrieving training backtrack flag: {e}")
    embeddings_val = request.data.get("embeddings", None)
    if embeddings_val is None and hasattr(msComm.data, "get"):
        embeddings_val = msComm.data.get("embeddings", None)

    if embeddings_val is None:
        raise ValueError("No embeddings found in msComm.data or request.data for vflAggregateRequest")

    serialized = [v.string_value for v in embeddings_val.list_value.values]

    clients_embeddings = [deserialise_array(s) for s in serialized]

    try:
        md = dict(msComm.metadata)
        dp_flag = md.get("dp_applied", "0")

        e0 = clients_embeddings[0].astype(np.float32, copy=False)
        e0_norm = float(np.linalg.norm(e0.ravel(), 2))
        e0_fp = fp(serialized[0])

        logger.info(
            f"[SERVER] vflAggregateRequest received: dp_applied={dp_flag} "
            f"n={len(clients_embeddings)} e0_norm={e0_norm:.6f} e0_fp={e0_fp}"
        )
    except Exception as e:
        logger.warning(f"[SERVER] Could not log DP verification stats: {e}")

    if vfl_server is None:
        if purge_pending.is_set():
            purge_pending.clear()
            logger.warning("Server model was purged by policy; reinitializing from scratch")
        else:
            logger.warning("Server model missing; reinitializing")
        vfl_server = VFLServer(load_data())

    try:
        data = vfl_server.aggregate_fit(clients_embeddings, backtrack)
        vfl_server.round_index += 1
        write_server_checkpoint()
    except Exception as e:
        if purge_pending.is_set():
            purge_pending.clear()
            logger.warning("Round aborted by policy purge")
        else:
            logger.error(f"aggregate_fit failed: {e}")
        data = Struct()

    ms_config.next_client.ms_comm.send_data(msComm, data, dict(msComm.metadata))


# ---  DYNAMOS Interface code At the Bottom --------

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

    DATA_STEWARD_NAME = os.getenv("DATA_STEWARD_NAME").lower()

    # Made a distinction between server microservice running as actual server, or just as relay before client.
    # I think this needs to change, might be an issue with the microservice chain.
    if DATA_STEWARD_NAME != "server":
        if request.type == "vflShutdownRequest":
            logger.info("Received vflShutdownRequest (relay mode), shutting down.")
            ms_config.next_client.ms_comm.send_data(msComm, msComm.data, dict(msComm.metadata))
            signal_continuation(stop_event, stop_microservice_condition)
        else:
            logger.info(f"Relay mode on {DATA_STEWARD_NAME}: forwarding request.")
            ms_config.next_client.ms_comm.send_data(msComm, msComm.data, dict(msComm.metadata))
        return Empty()
    else:
        if request.type == "vflAggregateRequest":
            logger.info("Received a vflAggregateRequest.")
            handleAggregateRequest(msComm)

        elif request.type == "vflPingRequest":
            logger.info("Received a vflPingRequest.")
            ms_config.next_client.ms_comm.send_data(msComm, msComm.data, {})

        elif request.type == "vflShutdownRequest":
            logger.info("Received a vflShutdownRequest.")
            signal_continuation(stop_event, stop_microservice_condition)

        return Empty()


def main():
    global config
    global ms_config
    global vfl_server
    global gateway

    # Wait for sidecar to be up
    sidecar_port = int(os.getenv("SIDECAR_PORT", "50051"))
    logger.info(f"Waiting for sidecar gRPC on localhost:{sidecar_port} ...")
    wait_for_port("127.0.0.1", sidecar_port, wait_time=90)

    # Load data correctly if pod is server, otherwise do nothing
    ds = os.getenv("DATA_STEWARD_NAME", "").lower()

    if ds == "server":
        data = load_data()
        vfl_server = VFLServer(data)
        logger.info("Initialized VFLServer (server mode)")
    else:
        vfl_server = None
        logger.info(f"Not server ({ds}); running in relay mode (no dataset load)")

    ms_config = NewConfiguration(
        config.service_name, config.grpc_addr, request_handler)

    gateway = connect_gateway(config.service_name, on_gateway_purge)

    if ds == "server":
        rehydrate_server()

    # Signal the message handler that all connections have been created
    signal_continuation(wait_for_setup_event, wait_for_setup_condition)

    # Wait for the end of processing to shutdown this Microservice
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
