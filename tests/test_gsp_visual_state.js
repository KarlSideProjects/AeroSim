const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");

const context = { window: {}, console, Math, Number, Array, Object, String, Boolean, JSON };
context.window.window = context.window;
vm.runInNewContext(fs.readFileSync("common/gsp/assets/gsp_drone_geometry.js", "utf8"), context, { filename: "gsp_drone_geometry.js" });
vm.runInNewContext(fs.readFileSync("common/gsp/assets/gsp_visual.js", "utf8"), context, { filename: "gsp_visual.js" });

// The rendered airframe is positioned from the active preset, so the mapping
// test uses the real hardware configuration rather than renderer constants.
const configuration = JSON.parse(fs.readFileSync("config/drones/5_inch_6s.json", "utf8"));

const map = context.window.__AEROSIM_GSP_VISUAL__.map_telemetry_to_view_state;
assert.equal(typeof map, "function");

const state = map({
    motor_order: ["rear_right", "front_right", "rear_left", "front_left"],
    motors: [
        { thrust_newtons: 2, speed_rad_s: 100, current_a: 1, saturated: false },
        { thrust_newtons: 8.5, speed_rad_s: 200, current_a: 1, saturated: false },
        { thrust_newtons: 9.8, speed_rad_s: 300, current_a: 1, saturated: false },
        { thrust_newtons: 1, speed_rad_s: 400, current_a: 1, saturated: true },
    ],
    rpm: [955, 1910, 2865, 3820],
    hardware_configuration: configuration,
    hardware_power_model: { max_total_thrust_newtons: 40, max_total_current_a: 40 },
    wind_body_mps: { x_val: 1, y_val: 2, z_val: 3 },
    drag_body_n: { x_val: 1, y_val: 0, z_val: 0 },
    body_drag_operating_state: "active",
    a3_operating_state: "disabled",
    a6_operating_state: "out_of_domain",
});

assert.deepEqual(state.motors.map((motor) => motor.health), ["normal", "warning", "critical", "critical"]);
assert.deepEqual(
    JSON.parse(JSON.stringify(state.motors.map((motor) => motor.position))),
    JSON.parse(JSON.stringify(configuration.aircraft.motor_layout.map((row) => [row.y, -row.z, -row.x]))),
);
assert.deepEqual(JSON.parse(JSON.stringify(state.motors.map((motor) => motor.label))), ["M1", "M2", "M3", "M4"]);
assert.equal(state.geometry.available, true, state.geometry.reason);
assert.equal(state.geometry.classification, "nominal");
assert.equal(state.motors[1].spin_direction, "ccw");
assert.equal(state.motors[3].angular_step_rad, Math.PI / 6);
assert.equal(state.flow.wind.state, "active");
assert.equal(state.flow.body_drag.state, "active");
assert.equal(state.flow.rotor_drag.state, "disabled");
assert.equal(state.flow.propwash.state, "out_of_domain");

const fallback = map({
    motor_order: ["rear_right"],
    motors: [{ speed_rad_s: 100, thrust_newtons: 1, current_a: 1, saturated: false }],
    wind_body_mps: null,
});
assert.equal(fallback.motors[0].health, "unavailable");
assert.equal(fallback.motors[0].rpm, 100 * 60 / (Math.PI * 2));
assert.equal(fallback.motors[0].spin_direction, "unavailable");
// Without a hardware configuration there is no honest placement to draw.
assert.equal(fallback.motors[0].position, null);
assert.equal(fallback.geometry.available, false);
assert.equal(fallback.flow.wind.state, "unavailable");

const boundaries = map({
    motor_order: ["rear_right", "front_right", "rear_left", "front_left"],
    motors: [
        { thrust_newtons: 8.49, current_a: 0, saturated: false },
        { thrust_newtons: 8.5, current_a: 0, saturated: false },
        { thrust_newtons: 9.8, current_a: 0, saturated: false },
        { thrust_newtons: Number.NaN, current_a: 0, saturated: false },
    ],
    hardware_power_model: { max_total_thrust_newtons: 40, max_total_current_a: 40 },
});
assert.deepEqual(boundaries.motors.map((motor) => motor.health), ["normal", "warning", "critical", "unavailable"]);

console.log("GSP visual state mapping passed");
