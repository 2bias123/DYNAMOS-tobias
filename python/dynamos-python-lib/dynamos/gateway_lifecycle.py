"""
Package dynamos, implements functionality for handling Microservice chains in Python.

File: gateway_lifecycle.py

Description:
Structural glue between a stateful microservice and its policy checkpoint
gateway: dial at startup, listen for state events on a background thread,
and request gateway shutdown when the microservice exits.

A chain without a gateway is a supported deployment: dial failure degrades to
no-gateway behaviour (returns None, all later calls no-op). Identity problems
do NOT degrade — the client exits fail-closed on missing or changed env.

Notes:
"""

import threading

import grpc

from .gateway_client import GatewayClient
from .logger import InitLogger

import policyCheckpointGateway_pb2 as gwTypes


def connect_gateway(subscriber_id, on_purge=None, max_attempts=8):
    """
    Dial the gateway and start the background state-event listener.

    Args:
        subscriber_id (str): Identifies this microservice on the event stream.
        on_purge (callable): Called with the StateEvent when a PURGE arrives.
        max_attempts (int): Dial attempts before degrading to no-gateway mode.

    Returns:
        GatewayClient when the gateway is reachable, None otherwise.
    """
    logger = InitLogger()

    try:
        client = GatewayClient(max_attempts=max_attempts)
    except Exception as e:
        logger.warning(f"No policy gateway reachable, continuing without one: {e}")
        return None

    def listen():
        try:
            for event in client.subscribe_state_events(subscriber_id):
                kind = gwTypes.StateEvent.Kind.Name(event.kind)
                if event.kind == gwTypes.StateEvent.PURGE:
                    logger.warning(f"Gateway PURGE received: reason={event.reason}")
                    if on_purge is not None:
                        try:
                            on_purge(event)
                        except Exception as e:
                            logger.error(f"Purge handler failed: {e}")
                else:
                    logger.info(f"Gateway state event: {kind} reason={event.reason}")
        except grpc.RpcError as e:
            logger.info(f"Gateway event stream closed: {e.code()}")
        except Exception as e:
            logger.warning(f"Gateway event listener stopped unexpectedly: {e}")

    threading.Thread(target=listen, daemon=True, name="gateway-events").start()
    logger.info(f"Gateway connected, state-event listener started ({subscriber_id})")
    return client


def shutdown_gateway(client, reason):
    """
    Ask the gateway to terminate so the Job pod can complete. Safe to call in
    no-gateway mode (client None) and when the gateway is already gone.
    """
    if client is None:
        return
    logger = InitLogger()
    try:
        client.shutdown(reason)
    except Exception as e:
        logger.warning(f"Gateway shutdown call failed (gateway may already be gone): {e}")
