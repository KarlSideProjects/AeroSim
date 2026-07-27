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
        if (!this.disabled && this.listeners.click) this.listeners.click();
    }

    getContext() {
        return { clearRect() {}, beginPath() {}, moveTo() {}, lineTo() {}, stroke() {} };
    }
}

class FakeClock {
    constructor() {
        this.nowMs = 0;
        this.nextId = 1;
        this.timers = new Map();
    }

    setTimeout(callback, delay) {
        const id = this.nextId++;
        this.timers.set(id, { at: this.nowMs + delay, callback });
        return id;
    }

    clearTimeout(id) {
        this.timers.delete(id);
    }

    setInterval() {
        return this.setTimeout(() => {}, 1000000);
    }

    clearInterval(id) {
        this.clearTimeout(id);
    }

    advance(delay) {
        const target = this.nowMs + delay;
        while (true) {
            const due = [...this.timers.entries()]
                .filter(([, timer]) => timer.at <= target)
                .sort((a, b) => a[1].at - b[1].at)[0];
            if (!due) break;
            this.timers.delete(due[0]);
            this.nowMs = due[1].at;
            due[1].callback();
        }
        this.nowMs = target;
    }

    nextDelay() {
        const due = [...this.timers.values()].sort((a, b) => a.at - b.at)[0];
        return due ? due.at - this.nowMs : null;
    }
}

class FakeWebSocket {
    static instances = [];
    static OPEN = 1;
    static CONNECTING = 0;
    static CLOSED = 3;

    constructor(url) {
        this.url = url;
        this.readyState = FakeWebSocket.CONNECTING;
        this.listeners = {};
        this.sent = [];
        FakeWebSocket.instances.push(this);
    }

    addEventListener(type, callback) {
        this.listeners[type] = callback;
    }

    send(payload) {
        assert.equal(this.readyState, FakeWebSocket.OPEN);
        this.sent.push(JSON.parse(payload));
    }

    close() {
        this.readyState = FakeWebSocket.CLOSED;
    }

    emit(type, payload) {
        if (type === "open") this.readyState = FakeWebSocket.OPEN;
        if (type === "close") this.readyState = FakeWebSocket.CLOSED;
        if (this.listeners[type]) this.listeners[type](payload);
    }
}

const ids = [
    "tuning-rows", "quick-adjust-rows", "connection", "fresh-state", "sparkline", "focus-state",
    "preset-name", "preset-note", "preset-source", "preset-target", "preset-save", "preset-refresh",
    "preset-retrieve", "preset-load", "preset-preview", "preset-compare-current", "preset-compare-two",
    "preset-status", "preset-diff", "migration-report", "rate", "vehicle", "authority", "tick",
    "latency", "registry", "position", "velocity", "attitude", "rates", "motors",
];
const elements = new Map(ids.map((id) => [id, new Element(id === "sparkline" ? "canvas" : "div")]));
elements.get("sparkline").width = 840;
elements.get("sparkline").height = 100;
const clock = new FakeClock();
const window = {
    location: { hash: "#port=8765&token=0123456789abcdef0123456789abcdef" },
    __AEROSIM_PANEL_TEST__: {},
    confirm: () => false,
    addEventListener() {},
};
const context = {
    window,
    document: {
        hidden: false,
        listeners: {},
        getElementById: (id) => elements.get(id),
        createElement: (tagName) => new Element(tagName),
        addEventListener(type, callback) { this.listeners[type] = callback; },
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
    performance: { now: () => clock.nowMs },
    setTimeout: clock.setTimeout.bind(clock),
    clearTimeout: clock.clearTimeout.bind(clock),
    setInterval: clock.setInterval.bind(clock),
    clearInterval: clock.clearInterval.bind(clock),
    console,
};

const panelSource = fs.readFileSync("common/gsp/gsp_panel.html", "utf8");
assert.doesNotMatch(panelSource, /localStorage|sessionStorage|indexedDB|document\.cookie/);
const script = panelSource.match(/<script>\n([\s\S]*?)\n<\/script>/)[1];
vm.runInNewContext(script, context, { filename: "gsp_panel.html" });

function message(socket, value) {
    socket.emit("message", { data: JSON.stringify(value) });
}

function ready(socket) {
    socket.emit("open");
    message(socket, {
        v: 2,
        t: "hello",
        d: {
            registry: {
                parameters: [{ key: "simpleflight.rate_p", quick_adjust_eligible: true, min: 0.6, max: 1.4, step: 0.01 }],
                quick_adjust: { slots: Array(8).fill(null) },
                presets: [],
            },
        },
    });
    const request = socket.sent.find((item) => item.t === "request_snapshot");
    assert.ok(request);
    return request.seq;
}

function fresh(socket, requestSequence) {
    message(socket, { v: 2, t: "telemetry", seq: 4, tick: 12, d: {
        fresh: true, request_seq: requestSequence, sample_seq: 1, vehicle_instance: "Drone1",
    } });
}

const first = FakeWebSocket.instances[0];
assert.deepEqual(FakeWebSocket.instances.map((socket) => socket.url), ["ws://127.0.0.1:8765"]);
assert.equal(elements.get("preset-save").disabled, true);
const firstRequest = ready(first);
const controlsBeforeSnapshot = window.__AEROSIM_PANEL_TEST__.quickAdjustControls();
assert.equal(controlsBeforeSnapshot.length, 8);
assert.equal(controlsBeforeSnapshot[0].apply.disabled, true);
assert.equal(elements.get("preset-save").disabled, true);
fresh(first, firstRequest);
assert.equal(controlsBeforeSnapshot[0].apply.disabled, false);
assert.equal(elements.get("preset-save").disabled, false);
let groupApply = elements.get("tuning-rows").children[0].children[1];
assert.equal(groupApply.disabled, false);

context.document.hidden = true;
first.emit("close");
assert.equal(elements.get("preset-save").disabled, true);
assert.equal(groupApply.disabled, true);
assert.equal(clock.nextDelay(), 250);
clock.advance(249);
assert.equal(FakeWebSocket.instances.length, 1);
clock.advance(1);
assert.equal(FakeWebSocket.instances.length, 2);

const hiddenSocket = FakeWebSocket.instances.at(-1);
const hiddenRequest = ready(hiddenSocket);
groupApply = elements.get("tuning-rows").children.at(-1).children[1];
const hiddenRates = hiddenSocket.sent.filter((item) => item.t === "set_telemetry");
assert.equal(hiddenRates.at(-1).d.hz, 0);
assert.equal(hiddenSocket.sent.filter((item) => item.t === "request_snapshot").at(-1).seq, hiddenRequest);
assert.equal(elements.get("preset-save").disabled, true);
assert.equal(groupApply.disabled, true);

context.document.hidden = false;
context.document.listeners.visibilitychange();
const restoredRequest = hiddenSocket.sent.filter((item) => item.t === "request_snapshot").at(-1).seq;
assert.equal(hiddenSocket.sent.filter((item) => item.t === "set_telemetry").at(-1).d.hz, 30);
assert.equal(elements.get("preset-save").disabled, true);
assert.equal(groupApply.disabled, true);
fresh(hiddenSocket, restoredRequest);
assert.equal(elements.get("preset-save").disabled, false);
assert.equal(groupApply.disabled, false);
hiddenSocket.emit("close");
assert.equal(clock.nextDelay(), 250);
clock.advance(250);

const delays = [];
for (const expected of [500, 1000, 2000, 4000, 5000]) {
    const socket = FakeWebSocket.instances.at(-1);
    socket.emit("close");
    assert.equal(clock.nextDelay(), expected);
    delays.push(clock.nextDelay());
    clock.advance(expected);
}
assert.deepEqual(delays, [500, 1000, 2000, 4000, 5000]);
assert.ok(FakeWebSocket.instances.every((socket) => socket.url === "ws://127.0.0.1:8765"));

const notReady = FakeWebSocket.instances.at(-1);
const notReadyRequest = ready(notReady);
notReady.emit("close");
assert.equal(clock.nextDelay(), 5000);
clock.advance(5000);
const staleSocket = notReady;
const replacement = FakeWebSocket.instances.at(-1);
const replacementRequest = ready(replacement);
fresh(staleSocket, notReadyRequest);
assert.equal(elements.get("preset-save").disabled, true);
fresh(replacement, replacementRequest);
assert.equal(elements.get("preset-save").disabled, false);

replacement.emit("close");
assert.equal(clock.nextDelay(), 250);
console.log("GSP panel recovery behavior passed");
