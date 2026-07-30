// Deterministic check for the GSP high-fidelity Quad-X geometry package.
//
// It loads the real hardware configuration presets and the vendored Three.js
// runtime, builds the drone model outside a browser, and proves that scale,
// M1-M4 mapping, spin direction and geometry classification come from the
// active hardware configuration instead of renderer constants.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const ROOT = path.resolve(__dirname, "..");
const INCH_M = 0.0254;

function loadThree() {
    const context = {
        console, Math, Number, Array, Object, String, Boolean, JSON, Date, Promise, Error,
        Uint8Array, Uint16Array, Uint32Array, Int8Array, Int16Array, Int32Array,
        Float32Array, Float64Array, ArrayBuffer, DataView, Map, Set, WeakMap, WeakSet, Symbol,
        setTimeout, clearTimeout, AbortController, URL, TextDecoder, TextEncoder, performance,
    };
    context.window = context;
    context.self = context;
    context.globalThis = context;
    vm.runInNewContext(
        fs.readFileSync(path.join(ROOT, "common/gsp/assets/three-0.180.0.global.min.js"), "utf8"),
        context,
        { filename: "three-0.180.0.global.min.js" },
    );
    return context;
}

const context = loadThree();
vm.runInNewContext(
    fs.readFileSync(path.join(ROOT, "common/gsp/assets/gsp_drone_geometry.js"), "utf8"),
    context,
    { filename: "gsp_drone_geometry.js" },
);

const THREE = context.THREE;
const geometry = context.window.__AEROSIM_GSP_DRONE_GEOMETRY__;
assert.equal(typeof geometry.derive_geometry_spec, "function");
assert.equal(typeof geometry.classify_geometry, "function");
assert.equal(typeof geometry.build_drone_model, "function");

// Values built inside the vm context carry that realm's prototypes, so compare
// them as plain data.
function plain(value) {
    return JSON.parse(JSON.stringify(value));
}

function preset(name) {
    return JSON.parse(fs.readFileSync(path.join(ROOT, "config/drones", name), "utf8"));
}

const freestyle = preset("5_inch_6s.json");
const race = preset("5_inch_6s_race.json");

// --- scale and identity come from the hardware configuration -----------------

const spec = geometry.derive_geometry_spec(freestyle);
assert.equal(spec.available, true, spec.reason || "freestyle geometry unavailable");
assert.equal(spec.identity.designation, freestyle.geometry.identity.designation);
assert.equal(spec.identity.airframe_class, freestyle.geometry.identity.airframe_class);
assert.equal(spec.propeller.diameter_m, freestyle.propeller.diameter_in * INCH_M);
assert.equal(spec.propeller.radius_m, freestyle.propeller.diameter_in * INCH_M / 2);
assert.equal(spec.propeller.blades, freestyle.propeller.blades);
// Expectations are computed from the preset, so a changed layout cannot pass
// silently on a hardcoded number.
const layout = freestyle.aircraft.motor_layout;
const propellerRadius = freestyle.propeller.diameter_in * INCH_M / 2;
const motorRadius = Math.max(...layout.map((row) => Math.hypot(row.x, row.y)));
const motorOffset = Math.max(...layout.flatMap((row) => [Math.abs(row.x), Math.abs(row.y)]));
assert.equal(spec.scale.wheelbase_m, freestyle.frame.wheelbase_m);
assert.ok(Math.abs(spec.scale.motor_radius_m - motorRadius) < 1e-12);
assert.ok(Math.abs(spec.scale.layout_wheelbase_m - motorRadius * 2) < 1e-12);
assert.ok(Math.abs(spec.scale.span_m - (motorOffset + propellerRadius) * 2) < 1e-12);

// The race preset has a different layout, propeller and identity, so a spec that
// merely echoed renderer constants could not tell the two apart.
const raceSpec = geometry.derive_geometry_spec(race);
assert.equal(raceSpec.available, true, raceSpec.reason || "race geometry unavailable");
assert.notEqual(raceSpec.scale.motor_radius_m, spec.scale.motor_radius_m);
assert.notEqual(raceSpec.propeller.radius_m, spec.propeller.radius_m);
assert.notEqual(raceSpec.identity.designation, spec.identity.designation);

// --- M1-M4 mapping and spin direction ---------------------------------------

assert.deepEqual(plain(spec.motors.map((motor) => motor.label)), ["M1", "M2", "M3", "M4"]);
assert.deepEqual(plain(spec.motors.map((motor) => motor.id)), freestyle.motor_order);
assert.deepEqual(plain(spec.motors.map((motor) => motor.spin_direction)), freestyle.spin_direction);
freestyle.aircraft.motor_layout.forEach((layout, index) => {
    const motor = spec.motors[index];
    assert.deepEqual(plain(motor.frd), { x: layout.x, y: layout.y, z: layout.z });
    // FRD -> scene: scene X is body right, scene Y is up, scene -Z is body forward.
    assert.deepEqual(plain(motor.scene), plain([layout.y, -layout.z, -layout.x]));
});
// Betaflight quad-X placement, read back from the derived spec only.
const byLabel = Object.fromEntries(spec.motors.map((motor) => [motor.label, motor]));
assert.ok(byLabel.M1.frd.x < 0 && byLabel.M1.frd.y > 0, "M1 is rear right");
assert.ok(byLabel.M2.frd.x > 0 && byLabel.M2.frd.y > 0, "M2 is front right");
assert.ok(byLabel.M3.frd.x < 0 && byLabel.M3.frd.y < 0, "M3 is rear left");
assert.ok(byLabel.M4.frd.x > 0 && byLabel.M4.frd.y < 0, "M4 is front left");
assert.equal(byLabel.M1.spin_direction, "cw");
assert.equal(byLabel.M2.spin_direction, "ccw");
// Diagonal pairs must spin the same way for a yaw-balanced quad-X.
assert.equal(byLabel.M1.spin_direction, byLabel.M4.spin_direction);
assert.equal(byLabel.M2.spin_direction, byLabel.M3.spin_direction);

// --- centre of mass and propeller clearance ---------------------------------

assert.deepEqual(plain(spec.center_of_mass_frd_m), freestyle.aircraft.cg_offset_m);
const spacing = Math.min(...layout.flatMap((a, index) => layout
    .slice(index + 1)
    .map((b) => Math.hypot(a.x - b.x, a.y - b.y))));
assert.ok(Math.abs(spec.scale.propeller_clearance_m - (spacing - freestyle.propeller.diameter_in * INCH_M)) < 1e-12);

// The shipped presets state a 225 mm wheelbase while aircraft.motor_layout, which
// the physics torque arms use, puts the motors on a wider diagonal. The renderer
// follows the layout and must say so rather than let the stated size stand.
assert.deepEqual(plain(spec.warnings), ["wheelbase_disagrees_with_motor_layout"]);
assert.equal(spec.classification, "nominal");
assert.ok(spec.classification_reasons.includes("wheelbase_disagrees_with_motor_layout"));

const consistent = JSON.parse(JSON.stringify(freestyle));
consistent.frame.wheelbase_m = motorRadius * 2;
assert.deepEqual(plain(geometry.derive_geometry_spec(consistent).warnings), []);

const overlapping = JSON.parse(JSON.stringify(consistent));
overlapping.propeller.diameter_in = 9.0;
const overlapSpec = geometry.derive_geometry_spec(overlapping);
assert.equal(overlapSpec.available, true);
assert.ok(overlapSpec.warnings.includes("propeller_overlap"), "overlapping props must warn");
assert.equal(overlapSpec.classification, "nominal", "overlapping props cannot be real geometry");

// --- geometry classification -------------------------------------------------

assert.ok(spec.classification_reasons.length > 0, "nominal geometry must state why");

const qualifying = {
    model_source: "Vendor frame CAD",
    source_url: "https://example.invalid/frame",
    dimensional_evidence: {
        evidence_class: "manufacturer_cad",
        documents: [{ title: "Frame CAD", url: "https://example.invalid/frame.step", sha256: "a".repeat(64) }],
        notes: "step file measured",
    },
    license: { spdx: "CC0-1.0", holder: "Vendor", attribution_required: false, attribution: "" },
    redistribution: "release",
    assets: [{ path: "common/gsp/assets/gsp_drone_geometry.js", sha256: "b".repeat(64) }],
};
const real = geometry.classify_geometry(qualifying);
assert.equal(real.classification, "real");
assert.deepEqual(plain(real.reasons), []);

function rejects(mutate, expectedReason) {
    const candidate = JSON.parse(JSON.stringify(qualifying));
    mutate(candidate);
    const verdict = geometry.classify_geometry(candidate);
    assert.equal(verdict.classification, "nominal", `expected nominal for ${expectedReason}`);
    assert.ok(verdict.reasons.includes(expectedReason), `expected reason ${expectedReason}, got ${verdict.reasons}`);
}

rejects((value) => { value.dimensional_evidence.evidence_class = "parametric_from_configuration"; }, "unqualified_dimensional_evidence");
rejects((value) => { value.dimensional_evidence.documents = []; }, "missing_dimensional_evidence_document");
rejects((value) => { value.redistribution = "personal_use_only"; }, "not_release_redistributable");
rejects((value) => { value.license.spdx = "CC-BY-NC-4.0"; }, "license_not_redistributable");
rejects((value) => { value.assets[0].sha256 = "short"; }, "missing_asset_hash");
rejects((value) => { value.assets = []; }, "missing_asset_hash");
rejects((value) => { value.license.attribution_required = true; value.license.attribution = ""; }, "missing_required_attribution");
rejects((value) => { value.source_url = ""; }, "missing_model_source");
assert.equal(geometry.classify_geometry(null).classification, "nominal");

// --- incomplete configuration fails closed ----------------------------------

for (const drop of ["geometry", "aircraft", "propeller", "motor_order", "spin_direction"]) {
    const broken = JSON.parse(JSON.stringify(freestyle));
    delete broken[drop];
    const verdict = geometry.derive_geometry_spec(broken);
    assert.equal(verdict.available, false, `${drop} must be required`);
    assert.ok(String(verdict.reason).length > 0);
}
assert.equal(geometry.derive_geometry_spec(null).available, false);

// --- the Three.js model is built to the configured real-world size ----------

const model = geometry.build_drone_model(THREE, spec);
assert.ok(model.group.isObject3D, "model must expose a Three.js group");
assert.deepEqual(Object.keys(model.rotors).sort().slice(), freestyle.motor_order.slice().sort());

for (const motor of spec.motors) {
    const rotor = model.rotors[motor.id];
    assert.ok(rotor, `missing rotor ${motor.id}`);
    assert.deepEqual(plain(rotor.group.position.toArray()), plain(motor.scene));
    assert.equal(rotor.label, motor.label);
    assert.equal(rotor.spin_sign, motor.spin_direction === "ccw" ? -1 : 1);
    // Three blades per configured propeller, each a distinct mesh.
    assert.equal(rotor.blades.children.length, freestyle.propeller.blades);
    const bladeSpan = new THREE.Box3().setFromObject(rotor.blades);
    const bladeRadius = Math.max(bladeSpan.max.x, bladeSpan.max.z, -bladeSpan.min.x, -bladeSpan.min.z);
    assert.ok(
        Math.abs(bladeRadius - spec.propeller.radius_m) < 0.002,
        `propeller radius ${bladeRadius} should match configured ${spec.propeller.radius_m}`,
    );
}

// Every rotor must be pitched to push air down. The leading edge is the side
// the blade advances towards, so it has to sit higher than the trailing edge.
// A clockwise rotor turns the negative way about scene +Y, which moves the blade
// at +X towards +Z, making +Z the leading side; counter-clockwise is mirrored.
for (const motor of spec.motors) {
    const rotor = model.rotors[motor.id];
    const position = rotor.blades.children[0].geometry.attributes.position;
    let leadingHeight = 0;
    let trailingHeight = 0;
    let leadingCount = 0;
    let trailingCount = 0;
    const leadingSide = rotor.spin_sign > 0 ? 1 : -1;
    for (let index = 0; index < position.count; index += 1) {
        if (position.getX(index) < spec.propeller.radius_m * 0.6) continue;
        const chordSide = Math.sign(position.getZ(index));
        if (chordSide === leadingSide) { leadingHeight += position.getY(index); leadingCount += 1; }
        else if (chordSide === -leadingSide) { trailingHeight += position.getY(index); trailingCount += 1; }
    }
    assert.ok(leadingCount > 0 && trailingCount > 0, `${motor.label} blade has no chord width to measure`);
    assert.ok(
        leadingHeight / leadingCount > trailingHeight / trailingCount,
        `${motor.label} (${motor.spin_direction}) is pitched to blow air upward`,
    );
}

const box = new THREE.Box3().setFromObject(model.group);
const size = box.getSize(new THREE.Vector3());
assert.ok(Math.abs(size.x - spec.scale.span_m) < 0.004, `model width ${size.x} should match span ${spec.scale.span_m}`);
assert.ok(Math.abs(size.z - spec.scale.span_m) < 0.004, `model depth ${size.z} should match span ${spec.scale.span_m}`);
assert.ok(size.y > 0.02 && size.y < 0.16, `model height ${size.y} must stay in 5-inch airframe range`);

// A real frame, real body, four distinct motors and four propellers.
let meshCount = 0;
model.group.traverse((node) => { if (node.isMesh) meshCount += 1; });
assert.ok(meshCount >= 40, `expected a detailed airframe, got ${meshCount} meshes`);
assert.equal(model.parts.arms.length, spec.motors.length);
assert.ok(model.parts.body.children.length >= 5, "body must carry frame plates, stack, canopy and camera");
assert.ok(model.parts.center_of_mass.isObject3D, "centre of mass must be inspectable");
assert.deepEqual(
    plain(model.parts.center_of_mass.position.toArray()),
    plain([spec.center_of_mass_frd_m.y, -spec.center_of_mass_frd_m.z, -spec.center_of_mass_frd_m.x]),
);

// The race preset builds a different-sized model from the same code.
const raceModel = geometry.build_drone_model(THREE, raceSpec);
const raceSize = new THREE.Box3().setFromObject(raceModel.group).getSize(new THREE.Vector3());
assert.ok(Math.abs(raceSize.x - raceSpec.scale.span_m) < 0.004);
assert.notEqual(raceSize.x, size.x);

console.log("GSP drone geometry package passed");
