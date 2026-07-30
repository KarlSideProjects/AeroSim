// AeroSim GSP drone geometry package.
//
// Every dimension here is read from the active hardware configuration. The
// module carries no airframe values of its own: swapping the preset swaps the
// rendered aircraft. It also decides whether the rendered geometry may be
// presented as `Real geometry`, and refuses that claim unless the recorded
// dimensional evidence and redistribution rights support it.
(function () {
    const root = typeof window === "undefined" ? globalThis : window;
    const INCH_M = 0.0254;
    const TAU = Math.PI * 2;
    // SPDX identifiers that permit release redistribution. Kept in step with
    // config/license_allowlist.json by scripts/check_gsp_drone_geometry.py.
    const REDISTRIBUTABLE_LICENSES = [
        "Apache-2.0", "BSD-2-Clause", "BSD-3-Clause", "CC0-1.0", "MIT", "Public-Domain", "Zlib",
    ];
    // Evidence strong enough to call rendered geometry real rather than nominal.
    const QUALIFYING_EVIDENCE_CLASSES = ["manufacturer_cad", "manufacturer_drawing", "measured_specimen"];
    const BODY_KEYS = [
        "center_plate_length_m", "center_plate_width_m", "plate_thickness_m", "bottom_plate_thickness_m",
        "stack_width_m", "stack_height_m", "standoff_height_m", "standoff_diameter_m",
        "canopy_length_m", "canopy_width_m", "canopy_height_m",
        "camera_width_m", "camera_height_m", "camera_depth_m", "camera_lens_diameter_m",
        "battery_length_m", "battery_width_m", "battery_height_m",
        "arm_root_width_m", "arm_tip_width_m", "arm_thickness_m",
        "landing_foot_height_m", "landing_foot_diameter_m",
        "antenna_length_m", "antenna_diameter_m",
    ];
    const MOTOR_KEYS = [
        "bell_diameter_m", "bell_height_m", "base_diameter_m", "base_height_m",
        "shaft_diameter_m", "shaft_height_m",
    ];
    const PROPELLER_DIMENSION_KEYS = [
        "hub_diameter_m", "hub_height_m", "blade_root_chord_m", "blade_max_chord_m", "blade_tip_chord_m",
        "blade_thickness_m", "blade_root_offset_m",
    ];
    // Blade pitch may legitimately be zero, so these are only required to be finite.
    const PROPELLER_ANGLE_KEYS = ["blade_root_twist_deg", "blade_tip_twist_deg"];
    const CARBON = 0x161b21;
    const ALUMINIUM = 0x9aa5ad;
    const ANODIZED = 0x3f5d6d;
    const POLYMER = 0x20262d;
    const PROP = 0xb9c9d6;
    const ACCENT = 0x67d5ff;
    const PACK = 0x14181d;
    const PACK_LABEL = 0xc8a13a;

    function finite(value) {
        return typeof value === "number" && Number.isFinite(value);
    }

    function positive(value) {
        return finite(value) && value > 0;
    }

    function hexHash(value) {
        return typeof value === "string" && /^[0-9a-f]{64}$/.test(value);
    }

    function text(value) {
        return typeof value === "string" && value.trim().length > 0;
    }

    // A clockwise rotor seen from above turns the negative way about the scene's
    // +Y axis. Every caller that needs a rotation, a pitch or a short label for a
    // spin direction reads it from here.
    function spinSign(direction) {
        return direction === "ccw" ? -1 : 1;
    }

    function spinAbbreviation(direction) {
        return direction === "cw" ? "CW" : direction === "ccw" ? "CCW" : "—";
    }

    // Keep negated zeros out of the derived data so serialized specs compare cleanly.
    function signed(value) {
        return value === 0 ? 0 : value;
    }

    // FRD body coordinates (+X forward, +Y right, +Z down) to the scene basis
    // used by the panel (+X right, +Y up, -Z forward).
    function sceneVector(frd) {
        return [signed(Number(frd.y)), signed(-Number(frd.z)), signed(-Number(frd.x))];
    }

    function missingKeys(source, keys, allowZero) {
        if (!source || typeof source !== "object") return keys.slice();
        const acceptable = allowZero ? (value) => finite(value) && value >= 0 : positive;
        return keys.filter((key) => !acceptable(Number(source[key])));
    }

    function numbers(source, keys) {
        const result = {};
        keys.forEach((key) => { result[key] = Number(source[key]); });
        return result;
    }

    function classifyGeometry(provenance) {
        const reasons = [];
        if (!provenance || typeof provenance !== "object") {
            return { classification: "nominal", real: false, reasons: ["missing_provenance"] };
        }
        if (!text(provenance.model_source) || !text(provenance.source_url)) reasons.push("missing_model_source");

        const evidence = provenance.dimensional_evidence;
        const evidenceClass = evidence && typeof evidence === "object" ? evidence.evidence_class : "";
        if (QUALIFYING_EVIDENCE_CLASSES.indexOf(evidenceClass) < 0) reasons.push("unqualified_dimensional_evidence");
        const documents = evidence && Array.isArray(evidence.documents) ? evidence.documents : [];
        if (!documents.length || !documents.every((entry) => entry && text(entry.title) && text(entry.url))) {
            reasons.push("missing_dimensional_evidence_document");
        }

        if (provenance.redistribution !== "release") reasons.push("not_release_redistributable");

        const license = provenance.license && typeof provenance.license === "object" ? provenance.license : {};
        if (REDISTRIBUTABLE_LICENSES.indexOf(license.spdx) < 0) reasons.push("license_not_redistributable");
        if (license.attribution_required === true && !text(license.attribution)) reasons.push("missing_required_attribution");

        const assets = Array.isArray(provenance.assets) ? provenance.assets : [];
        if (!assets.length || !assets.every((asset) => asset && text(asset.path) && hexHash(asset.sha256))) {
            reasons.push("missing_asset_hash");
        }

        return { classification: reasons.length ? "nominal" : "real", real: reasons.length === 0, reasons };
    }

    function deriveGeometrySpec(configuration) {
        if (!configuration || typeof configuration !== "object") {
            return { available: false, reason: "hardware configuration unavailable" };
        }
        const geometry = configuration.geometry;
        if (!geometry || typeof geometry !== "object") {
            return { available: false, reason: "hardware configuration has no geometry section" };
        }
        const identity = geometry.identity;
        if (!identity || !text(identity.designation) || !text(identity.airframe_class)) {
            return { available: false, reason: "geometry.identity is incomplete" };
        }
        const bodyMissing = missingKeys(geometry.body, BODY_KEYS);
        if (bodyMissing.length) {
            return { available: false, reason: "geometry.body is incomplete: " + bodyMissing.join(", ") };
        }
        const motorMissing = missingKeys(geometry.motor, MOTOR_KEYS);
        if (motorMissing.length) {
            return { available: false, reason: "geometry.motor is incomplete: " + motorMissing.join(", ") };
        }
        const propellerMissing = missingKeys(geometry.propeller, PROPELLER_DIMENSION_KEYS)
            .concat(missingKeys(geometry.propeller, PROPELLER_ANGLE_KEYS, true));
        if (propellerMissing.length) {
            return { available: false, reason: "geometry.propeller is incomplete: " + propellerMissing.join(", ") };
        }

        const order = Array.isArray(configuration.motor_order) ? configuration.motor_order : [];
        const spin = Array.isArray(configuration.spin_direction) ? configuration.spin_direction : [];
        const aircraft = configuration.aircraft;
        const layout = aircraft && Array.isArray(aircraft.motor_layout) ? aircraft.motor_layout : [];
        if (!order.length) return { available: false, reason: "motor_order is unavailable" };
        if (spin.length !== order.length) return { available: false, reason: "spin_direction does not match motor_order" };
        if (layout.length !== order.length) return { available: false, reason: "aircraft.motor_layout does not match motor_order" };
        const centerOfMass = aircraft ? aircraft.cg_offset_m : null;
        if (!centerOfMass || !finite(Number(centerOfMass.x)) || !finite(Number(centerOfMass.y)) || !finite(Number(centerOfMass.z))) {
            return { available: false, reason: "aircraft.cg_offset_m is unavailable" };
        }

        const propellerConfig = configuration.propeller;
        if (!propellerConfig || !positive(Number(propellerConfig.diameter_in)) || !positive(Number(propellerConfig.blades))) {
            return { available: false, reason: "propeller.diameter_in and propeller.blades are required" };
        }
        const frame = configuration.frame;
        if (!frame || !positive(Number(frame.wheelbase_m))) {
            return { available: false, reason: "frame.wheelbase_m is unavailable" };
        }

        const motors = [];
        for (let index = 0; index < order.length; index += 1) {
            const placement = layout[index];
            if (!placement || !finite(Number(placement.x)) || !finite(Number(placement.y)) || !finite(Number(placement.z))) {
                return { available: false, reason: "aircraft.motor_layout row " + index + " is incomplete" };
            }
            const spinDirection = spin[index] === "cw" || spin[index] === "ccw" ? spin[index] : "unavailable";
            const frd = { x: Number(placement.x), y: Number(placement.y), z: Number(placement.z) };
            motors.push({
                id: String(order[index]),
                index,
                label: "M" + (index + 1),
                frd,
                scene: sceneVector(frd),
                radius_m: Math.hypot(frd.x, frd.y),
                spin_direction: spinDirection,
            });
        }

        const diameter = Number(propellerConfig.diameter_in) * INCH_M;
        const radius = diameter / 2;
        let minimumSpacing = Infinity;
        for (let a = 0; a < motors.length; a += 1) {
            for (let b = a + 1; b < motors.length; b += 1) {
                minimumSpacing = Math.min(minimumSpacing, Math.hypot(
                    motors[a].frd.x - motors[b].frd.x,
                    motors[a].frd.y - motors[b].frd.y,
                ));
            }
        }
        const clearance = Number.isFinite(minimumSpacing) ? minimumSpacing - diameter : Number.NaN;
        const maximumRadius = motors.reduce((carry, motor) => Math.max(carry, motor.radius_m), 0);
        const maximumOffset = motors.reduce(
            (carry, motor) => Math.max(carry, Math.abs(motor.frd.x), Math.abs(motor.frd.y)), 0,
        );

        // The motor-to-motor diagonal implied by the layout the physics uses is
        // the only honest wheelbase. Report it when the configuration's own
        // wheelbase disagrees, so a stated size cannot outlive its geometry.
        const layoutWheelbase = maximumRadius * 2;
        const warnings = [];
        if (finite(clearance) && clearance < 0) warnings.push("propeller_overlap");
        if (Math.abs(layoutWheelbase - Number(frame.wheelbase_m)) > Number(frame.wheelbase_m) * 0.01) {
            warnings.push("wheelbase_disagrees_with_motor_layout");
        }

        const verdict = classifyGeometry(geometry.provenance);
        const classification = warnings.length ? "nominal" : verdict.classification;
        const reasons = warnings.length ? verdict.reasons.concat(warnings) : verdict.reasons;

        return {
            available: true,
            identity: {
                designation: String(identity.designation),
                airframe_class: String(identity.airframe_class),
                frame_reference: text(identity.frame_reference) ? String(identity.frame_reference) : "",
            },
            classification,
            classification_reasons: reasons,
            scale: {
                wheelbase_m: Number(frame.wheelbase_m),
                layout_wheelbase_m: layoutWheelbase,
                motor_radius_m: maximumRadius,
                // Overall width measured across the body axes.
                span_m: (maximumOffset + radius) * 2,
                propeller_clearance_m: clearance,
            },
            motors,
            center_of_mass_frd_m: {
                x: Number(centerOfMass.x), y: Number(centerOfMass.y), z: Number(centerOfMass.z),
            },
            propeller: Object.assign(numbers(geometry.propeller, PROPELLER_DIMENSION_KEYS.concat(PROPELLER_ANGLE_KEYS)), {
                diameter_m: diameter,
                radius_m: radius,
                blades: Number(propellerConfig.blades),
                pitch_in: finite(Number(propellerConfig.pitch_in)) ? Number(propellerConfig.pitch_in) : null,
            }),
            body: numbers(geometry.body, BODY_KEYS),
            motor: Object.assign(numbers(geometry.motor, MOTOR_KEYS), {
                stator: text(configuration.motor && configuration.motor.stator) ? String(configuration.motor.stator) : "",
                kv: finite(Number(configuration.motor && configuration.motor.kv)) ? Number(configuration.motor.kv) : null,
            }),
            camera_angle_deg: finite(Number(configuration.fpv && configuration.fpv.camera_angle_deg))
                ? Number(configuration.fpv.camera_angle_deg) : 0,
            provenance: geometry.provenance || null,
            warnings,
        };
    }

    // --- Three.js construction ------------------------------------------------

    function standard(THREE, color, metalness, roughness, extra) {
        return new THREE.MeshStandardMaterial(Object.assign({ color, metalness, roughness }, extra || {}));
    }

    function mesh(THREE, geometry, material, position, rotation) {
        const node = new THREE.Mesh(geometry, material);
        if (position) node.position.set(position[0], position[1], position[2]);
        if (rotation) node.rotation.set(rotation[0], rotation[1], rotation[2]);
        node.castShadow = true;
        node.receiveShadow = true;
        return node;
    }

    // A carbon plate that narrows from root to tip, extruded to its real thickness.
    function taperedPlate(THREE, length, rootWidth, tipWidth, thickness) {
        const shape = new THREE.Shape();
        shape.moveTo(0, -rootWidth / 2);
        shape.lineTo(length, -tipWidth / 2);
        shape.lineTo(length, tipWidth / 2);
        shape.lineTo(0, rootWidth / 2);
        shape.closePath();
        const geometry = new THREE.ExtrudeGeometry(shape, { depth: thickness, bevelEnabled: false });
        geometry.rotateX(-Math.PI / 2);
        geometry.translate(0, -thickness / 2, 0);
        geometry.computeVertexNormals();
        return geometry;
    }

    // A twisted, tapered propeller blade: planform from the configured chord
    // stations, then a spanwise twist from root to tip pitch.
    // twistSign orients the blade for its rotor's direction of travel. A rotor
    // that pushes air down needs its leading edge higher than its trailing edge,
    // and the leading edge is the side the blade advances towards, so the two
    // spin directions need opposite pitch. See spinSign() for the sign source.
    function bladeGeometry(THREE, propeller, radius, twistSign) {
        const rootOffset = propeller.blade_root_offset_m;
        const span = radius - rootOffset;
        if (!(span > 0)) return new THREE.BufferGeometry();
        const stations = 10;
        const chordAt = (t) => (t <= 0.4
            ? propeller.blade_root_chord_m + (propeller.blade_max_chord_m - propeller.blade_root_chord_m) * (t / 0.4)
            : propeller.blade_max_chord_m + (propeller.blade_tip_chord_m - propeller.blade_max_chord_m) * ((t - 0.4) / 0.6));
        const shape = new THREE.Shape();
        for (let index = 0; index <= stations; index += 1) {
            const t = index / stations;
            const chord = chordAt(t);
            const x = rootOffset + span * t;
            if (index === 0) shape.moveTo(x, -chord * 0.3);
            else shape.lineTo(x, -chord * 0.3);
        }
        for (let index = stations; index >= 0; index -= 1) {
            const t = index / stations;
            shape.lineTo(rootOffset + span * t, chordAt(t) * 0.7);
        }
        shape.closePath();

        const geometry = new THREE.ExtrudeGeometry(shape, {
            depth: propeller.blade_thickness_m, bevelEnabled: false, curveSegments: 2, steps: 1,
        });
        geometry.translate(0, 0, -propeller.blade_thickness_m / 2);

        const rootTwist = twistSign * propeller.blade_root_twist_deg * Math.PI / 180;
        const tipTwist = twistSign * propeller.blade_tip_twist_deg * Math.PI / 180;
        const position = geometry.attributes.position;
        for (let index = 0; index < position.count; index += 1) {
            const x = position.getX(index);
            const t = Math.max(0, Math.min(1, (x - rootOffset) / span));
            const angle = rootTwist + (tipTwist - rootTwist) * t;
            const y = position.getY(index);
            const z = position.getZ(index);
            position.setXYZ(index, x, y * Math.cos(angle) - z * Math.sin(angle), y * Math.sin(angle) + z * Math.cos(angle));
        }
        // Span along +X, chord along +Z, thickness along +Y so the disc lies flat.
        geometry.rotateX(-Math.PI / 2);
        geometry.computeVertexNormals();
        return geometry;
    }

    function buildBody(THREE, spec, materials) {
        const body = new THREE.Group();
        body.name = "airframe-body";
        const dimensions = spec.body;
        const bottomTop = dimensions.bottom_plate_thickness_m / 2;
        const topPlateCenter = bottomTop + dimensions.standoff_height_m + dimensions.plate_thickness_m / 2;
        const topPlateTop = topPlateCenter + dimensions.plate_thickness_m / 2;

        body.add(mesh(THREE, new THREE.BoxGeometry(
            dimensions.center_plate_width_m, dimensions.bottom_plate_thickness_m, dimensions.center_plate_length_m,
        ), materials.carbon, [0, 0, 0]));
        body.add(mesh(THREE, new THREE.BoxGeometry(
            dimensions.center_plate_width_m * 0.82, dimensions.plate_thickness_m, dimensions.center_plate_length_m * 0.7,
        ), materials.carbon, [0, topPlateCenter, 0]));

        const standoffGeometry = new THREE.CylinderGeometry(
            dimensions.standoff_diameter_m / 2, dimensions.standoff_diameter_m / 2, dimensions.standoff_height_m, 12,
        );
        const standoffX = dimensions.center_plate_width_m * 0.34;
        const standoffZ = dimensions.center_plate_length_m * 0.26;
        [[-1, -1], [1, -1], [-1, 1], [1, 1]].forEach((corner) => {
            body.add(mesh(THREE, standoffGeometry, materials.anodized, [
                corner[0] * standoffX, bottomTop + dimensions.standoff_height_m / 2, corner[1] * standoffZ,
            ]));
        });

        // Flight controller and ESC stack between the plates.
        body.add(mesh(THREE, new THREE.BoxGeometry(
            dimensions.stack_width_m, dimensions.stack_height_m * 0.4, dimensions.stack_width_m,
        ), materials.polymer, [0, bottomTop + dimensions.stack_height_m * 0.25, 0]));
        body.add(mesh(THREE, new THREE.BoxGeometry(
            dimensions.stack_width_m * 0.94, dimensions.stack_height_m * 0.4, dimensions.stack_width_m * 0.94,
        ), materials.polymer, [0, bottomTop + dimensions.stack_height_m * 0.78, 0]));

        // Canopy and tilted FPV camera at the nose.
        const canopyZ = -dimensions.center_plate_length_m * 0.5 + dimensions.canopy_length_m * 0.5;
        body.add(mesh(THREE, new THREE.BoxGeometry(
            dimensions.canopy_width_m, dimensions.canopy_height_m, dimensions.canopy_length_m,
        ), materials.polymer, [0, topPlateTop + dimensions.canopy_height_m / 2, canopyZ]));
        const cameraTilt = spec.camera_angle_deg * Math.PI / 180;
        const cameraCenter = [
            0,
            topPlateTop + dimensions.canopy_height_m * 0.55,
            canopyZ - dimensions.canopy_length_m * 0.5 + dimensions.camera_depth_m * 0.4,
        ];
        const camera = new THREE.Group();
        camera.name = "fpv-camera";
        camera.position.set(cameraCenter[0], cameraCenter[1], cameraCenter[2]);
        camera.rotation.x = cameraTilt;
        camera.add(mesh(THREE, new THREE.BoxGeometry(
            dimensions.camera_width_m, dimensions.camera_height_m, dimensions.camera_depth_m,
        ), materials.polymer));
        camera.add(mesh(THREE, new THREE.CylinderGeometry(
            dimensions.camera_lens_diameter_m / 2, dimensions.camera_lens_diameter_m / 2, dimensions.camera_depth_m * 0.5, 16,
        ), materials.glass, [0, 0, -dimensions.camera_depth_m * 0.6], [Math.PI / 2, 0, 0]));
        body.add(camera);

        // Battery pack strapped to the top plate.
        const packZ = dimensions.center_plate_length_m * 0.5 - dimensions.battery_length_m * 0.5;
        const packCenter = topPlateTop + dimensions.battery_height_m / 2;
        body.add(mesh(THREE, new THREE.BoxGeometry(
            dimensions.battery_width_m, dimensions.battery_height_m, dimensions.battery_length_m,
        ), materials.pack, [0, packCenter, packZ]));
        body.add(mesh(THREE, new THREE.BoxGeometry(
            dimensions.battery_width_m * 1.08, dimensions.battery_height_m * 1.06, dimensions.battery_length_m * 0.18,
        ), materials.strap, [0, packCenter, packZ]));

        // Rear video antenna.
        const antenna = new THREE.Group();
        antenna.name = "video-antenna";
        antenna.position.set(0, topPlateTop, dimensions.center_plate_length_m * 0.5);
        antenna.rotation.x = -Math.PI / 4;
        antenna.add(mesh(THREE, new THREE.CylinderGeometry(
            dimensions.antenna_diameter_m / 2, dimensions.antenna_diameter_m / 2, dimensions.antenna_length_m, 10,
        ), materials.polymer, [0, dimensions.antenna_length_m / 2, 0]));
        antenna.add(mesh(THREE, new THREE.SphereGeometry(dimensions.antenna_diameter_m * 0.9, 12, 10), materials.anodized));
        body.add(antenna);

        return body;
    }

    function buildRotor(THREE, spec, motor, materials) {
        const group = new THREE.Group();
        group.name = "rotor-" + motor.id;
        group.position.set(motor.scene[0], motor.scene[1], motor.scene[2]);
        const armTop = spec.body.arm_thickness_m / 2;
        const hardware = spec.motor;
        const propeller = spec.propeller;

        group.add(mesh(THREE, new THREE.CylinderGeometry(
            hardware.base_diameter_m / 2, hardware.base_diameter_m / 2, hardware.base_height_m, 24,
        ), materials.aluminium, [0, armTop + hardware.base_height_m / 2, 0]));
        const bellCenter = armTop + hardware.base_height_m + hardware.bell_height_m / 2;
        group.add(mesh(THREE, new THREE.CylinderGeometry(
            hardware.bell_diameter_m / 2, hardware.bell_diameter_m * 0.46, hardware.bell_height_m, 24,
        ), materials.bell, [0, bellCenter, 0]));
        const bellTop = armTop + hardware.base_height_m + hardware.bell_height_m;
        group.add(mesh(THREE, new THREE.CylinderGeometry(
            hardware.shaft_diameter_m / 2, hardware.shaft_diameter_m / 2, hardware.shaft_height_m, 12,
        ), materials.aluminium, [0, bellTop + hardware.shaft_height_m / 2, 0]));

        const discHeight = bellTop + propeller.hub_height_m / 2;
        group.add(mesh(THREE, new THREE.CylinderGeometry(
            propeller.hub_diameter_m / 2, propeller.hub_diameter_m * 0.58, propeller.hub_height_m, 18,
        ), materials.prop, [0, discHeight, 0]));

        const blades = new THREE.Group();
        blades.name = "blades-" + motor.id;
        blades.position.y = discHeight;
        const sign = spinSign(motor.spin_direction);
        // Pitch the blade for this rotor's direction of travel rather than
        // mirroring the mesh, which would invert its normals.
        const template = bladeGeometry(THREE, propeller, propeller.radius_m, -sign);
        for (let index = 0; index < propeller.blades; index += 1) {
            const blade = new THREE.Mesh(template, materials.prop.clone());
            blade.castShadow = true;
            blade.rotation.y = index * TAU / propeller.blades;
            blades.add(blade);
        }
        group.add(blades);

        const disc = mesh(THREE, new THREE.CircleGeometry(propeller.radius_m, 40), materials.disc.clone(),
            [0, discHeight + propeller.hub_height_m, 0], [-Math.PI / 2, 0, 0]);
        disc.castShadow = false;
        disc.receiveShadow = false;
        group.add(disc);

        return { group, blades, disc, label: motor.label, spin_sign: sign, motor };
    }

    function buildDroneModel(THREE, spec) {
        if (!spec || !spec.available) throw new Error("geometry spec unavailable");
        const materials = {
            carbon: standard(THREE, CARBON, 0.28, 0.52),
            aluminium: standard(THREE, ALUMINIUM, 0.86, 0.24),
            bell: standard(THREE, ANODIZED, 0.78, 0.3),
            anodized: standard(THREE, ANODIZED, 0.7, 0.36),
            polymer: standard(THREE, POLYMER, 0.18, 0.68),
            glass: standard(THREE, 0x0b1016, 0.1, 0.14),
            prop: standard(THREE, PROP, 0.14, 0.42, { transparent: true, opacity: 0.94, side: THREE.DoubleSide }),
            pack: standard(THREE, PACK, 0.22, 0.74),
            strap: standard(THREE, PACK_LABEL, 0.2, 0.66),
            disc: new THREE.MeshBasicMaterial({
                color: ACCENT, transparent: true, opacity: 0, side: THREE.DoubleSide, depthWrite: false,
            }),
        };

        const group = new THREE.Group();
        group.name = "drone-" + spec.identity.airframe_class;
        const body = buildBody(THREE, spec, materials);
        group.add(body);

        const arms = [];
        const rotors = {};
        spec.motors.forEach((motor) => {
            const reach = Math.hypot(motor.scene[0], motor.scene[2]);
            const arm = new THREE.Group();
            arm.name = "arm-" + motor.id;
            arm.rotation.y = Math.atan2(-motor.scene[2], motor.scene[0]);
            arm.add(mesh(THREE, taperedPlate(
                THREE, reach, spec.body.arm_root_width_m, spec.body.arm_tip_width_m, spec.body.arm_thickness_m,
            ), materials.carbon));
            group.add(arm);
            arms.push(arm);

            group.add(mesh(THREE, new THREE.CylinderGeometry(
                spec.body.landing_foot_diameter_m / 2, spec.body.landing_foot_diameter_m * 0.36,
                spec.body.landing_foot_height_m, 12,
            ), materials.polymer, [
                motor.scene[0] * 0.62,
                -spec.body.arm_thickness_m / 2 - spec.body.landing_foot_height_m / 2,
                motor.scene[2] * 0.62,
            ]));

            const rotor = buildRotor(THREE, spec, motor, materials);
            group.add(rotor.group);
            rotors[motor.id] = rotor;
        });

        const centerOfMass = new THREE.Group();
        centerOfMass.name = "center-of-mass";
        const centerScene = sceneVector(spec.center_of_mass_frd_m);
        centerOfMass.position.set(centerScene[0], centerScene[1], centerScene[2]);
        centerOfMass.add(new THREE.Mesh(
            new THREE.OctahedronGeometry(spec.body.standoff_diameter_m * 0.9),
            new THREE.MeshBasicMaterial({ color: ACCENT, transparent: true, opacity: 0.7 }),
        ));
        group.add(centerOfMass);

        return { group, rotors, parts: { body, arms, center_of_mass: centerOfMass } };
    }

    // M1-M4 callouts pinned above each rotor. The caller supplies the texture so
    // the geometry package stays independent of the document.
    function buildMotorLabels(THREE, spec, createLabelTexture) {
        const group = new THREE.Group();
        group.name = "motor-labels";
        if (!spec || !spec.available || typeof createLabelTexture !== "function") return group;
        const height = spec.body.arm_thickness_m / 2 + spec.motor.base_height_m + spec.motor.bell_height_m
            + spec.propeller.hub_height_m + spec.body.landing_foot_height_m;
        spec.motors.forEach((motor) => {
            const texture = createLabelTexture(motor);
            if (!texture) return;
            const sprite = new THREE.Sprite(new THREE.SpriteMaterial({
                map: texture, transparent: true, depthTest: false, sizeAttenuation: true,
            }));
            sprite.name = "label-" + motor.label;
            const scale = spec.propeller.radius_m * 0.9;
            sprite.scale.set(scale, scale * 0.5, 1);
            sprite.position.set(motor.scene[0], motor.scene[1] + height, motor.scene[2]);
            sprite.userData = { motor_id: motor.id, label: motor.label };
            group.add(sprite);
        });
        return group;
    }

    root.__AEROSIM_GSP_DRONE_GEOMETRY__ = {
        derive_geometry_spec: deriveGeometrySpec,
        classify_geometry: classifyGeometry,
        build_drone_model: buildDroneModel,
        build_motor_labels: buildMotorLabels,
        spin_sign: spinSign,
        spin_abbreviation: spinAbbreviation,
    };
}());
