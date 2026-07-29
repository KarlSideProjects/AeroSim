(function () {
    const canvas = document.getElementById("airframe-3d");
    const context = canvas && canvas.getContext("2d");
    if (!canvas || !context) return;

    const motorOrder = ["rear_right", "front_right", "rear_left", "front_left"];
    const motorPositions = [[.34, .34], [.34, -.34], [-.34, .34], [-.34, -.34]];
    let sample = window.__AEROSIM_GSP_TELEMETRY__ || {};
    let view = "isometric";
    let yaw = .78;
    let pitch = .62;
    let distance = 1.9;
    let dragging = false;
    let previousPointer = null;
    let spinPhase = 0;

    function setView(next) {
        view = next;
        const presets = { isometric: [.78, .62], top: [0, 1.54], side: [1.57, 0], rear: [3.14, 0] };
        [yaw, pitch] = presets[next] || presets.isometric;
    }

    ["isometric", "top", "side", "rear"].forEach((name) => {
        const button = document.getElementById(`view-${name}`);
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
    window.addEventListener("aerosim-gsp-telemetry", (event) => { sample = event.detail || {}; });
    window.__AEROSIM_GSP_VISUAL__ = { motor_order: motorOrder.slice(), set_view: setView, current_view: () => view };

    function motorFor(index) {
        const motors = Array.isArray(sample.motors) ? sample.motors : [];
        return motors[index] || null;
    }

    function resize() {
        const pixelRatio = Math.min(window.devicePixelRatio || 1, 2);
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

        motorPositions.forEach((position, index) => {
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
            context.fillText(`M${index + 1}`, rotor[0] + radius + 4, rotor[1] + 4);
        });
        if (!window.matchMedia || !window.matchMedia("(prefers-reduced-motion: reduce)").matches) spinPhase += .06;
        requestAnimationFrame(render);
    }

    render();
}());
