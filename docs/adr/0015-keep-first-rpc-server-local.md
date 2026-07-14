# Keep the first RPC server local

The first AirSim-compatible RPC server will bind only to loopback, default to `127.0.0.1:41451`, and allow its port to be configured. Non-loopback binding is rejected until AeroSim has an explicit authentication and transport-security design, because the AirSim control and sensor protocol does not itself provide a safe public-network boundary.
