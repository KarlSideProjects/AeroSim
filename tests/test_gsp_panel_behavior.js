const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");

class Element {
    constructor(tagName) {
        this.tagName = tagName;
        this.children = [];
        this.listeners = {};
        this.dataset = {};
        this.textContent = "";
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
        if (this.listeners.click) this.listeners.click();
    }

    getContext() {
        return { clearRect() {}, beginPath() {}, moveTo() {}, lineTo() {}, stroke() {} };
    }
}

const elements = new Map();
for (const id of ["tuning-rows", "quick-adjust-rows", "connection", "fresh-state", "sparkline", "focus-state",
    "preset-name", "preset-note", "preset-source", "preset-target", "preset-save", "preset-refresh",
    "preset-retrieve", "preset-load", "preset-preview", "preset-compare-current", "preset-compare-two", "preset-status", "preset-diff", "migration-report"]) {
    elements.set(id, new Element(id === "sparkline" ? "canvas" : "div"));
}
elements.get("sparkline").width = 840;
elements.get("sparkline").height = 100;

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
const window = {
    location: { hash: "#port=8765&token=0123456789abcdef0123456789abcdef" },
    __AEROSIM_PANEL_TEST__: {},
    confirm: () => confirmResult,
    addEventListener() {},
};
const context = {
    window,
    document: {
        hidden: false,
        getElementById: (id) => elements.get(id),
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
    Date,
    performance: { now: () => 1 },
    setTimeout: () => 1,
    clearTimeout() {},
    console,
};

const html = fs.readFileSync("common/gsp/gsp_panel.html", "utf8");
const script = html.match(/<script>\n([\s\S]*?)\n<\/script>/)[1];
vm.runInNewContext(script, context, { filename: "gsp_panel.html" });

const profile = { slots: Array(8).fill(null) };
const registry = { parameters: [{ key: "simpleflight.rate_p", quick_adjust_eligible: true, min: 0.6, max: 1.4, step: 0.01 }] };
context.window.__AEROSIM_PANEL_TEST__.renderQuickAdjust(profile, registry);
const controls = context.window.__AEROSIM_PANEL_TEST__.quickAdjustControls();
assert.equal(controls.length, 8);
controls[0].parameter.value = "simpleflight.rate_p";
controls[0].apply.click();
assert.equal(controls[0].status.textContent, "Waiting for acknowledgement…");
assert.notEqual(controls[7].status.textContent, "Waiting for acknowledgement…");

FakeWebSocket.instance.listeners.message({ data: JSON.stringify({
    v: 2,
    t: "quick_adjust_ack",
    d: { request_seq: 1, ok: true },
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
