import * as THREE from "./three-0.180.0.module.min.js";

const canvas = document.getElementById("airframe-3d");
if (canvas) {
    const renderer = new THREE.WebGLRenderer({ canvas, antialias: true, alpha: true });
    const scene = new THREE.Scene();
    const camera = new THREE.PerspectiveCamera(42, 1, 0.01, 100);
    const frame = new THREE.Group();
    const rotors = [];
    const motorOrder = ["rear_right", "front_right", "rear_left", "front_left"];
    const motorPositions = [[.34, 0, .34], [.34, 0, -.34], [-.34, 0, .34], [-.34, 0, -.34]];
    let sample = window.__AEROSIM_GSP_TELEMETRY__ || {};
    let view = "isometric";
    let dragging = false;
    let yaw = .78;
    let pitch = .62;
    let distance = 1.9;
    let previousPointer = null;

    scene.add(new THREE.HemisphereLight(0x46d6e8, 0x05080b, 2));
    const hub = new THREE.Mesh(new THREE.BoxGeometry(.22, .06, .16), new THREE.MeshStandardMaterial({ color: 0x263a47 }));
    frame.add(hub);
    motorPositions.forEach((position, index) => {
        const arm = new THREE.Mesh(new THREE.BoxGeometry(.52, .025, .025), new THREE.MeshStandardMaterial({ color: 0x7d939f }));
        arm.position.set(position[0] / 2, 0, position[2] / 2);
        arm.rotation.y = Math.atan2(position[2], position[0]);
        frame.add(arm);
        const rotor = new THREE.Mesh(new THREE.CylinderGeometry(.14, .14, .012, 32), new THREE.MeshStandardMaterial({ color: 0xffb020, transparent: true, opacity: .75 }));
        rotor.position.set(...position);
        rotor.userData.key = motorOrder[index];
        frame.add(rotor);
        rotors.push(rotor);
    });
    scene.add(frame);

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

    function motorsByKey() {
        const data = {};
        const values = Array.isArray(sample.motors) ? sample.motors : [];
        motorOrder.forEach((key, index) => { data[key] = values[index] || null; });
        return data;
    }
    function render() {
        const width = canvas.clientWidth || 1;
        const height = canvas.clientHeight || 1;
        renderer.setSize(width, height, false);
        camera.aspect = width / height;
        camera.position.set(distance * Math.cos(pitch) * Math.cos(yaw), distance * Math.sin(pitch), distance * Math.cos(pitch) * Math.sin(yaw));
        camera.lookAt(0, 0, 0);
        camera.updateProjectionMatrix();
        const motors = motorsByKey();
        const spins = sample.hardware_configuration && sample.hardware_configuration.spin_direction;
        rotors.forEach((rotor) => {
            const motor = motors[rotor.userData.key];
            if (!motor) { rotor.material.color.set(0x59646d); return; }
            const direction = Array.isArray(spins) && spins[motorOrder.indexOf(rotor.userData.key)] === "ccw" ? -1 : 1;
            if (!window.matchMedia || !window.matchMedia("(prefers-reduced-motion: reduce)").matches) rotor.rotation.y += direction * Number(motor.speed_rad_s || 0) / 3000;
            rotor.material.color.set(motor.saturated ? 0xff4d8d : 0xffb020);
        });
        renderer.render(scene, camera);
        requestAnimationFrame(render);
    }
    render();
}
