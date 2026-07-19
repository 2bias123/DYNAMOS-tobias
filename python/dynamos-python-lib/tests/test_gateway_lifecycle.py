"""
Unit tests for dynamos/gateway_lifecycle.py against an in-process gRPC server.
"""

import os
import threading
import unittest
from concurrent import futures

import grpc
from google.protobuf import empty_pb2

import policyCheckpointGateway_pb2 as gwTypes
import policyCheckpointGateway_pb2_grpc as gwServer

from dynamos.gateway_lifecycle import connect_gateway, shutdown_gateway

TEST_ENV = {
    "DATA_STEWARD_NAME": "SERVER",
    "REQUEST_USER": "u@x",
    "REQUEST_TYPE": "vflTrainModelRequest",
    "JOB_NAME": "job-1",
    "LOCAL_JOB_NAME": "job-1",
}


class PurgingGateway(gwServer.PolicyCheckpointGatewayServicer):
    """Emits AGREEMENT_CHANGED, then PURGE, then keeps the stream open."""

    def __init__(self):
        self.shutdowns = []
        self.stream_open = threading.Event()

    def SubscribeStateEvents(self, request, context):
        yield gwTypes.StateEvent(kind=gwTypes.StateEvent.AGREEMENT_CHANGED, reason="initial")
        yield gwTypes.StateEvent(kind=gwTypes.StateEvent.PURGE, reason="policy revoked")
        self.stream_open.set()
        context.sleep = threading.Event()
        context.sleep.wait(30)

    def Shutdown(self, request, context):
        self.shutdowns.append(request)
        return empty_pb2.Empty()


class GatewayLifecycleTest(unittest.TestCase):
    def setUp(self):
        self._saved_env = {k: os.environ.get(k) for k in list(TEST_ENV) + ["GATEWAY_PORT"]}
        os.environ.update(TEST_ENV)
        self.servicer = PurgingGateway()
        self.server = grpc.server(futures.ThreadPoolExecutor(max_workers=4))
        gwServer.add_PolicyCheckpointGatewayServicer_to_server(self.servicer, self.server)
        port = self.server.add_insecure_port("127.0.0.1:0")
        self.server.start()
        os.environ["GATEWAY_PORT"] = str(port)

    def tearDown(self):
        self.server.stop(None)
        for key, value in self._saved_env.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

    def test_purge_event_reaches_handler(self):
        purged = threading.Event()
        events = []

        def on_purge(event):
            events.append(event)
            purged.set()

        client = connect_gateway("test-ms", on_purge=on_purge)
        self.assertIsNotNone(client)
        self.assertTrue(purged.wait(timeout=5), "PURGE never reached the handler")
        self.assertEqual(events[0].reason, "policy revoked")
        client.close_program()

    def test_purge_handler_crash_does_not_kill_listener(self):
        purged = threading.Event()

        def bad_handler(event):
            purged.set()
            raise RuntimeError("handler bug")

        client = connect_gateway("test-ms", on_purge=bad_handler)
        self.assertTrue(purged.wait(timeout=5))
        client.close_program()

    def test_dial_failure_degrades_to_none(self):
        self.server.stop(None)
        os.environ["GATEWAY_PORT"] = "1"  # nothing listens here
        client = connect_gateway("test-ms", max_attempts=2)
        self.assertIsNone(client)

    def test_missing_identity_env_still_fail_closed(self):
        del os.environ["REQUEST_USER"]
        with self.assertRaises(SystemExit):
            connect_gateway("test-ms")

    def test_shutdown_none_is_noop(self):
        shutdown_gateway(None, "ms_exit")

    def test_shutdown_sends_reason(self):
        client = connect_gateway("test-ms")
        shutdown_gateway(client, "ms_exit")
        self.assertEqual(len(self.servicer.shutdowns), 1)
        self.assertEqual(self.servicer.shutdowns[0].reason, "ms_exit")
        client.close_program()

    def test_shutdown_after_gateway_gone_does_not_raise(self):
        client = connect_gateway("test-ms")
        self.server.stop(None)
        shutdown_gateway(client, "ms_exit")
        client.close_program()