"""
Unit tests for dynamos/gateway_client.py against an in-process gRPC server.

Run from dynamos-python-lib with protofiles on PYTHONPATH:
    python -m unittest discover -s tests
"""

import os
import socket
import threading
import time
import unittest
from concurrent import futures

import grpc
from google.protobuf import empty_pb2

import policyCheckpointGateway_pb2 as gwTypes
import policyCheckpointGateway_pb2_grpc as gwServer

from dynamos.gateway_client import GatewayClient

TEST_ENV = {
    "DATA_STEWARD_NAME": "SERVER",
    "REQUEST_USER": "u@x",
    "REQUEST_TYPE": "vflTrainModelRequest",
    "JOB_NAME": "job-1",
    "LOCAL_JOB_NAME": "job-1",
}


class FakeGateway(gwServer.PolicyCheckpointGatewayServicer):
    def __init__(self):
        self.writes = []
        self.reads = []
        self.shutdowns = []

    def RequestStateWrite(self, request, context):
        self.writes.append(request)
        return gwTypes.StateDecision(allowed=True, reason="test")

    def ValidateStateRead(self, request, context):
        self.reads.append(request)
        return gwTypes.StateReadResponse(allowed=True, reason="test", payload=b"\x01\x02\x03")

    def SubscribeStateEvents(self, request, context):
        yield gwTypes.StateEvent(kind=gwTypes.StateEvent.AGREEMENT_CHANGED, reason="test")

    def Shutdown(self, request, context):
        self.shutdowns.append(request)
        return empty_pb2.Empty()


def start_fake_gateway(port=0):
    servicer = FakeGateway()
    server = grpc.server(futures.ThreadPoolExecutor(max_workers=4))
    gwServer.add_PolicyCheckpointGatewayServicer_to_server(servicer, server)
    bound = server.add_insecure_port(f"127.0.0.1:{port}")
    server.start()
    return servicer, server, bound


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class GatewayClientTest(unittest.TestCase):
    def setUp(self):
        self._saved_env = {k: os.environ.get(k) for k in list(TEST_ENV) + ["GATEWAY_PORT"]}
        os.environ.update(TEST_ENV)
        self.servicer, self.server, port = start_fake_gateway()
        os.environ["GATEWAY_PORT"] = str(port)

    def tearDown(self):
        self.server.stop(None)
        for key, value in self._saved_env.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

    def test_write_carries_env_identity(self):
        client = GatewayClient()
        decision = client.request_state_write("kv", "k1", b"\x01")
        self.assertTrue(decision.allowed)
        self.assertEqual(len(self.servicer.writes), 1)
        identity = self.servicer.writes[0].identity
        self.assertEqual(identity.steward, "SERVER")
        self.assertEqual(identity.user, "u@x")
        self.assertEqual(identity.local_job_name, "job-1")
        client.close_program()

    def test_read_returns_payload(self):
        client = GatewayClient()
        response = client.validate_state_read("kv", "k1")
        self.assertTrue(response.allowed)
        self.assertEqual(response.payload, b"\x01\x02\x03")
        client.close_program()

    def test_subscribe_yields_initial_event(self):
        client = GatewayClient()
        stream = client.subscribe_state_events("sub1")
        event = next(iter(stream))
        self.assertEqual(event.kind, gwTypes.StateEvent.AGREEMENT_CHANGED)
        stream.cancel()
        client.close_program()

    def test_shutdown_sends_reason(self):
        client = GatewayClient()
        client.shutdown("ms_exit")
        self.assertEqual(len(self.servicer.shutdowns), 1)
        self.assertEqual(self.servicer.shutdowns[0].reason, "ms_exit")
        client.close_program()

    def test_dial_retries_until_gateway_ready(self):
        port = free_port()
        os.environ["GATEWAY_PORT"] = str(port)

        started = {}

        def start_late():
            time.sleep(1.5)
            started["servicer"], started["server"], _ = start_fake_gateway(port)

        threading.Thread(target=start_late, daemon=True).start()
        client = GatewayClient()
        decision = client.request_state_write("kv", "k1", b"\x01")
        self.assertTrue(decision.allowed)
        client.close_program()
        started["server"].stop(None)

    def test_missing_identity_env_exits(self):
        del os.environ["REQUEST_USER"]
        with self.assertRaises(SystemExit):
            GatewayClient()

    def test_env_change_after_startup_exits(self):
        client = GatewayClient()
        os.environ["REQUEST_USER"] = "mallory@evil.example"
        with self.assertRaises(SystemExit):
            client.request_state_write("kv", "k1", b"\x01")
        client.close_program()
