// Shared dependency-free DOM/socket fixture for the shipped renderer.
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

function fixture(target) {
  class Element {
    constructor(tag) {
      if (['button', 'input', 'select', 'textarea'].includes(tag)) this.disabled = false;
      this.tagName = tag; this.children = []; this.dataset = {}; this.style = { setProperty(name, value) { this[name] = value; } };
      this.classList = { add() {}, toggle() {} }; this.listeners = {}; this.isConnected = true; this.attributes = {};
      this.clientWidth = 340; this.clientHeight = 144; this.scrollWidth = 340; this.scrollHeight = 144;
    }
    append(...children) { children.forEach(child => { child.parent = this; this.children.push(child); }); }
    replaceChildren(...children) { this.children.forEach(child => { child.isConnected = false; }); this.children = []; this.append(...children); }
    focus() { document.activeElement = this; }
    closest() { return null; }
    click() { this.listeners.click?.({}); }
    getClientRects() { return this.hidden ? [] : [this.getBoundingClientRect()]; }
    querySelector(selector) {
      const cid = selector.match(/^\[data-cid="(.*)"\]$/)?.[1];
      for (const child of this.children) {
        if (child.dataset.cid === cid) return child;
        const nested = child.querySelector?.(selector);
        if (nested) return nested;
      }
      return null;
    }
    setAttribute(name, value) { this.attributes[name] = value; }
    setPointerCapture() {}
    getBoundingClientRect() { return { left: 0, top: 0, width: this.clientWidth, height: this.clientHeight }; }
    addEventListener(name, callback) { this.listeners[name] = callback; }
    remove() { if (this.parent) this.parent.children = this.parent.children.filter(child => child !== this); }
    replaceWith(next) { const parent = this.parent; if (parent) { this.remove(); parent.append(next); } }
    showModal() { this.open = true; }
  }
  const elements = Object.fromEntries(['pages', 'status', 'notifications', 'announcer'].map(id => [id, new Element('div')]));
  const documentEvents = {};
  const document = { title: '', activeElement: null, createElement: tag => new Element(tag),
    getElementById: id => elements[id], addEventListener(name, callback) { documentEvents[name] = callback; } };
  const sent = [], resized = [], listeners = {}, windowEvents = {};
  let timer = 0;
  const frames = [];
  class WebSocket {
    static OPEN = 1;
    readyState = 1;
    addEventListener(name, callback) { listeners[name] = callback; }
    send(raw) { sent.push(JSON.parse(raw)); }
  }
  const window = { location: { protocol: 'http:', host: '127.0.0.1', search: target === null ? '' : `?page=${target}` },
    innerWidth: 800, innerHeight: 600, outerWidth: 800, outerHeight: 630, screenX: 0, screenY: 0,
    requestAnimationFrame: work => frames.push(work), resizeTo: (...size) => resized.push(size), setTimeout: () => ++timer, clearTimeout() {},
    setInterval: () => ++timer, clearInterval() {},
    addEventListener: (name, callback) => { windowEvents[name] = callback; },
    removeEventListener: name => { delete windowEvents[name]; } };
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../../lib/webui/assets/app.js'), 'utf8'),
    { window, document, WebSocket, URLSearchParams, CSS: { escape: value => value }, queueMicrotask: work => work() });
  return { document, documentEvents, elements, sent, resized, windowEvents, window,
    frame: () => { frames.splice(0).forEach(work => work()); },
    receive: message => listeners.message({ data: JSON.stringify(message) }) };
}

module.exports = { fixture };
