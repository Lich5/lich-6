// Frontends uses existing contract 2.5 properties. Exercise the actual renderer
// and stylesheet without a live account or a dependency installation.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { JSDOM } = require('jsdom');

function fixture(t) {
  const assets = path.resolve(__dirname, '../../lib/webui/assets');
  const dom = new JSDOM(fs.readFileSync(path.join(assets, 'index.html'), 'utf8'), {
    url: 'http://127.0.0.1/', runScripts: 'outside-only'
  });
  dom.window.WebSocket = class {
    addEventListener() {}
    send() {}
  };
  const style = dom.window.document.createElement('style');
  style.textContent = fs.readFileSync(path.join(assets, 'app.css'), 'utf8');
  dom.window.document.head.append(style);
  dom.window.eval(fs.readFileSync(path.join(assets, 'app.js'), 'utf8'));
  t.after(() => dom.window.close());
  const page = { controls: new Map(), bindings: {}, submissions: {} };
  return { dom, render: component => dom.window.LichWebUI.render(page, component) };
}

test('frontend catalog remains scrollable at its declared maximum height', t => {
  const { dom, render } = fixture(t);
  const catalog = render({ type: 'table', cid: 'table:frontends-table', props: {
    max_height: 260, columns: [{ key: 'label', label: 'Frontend' }],
    rows: Array.from({ length: 40 }, (_, i) => ({ key: `frontend-${i}`, cells: { label: `Frontend ${i}` } }))
  } });
  dom.window.document.body.append(catalog);
  assert.equal(catalog.style.maxHeight, '260px');
  assert.equal(dom.window.getComputedStyle(catalog).overflow, 'auto');
  assert.equal(catalog.querySelectorAll('tbody tr').length, 40);
});

test('frontend field layout is scoped and does not change unrelated forms', t => {
  const { dom, render } = fixture(t);
  for (const [key, expected] of [['frontend-editor-section', 'grid'], ['unrelated-settings', 'flex']]) {
    const group = render({ type: 'group', cid: `group:${key}`, props: { label: 'Settings' }, children: [
      { type: 'text_input', cid: `input:${key}`, props: { label: 'Command', value: '' } }
    ] });
    dom.window.document.body.append(group);
    assert.equal(dom.window.getComputedStyle(group.querySelector('.field')).display, expected);
  }
});
