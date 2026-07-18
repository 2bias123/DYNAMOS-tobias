"""
Package dynamos, implements functionality for handling Microservice chains in Python.

File: gateway_client.py

Description:
Client for the chain-local policy checkpoint gateway. The gateway mediates all
access to retained intermediate state; this client dials it over the pod-local
port and exposes the four gateway RPCs.

Identity is constructed from the injected container environment and cached on
first use. Every call re-reads the environment and refuses to continue if it
no longer matches the cached identity: state access under a changed identity
is never allowed, so the process exits instead (fail-closed).

Notes:
"""

import grpc
import os
import sys
import time

from .logger import InitLogger

import policyCheckpointGateway_pb2 as gwTypes
import policyCheckpointGateway_pb2_grpc as gwServer

IDENTITY_ENV_VARS = (
    "DATA_STEWARD_NAME",
    "REQUEST_USER",
    "REQUEST_TYPE",
    "JOB_NAME",
    "LOCAL_JOB_NAME",
)


class GatewayClient:
    """Client for the policy checkpoint gateway running in the same Job pod."""

    def __init__(self, gateway_addr=None, max_attempts=8):
        """
        Initialize the client: build the identity from the environment and dial
        the gateway with retry-and-backoff (the gateway container may become
        ready after this microservice starts).

        Args:
            gateway_addr (str): Optional address override. Defaults to
                localhost:$GATEWAY_PORT.
            max_attempts (int): Connection attempts before giving up.

        """
        self.logger = InitLogger()
        self.identity = self._identity_from_env()

        if gateway_addr is None:
            port = os.environ.get("GATEWAY_PORT", "")
            if port == "":
                self.logger.error("Required env GATEWAY_PORT is empty")
                sys.exit(1)
            gateway_addr = f"localhost:{port}"
        self.gateway_addr = gateway_addr

        self.channel = self._connect(max_attempts)
        self.stub = gwServer.PolicyCheckpointGatewayStub(self.channel)

    def _identity_from_env(self):
        values = {}
        for key in IDENTITY_ENV_VARS:
            value = os.environ.get(key, "")
            if value == "":
                self.logger.error(f"Required env {key} is empty")
                sys.exit(1)
            values[key] = value

        return gwTypes.Identity(
            steward=values["DATA_STEWARD_NAME"],
            user=values["REQUEST_USER"],
            request_type=values["REQUEST_TYPE"],
            job_id=values["JOB_NAME"],
            local_job_name=values["LOCAL_JOB_NAME"],
        )

    def _verified_identity(self):
        """Re-read the environment and fail closed if it changed."""
        current = self._identity_from_env()
        if current != self.identity:
            self.logger.error("Identity environment changed after startup, refusing gateway call")
            sys.exit(1)
        return self.identity

    def _connect(self, max_attempts):
        channel = grpc.insecure_channel(self.gateway_addr)

        self.logger.debug(f"Try connecting to gateway at: {self.gateway_addr}")
        for i in range(1, max_attempts + 1):
            try:
                grpc.channel_ready_future(channel).result(timeout=min(2 ** (i - 1) * 0.5, 8))
                self.logger.info(f"Successfully connected to gateway at {self.gateway_addr}")
                return channel
            except grpc.FutureTimeoutError:
                self.logger.warning(f"Gateway not ready at {self.gateway_addr}, attempt {i}/{max_attempts}")

        raise Exception(f"Could not connect to gateway {self.gateway_addr} after {max_attempts} tries")

    def close_program(self):
        """Close the gRPC channel gracefully."""
        self.channel.close()
        self.logger.debug("Closed gateway channel")

    def request_state_write(self, state_class, state_key, payload, timeout=30):
        """
        Ask the gateway to persist state under this identity.

        Args:
            state_class (str): State class (e.g. a model kind).
            state_key (str): Key within the class.
            payload (bytes): Opaque serialized state.

        Returns:
            StateDecision: allowed/denied with reason and retention info.
        """
        request = gwTypes.StateWriteRequest(
            identity=self._verified_identity(),
            state_class=state_class,
            state_key=state_key,
            payload=payload,
        )
        return self.stub.RequestStateWrite(request, timeout=timeout)

    def validate_state_read(self, state_class, state_key, timeout=30):
        """
        Ask the gateway for previously retained state.

        Returns:
            StateReadResponse: allowed/denied; payload set when allowed.
        """
        request = gwTypes.StateReadRequest(
            identity=self._verified_identity(),
            state_class=state_class,
            state_key=state_key,
        )
        return self.stub.ValidateStateRead(request, timeout=timeout)

    def subscribe_state_events(self, subscriber_id):
        """
        Open the long-lived state event stream (purges, agreement changes).

        Returns:
            Iterator of StateEvent. Holding the stream open also signals the
            gateway that this microservice is still alive; call .cancel() on
            the returned stream when no longer needed.
        """
        request = gwTypes.SubscribeRequest(
            identity=self._verified_identity(),
            subscriber_id=subscriber_id,
        )
        return self.stub.SubscribeStateEvents(request)

    def shutdown(self, reason, timeout=10):
        """
        Tell the gateway this microservice is exiting so the gateway can
        terminate cleanly and let the Job complete.
        """
        request = gwTypes.ShutdownRequest(
            identity=self._verified_identity(),
            reason=reason,
        )
        self.stub.Shutdown(request, timeout=timeout)
        self.logger.info(f"Requested gateway shutdown: {reason}")
