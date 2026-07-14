# Use simulation time for all sensors

Every sensor will schedule and timestamp observations from one simulation-time clock. Pause freezes that clock, deterministic frame or duration stepping advances it, and each sensor samples at its configured rate; Dataset Recording must identify missing or dropped samples. Wall-clock timing is excluded because it would make replay, stepped automation, and cross-sensor alignment nondeterministic.
