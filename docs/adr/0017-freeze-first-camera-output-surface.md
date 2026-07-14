# Freeze the first camera output surface

The first AirSim Compatibility Surface will support `Scene`, `DepthPlanar`, and `Segmentation` image types with the pinned client's PNG, raw-byte, and floating-point depth behaviors. `DepthVis`, disparity, surface normals, infrared, and other image types are explicitly unsupported because they add separate rendering products without extending the confirmed Baseline Sensor Suite.
