const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");

class Element {
    constructor(tagName) {
        this.tagName = tagName;
        this.children = [];
        this.listeners = {};
        this.disabled = false;
        this.dataset = {};
        this._textContent = "";
        Object.defineProperty(this, "textContent", {
            get: () => this._textContent,
            set: (value) => {
                this._textContent = String(value);
                if (this._textContent === "") this.children = [];
            },
        });
        this.value = "";
    }

    appendChild(child) {
        this.children.push(child);
        return child;
    }

    addEventListener(type, callback) {
        this.listeners[type] = callback;
    }

    click() {
        if (!this.disabled && this.listeners.click) this.listeners.click();
    }

    getContext() {
        return { clearRect() {}, beginPath() {}, moveTo() {}, lineTo() {}, stroke() {} };
    }
}

const elements = new Map();
for (const id of ["tuning-rows", "quick-adjust-rows", "connection", "fresh-state", "sparkline", "focus-state",
    "rate", "vehicle", "authority", "tick", "latency", "registry", "position", "velocity", "attitude", "rates", "motors",
    "mode-armed", "config-hash", "endurance", "flight-diagnostics", "hardware-configuration", "hardware-derived", "telemetry-data",
    "visualization-status", "flow-legend", "motor-rear-right", "motor-front-right", "motor-rear-left", "motor-front-left",
    "geometry-classification", "geometry-identity", "geometry-scale", "geometry-motors", "geometry-provenance",
    "preset-name", "preset-note", "preset-source", "preset-target", "preset-save", "preset-refresh",
    "preset-retrieve", "preset-load", "preset-preview", "preset-compare-current", "preset-compare-two", "preset-status", "preset-diff", "migration-report",
    "wind-from", "wind-speed", "wind-preview", "wind-apply", "wind-status", "source-commanded", "source-truth", "source-estimated", "source-measured",
    "live-connection", "live-authority", "live-mode", "live-fresh", "live-vehicle", "live-tick", "live-failure", "live-m1", "live-m2", "live-m3", "live-m4", "command-chart", "rpm-chart", "language-zh", "language-en"]) {
    elements.set(id, new Element(["sparkline", "command-chart", "rpm-chart"].includes(id) ? "canvas" : "div"));
}
elements.get("sparkline").width = 840;
elements.get("sparkline").height = 100;
elements.get("wind-status").dataset.i18n = "preview_initial";
elements.get("wind-status").textContent = "Preview only; no physical mutation.";
elements.get("wind-preview").dataset.i18n = "preview";
elements.get("wind-preview").textContent = "Preview";
const i18nNodes = [elements.get("wind-status"), elements.get("wind-preview")];

class FakeWebSocket {
    static instance;

    constructor() {
        this.readyState = FakeWebSocket.OPEN;
        this.listeners = {};
        this.sent = [];
        FakeWebSocket.instance = this;
    }

    addEventListener(type, callback) {
        this.listeners[type] = callback;
    }

    send(payload) {
        this.sent.push(JSON.parse(payload));
    }
    close() {}
}
FakeWebSocket.OPEN = 1;

let confirmResult = false;
let perfNow = 1;
let rafCallbacks = [];
const window = {
    location: { hash: "#port=8765&token=0123456789abcdef0123456789abcdef" },
    __AEROSIM_PANEL_TEST__: {},
    confirm: () => confirmResult,
    addEventListener() {},
    requestAnimationFrame: (callback) => { rafCallbacks.push(callback); return rafCallbacks.length; },
};
const context = {
    window,
    document: {
        hidden: false,
        documentElement: {},
        getElementById: (id) => elements.get(id),
        querySelectorAll: (selector) => selector === "[data-i18n]" ? i18nNodes : [],
        createElement: (tagName) => new Element(tagName),
        addEventListener() {},
    },
    Option: class extends Element {
        constructor(text, value) {
            super("option");
            this.textContent = text;
            this.value = value;
        }
    },
    WebSocket: FakeWebSocket,
    URLSearchParams,
    JSON,
    Number,
    Math,
    Array,
    Object,
    String,
    Boolean,
    Date: { now: () => wallClockMs },
    performance: { now: () => perfNow },
    setTimeout: () => 1,
    clearTimeout() {},
    setInterval: () => 1,
    clearInterval() {},
    console,
};

// The geometry package and the visual bridge are bundled beside the panel, so
// load them into the same context. Without a canvas the visual layer stops at
// its telemetry mapping, which is exactly the surface the panel reads.
for (const asset of ["gsp_drone_geometry.js", "gsp_visual.js"]) {
    vm.runInNewContext(fs.readFileSync(`common/gsp/assets/${asset}`, "utf8"), context, { filename: asset });
}

const html = fs.readFileSync("common/gsp/gsp_panel.html", "utf8");
assert.match(html, /<label><span data-i18n="from">FROM°<\/span><input id="wind-from"/,
    "language changes must translate the wind label without replacing its input");
assert.doesNotMatch(html, /geometry: "[^"]*<b>/,
    "text-only translations must not render markup literally");
const script = html.match(/<script>\n([\s\S]*?)\n<\/script>/)[1];
vm.runInNewContext(script, context, { filename: "gsp_panel.html" });

assert.equal(elements.get("wind-status").textContent, "僅預覽；不會變更物理狀態。");
assert.equal(elements.get("wind-preview").textContent, "預覽");
assert.equal(context.document.documentElement.lang, "zh-Hant");
elements.get("language-en").click();
assert.equal(elements.get("wind-status").textContent, "Preview only; no physical mutation.");
assert.equal(elements.get("wind-preview").textContent, "Preview");
assert.equal(context.document.documentElement.lang, "en");
elements.get("language-zh").click();
const hardwareConfiguration = JSON.parse(fs.readFileSync("config/drones/5_inch_6s.json", "utf8"));

FakeWebSocket.instance.listeners.message({ data: JSON.stringify({
    v: 2,
    t: "hello",
    d: { registry: { parameters: [{ key: "simpleflight.rate_p", quick_adjust_eligible: true, min: 0.6, max: 1.4, step: 0.01 }], quick_adjust: { slots: [] }, presets: [] } },
}) });
const freshRequest = FakeWebSocket.instance.sent.find((item) => item.t === "request_snapshot");
FakeWebSocket.instance.listeners.message({ data: JSON.stringify({
    v: 2,
    t: "telemetry",
    tick: 1,
    d: { fresh: true, request_seq: freshRequest.seq, sample_seq: 1, config_hash: "config-fixture", authority: "flight_controller", armed: true,
        hardware_configuration: hardwareConfiguration,
        hardware_power_model: { hover_endurance_minutes: 4.2, max_total_thrust_newtons: 40, max_total_current_a: 40, max_motor_rpm: 15000 },
        px4_mavlink: { hil_actuator_controls: { source: "px4_mavlink", age_seconds: 0.02, stale: false, sample: { mapping_verified: true, command_normalized: { m1: 0.1, m2: 0.2, m3: 0.3, m4: 0.4 } } } },
        motor_order: ["rear_right", "front_right", "rear_left", "front_left"], rpm: [955, 1910, 2865, 3820],
        motors: [
            { thrust_newtons: 2, current_a: 1, saturated: false }, { thrust_newtons: 8.5, current_a: 1, saturated: false },
            { thrust_newtons: 9.8, current_a: 1, saturated: false }, { thrust_newtons: 1, current_a: 1, saturated: true },
        ],
        wind_world_mps: null, a3_operating_state: "disabled", a6_operating_state: "out_of_domain" },
}) });
assert.match(elements.get("telemetry-data").textContent, /a6_operating_state = out_of_domain/);
assert.match(elements.get("telemetry-data").textContent, /wind_world_mps = 未提供／模型未啟用/);
assert.match(elements.get("hardware-configuration").textContent, /battery.capacity_mah = 1300/);
assert.match(elements.get("hardware-derived").textContent, /derived.hover_endurance_minutes = 4.2/);
assert.equal(elements.get("config-hash").textContent, "config-fixture");
assert.equal(elements.get("motor-rear-right").dataset.motor, "rear_right");
assert.match(elements.get("motor-rear-right").textContent, /M1[\s\S]*955[\s\S]*2\.00[\s\S]*1\.00/);
assert.match(elements.get("motor-rear-left").textContent, /嚴重/);
assert.match(elements.get("flow-legend").textContent, /FRD.*m\/s/);
assert.match(elements.get("source-commanded").textContent, /命令.*PX4 MAVLink.*新鮮/);
assert.match(elements.get("source-truth").textContent, /地面真值/);
assert.match(elements.get("live-m1").textContent, /955 轉\/分.*2\.00 N.*1\.00 A.*cw.*位置 未提供/);
assert.match(elements.get("live-m1").textContent, /0\.10 命令/);
FakeWebSocket.instance.listeners.message({ data: JSON.stringify({
    v: 2,
    t: "telemetry",
    tick: 2,
    d: { sample_seq: 2, authority: "flight_controller", armed: true, hardware_configuration: hardwareConfiguration, rpm: [955, 1910, 2865, 3820], motors: [] },
}) });
assert.equal(elements.get("wind-apply").disabled, false,
    "regular telemetry after an accepted fresh snapshot keeps wind control safe to use");
elements.get("wind-from").value = "90"; elements.get("wind-speed").value = "3"; elements.get("wind-apply").click();
const windRequest = FakeWebSocket.instance.sent.at(-1);
assert.equal(windRequest.t, "set_wind"); assert.equal(elements.get("wind-apply").disabled, true);
FakeWebSocket.instance.listeners.message({ data: JSON.stringify({ v: 2, t: "wind_ack", d: { request_seq: windRequest.seq, ok: false, error: "unsafe" } }) });
assert.match(elements.get("wind-status").textContent, /風場被拒絕.*unsafe/); assert.equal(elements.get("wind-apply").disabled, false);

// Geometry stays inspectable: classification, scale, M1-M4 mapping, provenance.
assert.equal(elements.get("geometry-classification").dataset.classification, "nominal");
assert.equal(elements.get("geometry-classification").textContent, "名義幾何");
assert.match(elements.get("geometry-identity").textContent, /5-inch 6S Quad-X freestyle · quad_x_5_inch_freestyle/);
assert.match(elements.get("geometry-scale").textContent, /wheelbase 225\.0 mm/);
assert.match(elements.get("geometry-scale").textContent, /prop ⌀127\.0 mm × 4\.3" pitch × 3/);
assert.match(elements.get("geometry-scale").textContent, /wheelbase 225\.0 mm \(layout 318\.2 mm\)/);
assert.match(elements.get("geometry-provenance").textContent, /warnings = wheelbase_disagrees_with_motor_layout/);
const mapping = elements.get("geometry-motors").textContent.split("\n");
assert.equal(mapping.length, 4);
assert.match(mapping[0], /^M1 · 右後 · 順時針 · FRD \(-0\.1125, 0\.1125, 0\.0000\) m/);
assert.match(mapping[1], /^M2 · 右前 · 逆時針 · FRD \(0\.1125, 0\.1125, 0\.0000\) m/);
assert.match(mapping[2], /^M3 · 左後 · 逆時針/);
assert.match(mapping[3], /^M4 · 左前 · 順時針/);
assert.match(elements.get("geometry-provenance").textContent, /redistribution = release/);
assert.match(elements.get("geometry-provenance").textContent, /license = MIT · AeroSim contributors/);
assert.match(elements.get("geometry-provenance").textContent, /nominal_because = unqualified_dimensional_evidence, missing_dimensional_evidence_document/);
assert.match(elements.get("geometry-provenance").textContent, /asset = common\/gsp\/assets\/gsp_drone_geometry\.js sha256:[0-9a-f]{64}/);
const pingRequest = FakeWebSocket.instance.sent.find((item) => item.t === "ping");
perfNow = 3;
FakeWebSocket.instance.listeners.message({ data: JSON.stringify({
    v: 2,
    t: "pong",
    d: { echo: pingRequest.d, server_receive_usec: 2000, server_send_usec: 2000 },
}) });

const tuning = context.window.__AEROSIM_PANEL_TEST__.tuningControls()["simpleflight.rate_p"];
tuning.number.value = "1.0";
tuning.button.click();
const tuningRequest = FakeWebSocket.instance.sent.at(-1);
assert.equal(tuningRequest.d.client_sent_at_perf_ms, 3);
FakeWebSocket.instance.listeners.message({ data: JSON.stringify({
    v: 2,
    t: "tuning_ack",
    d: { request_seq: tuningRequest.seq, ok: true, commit_id: 1, committed_value: 1.0, native_commit_monotonic_usec: 13000 },
}) });
assert.equal(rafCallbacks.length, 1);
rafCallbacks.shift()(5);
assert.equal(rafCallbacks.length, 1);
rafCallbacks.shift()(23);
const timing = context.window.__AEROSIM_GSP_PERF__.snapshot();
assert.equal(timing.request_to_native_commit_ms.length, 1);
assert.equal(timing.native_commit_to_rendered_ack_ms.length, 1);
assert.equal(timing.request_to_native_commit_ms[0], 10);
assert.equal(timing.native_commit_to_rendered_ack_ms[0], 10);
assert.equal(timing.clock_sync.samples, 1);
assert.equal(timing.clock_sync.best_rtt_ms, 2);
assert.equal(timing.request_to_commit_ms, undefined);
assert.equal(timing.commit_to_rendered_ack_ms, undefined);

const profile = { slots: Array(8).fill(null) };
const registry = { parameters: [{ key: "simpleflight.rate_p", quick_adjust_eligible: true, min: 0.6, max: 1.4, step: 0.01 }] };
context.window.__AEROSIM_PANEL_TEST__.renderQuickAdjust(profile, registry);
const controls = context.window.__AEROSIM_PANEL_TEST__.quickAdjustControls();
assert.equal(controls.length, 8);
controls[0].parameter.value = "simpleflight.rate_p";
controls[0].apply.click();
const quickRequest = FakeWebSocket.instance.sent.at(-1);
assert.equal(controls[0].status.textContent, "Waiting for acknowledgement…");
assert.notEqual(controls[7].status.textContent, "Waiting for acknowledgement…");

FakeWebSocket.instance.listeners.message({ data: JSON.stringify({
    v: 2,
    t: "quick_adjust_ack",
    d: { request_seq: quickRequest.seq, ok: true },
}) });
assert.equal(controls[0].status.textContent, "Saved");
assert.notEqual(controls[7].status.textContent, "Saved");

const socket = FakeWebSocket.instance;
elements.get("preset-name").value = "race_01";
elements.get("preset-note").value = "panel note";
elements.get("preset-save").click();
const saveRequest = socket.sent.at(-1);
assert.equal(saveRequest.t, "save_preset");
assert.deepEqual(saveRequest.d, { name: "race_01", note: "panel note" });
socket.listeners.message({ data: JSON.stringify({
    v: 2,
    t: "preset_ack",
    d: { request_seq: saveRequest.seq, ok: true, presets: [{ name: "race_01", sim_version: "test", created_at: "now" }] },
}) });
assert.equal(elements.get("preset-source").children.length, 2);
elements.get("preset-source").value = "race_01";

elements.get("preset-retrieve").click();
const retrieveRequest = socket.sent.at(-1);
assert.equal(retrieveRequest.t, "retrieve_preset");
assert.deepEqual(retrieveRequest.d, { name: "race_01" });
socket.listeners.message({ data: JSON.stringify({
    v: 2,
    t: "preset_ack",
    d: { request_seq: retrieveRequest.seq, ok: true, preset: { name: "race_01", note: "panel note" } },
}) });
assert.match(elements.get("preset-status").textContent, /panel note/);

elements.get("preset-preview").click();
const previewRequest = socket.sent.at(-1);
assert.equal(previewRequest.t, "preview_preset_migration");
assert.deepEqual(previewRequest.d, { name: "race_01" });
socket.listeners.message({ data: JSON.stringify({
    v: 2,
    t: "preset_ack",
    d: {
        request_seq: previewRequest.seq,
        ok: true,
        operation: "preview_preset_migration",
        preset_name: "race_01",
        migration_id: "opaque-migration-id",
        removed: [{ parameter: "old", value: 9 }],
        missing: [{ parameter: "new", default_value: 3 }],
        out_of_range: [{ parameter: "simpleflight.rate_p", original_value: 99, corrected_value: 1.4 }],
    },
}) });
assert.match(elements.get("migration-report").textContent, /old/);
assert.match(elements.get("migration-report").textContent, /new/);
assert.match(elements.get("migration-report").textContent, /99.*1\.4/);
assert.equal(socket.sent.at(-1), previewRequest);
confirmResult = true;
elements.get("preset-preview").click();
const confirmedPreviewRequest = socket.sent.at(-1);
socket.listeners.message({ data: JSON.stringify({
    v: 2,
    t: "preset_ack",
    d: {
        request_seq: confirmedPreviewRequest.seq,
        ok: true,
        operation: "preview_preset_migration",
        preset_name: "race_01",
        migration_id: "opaque-migration-id-2",
        removed: [],
        missing: [],
        out_of_range: [],
    },
}) });
const applyRequest = socket.sent.at(-1);
assert.equal(applyRequest.t, "apply_preset_migration");
assert.deepEqual(applyRequest.d, { name: "race_01", migration_id: "opaque-migration-id-2", confirmed: true });

elements.get("preset-compare-current").click();
const compareRequest = socket.sent.at(-1);
assert.equal(compareRequest.t, "compare_presets");
assert.deepEqual(compareRequest.d, { left: "", right: "race_01" });
socket.listeners.message({ data: JSON.stringify({
    v: 2,
    t: "preset_ack",
    d: {
        request_seq: compareRequest.seq,
        ok: true,
        changes: [
            { parameter: "simpleflight.rate_p", before: 1, after: 2, percentage: 100, percentage_status: "finite" },
            { parameter: "simpleflight.rate_i", before: 0, after: 1, percentage: null, percentage_status: "zero_baseline" },
        ],
    },
}) });
assert.match(elements.get("preset-diff").textContent, /simpleflight\.rate_p/);
assert.match(elements.get("preset-diff").textContent, /zero_baseline/);
assert.doesNotMatch(elements.get("preset-diff").textContent, /unchanged/);

elements.get("preset-target").value = "race_01";
elements.get("preset-compare-two").click();
const compareTwoRequest = socket.sent.at(-1);
assert.equal(compareTwoRequest.t, "compare_presets");
assert.deepEqual(compareTwoRequest.d, { left: "race_01", right: "race_01" });
socket.listeners.message({ data: JSON.stringify({
    v: 2,
    t: "preset_ack",
    d: { request_seq: compareTwoRequest.seq, ok: true, changes: [] },
}) });
assert.equal(elements.get("preset-diff").textContent, "No changes.");

elements.get("preset-load").click();
const loadRequest = socket.sent.at(-1);
assert.equal(loadRequest.t, "load_preset");
assert.deepEqual(loadRequest.d, { name: "race_01" });
socket.listeners.message({ data: JSON.stringify({
    v: 2,
    t: "tuning_ack",
    d: { request_seq: loadRequest.seq, ok: true },
}) });
assert.equal(elements.get("preset-status").textContent, "Preset load committed.");
console.log("GSP panel row behavior passed");
