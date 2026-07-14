#!/usr/bin/env python3
"""Exercise the frozen RPC subset through the unmodified AirSim 1.8.1 client."""

import argparse
import json

import airsim


def expect_rpc_error(client: airsim.VehicleClient) -> None:
    try:
        client.client.call("futureApi")
    except Exception as exc:  # msgpack-rpc-python exposes RPCError by version.
        if "unsupported RPC method" not in str(exc):
            raise AssertionError(f"unexpected unsupported-method error: {exc}") from exc
        return
    raise AssertionError("unsupported RPC method unexpectedly succeeded")


def exercise(port: int) -> None:
    client = airsim.VehicleClient(ip="127.0.0.1", port=port, timeout_value=5)
    assert client.ping() is True
    assert client.getServerVersion() == 1
    assert client.getMinRequiredClientVersion() == 1
    settings = json.loads(client.getSettingsString())
    assert settings["SettingsVersion"] == 1.2
    assert settings["ApiServerPort"] == port
    assert settings["ClockType"] == "SteppableClock"
    assert settings["Vehicles"]["Drone1"]["VehicleType"] == "SimpleFlight"

    client.simPause(True)
    assert client.simIsPause() is True
    client.simContinueForFrames(4)
    assert client.simIsPause() is True
    client.simContinueForTime(2.0 / 240.0)
    assert client.simIsPause() is True
    expect_rpc_error(client)

    client.reset()
    assert client.simIsPause() is False
    close = getattr(client.client, "close", None)
    if close is not None:
        close()

    reconnected = airsim.VehicleClient(ip="127.0.0.1", port=port, timeout_value=5)
    assert reconnected.ping() is True
    reconnected.client.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    exercise(parser.parse_args().port)
