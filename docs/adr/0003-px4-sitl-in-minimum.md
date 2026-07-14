# Include PX4 SITL in the AirSim-class minimum

The AirSim-class minimum must support PX4 software-in-the-loop flight control. Deferring every external flight controller would leave AeroSim as a game with custom physics rather than an AirSim-class simulation platform; ArduPilot SITL and hardware-in-the-loop remain outside the minimum to keep the first compatibility boundary singular.
