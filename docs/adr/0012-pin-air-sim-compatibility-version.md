# Pin AirSim compatibility to Python client 1.8.1

The AirSim Compatibility Surface will target the official `airsim==1.8.1` Python client and a published subset of its APIs and `settings.json` schema. The compatibility manifest is frozen per AeroSim release, and unsupported calls or settings must be reported explicitly; a floating "latest AirSim" target would make client behavior and acceptance tests unstable.
