(function () {
    const root = typeof window === "undefined" ? globalThis : window;
    const MOTOR_POSITIONS = {
        rear_right: [1, 0, 1],
        front_right: [1, 0, -1],
        rear_left: [-1, 0, 1],
        front_left: [-1, 0, -1],
    };
    const TAU = Math.PI * 2;
    let view = "isometric";
    let visualStatus = { available: false, rotor_count: 0, context_lost: false };
    let labels = {};

    function finite(value) {
        return typeof value === "number" && Number.isFinite(value);
    }

    function vectorState(value, gate) {
        if (gate && gate !== "active") return { state: gate, value: null };
        if (!value || !finite(Number(value.x_val)) || !finite(Number(value.y_val)) || !finite(Number(value.z_val))) {
            return { state: "unavailable", value: null };
        }
        return {
            state: "active",
            value: { x: Number(value.x_val), y: Number(value.y_val), z: Number(value.z_val) },
        };
    }

    function mapTelemetryToViewState(sample, frameSeconds) {
        sample = sample || {};
        const motors = Array.isArray(sample.motors) ? sample.motors : [];
        const order = Array.isArray(sample.motor_order) ? sample.motor_order : [];
        const rpm = Array.isArray(sample.rpm) ? sample.rpm : [];
        const spin = sample.hardware_configuration && Array.isArray(sample.hardware_configuration.spin_direction)
            ? sample.hardware_configuration.spin_direction
            : [];
        const power = sample.hardware_power_model || {};
        const count = motors.length;
        const maxThrust = Number(power.max_total_thrust_newtons) / count;
        const maxCurrent = Number(power.max_total_current_a) / count;
        const hasPower = count > 0 && finite(maxThrust) && maxThrust > 0 && finite(maxCurrent) && maxCurrent > 0;
        const seconds = finite(frameSeconds) && frameSeconds > 0 ? frameSeconds : 1 / 60;

        return {
            axes: { body: "FRD", scene: { forward: "-Z", right: "+X", down: "-Y" } },
            motors: motors.map((motor, index) => {
                const thrust = Number(motor && motor.thrust_newtons);
                const current = Number(motor && motor.current_a);
                const speed = Number(motor && motor.speed_rad_s);
                const measuredRpm = finite(Number(rpm[index])) ? Number(rpm[index]) : speed * 60 / TAU;
                const ratio = hasPower && finite(thrust) && finite(current)
                    ? Math.max(thrust / maxThrust, current / maxCurrent)
                    : Number.NaN;
                let health = "unavailable";
                if (finite(ratio)) health = motor && motor.saturated ? "critical" : ratio >= 0.98 ? "critical" : ratio >= 0.85 ? "warning" : "normal";
                const id = String(order[index] || "motor_" + (index + 1));
                const normalized = finite(ratio) ? Math.max(0, Math.min(ratio, 1)) : 0;
                return {
                    id,
                    index,
                    position: MOTOR_POSITIONS[id] || [0, 0, 0],
                    rpm: finite(measuredRpm) ? measuredRpm : null,
                    thrust_newtons: finite(thrust) ? thrust : null,
                    current_a: finite(current) ? current : null,
                    saturated: !!(motor && motor.saturated),
                    spin_direction: spin[index] === "cw" || spin[index] === "ccw" ? spin[index] : "unavailable",
                    health,
                    rotor_opacity: 1 - normalized * 0.85,
                    disc_opacity: normalized * 0.85,
                    angular_step_rad: finite(measuredRpm) ? Math.min(Math.PI / 6, Math.abs(measuredRpm) * TAU / 60 * seconds) : 0,
                };
            }),
            flow: {
                wind: vectorState(sample.wind_body_mps),
                airspeed: vectorState(sample.airspeed_body_frd_mps_mean),
                body_drag: vectorState(sample.drag_body_n, String(sample.body_drag_operating_state || "unavailable")),
                mean_drag: vectorState(sample.body_drag_force_body_frd_n_mean, String(sample.body_drag_operating_state || "unavailable")),
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

    root.__AEROSIM_GSP_VISUAL__ = {
        map_telemetry_to_view_state: mapTelemetryToViewState,
        set_labels: setLabels,
        set_view: setView,
        current_view: () => view,
        status: () => Object.assign({}, visualStatus),
    };

    if (typeof document === "undefined") return;
    const canvas = document.getElementById("airframe-3d");
    const context = canvas && canvas.getContext("2d");
    if (!canvas || !context) return;

    const motorOrder = ["rear_right", "front_right", "rear_left", "front_left"];
    const motorPositions = [[.34, .34], [.34, -.34], [-.34, .34], [-.34, -.34]];
    let sample = root.__AEROSIM_GSP_TELEMETRY__ || {};
    let yaw = .78;
    let pitch = .62;
    let distance = 1.9;
    let dragging = false;
    let previousPointer = null;
    let spinPhase = 0;

    ["isometric", "top", "side", "rear"].forEach((name) => {
        const button = document.getElementById("view-" + name);
        if (button) button.addEventListener("click", () => setView(name));
    });
    canvas.addEventListener("pointerdown", (event) => { dragging = true; previousPointer = event; canvas.setPointerCapture?.(event.pointerId); });
    canvas.addEventListener("pointerup", () => { dragging = false; previousPointer = null; });
    canvas.addEventListener("pointermove", (event) => {
        if (!dragging || !previousPointer) return;
        yaw += (event.clientX - previousPointer.clientX) * .012;
        pitch = Math.max(-1.45, Math.min(1.45, pitch + (event.clientY - previousPointer.clientY) * .012));
        previousPointer = event;
    });
    canvas.addEventListener("wheel", (event) => { distance = Math.max(.7, Math.min(4, distance + event.deltaY * .002)); event.preventDefault(); }, { passive: false });
    root.addEventListener("aerosim-gsp-telemetry", (event) => { sample = event.detail || {}; });

    function motorFor(index) {
        const motors = Array.isArray(sample.motors) ? sample.motors : [];
        return motors[index] || null;
    }

    function resize() {
        const pixelRatio = Math.min(root.devicePixelRatio || 1, 2);
        const width = Math.max(1, Math.round(canvas.clientWidth * pixelRatio));
        const height = Math.max(1, Math.round(canvas.clientHeight * pixelRatio));
        if (canvas.width !== width || canvas.height !== height) {
            canvas.width = width;
            canvas.height = height;
        }
        context.setTransform(pixelRatio, 0, 0, pixelRatio, 0, 0);
        return { width: canvas.clientWidth || 1, height: canvas.clientHeight || 1 };
    }

    function render() {
        const size = resize();
        const centerX = size.width / 2;
        const centerY = size.height / 2;
        const scale = Math.min(size.width, size.height) * .62 / distance;
        const verticalScale = Math.max(.24, Math.abs(Math.sin(pitch)));
        const cosine = Math.cos(yaw);
        const sine = Math.sin(yaw);
        const project = (x, z) => [centerX + (x * cosine - z * sine) * scale, centerY + (x * sine + z * cosine) * scale * verticalScale];
        const hub = project(0, 0);
        context.clearRect(0, 0, size.width, size.height);
        context.fillStyle = "#0c1219";
        context.fillRect(0, 0, size.width, size.height);
        context.strokeStyle = "#31445d";
        context.lineWidth = 1;
        context.beginPath(); context.moveTo(0, centerY); context.lineTo(size.width, centerY); context.stroke();

        motorPositions.forEach((position) => {
            const rotor = project(position[0], position[1]);
            context.strokeStyle = "#7d939f";
            context.lineWidth = 5;
            context.beginPath(); context.moveTo(hub[0], hub[1]); context.lineTo(rotor[0], rotor[1]); context.stroke();
        });
        context.fillStyle = "#263a47";
        context.fillRect(hub[0] - 12, hub[1] - 8, 24, 16);

        const spins = sample.hardware_configuration && sample.hardware_configuration.spin_direction;
        motorPositions.forEach((position, index) => {
            const rotor = project(position[0], position[1]);
            const motor = motorFor(index);
            const color = !motor ? "#59646d" : motor.saturated ? "#ff4d8d" : "#ffb020";
            const radius = Math.max(9, scale * .14);
            context.fillStyle = color;
            context.globalAlpha = .78;
            context.beginPath(); context.arc(rotor[0], rotor[1], radius, 0, Math.PI * 2); context.fill();
            context.globalAlpha = 1;
            const direction = Array.isArray(spins) && spins[index] === "ccw" ? -1 : 1;
            context.strokeStyle = "#dce7f5";
            context.lineWidth = 2;
            for (let blade = 0; blade < 2; blade += 1) {
                const angle = spinPhase * direction + blade * Math.PI / 2;
                context.beginPath(); context.moveTo(rotor[0], rotor[1]); context.lineTo(rotor[0] + Math.cos(angle) * radius, rotor[1] + Math.sin(angle) * radius); context.stroke();
            }
            context.fillStyle = "#dce7f5";
            context.font = "12px system-ui";
            context.fillText("M" + (index + 1), rotor[0] + radius + 4, rotor[1] + 4);
        });
        if (!root.matchMedia || !root.matchMedia("(prefers-reduced-motion: reduce)").matches) spinPhase += .06;
        root.requestAnimationFrame(render);
    }

    render();
}());
