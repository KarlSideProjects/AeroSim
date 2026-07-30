(function () {
    const root = typeof window === "undefined" ? globalThis : window;
    const TAU = Math.PI * 2;
    const geometryPackage = root.__AEROSIM_GSP_DRONE_GEOMETRY__ || null;
    let view = "isometric";
    let visualStatus = { available: false, rotor_count: 0, context_lost: false };
    let labels = {};
    let rotorById = {};
    let motorLabels = null;
    let geometrySpec = geometryPackage
        ? { available: false, reason: "waiting for hardware configuration" }
        : { available: false, reason: "geometry package unavailable" };

    function finite(value) {
        return typeof value === "number" && Number.isFinite(value);
    }

    function vectorState(value, gate) {
        if (gate && gate !== "active") return { state: gate, value: null };
        if (!finiteVector(value)) return { state: "unavailable", value: null };
        return { state: "active", value: { x: vectorAxis(value, "x"), y: vectorAxis(value, "y"), z: vectorAxis(value, "z") } };
    }

    function vectorAxis(value, axis) {
        if (!value || typeof value !== "object") return undefined;
        return Object.prototype.hasOwnProperty.call(value, axis) ? value[axis] : value[axis + "_val"];
    }

    function finiteVector(value) {
        return finite(vectorAxis(value, "x")) && finite(vectorAxis(value, "y")) && finite(vectorAxis(value, "z"));
    }

    function positiveVector(value) {
        return finiteVector(value) && vectorAxis(value, "x") > 0 && vectorAxis(value, "y") > 0 && vectorAxis(value, "z") > 0;
    }

    function qualifiedBodyDrag(sample) {
        const configuration = sample.hardware_configuration || {};
        const bodyDrag = configuration.aerodynamics && configuration.aerodynamics.body_drag;
        const evidence = bodyDrag && bodyDrag.evidence;
        const evidenceState = evidence && String(evidence.state || "");
        const airspeed = sample.airspeed_body_frd_mps_mean;
        return String(sample.body_drag_operating_state || "") === "active" &&
            ["provisional_estimate", "measured"].includes(evidenceState) &&
            typeof evidence.provenance === "string" && evidence.provenance.length > 0 &&
            finite(sample.air_density_kg_m3) && sample.air_density_kg_m3 > 0 &&
            finite(bodyDrag.air_density_kg_m3) && bodyDrag.air_density_kg_m3 > 0 &&
            positiveVector(bodyDrag.drag_coefficient) &&
            positiveVector(configuration.frame && configuration.frame.frontal_area_m2) &&
            finiteVector(bodyDrag.center_of_pressure_frd_m) &&
            finiteVector(configuration.aircraft && configuration.aircraft.cg_offset_m) &&
            finiteVector(airspeed);
    }

    // Rendered geometry always comes from the hardware configuration the
    // simulator sent, never from renderer constants.
    function deriveGeometry(sample) {
        if (!geometryPackage) return { available: false, reason: "geometry package unavailable" };
        return geometryPackage.derive_geometry_spec(sample ? sample.hardware_configuration : null);
    }

    function mapTelemetryToViewState(sample, frameSeconds) {
        sample = sample || {};
        const motors = Array.isArray(sample.motors) ? sample.motors : [];
        const order = Array.isArray(sample.motor_order) ? sample.motor_order : [];
        const rpm = Array.isArray(sample.rpm) ? sample.rpm : [];
        const spin = sample.hardware_configuration && Array.isArray(sample.hardware_configuration.spin_direction) ? sample.hardware_configuration.spin_direction : [];
        const power = sample.hardware_power_model || {};
        const count = motors.length;
        const maxThrust = Number(power.max_total_thrust_newtons) / count;
        const maxCurrent = Number(power.max_total_current_a) / count;
        const hasPower = count > 0 && finite(maxThrust) && maxThrust > 0 && finite(maxCurrent) && maxCurrent > 0;
        const seconds = finite(frameSeconds) && frameSeconds > 0 ? frameSeconds : 1 / 60;
        const geometry = deriveGeometry(sample);
        const placements = geometry.available ? geometry.motors : [];
        return {
            axes: { body: "FRD", scene: { forward: "-Z", right: "+X", down: "-Y" } },
            geometry,
            motors: motors.map((motor, index) => {
                const thrust = Number(motor && motor.thrust_newtons);
                const current = Number(motor && motor.current_a);
                const speed = Number(motor && motor.speed_rad_s);
                const measuredRpm = finite(Number(rpm[index])) ? Number(rpm[index]) : speed * 60 / TAU;
                const ratio = hasPower && finite(thrust) && finite(current) ? Math.max(thrust / maxThrust, current / maxCurrent) : Number.NaN;
                const health = !finite(ratio) ? "unavailable" : motor && motor.saturated || ratio >= .98 ? "critical" : ratio >= .85 ? "warning" : "normal";
                const normalized = finite(ratio) ? Math.max(0, Math.min(ratio, 1)) : 0;
                const id = String(order[index] || "motor_" + (index + 1));
                const placement = placements[index] && placements[index].id === id ? placements[index] : null;
                return {
                    id, index, label: "M" + (index + 1),
                    position: placement ? placement.scene : null,
                    rpm: finite(measuredRpm) ? measuredRpm : null,
                    thrust_newtons: finite(thrust) ? thrust : null, current_a: finite(current) ? current : null,
                    saturated: !!(motor && motor.saturated), spin_direction: spin[index] === "cw" || spin[index] === "ccw" ? spin[index] : "unavailable",
                    health, rotor_opacity: 1 - normalized * .85, disc_opacity: normalized * .85,
                    angular_step_rad: finite(measuredRpm) ? Math.min(Math.PI / 6, Math.abs(measuredRpm) * TAU / 60 * seconds) : 0,
                };
            }),
            flow: {
                wind: vectorState(sample.wind_body_mps), airspeed: vectorState(sample.airspeed_body_frd_mps_mean),
                body_drag: vectorState(sample.body_drag_force_body_frd_n_mean, qualifiedBodyDrag(sample) ? "active" : "unavailable"),
                body_drag_torque: vectorState(sample.body_drag_torque_body_frd_nm_mean, qualifiedBodyDrag(sample) ? "active" : "unavailable"),
                rotor_drag: vectorState(sample.a3_drag_force_body_frd_n_mean, String(sample.a3_operating_state || "unavailable")),
                propwash: vectorState(sample.propwash_disturbance_rad_s2, String(sample.a6_operating_state || "unavailable")),
                downwash: finite(Number(sample.downwash_force_n)) ? { state: "active", value: Number(sample.downwash_force_n) } : { state: "unavailable", value: null },
                ground_effect: finite(Number(sample.ground_effect_gain)) ? { state: "active", value: Number(sample.ground_effect_gain) } : { state: "unavailable", value: null },
                density: finite(Number(sample.air_density_kg_m3)) ? { state: "active", value: Number(sample.air_density_kg_m3) } : { state: "unavailable", value: null },
            },
        };
    }

    function setView(next) {
        view = ["isometric", "top", "side", "rear"].includes(next) ? next : "isometric";
    }

    function setLabels(next) {
        labels = next || {};
    }

    function renderedLabels() {
        if (!motorLabels) return [];
        return motorLabels.children.map((sprite) => ({
            label: String(sprite.userData.label),
            motor_id: String(sprite.userData.motor_id),
            position: sprite.position.toArray(),
        }));
    }

    function geometryReport() {
        if (!geometrySpec.available) {
            return {
                available: false,
                reason: String(geometrySpec.reason || "geometry unavailable"),
                classification: "unavailable",
            };
        }
        return {
            available: true,
            classification: geometrySpec.classification,
            classification_reasons: geometrySpec.classification_reasons.slice(),
            identity: Object.assign({}, geometrySpec.identity),
            scale: Object.assign({}, geometrySpec.scale),
            center_of_mass_frd_m: Object.assign({}, geometrySpec.center_of_mass_frd_m),
            propeller: Object.assign({}, geometrySpec.propeller),
            motor: Object.assign({}, geometrySpec.motor),
            motors: geometrySpec.motors.map((motor) => ({
                id: motor.id, label: motor.label, spin_direction: motor.spin_direction,
                frd: Object.assign({}, motor.frd), scene: motor.scene.slice(), radius_m: motor.radius_m,
            })),
            provenance: geometrySpec.provenance,
            warnings: geometrySpec.warnings.slice(),
            rendered: Object.keys(rotorById).length > 0,
            rendered_labels: renderedLabels(),
        };
    }

    function api() {
        return {
            map_telemetry_to_view_state: mapTelemetryToViewState,
            set_labels: setLabels,
            set_view: setView,
            current_view: () => view,
            status: () => Object.assign({}, visualStatus),
            geometry: geometryReport,
            rotor: (id) => rotorById[id] || null,
        };
    }

    root.__AEROSIM_GSP_VISUAL__ = api();
    if (typeof document === "undefined") return;
    const canvas = document.getElementById("airframe-3d");
    const THREE = root.THREE;
    if (!canvas || !THREE || !geometryPackage) return;

    let renderer;
    try {
        renderer = new THREE.WebGLRenderer({ canvas, antialias: true, alpha: false });
    } catch (_error) {
        return;
    }
    renderer.outputColorSpace = THREE.SRGBColorSpace;
    renderer.toneMapping = THREE.ACESFilmicToneMapping;
    renderer.shadowMap.enabled = true;
    renderer.shadowMap.type = THREE.PCFSoftShadowMap;

    const scene = new THREE.Scene();
    scene.background = new THREE.Color(0x0c1219);
    const camera = new THREE.PerspectiveCamera(38, 1, .01, 20);
    const key = new THREE.DirectionalLight(0xd9ecff, 2.2);
    key.position.set(.4, .6, .2); key.castShadow = true; scene.add(key);
    scene.add(new THREE.HemisphereLight(0x9fc8ff, 0x102236, 1.6));
    const ground = new THREE.Mesh(new THREE.PlaneGeometry(1, 1), new THREE.MeshStandardMaterial({ color: 0x101923, roughness: .94 }));
    ground.rotation.x = -Math.PI / 2; ground.receiveShadow = true; scene.add(ground);
    const airframe = new THREE.Group(); scene.add(airframe);
    const flow = new THREE.ArrowHelper(new THREE.Vector3(0, 0, -1), new THREE.Vector3(), 0, 0x67d5ff, .18, .1);
    scene.add(flow);
    const downwash = new THREE.ArrowHelper(new THREE.Vector3(0, -1, 0), new THREE.Vector3(0, .05, 0), 0, 0xffcf78, .12, .08);
    scene.add(downwash);

    let sample = root.__AEROSIM_GSP_TELEMETRY__ || {};
    let state = mapTelemetryToViewState(sample);
    let lastFrame = performance.now();
    let dragging = false;
    let previousPointer = null;
    let yaw = .78;
    let pitch = .62;
    let distance = 1;
    let model = null;
    let truthGhost = null;
    let renderedSignature = "";

    // "M1 CW" callouts drawn into a texture so the rotor mapping is readable in
    // the render itself, not only in the panel text.
    function createLabelTexture(motor) {
        const labelCanvas = document.createElement("canvas");
        labelCanvas.width = 192;
        labelCanvas.height = 96;
        const context = labelCanvas.getContext("2d");
        if (!context) return null;
        context.fillStyle = "rgba(9,14,20,0.86)";
        context.fillRect(0, 0, labelCanvas.width, labelCanvas.height);
        context.strokeStyle = "rgba(103,213,255,0.75)";
        context.lineWidth = 4;
        context.strokeRect(2, 2, labelCanvas.width - 4, labelCanvas.height - 4);
        context.fillStyle = "#e4eef8";
        context.font = "600 46px ui-sans-serif, system-ui, sans-serif";
        context.textAlign = "center";
        context.textBaseline = "middle";
        const spin = geometryPackage.spin_abbreviation(motor.spin_direction);
        context.fillText(motor.label + " " + spin, labelCanvas.width / 2, labelCanvas.height / 2);
        const texture = new THREE.CanvasTexture(labelCanvas);
        texture.colorSpace = THREE.SRGBColorSpace;
        return texture;
    }

    function disposeNode(node) {
        node.traverse((child) => {
            if (child.geometry) child.geometry.dispose();
            const material = child.material;
            if (Array.isArray(material)) material.forEach((entry) => entry.dispose());
            else if (material) {
                if (material.map) material.map.dispose();
                material.dispose();
            }
        });
    }

    function buildTruthGhost(source) {
        const ghost = new THREE.Group();
        source.updateWorldMatrix(true, true);
        source.traverse((child) => {
            if (!child.isMesh || !child.geometry) return;
            const edge = new THREE.LineSegments(
                new THREE.EdgesGeometry(child.geometry),
                new THREE.LineDashedMaterial({ color: 0xffcf78, dashSize: .008, gapSize: .005 }),
            );
            edge.matrix.copy(child.matrixWorld);
            edge.matrixAutoUpdate = false;
            edge.computeLineDistances();
            ghost.add(edge);
        });
        ghost.visible = false;
        return ghost;
    }

    // The model is rebuilt inside the render loop, one frame after the telemetry
    // that changed it. Announce the new state so the panel's status and geometry
    // card do not describe the previous frame.
    function announceVisualState() {
        if (typeof CustomEvent !== "function" || !root.dispatchEvent) return;
        root.dispatchEvent(new CustomEvent("aerosim-gsp-visual", { detail: Object.assign({}, visualStatus) }));
    }

    function applyGeometry(spec) {
        const signature = spec.available ? JSON.stringify({
            identity: spec.identity, scale: spec.scale, body: spec.body, motor: spec.motor,
            propeller: spec.propeller, camera_angle_deg: spec.camera_angle_deg,
            motors: spec.motors.map((motor) => [motor.id, motor.scene, motor.spin_direction]),
            center: spec.center_of_mass_frd_m,
        }) : "";
        if (signature === renderedSignature) return;
        renderedSignature = signature;
        while (airframe.children.length) {
            const child = airframe.children.pop();
            disposeNode(child);
        }
        if (truthGhost) {
            scene.remove(truthGhost);
            disposeNode(truthGhost);
            truthGhost = null;
        }
        model = null;
        motorLabels = null;
        rotorById = {};
        if (!spec.available) {
            visualStatus = { available: false, rotor_count: 0, context_lost: visualStatus.context_lost };
            announceVisualState();
            return;
        }
        model = geometryPackage.build_drone_model(THREE, spec);
        airframe.add(model.group);
        // The truth ghost shares the configured model; it never reintroduces
        // nominal coordinates or dimensions into the renderer.
        truthGhost = buildTruthGhost(model.group);
        scene.add(truthGhost);
        motorLabels = geometryPackage.build_motor_labels(THREE, spec, createLabelTexture);
        airframe.add(motorLabels);
        rotorById = model.rotors;
        const span = spec.scale.span_m;
        ground.geometry.dispose();
        ground.geometry = new THREE.PlaneGeometry(span * 6, span * 6);
        ground.position.y = -(spec.body.arm_thickness_m / 2 + spec.body.landing_foot_height_m);
        key.position.set(span * 1.2, span * 1.8, span * .6);
        distance = span * 2.4;
        visualStatus = {
            available: true,
            rotor_count: Object.keys(rotorById).length,
            context_lost: visualStatus.context_lost,
        };
        announceVisualState();
    }

    function setCamera() {
        const presets = { isometric: [.78, .62], top: [0, 1.54], side: [1.57, 0], rear: [3.14, 0] };
        if (view !== "free") [yaw, pitch] = presets[view] || presets.isometric;
        camera.position.set(Math.sin(yaw) * Math.cos(pitch) * distance, Math.sin(pitch) * distance, Math.cos(yaw) * Math.cos(pitch) * distance);
        camera.lookAt(0, 0, 0);
    }

    function sceneVector(vector) {
        return new THREE.Vector3(vector.y, -vector.z, -vector.x);
    }

    function updateFlow() {
        const span = geometrySpec.available ? geometrySpec.scale.span_m : 0;
        const wind = state.flow.wind;
        if (wind.state === "active" && span > 0) {
            const vector = sceneVector(wind.value); const length = vector.length();
            flow.visible = length > 0;
            if (length > 0) {
                flow.position.set(0, span * .6, 0);
                flow.setDirection(vector.normalize());
                flow.setLength(Math.min(span, length / 15 * span), span * .12, span * .06);
            }
        } else flow.visible = false;
        const down = state.flow.downwash;
        downwash.visible = down.state === "active" && down.value > 0 && span > 0;
        if (downwash.visible) downwash.setLength(Math.min(span * .6, down.value / 10 * span * .6), span * .1, span * .05);
    }

    function updateScene(seconds) {
        state = mapTelemetryToViewState(sample, seconds);
        geometrySpec = state.geometry;
        applyGeometry(geometrySpec);
        state.motors.forEach((motor) => {
            const rotor = rotorById[motor.id]; if (!rotor) return;
            const color = motor.health === "critical" ? 0xff8aad : motor.health === "warning" ? 0xffcf78 : motor.health === "normal" ? 0x9ee6b1 : 0x59646d;
            rotor.blades.children.forEach((blade) => { blade.material.color.setHex(color); blade.material.opacity = motor.rotor_opacity; });
            rotor.disc.material.color.setHex(color); rotor.disc.material.opacity = motor.disc_opacity;
            // A clockwise rotor seen from above turns the negative way about +Y.
            if (!root.matchMedia || !root.matchMedia("(prefers-reduced-motion: reduce)").matches) rotor.blades.rotation.y -= motor.angular_step_rad * rotor.spin_sign;
        });
        updateFlow();
        const px4 = sample.px4_mavlink && sample.px4_mavlink.local_position_ned;
        const attitude = sample.px4_mavlink && sample.px4_mavlink.attitude;
        const estimate = px4 && !px4.stale && px4.sample && px4.sample.position_ned;
        const truth = sample.pos_ned;
        if (estimate && truth && finiteVector(estimate) && finiteVector(truth)) {
            // PX4 estimate drives the solid Drone; local simulation stays the labelled ghost.
            const delta = sceneVector({ x: vectorAxis(estimate, "x") - vectorAxis(truth, "x"), y: vectorAxis(estimate, "y") - vectorAxis(truth, "y"), z: vectorAxis(estimate, "z") - vectorAxis(truth, "z") });
            airframe.position.copy(delta.clampLength(0, 1.5)); truthGhost.visible = true;
        } else {
            airframe.position.set(0, 0, 0);
            if (truthGhost) truthGhost.visible = false;
        }
        if (attitude && !attitude.stale && attitude.sample && finite(Number(attitude.sample.roll_rad)) && finite(Number(attitude.sample.pitch_rad)) && finite(Number(attitude.sample.yaw_rad))) airframe.rotation.set(-Number(attitude.sample.pitch_rad), -Number(attitude.sample.yaw_rad), Number(attitude.sample.roll_rad));
    }

    function resize() {
        const width = Math.max(1, canvas.clientWidth || 1); const height = Math.max(1, canvas.clientHeight || 1);
        renderer.setPixelRatio(Math.min(root.devicePixelRatio || 1, 2)); renderer.setSize(width, height, false);
        camera.aspect = width / height; camera.updateProjectionMatrix();
    }

    canvas.addEventListener("pointerdown", (event) => { dragging = true; previousPointer = event; canvas.setPointerCapture?.(event.pointerId); });
    canvas.addEventListener("pointerup", () => { dragging = false; previousPointer = null; });
    canvas.addEventListener("pointermove", (event) => {
        if (!dragging || !previousPointer) return;
        view = "free"; yaw += (event.clientX - previousPointer.clientX) * .012; pitch = Math.max(-1.35, Math.min(1.35, pitch + (event.clientY - previousPointer.clientY) * .012)); previousPointer = event;
    });
    canvas.addEventListener("wheel", (event) => {
        const span = geometrySpec.available ? geometrySpec.scale.span_m : 1;
        distance = Math.max(span * 1.2, Math.min(span * 6, distance + event.deltaY * span * .002));
        event.preventDefault();
    }, { passive: false });
    canvas.addEventListener("webglcontextlost", (event) => {
        event.preventDefault();
        visualStatus = { available: false, rotor_count: 0, context_lost: true };
        announceVisualState();
    });
    root.addEventListener("aerosim-gsp-telemetry", (event) => { sample = event.detail || {}; });

    try {
        if (THREE.RoomEnvironment && THREE.PMREMGenerator) {
            const pmrem = new THREE.PMREMGenerator(renderer); scene.environment = pmrem.fromScene(new THREE.RoomEnvironment()).texture; pmrem.dispose();
        }
    } catch (_error) {
        // A missing environment map only costs reflections.
    }

    function render(now) {
        const seconds = Math.min(.1, Math.max(0, (now - lastFrame) / 1000)); lastFrame = now;
        resize(); updateScene(seconds); setCamera(); renderer.render(scene, camera); root.requestAnimationFrame(render);
    }
    root.requestAnimationFrame(render);
}());
