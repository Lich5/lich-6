const { test } = require('node:test');
const assert = require('node:assert/strict');
const { JSDOM } = require('jsdom');
const fs = require('node:fs');
const path = require('node:path');

function fixture() {
  const dom = new JSDOM('<div id="status"></div><div id="pages"></div><div id="notifications"></div><div id="announcer"></div>',
    { url: 'http://127.0.0.1/', runScripts: 'outside-only' });
  const frames = [], sent = [], widths = new Map(), observers = [];
  let listener;
  dom.window.requestAnimationFrame = callback => frames.push(callback);
  dom.window.ResizeObserver = class {
    constructor(callback) { this.callback = callback; observers.push(this); }
    observe() {}
    disconnect() { this.disconnected = true; }
  };
  dom.window.HTMLElement.prototype.getBoundingClientRect = function () {
    return { width: widths.get(this.dataset.cid) || 0, height: 20, top: 0, left: 0 };
  };
  dom.window.WebSocket = class {
    static OPEN = 1;
    readyState = 1;
    addEventListener(name, callback) { if (name === 'message') listener = callback; }
    send(value) { sent.push(JSON.parse(value)); }
  };
  dom.window.eval(fs.readFileSync(path.join(__dirname, '../../lib/webui/assets/app.js'), 'utf8'));
  return { dom, widths, sent, observers,
    receive: value => listener({ data: JSON.stringify(value) }),
    frame: () => frames.splice(0).forEach(callback => callback()),
    element: cid => dom.window.document.querySelector(`[data-cid="${cid}"]`) };
}


test('table fills apply only to enabled cells and update without interpreting source markup', t => {
  const f = fixture(); t.after(() => f.dom.window.close());
  f.receive({ type: 'hello', pages: [{ address: 'colors' }] });
  function render(generation, color) {
    f.receive({ type: 'render', page: 'colors', generation, tree: { type: 'page', cid: 'root', props: { title: 'Cells' }, children: [{
      type: 'table', cid: 'table', props: { columns: [{ key: 'text', label: 'Name', ...(color ? { background: color } : {}) }], rows: [
        { key: 'painted', cells: { text: '<b>Literal</b>' } },
        { key: 'plain', cells: { text: 'Plain' }, background_disabled: ['text'] }
      ] }
    }] } });
  }
  render(1, { r: 255, g: 255, b: 255, a: 1 });
  let cells = f.element('table').querySelectorAll('tbody td');
  assert.equal(cells[0].style.backgroundColor, 'rgb(255, 255, 255)');
  assert.equal(cells[1].style.backgroundColor, '');
  assert.equal(cells[0].textContent, '<b>Literal</b>');
  assert.equal(cells[0].querySelector('b'), null);
  render(2, null);
  cells = f.element('table').querySelectorAll('tbody td');
  assert.equal(cells[0].style.backgroundColor, '');
});

test('switch uses a keyboard-accessible boolean input, preserves state, and sends change events', t => {
  const f = fixture(); t.after(() => f.dom.window.close());
  f.receive({ type: 'hello', pages: [{ address: 'switch' }] });
  function render(generation, checked, disabled = false) {
    f.receive({ type: 'render', page: 'switch', generation, bindings: { dark: ['change'] }, tree: {
      type: 'page', cid: 'root', props: { title: 'Switch' }, children: [{ type: 'toggle', cid: 'dark', props: {
        label: 'Dark mode', appearance: 'switch', checked, disabled
      } }]
    } });
  }
  render(1, false);
  let input = f.element('dark').querySelector('input');
  assert.equal(input.type, 'checkbox');
  assert.equal(input.getAttribute('role'), 'switch');
  assert.equal(input.getAttribute('aria-label'), 'Dark mode');
  assert.equal(f.element('dark').querySelector('.webui-switch-track').getAttribute('aria-hidden'), 'true');
  input.click();
  assert.equal(input.checked, true);
  assert.deepEqual(f.sent.at(-1).payload, { value: true });
  assert.equal(f.sent.at(-1).event, 'change');
  render(2, true, true);
  input = f.element('dark').querySelector('input');
  const before = f.sent.length;
  input.click();
  assert.equal(input.disabled, true);
  assert.equal(input.checked, true);
  assert.equal(f.sent.length, before);
});
