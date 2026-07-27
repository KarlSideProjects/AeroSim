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
        this.listeners.click();
    }

    getContext() {
        return { clearRect() {}, beginPath() {}, moveTo() {}, lineTo() {}, stroke() {} };
    }
}

const elements = new Map();
for (const id of ["tuning-rows", "quick-adjust-rows", "connection", "fresh-state", "sparkline", "focus-state"]) {
    elements.set(id, new Element(id === "sparkline" ? "canvas" : "div"));
}
elements.get("sparkline").width = 840;
elements.get("sparkline").height = 100;

class FakeWebSocket {
    static instance;

    constructor() {
        this.readyState = FakeWebSocket.OPEN;
        this.listeners = {};
        FakeWebSocket.instance = this;
    }

    addEventListener(type, callback) {
        this.listeners[type] = callback;
    }

    send() {}
    close() {}
}
FakeWebSocket.OPEN = 1;

const window = {
    location: { hash: "#port=8765&token=0123456789abcdef0123456789abcdef" },
    __AEROSIM_PANEL_TEST__: {},
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
console.log("GSP panel row behavior passed");
