import * as THREE from "./three-0.180.0.module.min.js";

const canvas = document.getElementById("airframe-3d");
if (canvas) {
    const renderer = new THREE.WebGLRenderer({ canvas, antialias: true, alpha: true });
    const scene = new THREE.Scene();
    const camera = new THREE.PerspectiveCamera(42, 1, 0.01, 100);
    camera.position.set(1.35, 1.1, 1.35);
    camera.lookAt(0, 0, 0);
    scene.add(new THREE.HemisphereLight(0x46d6e8, 0x05080b, 2));
    const frame = new THREE.Group();
    const hub = new THREE.Mesh(new THREE.BoxGeometry(.22, .06, .16), new THREE.MeshStandardMaterial({ color: 0x263a47 }));
    frame.add(hub);
    const rotors = [];
    [[-.34, 0, -.34], [.34, 0, -.34], [-.34, 0, .34], [.34, 0, .34]].forEach((position) => {
        const arm = new THREE.Mesh(new THREE.BoxGeometry(.52, .025, .025), new THREE.MeshStandardMaterial({ color: 0x7d939f }));
        arm.position.set(position[0] / 2, 0, position[2] / 2); arm.rotation.y = Math.atan2(position[2], position[0]); frame.add(arm);
        const rotor = new THREE.Mesh(new THREE.CylinderGeometry(.14, .14, .012, 32), new THREE.MeshStandardMaterial({ color: 0xffb020, transparent: true, opacity: .75 }));
        rotor.position.set(...position); frame.add(rotor); rotors.push(rotor);
    });
    scene.add(frame);
    let sample = window.__AEROSIM_GSP_TELEMETRY__ || {};
    window.addEventListener("aerosim-gsp-telemetry", (event) => { sample = event.detail || {}; });
    function render() {
        const width = canvas.clientWidth || 1, height = canvas.clientHeight || 1;
        renderer.setSize(width, height, false); camera.aspect = width / height; camera.updateProjectionMatrix();
        const motors = sample.motors || [];
        rotors.forEach((rotor, index) => { rotor.rotation.y += .04 + Number((motors[index] || {}).speed_rad_s || 0) / 3000; rotor.material.color.set((motors[index] || {}).saturated ? 0xff4d8d : 0xffb020); });
        frame.rotation.y += .002; renderer.render(scene, camera); requestAnimationFrame(render);
    }
    render();
}
