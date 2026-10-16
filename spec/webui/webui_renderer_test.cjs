// DOM unit checks, independent of a browser or live account. Install the locked
// test dependencies with npm ci --prefix spec/webui; see spec/README.md.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { JSDOM } = require('jsdom');

function fixture() {
  const root = path.resolve(__dirname, '../../lib/webui/assets');
  const dom = new JSDOM(fs.readFileSync(path.join(root, 'index.html'), 'utf8'), {
    url: 'http://127.0.0.1/', runScripts: 'outside-only', pretendToBeVisual: true
  });
  const sent = [];
  const listeners = {};
  dom.window.WebSocket = class {
    static OPEN = 1;
    readyState = 1;
    addEventListener(name, callback) { listeners[name] = callback; }
    send(json) { sent.push(JSON.parse(json)); }
  };
  dom.window.eval(fs.readFileSync(path.join(root, 'app.js'), 'utf8'));
  return { dom, sent, page: { controls: new Map(), bindings: {}, submissions: {} },
    receive: message => listeners.message({ data: JSON.stringify(message) }) };
}

test('native minimize measurements are deduplicated and listeners retire on close', t => {
  const { dom, receive, sent } = fixture(); t.after(() => dom.window.close());
  const bridge = { minimized: false, present() {} };
  dom.window.lichNativeWindow = bridge;
  receive({ type: 'hello', pages: [{ address: 'state' }] });
  receive({ type: 'render', page: 'state', generation: 1, bindings: { root: ['window_state'] }, tree: {
    type: 'page', cid: 'root', props: {}, children: [{ type: 'text', cid: 'die', props: { content: '\u2680', font_size: 70.3125, font_unit: 'pt' } }]
  } });
  assert.equal(dom.window.document.querySelector('[data-cid="die"]').style.fontSize, '70.3125pt');
  for (const minimized of [true, true, false]) {
    bridge.minimized = minimized;
    dom.window.dispatchEvent(new dom.window.Event('lich-window-state'));
  }
  assert.deepEqual(sent.filter(message => message.event === 'window_state').map(message => message.payload.minimized), [false, true, false]);
  receive({ type: 'page_closed', page: 'state' });
  const count = sent.length;
  bridge.minimized = true;
  dom.window.dispatchEvent(new dom.window.Event('lich-window-state'));
  assert.equal(sent.length, count);
});

test('positioned children measure natural bounds and stack pointer surfaces retain events', t => {
  const { dom, receive, sent } = fixture(); t.after(() => dom.window.close());
  const frames = [];
  dom.window.requestAnimationFrame = callback => frames.push(callback);
  receive({ type: 'hello', pages: [{ address: 'fixed' }] });
  receive({ type: 'render', page: 'fixed', generation: 1, bindings: { surface: ['pointer_press'] }, tree: {
    type: 'page', cid: 'root', props: {}, children: [{ type: 'overlay', cid: 'fixed', props: { positioned: true }, children: [
      { type: 'stack', cid: 'surface', placement: { x: 120, y: 40 }, props: { pointer_events: true, orientation: 'vertical', gap: 0 }, children: [
        { type: 'text', cid: 'label', props: { content: 'Click' } }
      ] }
    ] }]
  } });
  const surface = dom.window.document.querySelector('[data-cid="surface"]');
  const fixed = dom.window.document.querySelector('[data-cid="fixed"]');
  Object.defineProperties(surface, { offsetWidth: { value: 80 }, offsetHeight: { value: 20 } });
  frames.splice(0).forEach(callback => callback());
  assert.equal(surface.style.position, 'absolute');
  assert.equal(surface.style.left, '120px');
  assert.equal(fixed.style.minWidth, '200px');
  assert.equal(fixed.style.minHeight, '60px');
  surface.firstChild.dispatchEvent(new dom.window.MouseEvent('pointerdown', { bubbles: true, button: 0, clientX: 121, clientY: 42 }));
  const events = sent.filter(message => message.event === 'pointer_press');
  assert.equal(events.length, 1);
  assert.equal(events[0].cid, 'surface');
  assert.equal(events[0].payload.button, 1);
});

test('revisioned focus survives initial publication and does not steal focus on refresh', t => {
  const { dom, receive } = fixture(); t.after(() => dom.window.close());
  dom.window.CSS = { escape: value => value };
  receive({ type: 'hello', pages: [{ address: 'focus' }] });
  const render = (generation, revision) => receive({ type: 'render', page: 'focus', generation,
    facilities: { focus: 'first', focus_revision: revision }, tree: {
      type: 'page', cid: 'root', props: {}, children: [
        { type: 'text_input', cid: 'first', props: { value: 'First' } },
        { type: 'text_input', cid: 'second', props: { value: 'Second' } }
      ]
    } });
  const input = cid => dom.window.document.querySelector(`[data-cid="${cid}"] input`);
  render(1, 1);
  assert.equal(dom.window.document.activeElement, input('first'));
  input('second').focus();
  render(2, 1);
  assert.equal(dom.window.document.activeElement, input('second'));
  render(3, 2);
  assert.equal(dom.window.document.activeElement, input('first'));
});

test('bounded font properties style actual button and entry controls', t => {
  const { dom, receive } = fixture(); t.after(() => dom.window.close());
  receive({ type: 'hello', pages: [{ address: 'fonts' }] });
  receive({ type: 'render', page: 'fonts', generation: 1, tree: {
    type: 'page', cid: 'root', props: {}, children: [
      { type: 'button', cid: 'button', props: { label: 'Roll', font_family: 'monospace', font_size: 10, font_unit: 'pt' } },
      { type: 'text_input', cid: 'entry', props: { value: 'Score', read_only: true, has_frame: false, font_family: 'serif', font_size: 12, font_unit: 'pt' } },
      { type: 'text', cid: 'limited', props: { content: 'Several\nlines\nof text', line_limit: 2 } }
    ]
  } });
  const button = dom.window.document.querySelector('button[data-cid="button"]');
  const entry = dom.window.document.querySelector('[data-cid="entry"] input');
  assert.equal(button.style.fontFamily, 'monospace');
  assert.equal(button.style.fontSize, '10pt');
  assert.equal(entry.style.fontFamily, 'serif');
  assert.equal(entry.style.fontSize, '12pt');
  assert.equal(entry.readOnly, true);
  assert.equal(entry.style.borderStyle, 'none');
  const limited = dom.window.document.querySelector('[data-cid="limited"]');
  assert.equal(limited.style.webkitLineClamp, '2');
  assert.equal(limited.style.overflow, 'hidden');
  assert.equal(limited.textContent, 'Several\nlines\nof text');
});

test('sparse instruction cells retain tall grid spans and horizontal Alignment placement', t => {
  const { dom, receive } = fixture(); t.after(() => dom.window.close());
  receive({ type: 'hello', pages: [{ address: 'tall-grid' }] });
  receive({ type: 'render', page: 'tall-grid', generation: 1, tree: {
    type: 'page', cid: 'root', props: {}, children: [{ type: 'grid', cid: 'grid', props: { cols: 2 }, children: [{
      type: 'stack', cid: 'instructions', props: { align: 'end' }, placement: { column: 2, row: 9, span: 1, row_span: 92 }, children: [
        { type: 'text', cid: 'text', props: { content: 'Instructions remain reachable' } }
      ]
    }] }]
  } });
  const cell = dom.window.document.querySelector('[data-cid="instructions"]');
  assert.equal(cell.style.gridRow, '9 / span 92');
  assert.equal(cell.style.gridColumn, '2 / span 1');
  assert.equal(cell.style.justifySelf, 'end');
  assert.equal(cell.textContent, 'Instructions remain reachable');
});

// Model paths are positional; browser state must instead retain stable row/column IDs.
function modelTable(receive, generation, props) {
  receive({ type: 'render', page: 'models', generation,
    bindings: { grid: ['row_toggle', 'selection_change', 'cursor_change', 'row_activate', 'cell_edit', 'sort_change'] },
    tree: { type: 'page', cid: 'root', props: {}, children: [{ type: 'table', cid: 'grid', props: {
      columns: [{ key: 'name', label: 'Name' }], selection: 'single', selected: [], ...props
    } }] } });
}

for (const completion of ['drop', 'dragend']) {
  test(`${completion} releases a queued table render without another click or pointerup`, async t => {
    const { dom, receive, sent } = fixture(); t.after(() => dom.window.close());
    const { document, Event } = dom.window;
    receive({ type: 'hello', pages: [{ address: 'models' }] });
    modelTable(receive, 1, { rows: [{ key: 'a', cells: { name: 'Before' } }] });
    const row = document.querySelector('tbody tr');
    row.dispatchEvent(new Event('pointerdown', { bubbles: true }));
    modelTable(receive, 2, { rows: [] });
    assert.equal(document.querySelectorAll('tbody tr').length, 1, 'preserve the active gesture target');
    // WebKit's native drag may finish without a matching pointerup/cancel.
    // Drop covers a completed transfer; dragend also covers a cancelled drag.
    row.dispatchEvent(new Event(completion, { bubbles: true }));
    await new Promise(resolve => dom.window.setTimeout(resolve, 10));
    assert.equal(document.querySelectorAll('tbody tr').length, 0, 'apply the queued authoritative move');
    modelTable(receive, 3, { rows: [{ key: 'b', cells: { name: 'After' } }] });
    assert.equal(document.querySelector('tbody tr').textContent, 'After', 'later updates must also flow');
    assert.equal(sent.filter(message => ['row_drop', 'row_activate'].includes(message.event)).length, 0,
      'releasing a render must not synthesize another transfer or activation');
  });
}

test('pointer release preserves the current target through click before applying a queued render', async t => {
  const { dom, receive } = fixture(); t.after(() => dom.window.close());
  const { document, Event } = dom.window;
  receive({ type: 'hello', pages: [{ address: 'models' }] });
  modelTable(receive, 1, { rows: [{ key: 'a', cells: { name: 'Before' } }] });
  const row = document.querySelector('tbody tr');
  row.dispatchEvent(new Event('pointerdown', { bubbles: true }));
  modelTable(receive, 2, { rows: [] });
  row.dispatchEvent(new Event('pointerup', { bubbles: true }));
  let connectedAtClick = false;
  row.addEventListener('click', () => { connectedAtClick = row.isConnected; });
  row.dispatchEvent(new Event('click', { bubbles: true }));
  assert.equal(connectedAtClick, true);
  await new Promise(resolve => dom.window.setTimeout(resolve, 10));
  assert.equal(document.querySelectorAll('tbody tr').length, 0);
});

test('table typeahead retains its viewer-local prefix across renders and does not edit cells', t => {
  const a = fixture(), b = fixture();
  t.after(() => { a.dom.window.close(); b.dom.window.close(); });
  const props = { search_column: 'name', rows: [
    { key: 'a', cells: { name: 'Apple' } }, { key: 'b', cells: { name: 'Beta' } }, { key: 'c', cells: { name: 'Bravo' } }
  ] };
  for (const f of [a, b]) { f.receive({ type: 'hello', pages: [{ address: 'models' }] }); modelTable(f.receive, 1, props); }
  const key = value => a.dom.window.document.activeElement.dispatchEvent(new a.dom.window.KeyboardEvent('keydown', { key: value, bubbles: true }));
  a.dom.window.document.querySelector('tbody tr').focus();
  key('b');
  assert.equal(a.dom.window.document.activeElement.dataset.rowKey, 'b');
  modelTable(a.receive, 2, props);
  key('r');
  assert.equal(a.dom.window.document.activeElement.dataset.rowKey, 'c');
  assert.equal(b.sent.filter(message => message.event === 'selection_change').length, 0);
  key('Escape'); key('a');
  assert.equal(a.dom.window.document.activeElement.dataset.rowKey, 'a');
  assert.equal(a.sent.filter(message => message.event === 'cell_edit').length, 0);
  assert.deepEqual(props.rows.map(row => row.cells.name), ['Apple', 'Beta', 'Bravo']);
});

test('tree expansion hides descendants, navigates by keyboard and preserves focused identity across refresh', t => {
  const { dom, receive, sent } = fixture(); t.after(() => dom.window.close());
  const { document, KeyboardEvent } = dom.window;
  receive({ type: 'hello', pages: [{ address: 'models' }] });
  const rows = [{ key: 'parent', cells: { name: 'Parent' } }, { key: 'child', parent: 'parent', cells: { name: 'Child' } }, { key: 'other', cells: { name: 'Other' } }];
  modelTable(receive, 1, { rows });
  assert.equal(document.querySelectorAll('tbody tr').length, 2);
  document.querySelector('[aria-label="Expand Parent"]').click();
  assert.equal(document.querySelectorAll('tbody tr').length, 3);
  assert.ok(sent.some(message => message.event === 'row_toggle' && message.payload.expanded));
  document.querySelector('[data-row-key="parent"]').dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowRight', bubbles: true }));
  assert.equal(document.activeElement.dataset.rowKey, 'child');
  modelTable(receive, 2, { rows, expanded: ['parent'], cursor: { row: 'child' } });
  assert.equal(document.activeElement.dataset.rowKey, 'child');
  document.activeElement.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowLeft', bubbles: true }));
  assert.equal(document.activeElement.dataset.rowKey, 'parent');
  document.activeElement.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowLeft', bubbles: true }));
  assert.equal(document.querySelectorAll('tbody tr').length, 2);
  assert.equal(document.querySelector('[data-row-key="parent"]').getAttribute('aria-expanded'), 'false');
});

test('multiple selection supports additive and range gestures without changing single selection', t => {
  const { dom, receive, sent } = fixture(); t.after(() => dom.window.close());
  receive({ type: 'hello', pages: [{ address: 'models' }] });
  const rows = ['a', 'b', 'c'].map(key => ({ key, cells: { name: key } }));
  modelTable(receive, 1, { rows, selection: 'multi' });
  const click = (key, modifiers = {}) => dom.window.document.querySelector(`[data-row-key="${key}"]`).dispatchEvent(new dom.window.MouseEvent('click', { bubbles: true, ...modifiers }));
  click('a'); click('c', { ctrlKey: true });
  assert.deepEqual(sent.filter(message => message.event === 'selection_change').at(-1).payload.rows, ['a', 'c']);
  click('b', { shiftKey: true });
  assert.deepEqual(sent.filter(message => message.event === 'selection_change').at(-1).payload.rows, ['b', 'c']);
  modelTable(receive, 2, { rows, selection: 'single' });
  click('a'); click('c', { ctrlKey: true });
  assert.deepEqual(sent.filter(message => message.event === 'selection_change').at(-1).payload.rows, ['c']);
});

test('boolean cells expose one-click proposals and an unchanged server value reverses a rejected proposal', t => {
  const { dom, receive, sent } = fixture(); t.after(() => dom.window.close());
  receive({ type: 'hello', pages: [{ address: 'models' }] });
  const props = { rows: [{ key: 'a', cells: { flag: false } }], columns: [{ key: 'flag', label: 'Enabled', editor: { type: 'checkbox' } }] };
  modelTable(receive, 1, props);
  dom.window.document.querySelector('tbody input').click();
  const edits = sent.filter(message => message.event === 'cell_edit');
  assert.equal(edits.length, 1);
  assert.deepEqual(edits[0].payload, { row: 'a', column: 'flag', value: true });
  modelTable(receive, 2, props);
  assert.equal(dom.window.document.querySelector('tbody input').checked, false);
});

test('hierarchical sorting keeps siblings together and model sorting waits for authoritative row order', t => {
  const { dom, receive, sent } = fixture(); t.after(() => dom.window.close());
  receive({ type: 'hello', pages: [{ address: 'models' }] });
  const props = { rows: [{ key: 'z', cells: { name: 'Z' } }, { key: 'a', parent: 'z', cells: { name: 'A' } }, { key: 'b', cells: { name: 'B' } }],
    columns: [{ key: 'name', label: 'Name', sortable: true }], sortable: true, expanded: ['z'] };
  modelTable(receive, 1, props);
  dom.window.document.querySelector('th button').click();
  const order = () => [...dom.window.document.querySelectorAll('tbody tr')].map(row => row.dataset.rowKey);
  assert.deepEqual(order(), ['b', 'z', 'a']);
  modelTable(receive, 2, { ...props, sort_mode: 'model', headers: false });
  assert.deepEqual(order(), ['z', 'a', 'b']);
  assert.equal(dom.window.document.querySelector('thead'), null);
  modelTable(receive, 3, { ...props, sort_mode: 'model' });
  dom.window.document.querySelector('th button').click();
  assert.deepEqual(order(), ['z', 'a', 'b']);
  assert.ok(sent.some(message => message.event === 'sort_change'));
});

test('single-click tables activate once for a double-click sequence and retain Enter activation', t => {
  const { dom, receive, sent } = fixture(); t.after(() => dom.window.close());
  receive({ type: 'hello', pages: [{ address: 'models' }] });
  modelTable(receive, 1, { activation: 'single', rows: [{ key: 'a', cells: { name: 'A' } }] });
  const cell = dom.window.document.querySelector('tbody td');
  for (const [type, detail] of [['click', 1], ['click', 2], ['dblclick', 2]]) {
    cell.dispatchEvent(new dom.window.MouseEvent(type, { bubbles: true, detail }));
  }
  assert.equal(sent.filter(message => message.event === 'row_activate').length, 1);
  assert.deepEqual(sent.filter(message => message.event === 'row_activate')[0].payload, { row: 'a', column: 'name' });
  dom.window.document.querySelector('tbody tr').dispatchEvent(new dom.window.KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
  assert.equal(sent.filter(message => message.event === 'row_activate').length, 2);
});

test('hidden tab selectors keep the selected content accessible and other pages hidden', t => {
  const { dom, receive } = fixture(); t.after(() => dom.window.close());
  receive({ type: 'hello', pages: [{ address: 'hidden-tabs' }] });
  const render = (show_tabs, selected) => receive({ type: 'render', page: 'hidden-tabs', generation: selected + 1,
    bindings: { tabs: ['select'] }, tree: { type: 'page', cid: 'root', props: {}, children: [{
      type: 'tabs', cid: 'tabs', props: { names: ['First', 'Second'], show_tabs, selected, size_to_all: true },
      children: [{ type: 'text', cid: 'first', props: { content: 'First content' } }, { type: 'text', cid: 'second', props: { content: 'Second content' } }]
    }] } });
  render(false, 0);
  const document = dom.window.document;
  assert.equal(document.querySelector('.tab-list').style.display, 'none');
  assert.equal(document.querySelector('[data-cid="first"]').getAttribute('role'), 'group');
  assert.equal(document.querySelector('[data-cid="first"]').getAttribute('aria-label'), 'First');
  assert.equal(document.querySelector('[data-cid="second"]').hidden, true);
  assert.equal(document.querySelector('[data-cid="second"]').inert, true);
  render(true, 1);
  assert.equal(document.querySelector('.tab-list').hidden, false);
  assert.equal(document.querySelector('[data-cid="first"]').hidden, true);
  assert.equal(document.querySelector('[data-cid="second"]').getAttribute('role'), 'tabpanel');
});

test('row activation reports the actual column and a removed cursor never focuses a replacement row', t => {
  const { dom, receive, sent } = fixture(); t.after(() => dom.window.close());
  receive({ type: 'hello', pages: [{ address: 'models' }] });
  const props = { rows: [{ key: 'a', cells: { first: 'A', second: 'B' } }], columns: [{ key: 'first', label: 'First' }, { key: 'second', label: 'Second' }] };
  modelTable(receive, 1, props);
  dom.window.document.querySelector('[data-column-key="second"]').dispatchEvent(new dom.window.MouseEvent('dblclick', { bubbles: true }));
  assert.deepEqual(sent.filter(message => message.event === 'row_activate').at(-1).payload, { row: 'a', column: 'second' });
  dom.window.document.querySelector('tbody tr').focus();
  modelTable(receive, 2, { ...props, rows: [{ key: 'new', cells: { first: 'New' } }], cursor: {} });
  assert.notEqual(dom.window.document.activeElement.dataset.rowKey, 'new');
});

test('modifier clicks on editable cells select multiple rows without opening an editor', t => {
  const { dom, receive, sent } = fixture(); t.after(() => dom.window.close());
  receive({ type: 'hello', pages: [{ address: 'models' }] });
  modelTable(receive, 1, { selection: 'multi', selected: ['a'],
    columns: [{ key: 'name', label: 'Name', editor: { type: 'text' } }],
    rows: [{ key: 'a', cells: { name: 'A' } }, { key: 'b', cells: { name: 'B' } }] });
  dom.window.document.querySelector('[data-row-key="b"] td').dispatchEvent(new dom.window.MouseEvent('click', { bubbles: true, ctrlKey: true }));
  assert.equal(dom.window.document.querySelector('tbody input'), null);
  assert.deepEqual(sent.filter(message => message.event === 'selection_change').at(-1).payload.rows, ['a', 'b']);
});

test('editable combo text cannot impersonate an option ID or the clearing sentinel', t => {
  const { dom, receive, sent } = fixture(); t.after(() => dom.window.close());
  receive({ type: 'hello', pages: [{ address: 'models' }] });
  receive({ type: 'render', page: 'models', generation: 1, bindings: { combo: ['change'] },
    tree: { type: 'page', cid: 'root', props: {}, children: [{ type: 'select', cid: 'combo', props: {
      editable: true, free_text_prefix: 'text:', empty_value: 'none', value: 'none',
      options: [{ value: 'none', label: '' }, { value: 'row', label: 'Label' }]
    } }] } });
  const input = dom.window.document.querySelector('input');
  for (const text of ['row', 'none', 'text:literal']) {
    input.value = text;
    input.dispatchEvent(new dom.window.Event('input', { bubbles: true }));
    assert.equal(sent.filter(message => message.event === 'change').at(-1).payload.value, `text:${text}`);
    assert.equal(input.value, text);
  }
  const picker = dom.window.document.querySelector('select');
  picker.value = 'row'; picker.dispatchEvent(new dom.window.Event('change', { bubbles: true }));
  assert.equal(input.value, 'Label');
  assert.equal(sent.filter(message => message.event === 'change').at(-1).payload.value, 'row');
});

test('Markdown does not forward host cookies to another local port or scheme', t => {
  const { dom, receive } = fixture();
  t.after(() => dom.window.close());
  receive({ type: 'hello', pages: [{ address: 'links' }] });
  receive({ type: 'render', page: 'links', generation: 1,
    tree: { type: 'page', cid: 'root', props: {}, children: [
      { type: 'markdown', cid: 'help', props: { content:
        '[other port](http://127.0.0.1:9090/) [numeric alias](http://2130706433:9090/) ' +
        '[other scheme](https://127.0.0.1/) [invalid](http://[broken) ' +
        '[local](http://127.0.0.1/help) [wiki](https://gswiki.play.net/)' } }
    ] } });
  const help = dom.window.document.querySelector('[data-cid="help"]');
  assert.deepEqual([...help.querySelectorAll('a')].map(link => link.href),
    ['http://127.0.0.1/help', 'https://gswiki.play.net/']);
  assert.ok(help.textContent.includes('other port'));
  assert.ok(help.textContent.includes('invalid'));
});

test('cascading menus require clicks, retain the selected branch and dismiss one level with Escape', t => {
  const { dom, receive } = fixture();
  t.after(() => dom.window.close());
  const { document, HTMLElement, Event, MouseEvent, KeyboardEvent } = dom.window;
  const visible = new Set();
  HTMLElement.prototype.showPopover = function () { visible.add(this); };
  HTMLElement.prototype.hidePopover = function () { visible.delete(this); };
  Object.defineProperty(dom.window, 'innerWidth', { value: 320 });
  Object.defineProperty(dom.window, 'innerHeight', { value: 240 });
  receive({ type: 'hello', pages: [{ address: 'menus' }] });
  receive({ type: 'render', page: 'menus', generation: 1, bindings: {}, submissions: {},
    tree: { type: 'page', cid: 'root', props: { bare: true }, children: [
      { type: 'group', cid: 'surface', props: { context_menu: 'menu' } },
      { type: 'group', cid: 'menu', props: { menu: 'context', key: 'menu' }, children: [
        { type: 'group', cid: 'outer', props: { menu: 'submenu', label: 'Outer' }, children: [
          { type: 'group', cid: 'inner', props: { menu: 'submenu', label: 'Inner' }, children: [
            { type: 'button', cid: 'choice', props: { label: 'Choose' } }
          ] }
        ] },
        { type: 'group', cid: 'sibling', props: { menu: 'submenu', label: 'Sibling' }, children: [] }
      ] }
    ] }
  });
  const surface = document.querySelector('[data-cid="surface"]');
  const menu = document.querySelector('.webui-context-menu');
  const outer = document.querySelector('[data-cid="outer"]');
  const triggers = [...document.querySelectorAll('.submenu-trigger')];
  const panels = [...document.querySelectorAll('.submenu-items')];
  triggers.forEach(trigger => { trigger.getBoundingClientRect = () => ({ left: 130, right: 320, top: 200 }); });
  panels.forEach(panel => { panel.getBoundingClientRect = () => ({ width: 180, height: 240 }); });
  const open = () => {
    surface.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, clientX: 300, clientY: 200 }));
    triggers.slice(0, 2).forEach(trigger => trigger.click());
    assert.equal(visible.size, 2);
    assert.equal(panels[0].getAttribute('popover'), 'manual');
    assert.equal(panels[0].style.left, '0px');
    assert.equal(panels[0].style.top, '0px');
  };
  const closed = () => {
    assert.equal(visible.size, 0);
    triggers.forEach(trigger => assert.equal(trigger.getAttribute('aria-expanded'), 'false'));
    panels.forEach(panel => assert.equal(panel.style.display, 'none'));
  };
  outer.dispatchEvent(new Event('pointerenter'));
  assert.equal(visible.size, 0, 'hover must not open a submenu');
  open();
  outer.dispatchEvent(new Event('pointerleave'));
  assert.equal(visible.size, 2, 'crossing other rows must not close the selected branch');
  document.querySelector('[data-cid="sibling"]').dispatchEvent(new Event('pointerenter'));
  assert.equal(visible.has(panels[2]), false, 'hovering another branch must not replace the selected branch');
  document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }));
  assert.equal(visible.size, 1);
  assert.equal(visible.has(panels[0]), true);
  assert.equal(document.activeElement, triggers[1]);
  document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }));
  closed();
  assert.equal(menu.style.display, 'block');
  assert.equal(document.activeElement, triggers[0]);
  document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }));
  assert.equal(menu.style.display, 'none');
  open();
  triggers[2].click();
  assert.equal(visible.size, 1);
  assert.equal(visible.has(panels[2]), true, 'clicking a sibling closes the old branch and its descendants');
  open();
  triggers[0].click();
  closed();
  open();
  document.body.dispatchEvent(new Event('pointerdown', { bubbles: true }));
  closed();
  open();
  document.querySelector('[data-cid="choice"]').click();
  closed();
});

for (const explicit of [false, true]) {
  test(`editable choices preserve ${explicit ? 'an explicit empty ID' : 'an absent value'} on creation and restoration`, t => {
    const { dom, page, sent } = fixture();
    t.after(() => dom.window.close());
    page.bindings.choice = ['change'];
    const options = [{ value: '', label: 'Empty ID option' }, { value: 'undefined', label: 'Literal undefined' }];
    const wrapper = dom.window.LichWebUI.render(page, {
      type: 'select', cid: 'choice', props: { editable: true, options, ...(explicit ? { value: '' } : {}) }
    });
    const entry = wrapper.querySelector('input');
    const picker = wrapper.querySelector('select');
    const assertChoice = selected => {
      assert.equal(entry.value, selected ? 'Empty ID option' : '');
      assert.equal(picker.selectedIndex, selected ? 0 : -1);
      assert.equal(entry.choiceValue(), '');
    };
    assertChoice(explicit);
    entry.dispatchEvent(new dom.window.Event('change'));
    assertChoice(explicit);
    assert.equal(sent.length, 0, 'an unchanged entry must not create a selection or event');
    if (!explicit) {
      picker.value = '';
      picker.dispatchEvent(new dom.window.Event('change'));
      assertChoice(true);
      assert.deepEqual(sent.at(-1).payload, { value: '' });
    }
    entry.restoreChoice('');
    assertChoice(true);
    entry.restoreChoice(undefined);
    assertChoice(false);
    entry.restoreChoice('');
    assertChoice(true);
  });
}

test('editable choices retain an explicitly selected empty ID across unrelated renders', t => {
  const { dom, receive, sent } = fixture();
  t.after(() => dom.window.close());
  receive({ type: 'hello', pages: [{ address: 'choices' }] });
  const frame = generation => ({ type: 'render', page: 'choices', generation,
    bindings: { choice: ['change'], save: ['activate'] }, submissions: { save: ['choice'] },
    tree: { type: 'page', cid: 'root', props: {}, children: [
      { type: 'select', cid: 'choice', props: { editable: true, value: 'x',
        options: [{ value: '', label: 'Empty ID option' }, { value: 'x', label: 'X' }] } },
      { type: 'button', cid: 'save', props: { label: 'Save' } }
    ] }
  });
  receive(frame(1));
  const picker = dom.window.document.querySelector('select');
  picker.value = '';
  picker.dispatchEvent(new dom.window.Event('change'));
  assert.deepEqual(sent.at(-1).payload, { value: '' });
  receive(frame(2));
  assert.equal(dom.window.document.querySelector('input').value, 'Empty ID option');
  assert.equal(dom.window.document.querySelector('select').selectedIndex, 0);
  dom.window.document.querySelector('button').click();
  assert.deepEqual(sent.at(-1).submission, ['']);
});

test('plain text preserves chart line breaks and honors nonwrapping labels', () => {
  const { dom, page } = fixture();
  const text = dom.window.LichWebUI.render(page, {
    type: 'text', cid: 'chart', props: { content: 'Armor\nFull Plate', wrap: false }
  });
  assert.equal(text.textContent, 'Armor\nFull Plate');
  assert.equal(text.style.whiteSpace, 'pre');
  dom.window.close();
});

test('native typography applies bounded properties while keeping text literal', () => {
  const { dom, page } = fixture();
  const style = { font_size: 18, foreground: { r: 224, g: 27, b: 36, a: 1 }, background: { r: 0, g: 0, b: 0, a: 0.5 } };
  const literal = '<img src=x onerror=alert(1)>';
  const text = dom.window.LichWebUI.render(page, { type: 'text', cid: 'native', props: { content: literal, tone: 'positive', ...style } });
  const surface = dom.window.LichWebUI.render(page, { type: 'composite', cid: 'native-composite', props: {
    width: 100, height: 30, layers: [{ kind: 'label', text: literal, x: 0, y: 0, ...style }]
  } });
  for (const element of [text, surface.querySelector('.composite-label')]) {
    assert.equal(element.textContent, literal);
    assert.equal(element.querySelector('img'), null);
    assert.equal(element.style.fontSize, '18pt');
    assert.equal(element.style.color, 'rgb(224, 27, 36)');
    assert.equal(element.style.backgroundColor, 'rgba(0, 0, 0, 0.5)');
  }
  dom.window.close();
});

test('multiline input keeps ordered script lists editable and submits their exact text', () => {
  const { dom, page, sent } = fixture();
  page.bindings.order = ['change'];
  const field = dom.window.LichWebUI.render(page, {
    type: 'textarea', cid: 'order', props: { value: '401\n101', rows: 8, max_length: 100, label: 'Cast order' }
  });
  const control = field.querySelector('textarea');
  assert.ok(control);
  assert.equal(control.value, '401\n101');
  assert.equal(control.rows, 8);
  control.value = '101\n401';
  control.dispatchEvent(new dom.window.Event('input'));
  assert.equal(sent.at(-1).payload.value, '101\n401');
  assert.equal(page.controls.get('order'), control);
  dom.window.close();
});

test('table sorting keeps stable row identities and numeric order', () => {
  const { dom, page, sent } = fixture();
  page.bindings.catalog = ['sort_change', 'selection_change', 'row_activate'];
  const table = dom.window.LichWebUI.render(page, {
    type: 'table', cid: 'catalog', props: {
      columns: [{ key: 'downloads', label: 'Downloads', sortable: true }], sortable: true, selection: 'single',
      sort: { column: 'downloads', direction: 'asc' },
      rows: [{ key: 'ten', cells: { downloads: 10 } }, { key: 'two', cells: { downloads: 2 } }]
    }
  });
  assert.deepEqual([...table.querySelectorAll('tbody tr')].map(row => row.dataset.rowKey), ['two', 'ten']);
  table.querySelector('th button').click();
  assert.equal(sent.at(-1).event, 'sort_change');
  assert.equal(sent.at(-1).payload.direction, 'desc');
  table.querySelector('tbody tr').dispatchEvent(new dom.window.MouseEvent('dblclick'));
  assert.equal(sent.at(-1).event, 'row_activate');
  assert.equal(sent.at(-1).payload.row, 'ten');
  dom.window.close();
});

test('composite uses scaled layout, literal labels, masked tint and vertical bars', () => {
  const { dom, page } = fixture();
  const surface = dom.window.LichWebUI.render(page, {
    type: 'composite', cid: 'map', props: { width: 100, height: 80, scale: 2, layers: [
      { kind: 'image', src: '/files/maps/body.png', mask: '/files/maps/wound.png', tint: { r: 255, g: 0, b: 0, a: 0.5 }, x: 0, y: 0, w: 50, h: 60 },
      { kind: 'label', x: 1, y: 2, text: '<script>literal</script>' },
      { kind: 'bar', x: 4, y: 5, w: 8, h: 40, value: 0.25, orientation: 'vertical', tone: 'positive' }
    ] }
  });
  assert.equal(surface.style.width, '200px');
  assert.equal(surface.style.height, '160px');
  assert.equal(surface.querySelector('.composite-surface').style.transform, 'scale(2)');
  assert.equal(surface.querySelector('script'), null);
  assert.equal(surface.querySelector('.composite-label').textContent, '<script>literal</script>');
  assert.match(surface.querySelector('.composite-image').style.maskImage, /wound.png/);
  assert.match(surface.querySelector('.composite-image').style.backgroundImage, /body.png/);
  assert.equal(surface.querySelector('.composite-image').style.backgroundBlendMode, 'multiply');
  assert.equal(surface.querySelector('.composite-bar-fill').style.height, '25%');
  assert.equal(surface.querySelector('.composite-bar-fill').style.bottom, '0px');
  dom.window.close();
});

test('composite reports absolute unscaled coordinates once, including modifiers and keyboard regions', () => {
  const { dom, page, sent } = fixture();
  page.bindings.map = ['surface_activate', 'region_activate'];
  const view = dom.window.LichWebUI.render(page, {
    type: 'composite', cid: 'map', props: { width: 100, height: 80, scale: 2, surface_events: true,
      layers: [{ kind: 'region', key: 'room-7', x1: 10, y1: 12, x2: 20, y2: 22, label: 'Room seven', activates: true }] }
  });
  const surface = view.querySelector('.composite-surface');
  surface.getBoundingClientRect = () => ({ left: -30, top: -40, width: 200, height: 160 });
  surface.dispatchEvent(new dom.window.MouseEvent('click', { bubbles: true, clientX: 10, clientY: 20, ctrlKey: true, shiftKey: true }));
  assert.deepEqual(sent.at(-1).payload, { x: 20, y: 30, button: 'primary', modifiers: ['ctrl', 'shift'] });
  const count = sent.length;
  view.querySelector('button').click();
  assert.equal(sent.length, count + 1);
  assert.equal(sent.at(-1).event, 'region_activate');
  assert.equal(sent.at(-1).payload.region, 'room-7');
  dom.window.close();
});

test('log and overlay render literal text and layered children without HTML execution', () => {
  const { dom, page } = fixture();
  const log = dom.window.LichWebUI.render(page, {
    type: 'log', cid: 'chat', props: { lines: ['<img src=x>', 'second'], max_lines: 1000, follow: true }
  });
  assert.equal(log.textContent, '<img src=x>\nsecond');
  assert.equal(log.querySelector('img'), null);
  const overlay = dom.window.LichWebUI.render(page, {
    type: 'overlay', cid: 'spell', props: {}, children: [
      { type: 'progress', cid: 'bar', props: { value: 0.5 } },
      { type: 'text', cid: 'name', props: { content: 'Fixture spell' } }
    ]
  });
  assert.equal(overlay.querySelector('progress').value, 0.5);
  assert.equal(overlay.children[1].style.gridArea, '1 / 1');
  dom.window.close();
});

test('terminal submission permits the server to clear a field back to its original empty value', () => {
  const { dom, receive } = fixture();
  receive({ type: 'hello', pages: [{ address: 'locations' }] });
  const render = generation => ({ type: 'render', page: 'locations', generation,
    bindings: { create: ['activate'] }, submissions: { create: ['name'] }, tree: {
      type: 'page', cid: 'root', props: { title: 'Locations' }, children: [
        { type: 'text_input', cid: 'name', props: { value: '' }, children: [] },
        { type: 'button', cid: 'create', props: { label: 'Create' }, children: [] }
      ]
    }
  });
  receive(render(1));
  dom.window.document.querySelector('input').value = 'Fixture hunting';
  dom.window.document.querySelector('button').click();
  receive(render(2));
  assert.equal(dom.window.document.querySelector('input').value, '');
  dom.window.close();
});

for (const type of ['checkbox', 'toggle']) {
  test(`server reset of a submitted ${type} wins while unsent drafts survive`, t => {
    const { dom, receive, sent } = fixture(); t.after(() => dom.window.close());
    const { document, Event } = dom.window;
    receive({ type: 'hello', pages: [{ address: 'choices' }] });
    const render = (generation, disabled = false, bound = true) => ({
      type: 'render', page: 'choices', generation, bindings: bound ? { choice: ['change'] } : {},
      tree: { type: 'page', cid: 'root', props: {}, children: [
        { type, cid: 'choice', props: { label: 'Choice', checked: false, disabled, appearance: 'button' }, children: [] }
      ] }
    });
    const control = () => document.querySelector('[data-cid="choice"] input, button[data-cid="choice"]');
    const checked = () => type === 'checkbox' ? control().checked : control().getAttribute('aria-pressed') === 'true';
    const change = () => {
      if (type === 'checkbox') { control().checked = true; control().dispatchEvent(new Event('change')); }
      else control().click();
    };
    receive(render(1));
    change();
    assert.equal(sent.at(-1).payload.value, true);
    receive(render(2, true));
    assert.equal(checked(), false, 'the callback reset must not be restored as an unsent edit');
    receive(render(3, false, false));
    change();
    receive(render(4, false, false));
    assert.equal(checked(), true, 'an unsubmitted draft still survives an unrelated render');
  });
}

test('cleared sensitive text cannot return on the next render', () => {
  const { dom, receive } = fixture();
  receive({ type: 'hello', pages: [{ address: 'sensitive-text' }] });
  const render = generation => ({ type: 'render', page: 'sensitive-text', generation,
    bindings: { save: ['activate'] }, submissions: { save: ['token'] }, tree: {
      type: 'page', cid: 'root', props: { title: 'Terminal-only input' }, children: [
        { type: 'text_input', cid: 'token', props: { value: '', sensitive: true }, children: [] },
        { type: 'button', cid: 'save', props: { label: 'Save' }, children: [] }
      ]
    }
  });
  receive(render(1));
  dom.window.document.querySelector('input').value = 'fixture-only';
  dom.window.document.querySelector('button').click();
  receive({ type: 'clear_sensitive', cids: ['token'] });
  receive(render(2));
  assert.equal(dom.window.document.querySelector('input').value, '');
  dom.window.close();
});

test('grid renders real children and preserves column and row spans', () => {
  const { dom, page } = fixture();
  const grid = dom.window.LichWebUI.render(page, {
    type: 'grid', cid: 'grid', props: { cols: 4, gap: 3, column_gap: 20, row_gap: 5 }, children: [{
      type: 'text', cid: 'cell', props: { content: 'Measured cell' },
      placement: { span: 2, row_span: 3 }, children: []
    }]
  });
  assert.equal(grid.textContent, 'Measured cell');
  assert.equal(grid.style.gridTemplateColumns, 'repeat(4, minmax(0, 1fr))');
  assert.equal(grid.firstChild.style.gridColumn, 'span 2');
  assert.equal(grid.firstChild.style.gridRow, 'span 3');
  assert.equal(grid.style.columnGap, '20px');
  assert.equal(grid.style.rowGap, '5px');
  dom.window.close();
});

test('change carries only its payload; terminal submit carries the declared scope', () => {
  const { dom, page, sent } = fixture();
  page.bindings.name = ['change', 'submit'];
  page.submissions.name = ['name', 'password'];
  const component = { type: 'text_input', cid: 'name', props: { value: '' }, children: [] };
  const wrapper = dom.window.LichWebUI.render(page, component);
  const input = wrapper.querySelector('input');
  page.controls.set('password', { type: 'password', value: 'fixture-only' });
  input.value = 'draft';
  input.dispatchEvent(new dom.window.Event('change'));
  assert.equal(sent.at(-1).submission, undefined);
  input.dispatchEvent(new dom.window.KeyboardEvent('keydown', { key: 'Enter' }));
  assert.deepEqual(sent.at(-1).submission, ['draft', 'fixture-only']);
  dom.window.close();
});

test('focus is an empty notification even on an input with a password submit scope', () => {
  const { dom, page, sent } = fixture();
  page.bindings.name = ['focus', 'submit'];
  page.submissions.name = ['password'];
  page.controls.set('password', { type: 'password', value: 'fixture-only' });
  const wrapper = dom.window.LichWebUI.render(page, {
    type: 'text_input', cid: 'name', props: { value: '(new var name)' }, children: []
  });
  const control = wrapper.querySelector('input');
  control.dispatchEvent(new dom.window.Event('focus'));
  assert.deepEqual(sent.at(-1).payload, {});
  assert.equal(sent.at(-1).submission, undefined);
  page.restoringFocus = true;
  control.dispatchEvent(new dom.window.Event('focus'));
  assert.equal(sent.length, 1, 'restoring focus after a render must not run source logic again');
  dom.window.close();
});

test('adding a row preserves typing and focus, while an explicit server edit wins', () => {
  const { dom, sent, receive } = fixture();
  receive({ type: 'hello', pages: [{ address: 'vars' }] });
  const render = (generation, value) => ({ type: 'render', page: 'vars', generation,
    bindings: { name: ['focus', 'change'] }, tree: {
      type: 'page', cid: 'root', props: { title: 'Vars' }, children: [
        { type: 'text_input', cid: 'name', props: { value }, children: [] },
        { type: 'text', cid: `row-${generation}`, props: { content: 'Another row' }, children: [] }
      ]
    }
  });
  receive(render(1, ''));
  let input = dom.window.document.querySelector('input');
  input.focus();
  input.value = 'unfinished';
  input.setSelectionRange(3, 3);
  const notifications = sent.filter(message => message.event === 'focus').length;
  receive(render(2, ''));
  input = dom.window.document.querySelector('input');
  assert.equal(input.value, 'unfinished');
  assert.equal(dom.window.document.activeElement, input);
  assert.equal(input.selectionStart, 3);
  assert.equal(sent.filter(message => message.event === 'focus').length, notifications);
  receive(render(3, 'server correction'));
  assert.equal(dom.window.document.querySelector('input').value, 'server correction');
  dom.window.close();
});

test('scroll reports real vertical dimensions and suppresses duplicate measurements', async () => {
  const { dom, page, sent } = fixture();
  page.bindings.scroll = ['scrolled'];
  const element = dom.window.LichWebUI.render(page, {
    type: 'scroll', cid: 'scroll', props: { scroll_position: 120 }, children: []
  });
  Object.defineProperties(element, { scrollHeight: { value: 800 }, clientHeight: { value: 300 } });
  dom.window.document.body.append(element);
  await new Promise(resolve => dom.window.requestAnimationFrame(resolve));
  assert.deepEqual(sent.at(-1).payload, { position: 120, upper: 800, page_size: 300 });
  const count = sent.length;
  element.dispatchEvent(new dom.window.Event('scroll'));
  assert.equal(sent.length, count);
  element.scrollTop = 140;
  element.dispatchEvent(new dom.window.Event('scroll'));
  assert.equal(sent.at(-1).payload.position, 140);
  dom.window.close();
});

test('native map horizontal panning survives tree replacement without a new shim event', async () => {
  const { dom, page } = fixture();
  const component = { type: 'scroll', cid: 'map-scroll', props: {}, children: [] };
  let view = dom.window.LichWebUI.render(page, component);
  dom.window.document.body.append(view);
  view.scrollLeft = 180;
  view.scrollTop = 35;
  view.dispatchEvent(new dom.window.Event('scroll'));
  view.remove();
  view = dom.window.LichWebUI.render(page, component);
  dom.window.document.body.append(view);
  await new Promise(resolve => dom.window.requestAnimationFrame(resolve));
  assert.equal(view.scrollLeft, 180);
  assert.equal(view.scrollTop, 35);
  dom.window.close();
});

for (const type of ['checkbox', 'toggle']) {
  for (const accepted of [true, false]) {
    test(`${type} stale replay displays the server's ${accepted ? 'accepted change' : 'callback reset'}`, t => {
      const { dom, sent, receive } = fixture(); t.after(() => dom.window.close());
      receive({ type: 'hello', pages: [{ address: 'replay' }] });
      const render = (generation, checked) => receive({ type: 'render', page: 'replay', generation,
        bindings: { choice: ['change'] }, tree: { type: 'page', cid: 'root', props: {}, children: [
          { type, cid: 'choice', props: { label: 'Choice', checked, ...(type === 'toggle' ? { appearance: 'button' } : {}) } }
        ] } });
      const control = () => dom.window.document.querySelector(type === 'checkbox' ? 'input' : '.webui-toggle');
      const checked = () => type === 'checkbox' ? control().checked : control().getAttribute('aria-pressed') === 'true';
      render(1, false);
      control().click();
      const original = sent.find(message => message.event === 'change');
      // Another event publishes first. The rejection then supplies the same
      // replacement tree, on which the original intent is retried once.
      render(2, false);
      receive({ type: 'refusal', reason: 'stale_generation', page: 'replay', cid: 'choice',
        event: 'change', request: original.request });
      render(2, false);
      render(3, accepted);
      assert.deepEqual(sent.filter(message => message.event === 'change').map(message => message.payload.value), [true, true]);
      assert.equal(checked(), accepted, 'an old server value must not become an unsent user edit during replay');
      control().click();
      assert.equal(sent.at(-1).payload.value, !accepted, 'the next click starts from the displayed server state');
    });
  }
}

test('a stale submission retry retains its snapshot without reviving an old displayed combo value', t => {
  const { dom, sent, receive } = fixture(); t.after(() => dom.window.close());
  receive({ type: 'hello', pages: [{ address: 'replay' }] });
  const render = (generation, value) => receive({ type: 'render', page: 'replay', generation,
    bindings: { choice: ['change'], save: ['activate'] }, submissions: { save: ['choice'] },
    tree: { type: 'page', cid: 'root', props: {}, children: [
      { type: 'select', cid: 'choice', props: { editable: true, value, options: [
        { value: 'robes', label: 'Robes' }, { value: 'plate', label: 'Full Plate' }
      ] } },
      { type: 'button', cid: 'save', props: { label: 'Save' } }
    ] } });
  render(1, 'robes');
  const chooser = dom.window.document.querySelector('select');
  chooser.value = 'plate';
  chooser.dispatchEvent(new dom.window.Event('change'));
  dom.window.document.querySelector('button').click();
  const original = sent.at(-1);
  assert.deepEqual(original.submission, ['plate']);
  render(2, 'robes');
  receive({ type: 'refusal', reason: 'stale_generation', page: 'replay', cid: 'save', event: 'activate', request: original.request });
  render(2, 'robes');
  assert.deepEqual(sent.at(-1).submission, ['plate'], 'retry retains the original submission');
  render(3, 'plate');
  assert.equal(dom.window.document.querySelector('input').value, 'Full Plate');
  assert.equal(dom.window.document.querySelector('select').value, 'plate');
});

test('a stale refusal replays only its identified click once, across unrelated renders', () => {
  const { dom, sent, receive } = fixture();
  receive({ type: 'hello', pages: [{ address: 'actions' }] });
  const render = generation => ({ type: 'render', page: 'actions', generation,
    bindings: { save: ['activate'] }, tree: { type: 'page', cid: 'root', props: { title: 'Actions' }, children: [
      { type: 'button', cid: 'save', props: { label: 'Save' }, children: [] }
    ] } });
  receive(render(1));
  dom.window.document.querySelector('button').click();
  const first = sent.at(-1);
  assert.equal(typeof first.request, 'number');
  receive(render(2));
  dom.window.document.querySelector('button').click();
  const second = sent.at(-1);
  receive({ type: 'refusal', reason: 'stale_generation', page: 'actions', cid: 'save', event: 'activate', request: first.request });
  receive(render(3));
  assert.equal(sent.filter(message => message.event === 'activate').length, 3);
  const retry = sent.at(-1);
  assert.notEqual(retry.request, second.request);
  receive({ type: 'refusal', reason: 'stale_generation', page: 'actions', cid: 'save', event: 'activate', request: retry.request });
  receive(render(4));
  assert.equal(sent.filter(message => message.event === 'activate').length, 3);
  dom.window.close();
});

test('clearing a password discards every retained submit that referenced it', () => {
  const { dom, sent, receive } = fixture();
  receive({ type: 'hello', pages: [{ address: 'login' }] });
  const render = generation => ({ type: 'render', page: 'login', generation,
    bindings: { save: ['activate'] }, submissions: { save: ['secret'] },
    tree: { type: 'page', cid: 'root', props: { title: 'Login' }, children: [
      { type: 'password_input', cid: 'secret', props: {}, children: [] },
      { type: 'button', cid: 'save', props: { label: 'Save' }, children: [] }
    ] } });
  receive(render(1));
  dom.window.document.querySelector('input').value = 'synthetic-fixture';
  dom.window.document.querySelector('button').click();
  const first = sent.at(-1);
  receive({ type: 'refusal', reason: 'stale_generation', page: 'login', cid: 'save', event: 'activate', request: first.request });
  receive({ type: 'clear_sensitive', cids: ['secret'] });
  receive(render(2));
  assert.equal(dom.window.document.querySelector('input').value, '');
  assert.equal(sent.filter(message => message.event === 'activate').length, 1);
  dom.window.close();
});

test('numeric input renders its bounded range and reports a number', () => {
  const { dom, page, sent } = fixture();
  page.bindings.level = ['change'];
  const wrapper = dom.window.LichWebUI.render(page, {
    type: 'number_input', cid: 'level', props: { value: 2, min: 0, max: 3, step: 1 }, children: []
  });
  const control = wrapper.querySelector('input');
  assert.equal(control.type, 'number');
  assert.equal(control.min, '0');
  assert.equal(control.max, '3');
  control.value = '3';
  control.dispatchEvent(new dom.window.Event('input'));
  assert.deepEqual(sent.at(-1).payload, { value: 3 });
  control.dispatchEvent(new dom.window.Event('change'));
  assert.deepEqual(sent.at(-1).payload, { value: 3 });
  control.value = '';
  control.dispatchEvent(new dom.window.Event('change'));
  assert.equal(sent.length, 1, 'a temporarily empty edit is not a numeric value');
  dom.window.close();
});

test('modal page announcements do not reattach an already attached form', () => {
  const { dom, sent, receive } = fixture();
  receive({ type: 'hello', pages: [{ address: 'form' }] });
  receive({ type: 'render', page: 'form', generation: 1, resume: 'opaque-token',
    tree: { type: 'page', cid: 'root', props: { title: 'Form' }, children: [] } });
  receive({ type: 'pages', pages: [{ address: 'form' }, { address: 'modal' }] });
  receive({ type: 'pages', pages: [{ address: 'form' }, { address: 'modal' }] });
  assert.deepEqual(sent.filter(message => message.type === 'attach').map(message => message.page), ['form', 'modal']);
  dom.window.close();
});

test('independent radio options submit one exclusive choice and button toggles submit booleans', t => {
  const { dom, receive, sent } = fixture();
  t.after(() => dom.window.close());
  receive({ type: 'hello', pages: [{ address: 'choices' }] });
  const render = (generation, toggleChecked = false) => ({ type: 'render', page: 'choices', generation,
    bindings: { first: ['change'], second: ['change'], toggle: ['change'], save: ['activate'] },
    submissions: { save: ['first', 'second', 'toggle'] },
    tree: { type: 'page', cid: 'root', props: {}, children: [
      { type: 'radio_option', cid: 'first', props: { group: 'mode', label: 'First', checked: true } },
      { type: 'stack', cid: 'row', props: {}, children: [
        { type: 'radio_option', cid: 'second', props: { group: 'mode', label: 'Second', checked: false } }
      ] },
      { type: 'toggle', cid: 'toggle', props: { label: 'Enabled', appearance: 'button', checked: toggleChecked } },
      { type: 'button', cid: 'save', props: { label: 'Save' } }
    ] } });
  receive(render(1));
  let inputs = [...dom.window.document.querySelectorAll('input[type=radio]')];
  inputs[1].click();
  assert.deepEqual(inputs.map(input => input.checked), [false, true]);
  assert.deepEqual(sent.at(-1).payload, { value: true });
  dom.window.document.querySelector('.webui-toggle').click();
  assert.deepEqual(sent.at(-1).payload, { value: true });
  receive(render(2, true));
  inputs = [...dom.window.document.querySelectorAll('input[type=radio]')];
  assert.deepEqual(inputs.map(input => input.checked), [false, true], 'refresh retains the unsent radio draft');
  assert.equal(dom.window.document.querySelector('.webui-toggle').getAttribute('aria-pressed'), 'true');
  [...dom.window.document.querySelectorAll('button')].find(button => button.textContent === 'Save').click();
  assert.deepEqual(sent.at(-1).submission, [false, true, true]);
});

test('spin decimal presentation preserves numeric precision and accepts off-step typed values', t => {
  const { dom, receive, sent } = fixture();
  t.after(() => dom.window.close());
  receive({ type: 'hello', pages: [{ address: 'numeric' }] });
  receive({ type: 'render', page: 'numeric', generation: 1,
    bindings: { spin: ['change'], save: ['activate'] }, submissions: { save: ['spin'] },
    tree: { type: 'page', cid: 'root', props: {}, children: [
      { type: 'number_input', cid: 'spin', props: { value: 0.55, min: 0.5, max: 10, step: 0.1, digits: 1,
        snap_to_step: false, acceleration: 0.1, page_step: 1, stepper_buttons: true } },
      { type: 'button', cid: 'save', props: { label: 'Save' } }
    ] } });
  const input = dom.window.document.querySelector('input');
  const save = [...dom.window.document.querySelectorAll('button')].find(button => button.textContent === 'Save');
  assert.equal(input.value, '0.6');
  save.click();
  assert.deepEqual(sent.at(-1).submission, [0.55]);
  input.value = '2.75';
  input.dispatchEvent(new dom.window.Event('input'));
  assert.deepEqual(sent.at(-1).payload, { value: 2.75 });
  input.dispatchEvent(new dom.window.Event('blur'));
  assert.equal(input.value, '2.8');
  save.click();
  assert.deepEqual(sent.at(-1).submission, [2.75]);
  dom.window.document.querySelector('[aria-label=Increase]').click();
  assert.deepEqual(sent.at(-1).payload, { value: 2.85 });
});

test('held spin buttons accelerate, stop on release, and dispose timers on replacement', t => {
  const { dom, receive, sent } = fixture();
  t.after(() => dom.window.close());
  const timers = new Map();
  let sequence = 0;
  dom.window.setTimeout = (callback, delay) => { timers.set(++sequence, { callback, delay }); return sequence; };
  dom.window.clearTimeout = id => timers.delete(id);
  receive({ type: 'hello', pages: [{ address: 'held' }] });
  const render = generation => ({ type: 'render', page: 'held', generation, bindings: { spin: ['change'] },
    tree: { type: 'page', cid: 'root', props: {}, children: [
      { type: 'number_input', cid: 'spin', props: { value: 0, min: 0, max: 100, step: 1, digits: 0,
        snap_to_step: false, acceleration: 2, page_step: 5, stepper_buttons: true } }
    ] } });
  receive(render(1));
  const increase = dom.window.document.querySelector('[aria-label=Increase]');
  increase.dispatchEvent(new dom.window.MouseEvent('pointerdown', { button: 0 }));
  assert.equal(sent.at(-1).payload.value, 1);
  const tick = delay => {
    const entry = [...timers].find(([, timer]) => timer.delay === delay);
    assert.ok(entry, `expected ${delay} ms timer`);
    timers.delete(entry[0]); entry[1].callback();
  };
  tick(500);
  for (let count = 0; count < 6; count++) tick(50);
  assert.equal(sent.at(-1).payload.value, 10, 'six repeats precede the accelerated step');
  increase.dispatchEvent(new dom.window.MouseEvent('pointerup', { button: 0 }));
  increase.click();
  assert.equal(sent.at(-1).payload.value, 10, 'release click must not duplicate the pointer step');
  assert.equal([...timers.values()].some(timer => timer.delay === 50), false);
  increase.dispatchEvent(new dom.window.MouseEvent('pointerdown', { button: 0 }));
  receive(render(2));
  assert.equal([...timers.values()].some(timer => [50, 500].includes(timer.delay)), false);
});

test('plain editors honor read-only, wrapping and cursor policy without emitting edits', t => {
  const { dom, page, sent } = fixture();
  t.after(() => dom.window.close());
  const component = { type: 'textarea', cid: 'readonly', props: {
    value: '<literal>\nsecond', read_only: true, wrap: 'none', cursor_visible: false
  } };
  page.bindings = { readonly: ['change'] };
  const wrapper = dom.window.LichWebUI.render(page, component);
  const editor = wrapper.querySelector('textarea');
  assert.equal(editor.value, '<literal>\nsecond');
  assert.equal(editor.readOnly, true);
  assert.equal(editor.wrap, 'off');
  assert.equal(editor.style.caretColor, 'transparent');
  editor.dispatchEvent(new dom.window.Event('input'));
  assert.equal(sent.length, 0);
});

test('an empty image issues no source request and a replacement restores its dimensions', t => {
  const { dom, page } = fixture();
  t.after(() => dom.window.close());
  const empty = dom.window.LichWebUI.render(page, { type: 'image', cid: 'image', props: { src: '' } });
  assert.equal(empty.hasAttribute('src'), false);
  const full = dom.window.LichWebUI.render(page, { type: 'image', cid: 'image', props: {
    src: '/files/owner/pixel.png', width: 20, height: 10
  } });
  assert.equal(full.getAttribute('src'), '/files/owner/pixel.png');
  assert.equal(full.style.width, '20px');
  assert.equal(full.style.height, '10px');
});

test('server-requested popup location and dismissal remain bounded and do not reopen on a closed render', t => {
  const { dom, receive, sent } = fixture();
  t.after(() => dom.window.close());
  const { document, KeyboardEvent } = dom.window;
  receive({ type: 'hello', pages: [{ address: 'popup' }] });
  const render = open => receive({ type: 'render', page: 'popup', generation: open ? 1 : 2,
    bindings: { menu: ['dismiss'] }, submissions: {}, tree: { type: 'page', cid: 'root', props: {}, children: [
      { type: 'group', cid: 'menu', props: { menu: 'context', key: 'popup-menu', open, popup_position: [42, 65] }, children: [
        { type: 'button', cid: 'action', props: { label: 'Action' } }
      ] }
    ] } });
  render(true);
  let menu = document.querySelector('.webui-context-menu');
  assert.equal(menu.style.display, 'block');
  assert.equal(menu.style.left, '42px');
  document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }));
  assert.deepEqual(sent.filter(message => message.event === 'dismiss').map(message => message.cid), ['menu']);
  render(false);
  menu = document.querySelector('.webui-context-menu');
  assert.equal(menu.style.display, 'none');
});

test('menu choices change exclusively and submit hidden text on activation', t => {
  const { dom, receive, sent } = fixture();
  t.after(() => dom.window.close());
  receive({ type: 'hello', pages: [{ address: 'choices' }] });
  receive({ type: 'render', page: 'choices', generation: 1,
    bindings: { second: ['change', 'activate'], check: ['change', 'activate'] },
    submissions: { second: ['text', 'first', 'second', 'check'], check: ['text', 'first', 'second', 'check'] },
    tree: { type: 'page', cid: 'root', props: {}, children: [
      { type: 'expander', cid: 'fold', props: { label: 'Details', open: false }, children: [
        { type: 'textarea', cid: 'text', props: { value: 'Saved\ntext' } }
      ] },
      { type: 'radio_option', cid: 'first', props: { appearance: 'menu', group: 'g', label: 'First', checked: true } },
      { type: 'radio_option', cid: 'second', props: { appearance: 'menu', group: 'g', label: 'Second', checked: false } },
      { type: 'toggle', cid: 'check', props: { appearance: 'menu', label: 'Check', checked: false } }
    ] } });
  const second = dom.window.document.querySelector('[data-cid="second"]');
  second.click();
  assert.equal(dom.window.document.querySelector('[data-cid="first"]').getAttribute('aria-checked'), 'false');
  assert.deepEqual(sent.filter(message => message.type === 'event').map(message => message.event), ['change', 'activate']);
  assert.deepEqual(sent.find(message => message.event === 'activate').submission, ['Saved\ntext', false, true, false]);
  dom.window.document.querySelector('[data-cid="check"]').click();
  assert.deepEqual(sent.filter(message => message.event === 'activate').at(-1).submission, ['Saved\ntext', false, true, true]);
});

test('native and menu radio choices clear only peers in their common page group', t => {
  const { dom, receive } = fixture();
  t.after(() => dom.window.close());
  receive({ type: 'hello', pages: [{ address: 'mixed' }] });
  receive({ type: 'render', page: 'mixed', generation: 1, bindings: {}, submissions: {},
    tree: { type: 'page', cid: 'root', props: {}, children: [
      { type: 'radio_option', cid: 'native', props: { group: 'g', label: 'Native', checked: true } },
      { type: 'radio_option', cid: 'menu', props: { appearance: 'menu', group: 'g', label: 'Menu', checked: false } },
      { type: 'radio_option', cid: 'other', props: { appearance: 'menu', group: 'other', label: 'Other', checked: true } }
    ] } });
  const native = dom.window.document.querySelector('input[type="radio"]');
  const menu = dom.window.document.querySelector('[data-cid="menu"]');
  const other = dom.window.document.querySelector('[data-cid="other"]');
  menu.click();
  assert.equal(native.checked, false);
  assert.equal(menu.getAttribute('aria-checked'), 'true');
  native.click();
  assert.equal(native.checked, true);
  assert.equal(menu.getAttribute('aria-checked'), 'false');
  assert.equal(other.getAttribute('aria-checked'), 'true');
});

test('menu keys rove within one branch, skip unavailable entries and restore focus on dismissal', t => {
  const { dom, receive, sent } = fixture();
  t.after(() => dom.window.close());
  const { document, KeyboardEvent, MouseEvent } = dom.window;
  receive({ type: 'hello', pages: [{ address: 'keyboard' }] });
  receive({ type: 'render', page: 'keyboard', generation: 1, bindings: { check: ['activate'], menu: ['dismiss'] }, submissions: {},
    tree: { type: 'page', cid: 'root', props: {}, children: [
      { type: 'button', cid: 'origin', props: { label: 'Origin' } },
      { type: 'group', cid: 'surface', props: { context_menu: 'actions' } },
      { type: 'group', cid: 'menu', props: { menu: 'context', key: 'actions' }, children: [
        { type: 'toggle', cid: 'check', props: { appearance: 'menu', label: 'Check', checked: false } },
        { type: 'button', cid: 'disabled', props: { label: 'Disabled', disabled: true } },
        { type: 'button', cid: 'hidden', props: { label: 'Hidden', hidden: true } },
        { type: 'divider', cid: 'separator', props: {} },
        { type: 'group', cid: 'nested', props: { menu: 'submenu', label: 'Nested' }, children: [
          { type: 'radio_option', cid: 'first', props: { appearance: 'menu', group: 'g', label: 'First', checked: true } },
          { type: 'radio_option', cid: 'last', props: { appearance: 'menu', group: 'g', label: 'Last', checked: false } }
        ] }
      ] }
    ] } });
  const origin = document.querySelector('[data-cid="origin"]');
  origin.focus();
  document.querySelector('[data-cid="surface"]').dispatchEvent(new MouseEvent('contextmenu', { bubbles: true }));
  const check = document.querySelector('[data-cid="check"]');
  const trigger = document.querySelector('.submenu-trigger');
  const first = document.querySelector('[data-cid="first"]');
  const last = document.querySelector('[data-cid="last"]');
  const key = value => document.activeElement.dispatchEvent(new KeyboardEvent('keydown', { key: value, bubbles: true, cancelable: true }));
  assert.equal(document.activeElement, check);
  assert.equal(check.tabIndex, 0);
  key('ArrowDown');
  assert.equal(document.activeElement, trigger);
  assert.equal(check.tabIndex, -1);
  key('ArrowDown');
  assert.equal(document.activeElement, check);
  key('ArrowUp');
  assert.equal(document.activeElement, trigger);
  key('Home');
  assert.equal(document.activeElement, check);
  key('End');
  assert.equal(document.activeElement, trigger);
  key('ArrowRight');
  assert.equal(document.activeElement, first);
  key('End');
  assert.equal(document.activeElement, last);
  key('ArrowDown');
  assert.equal(document.activeElement, first);
  key('ArrowLeft');
  assert.equal(document.activeElement, trigger);
  assert.equal(trigger.getAttribute('aria-expanded'), 'false');
  key('ArrowRight');
  key('Escape');
  assert.equal(document.activeElement, trigger);
  key('Escape');
  assert.equal(document.activeElement, origin);
  assert.deepEqual(sent.filter(message => message.type === 'event').map(message => message.event), ['dismiss']);
});

for (const opening of ['client', 'server']) {
  test(`${opening}-opened menus retain submenu paths and keyboard position across renders`, t => {
    const { dom, receive, sent } = fixture();
    t.after(() => dom.window.close());
    const { document, KeyboardEvent, MouseEvent, HTMLElement } = dom.window;
    const popovers = new Set();
    HTMLElement.prototype.showPopover = function () { popovers.add(this); };
    HTMLElement.prototype.hidePopover = function () { popovers.delete(this); };
    receive({ type: 'hello', pages: [{ address: 'menu-refresh' }] });
    let generation = 0;
    const render = () => receive({ type: 'render', page: 'menu-refresh', generation: ++generation,
      bindings: { menu: ['dismiss'], last: ['activate'] }, submissions: {},
      tree: { type: 'page', cid: 'root', props: {}, children: [
        { type: 'group', cid: 'surface', props: { context_menu: 'actions' } },
        { type: 'group', cid: 'menu', props: { menu: 'context', key: 'actions', ...(opening === 'server' ? { open: true } : {}) }, children: [
          { type: 'button', cid: 'action', props: { label: 'Action' } },
          { type: 'group', cid: 'outer', props: { menu: 'submenu', label: 'Outer' }, children: [
            { type: 'group', cid: 'inner', props: { menu: 'submenu', label: 'Inner' }, children: [
              { type: 'radio_option', cid: 'first', props: { appearance: 'menu', group: 'g', label: 'First', checked: true } },
              { type: 'radio_option', cid: 'last', props: { appearance: 'menu', group: 'g', label: 'Last', checked: false } }
            ] }
          ] }
        ] }
      ] } });
    const trigger = cid => document.querySelector(`[data-cid="${cid}"] > .submenu-trigger`);
    const key = value => document.activeElement.dispatchEvent(new KeyboardEvent('keydown', { key: value, bubbles: true, cancelable: true }));
    render();
    if (opening === 'client') document.querySelector('[data-cid="surface"]').dispatchEvent(new MouseEvent('contextmenu', { bubbles: true }));
    key('ArrowDown');
    assert.equal(document.activeElement, trigger('outer'));
    // CI delivered a render between focusing the trigger and processing ArrowRight.
    // Trigger buttons are not form controls, so input-only focus preservation misses them.
    render();
    assert.equal(document.activeElement, trigger('outer'));
    key('ArrowRight');
    assert.equal(document.activeElement, trigger('inner'));
    key('ArrowRight');
    key('End');
    assert.equal(document.activeElement, document.querySelector('[data-cid="last"]'));
    // A second delivery must reopen the ancestor path before restoring nested focus.
    render();
    assert.equal(trigger('outer').getAttribute('aria-expanded'), 'true');
    assert.equal(trigger('inner').getAttribute('aria-expanded'), 'true');
    assert.equal(document.activeElement, document.querySelector('[data-cid="last"]'));
    const panel = document.activeElement.closest('.submenu-items');
    assert.equal(popovers.has(panel), true);
    assert.equal(panel.style.display, 'block');
    assert.equal(document.activeElement.tabIndex, 0);
    key('ArrowUp');
    assert.equal(document.activeElement, document.querySelector('[data-cid="first"]'));
    assert.equal(sent.filter(message => message.type === 'event').length, 0, 'restoration is not activation');
    key('Escape');
    assert.equal(document.activeElement, trigger('inner'));
    assert.equal(trigger('inner').getAttribute('aria-expanded'), 'false');
    assert.equal(trigger('outer').getAttribute('aria-expanded'), 'true');
  });
}

for (const change of ['close', 'remove', 'replace', 'disable-branch', 'remove-item']) {
  test(`menu restoration respects a server ${change} update`, t => {
    const { dom, receive, sent } = fixture();
    t.after(() => dom.window.close());
    const { document, KeyboardEvent } = dom.window;
    receive({ type: 'hello', pages: [{ address: 'menu-update' }] });
    const render = updated => receive({ type: 'render', page: 'menu-update', generation: updated ? 2 : 1,
      bindings: { menu: ['dismiss'], last: ['activate'] }, submissions: {},
      tree: { type: 'page', cid: 'root', props: {}, children: updated && change === 'remove' ? [] : [
        { type: 'group', cid: updated && change === 'replace' ? 'replacement' : 'menu',
          props: { menu: 'context', key: 'actions', open: !(updated && change === 'close') }, children: [
            { type: 'button', cid: 'action', props: { label: 'Action' } },
            { type: 'group', cid: 'branch', props: { menu: 'submenu', label: 'Branch', disabled: updated && change === 'disable-branch' }, children: [
              { type: 'button', cid: 'first', props: { label: 'First' } },
              ...(updated && change === 'remove-item' ? [] : [{ type: 'button', cid: 'last', props: { label: 'Last' } }])
            ] }
          ] }
      ] } });
    const key = value => document.activeElement.dispatchEvent(new KeyboardEvent('keydown', { key: value, bubbles: true, cancelable: true }));
    render(false);
    key('ArrowDown');
    key('ArrowRight');
    key('End');
    assert.equal(document.activeElement, document.querySelector('[data-cid="last"]'));
    render(true);
    const menu = document.querySelector('.webui-context-menu');
    if (change === 'remove') assert.equal(menu, null);
    else if (change === 'close') assert.equal(menu.style.display, 'none');
    else {
      const trigger = document.querySelector('.submenu-trigger');
      assert.equal(trigger.getAttribute('aria-expanded'), change === 'remove-item' ? 'true' : 'false');
      assert.equal(document.activeElement, document.querySelector(`[data-cid="${change === 'remove-item' ? 'first' : 'action'}"]`));
    }
    assert.equal(sent.filter(message => message.type === 'event').length, 0);
  });
}

for (const opening of ['client', 'server']) {
  for (const originType of ['button', 'text_input']) {
    test(`${opening}-opened menus restore the current ${originType} after page replacement`, t => {
      const { dom, receive } = fixture();
      t.after(() => dom.window.close());
      const { document, KeyboardEvent, MouseEvent } = dom.window;
      receive({ type: 'hello', pages: [{ address: 'focus-refresh' }] });
      const render = (generation, open) => receive({ type: 'render', page: 'focus-refresh', generation,
        bindings: { menu: ['dismiss'] }, submissions: {},
        tree: { type: 'page', cid: 'root', props: {}, children: [
          { type: originType, cid: 'origin', props: { label: 'Origin', ...(originType === 'text_input' ? { value: '' } : {}) } },
          { type: 'group', cid: 'surface', props: { context_menu: 'actions' } },
          { type: 'group', cid: 'menu', props: { menu: 'context', key: 'actions', ...(open === undefined ? {} : { open }) }, children: [
            { type: 'toggle', cid: 'choice', props: { appearance: 'menu', label: 'Choice', checked: false } }
          ] }
        ] } });
      const origin = () => originType === 'button' ? document.querySelector('[data-cid="origin"]') : document.querySelector('input');
      render(1, opening === 'server' ? false : undefined);
      const original = origin();
      original.focus();
      if (opening === 'client') {
        document.querySelector('[data-cid="surface"]').dispatchEvent(new MouseEvent('contextmenu', { bubbles: true }));
      } else {
        // The server requests opening in the same render that detaches the origin.
        render(2, true);
      }
      assert.equal(document.activeElement, document.querySelector('[data-cid="choice"]'));
      // Another render while the menu is focused must retain the original target,
      // rather than replacing it with the menu item or document.body.
      render(3, opening === 'server' ? true : undefined);
      assert.equal(original.isConnected, false);
      document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }));
      assert.equal(document.activeElement, origin());
      assert.notEqual(document.activeElement, original);
    });
  }
}

test('overlay alignment and pass-through are layer-local and disappear after a live reset', t => {
  const { dom, receive } = fixture(); t.after(() => dom.window.close());
  receive({ type: 'hello', pages: [{ address: 'overlay' }] });
  const render = (generation, passThrough) => receive({ type: 'render', page: 'overlay', generation,
    tree: { type: 'page', cid: 'root', props: {}, children: [{ type: 'overlay', cid: 'layers', props: {}, children: [
      { type: 'progress', cid: 'bar', props: { value: 0.5, pointer_events: true } },
      { type: 'text', cid: 'label', props: { content: '01:00', align: 'end', vertical_align: 'start' }, placement: { pass_through: passThrough } }
    ] }] } });
  render(1, true);
  let label = dom.window.document.querySelector('[data-cid="label"]');
  assert.equal(label.style.justifySelf, 'end');
  assert.equal(label.style.alignSelf, 'start');
  assert.equal(label.dataset.overlayPassThrough, 'true');
  assert.equal(dom.window.document.querySelector('[data-cid="bar"]').dataset.overlayPassThrough, undefined);
  render(2, false);
  label = dom.window.document.querySelector('[data-cid="label"]');
  assert.equal(label.dataset.overlayPassThrough, undefined);
});

test('button text children retain literal styling, live updates and one activation', t => {
  const { dom, receive, sent } = fixture(); t.after(() => dom.window.close());
  receive({ type: 'hello', pages: [{ address: 'dice' }] });
  const render = (generation, content, children = true) => receive({ type: 'render', page: 'dice', generation,
    bindings: { die: ['activate'] }, tree: { type: 'page', cid: 'root', props: {}, children: [
      { type: 'button', cid: 'die', props: { label: 'Fallback' }, children: children ? [
        { type: 'text', cid: 'face', slot: 'content', props: { content, font_style: 'italic' } }
      ] : [] }
    ] } });
  render(1, '<six>');
  let button = dom.window.document.querySelector('button');
  assert.equal(button.textContent, '<six>');
  assert.equal(button.querySelector('[data-cid="face"]').style.fontStyle, 'italic');
  assert.equal(button.querySelector('six'), null);
  button.querySelector('[data-cid="face"]').click();
  assert.equal(sent.filter(message => message.event === 'activate').length, 1);
  render(2, 'Five');
  assert.equal(dom.window.document.querySelector('button').textContent, 'Five');
  render(3, '', false);
  assert.equal(dom.window.document.querySelector('button').textContent, 'Fallback');
});

test('button pointer presses retain activation and ignore disabled presses', t => {
  const { dom, receive, sent } = fixture(); t.after(() => dom.window.close());
  receive({ type: 'hello', pages: [{ address: 'buttons' }] });
  const render = (generation, disabled) => receive({ type: 'render', page: 'buttons', generation,
    bindings: { action: ['pointer_press', 'activate'] }, tree: { type: 'page', cid: 'root', props: {}, children: [
      { type: 'button', cid: 'action', props: { pointer_events: true, label: 'Customize', disabled } }
    ] } });
  render(1, false);
  let button = dom.window.document.querySelector('button');
  button.dispatchEvent(new dom.window.MouseEvent('pointerdown', { bubbles: true, button: 2, clientX: 4, clientY: 8 }));
  const press = sent.filter(message => message.event === 'pointer_press');
  assert.equal(press.length, 1);
  assert.equal(press[0].payload.button, 3);
  assert.equal(press[0].payload.x, 4);
  button.click();
  assert.equal(sent.filter(message => message.event === 'activate').length, 1);
  render(2, true);
  button = dom.window.document.querySelector('button');
  button.dispatchEvent(new dom.window.MouseEvent('pointerdown', { bubbles: true, button: 0 }));
  button.click();
  assert.equal(sent.filter(message => message.event === 'pointer_press').length, 1);
  assert.equal(sent.filter(message => message.event === 'activate').length, 1);
});

test('progress pointer presses reuse the bounded event payload and suppress the browser menu', t => {
  const { dom, receive, sent } = fixture(); t.after(() => dom.window.close());
  receive({ type: 'hello', pages: [{ address: 'progress' }] });
  receive({ type: 'render', page: 'progress', generation: 1, bindings: { bar: ['pointer_press'] },
    tree: { type: 'page', cid: 'root', props: {}, children: [
      { type: 'progress', cid: 'bar', props: { pointer_events: true, value: 0.5 } }
    ] } });
  const bar = dom.window.document.querySelector('progress');
  bar.dispatchEvent(new dom.window.MouseEvent('pointerdown', { bubbles: true, button: 2, clientX: 4, clientY: 8 }));
  const events = sent.filter(message => message.event === 'pointer_press');
  assert.equal(events.length, 1);
  assert.equal(events[0].cid, 'bar');
  assert.equal(events[0].payload.button, 3);
  const menu = new dom.window.MouseEvent('contextmenu', { bubbles: true, cancelable: true });
  bar.dispatchEvent(menu);
  assert.equal(menu.defaultPrevented, true);
});

test('nested pointer surfaces send one viewport event for the nearest enabled surface', t => {
  const { dom, receive, sent } = fixture();
  t.after(() => dom.window.close());
  receive({ type: 'hello', pages: [{ address: 'pointer' }] });
  receive({ type: 'render', page: 'pointer', generation: 1,
    bindings: { root: ['pointer_press'], label: ['pointer_press'] }, submissions: {},
    tree: { type: 'page', cid: 'root', props: { pointer_events: true }, children: [
      { type: 'text', cid: 'label', props: { pointer_events: true, content: 'Choose' } }
    ] } });
  dom.window.document.querySelector('[data-cid="label"]').dispatchEvent(new dom.window.MouseEvent('pointerdown', {
    bubbles: true, clientX: 32, clientY: 48, button: 2, ctrlKey: true
  }));
  const events = sent.filter(message => message.event === 'pointer_press');
  assert.equal(events.length, 1);
  assert.equal(events[0].cid, 'label');
  assert.equal(events[0].payload.x, 32);
  assert.equal(events[0].payload.y, 48);
  assert.equal(events[0].payload.button, 3);
  assert.equal(events[0].payload.state, 4);
});


test('disabled menu containers make their action descendants inert', t => {
  const { dom, page } = fixture();
  t.after(() => dom.window.close());
  const menu = dom.window.LichWebUI.render(page, { type: 'group', cid: 'disabled-menu',
    props: { menu: 'context', key: 'disabled', disabled: true }, children: [
      { type: 'button', cid: 'action', props: { label: 'Unavailable' } }
    ] });
  assert.equal(menu.inert, true);
});

test('live input retains newer typing and caret through an older reply, then accepts a script reset', t => {
  const { dom, sent, receive } = fixture(); t.after(() => dom.window.close());
  const { document, Event } = dom.window;
  receive({ type: 'hello', pages: [{ address: 'live-search' }] });
  const render = (generation, value, request = 0) => receive({ type: 'render', page: 'live-search', generation,
    input_requests: { query: request }, bindings: { query: ['change'] }, tree: {
      type: 'page', cid: 'root', props: {}, children: [
        { type: 'text_input', cid: 'query', props: { value, change_mode: 'input' } }
      ]
    } });
  const input = () => document.querySelector('input');
  const type = value => {
    input().value = value; input().setSelectionRange(value.length, value.length);
    input().dispatchEvent(new Event('input'));
    return sent.at(-1);
  };
  render(1, ''); input().focus();
  const first = type('Drea'), latest = type('Dreaven');
  render(2, 'Drea', first.request);
  assert.equal(input().value, 'Dreaven');
  assert.equal(input().selectionStart, 7);
  assert.equal(document.activeElement, input());
  receive({ type: 'refusal', reason: 'stale_generation', page: 'live-search', cid: 'query', event: 'change', request: first.request });
  render(2, 'Drea', first.request);
  assert.equal(sent.filter(message => message.event === 'change').length, 2, 'never replay superseded input');
  assert.equal(document.querySelectorAll('.notification').length, 0, 'superseded input is not a user-visible failure');
  receive({ type: 'refusal', reason: 'stale_generation', page: 'live-search', cid: 'query', event: 'change', request: latest.request });
  render(2, 'Drea', first.request);
  const retry = sent.at(-1);
  assert.equal(retry.payload.value, 'Dreaven');
  assert.equal(retry.generation, 2);
  render(3, '', retry.request);
  assert.equal(input().value, '', 'an acknowledged callback may deliberately clear the field');
});

test('automatic columns fit their allocation independently of long cells while authored and dragged widths survive', async t => {
  const { dom, page } = fixture(); t.after(() => dom.window.close());
  const { document, KeyboardEvent } = dom.window;
  let resize, available = 0;
  dom.window.ResizeObserver = class { constructor(callback) { resize = callback; } observe() {} disconnect() {} };
  const longText = 'long tag '.repeat(200);
  const table = dom.window.LichWebUI.render(page, { type: 'table', cid: 'bounded', props: {
    columns: [{ key: 'fixed', label: 'Fixed', width: 120, resizable: true },
      { key: 'zero', label: 'Zero', width: 0, resizable: true },
      { key: 'tags', label: 'Tags', resizable: true }],
    rows: [{ key: 'one', cells: { fixed: 'Name', zero: 'Value', tags: longText } }]
  } });
  Object.defineProperty(table, 'clientWidth', { get: () => available });
  document.body.append(table);
  const cols = [...table.querySelectorAll('col')];
  [...table.querySelectorAll('th')].forEach((heading, index) => {
    heading.firstElementChild.getBoundingClientRect = () => ({ width: 40 });
    heading.getBoundingClientRect = () => ({ width: parseFloat(cols[index].style.width) || 0 });
  });
  await new Promise(resolve => dom.window.requestAnimationFrame(resolve));
  assert.equal(cols[2].style.width, '', 'a hidden table must wait for allocation');
  available = 300; resize();
  assert.deepEqual(cols.map(col => parseFloat(col.style.width)), [120, 90, 90]);
  assert.equal(table.querySelector('table').style.width, '300px');
  assert.equal(table.querySelector('td:last-child').title, longText, 'clipping retains the complete literal cell text');
  available = 500; resize();
  assert.deepEqual(cols.map(col => parseFloat(col.style.width)), [120, 190, 190]);
  table.querySelector('th:last-child .webui-column-resize').dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowRight' }));
  assert.deepEqual(cols.map(col => parseFloat(col.style.width)), [120, 190, 200]);
  available = 300; resize();
  assert.equal(table.querySelector('table').style.width, '510px', 'explicit viewer sizing is not silently compressed');
});


test('single-line read-only inputs retain focus and do not emit client edits', t => {
  const { dom, page, sent } = fixture(); t.after(() => dom.window.close());
  page.bindings.readonly = ['change', 'focus'];
  const wrapper = dom.window.LichWebUI.render(page, { type: 'text_input', cid: 'readonly', props: {
    value: 'Profile', read_only: true, change_mode: 'input'
  } });
  dom.window.document.body.append(wrapper);
  const input = wrapper.querySelector('input');
  assert.equal(input.readOnly, true);
  input.focus();
  assert.equal(dom.window.document.activeElement, input);
  input.dispatchEvent(new dom.window.Event('input'));
  assert.equal(sent.filter(message => message.event === 'change').length, 0);
  assert.equal(sent.filter(message => message.event === 'focus').length, 1);
});

test('textarea blur delivers the latest value separately from changes and ignores focus restoration', t => {
  const { dom, page, sent } = fixture(); t.after(() => dom.window.close());
  page.bindings.text = ['change', 'blur'];
  const wrapper = dom.window.LichWebUI.render(page, { type: 'textarea', cid: 'text', props: { value: '' } });
  const input = wrapper.querySelector('textarea');
  input.value = 'Latest\ntext';
  input.dispatchEvent(new dom.window.Event('input'));
  input.dispatchEvent(new dom.window.Event('blur'));
  assert.deepEqual(sent.map(message => message.event), ['change', 'blur']);
  assert.equal(sent.at(-1).payload.value, 'Latest\ntext');
  page.restoringFocus = true;
  input.dispatchEvent(new dom.window.Event('blur'));
  assert.equal(sent.length, 2);
});

test('Markdown anchor titles remain literal and cannot introduce HTML', t => {
  const { dom, page } = fixture(); t.after(() => dom.window.close());
  const wrapper = dom.window.LichWebUI.render(page, { type: 'markdown', cid: 'help', props: {
    content: '[Help](https://example.org/help "<img src=x> & a title")'
  } });
  assert.equal(wrapper.querySelector('a').title, '<img src=x> & a title');
  assert.equal(wrapper.querySelector('a').href, 'https://example.org/help');
  assert.equal(wrapper.querySelector('img'), null);
});

test('named cursor hints update and reset on the same page and child controls', t => {
  const f = fixture();
  t.after(() => f.dom.window.close());
  f.receive({ type: 'hello', pages: [{ address: 'main', title: 'Cursor hints' }] });
  const render = (generation, hint) => f.receive({ type: 'render', page: 'main', generation,
    tree: { type: 'page', cid: 'page', props: { title: 'Cursor hints', ...(hint ? { cursor_hint: hint } : {}) }, children: [
      { type: 'button', cid: 'page/b', props: { label: 'Nested', cursor_hint: 'pointer' }, children: [] }
    ] } });
  render(1, 'cell');
  let root = f.dom.window.document.querySelector('[data-cid="page"]');
  assert.equal(root.style.getPropertyValue('--webui-cursor-hint'), 'cell');
  assert.equal(f.dom.window.document.querySelector('[data-cid="page/b"]').style.getPropertyValue('--webui-cursor-hint'), 'pointer');
  render(2, 'copy');
  root = f.dom.window.document.querySelector('[data-cid="page"]');
  assert.equal(root.style.getPropertyValue('--webui-cursor-hint'), 'copy');
  render(3, null);
  root = f.dom.window.document.querySelector('[data-cid="page"]');
  assert.equal(root.dataset.cursorHint, undefined);
  assert.equal(root.style.getPropertyValue('--webui-cursor-hint'), '');
});

test('nested container sensitivity and window visibility preserve authored settings and input drafts', t => {
  const { dom, receive, sent } = fixture(); t.after(() => dom.window.close());
  const { document, Event } = dom.window;
  receive({ type: 'hello', pages: [{ address: 'controls' }] });
  const render = (generation, disabled, hidden = false) => receive({ type: 'render', page: 'controls', generation,
    bindings: { edit: ['change'], action: ['activate'] },
    tree: { type: 'page', cid: 'root', props: { presentation: { hidden } }, children: [
      { type: 'stack', cid: 'parent', props: { disabled }, children: [
        { type: 'grid', cid: 'nested', props: { columns: 2 }, children: [
          { type: 'text_input', cid: 'edit', props: { value: 'Initial' } },
          { type: 'button', cid: 'action', props: { label: 'Action' } },
          { type: 'button', cid: 'local', props: { label: 'Local disabled', disabled: true } }
        ] }
      ] }
    ] } });
  render(1, false);
  document.querySelector('input').value = 'Retained draft';
  render(2, true);
  assert.equal(document.querySelector('input').disabled, true);
  document.querySelector('[data-cid="action"]').dispatchEvent(new Event('click', { bubbles: true }));
  assert.equal(sent.filter(message => message.event === 'activate').length, 0);
  render(3, false, true);
  assert.equal(document.querySelector('.webui-page').hidden, true);
  render(4, false);
  assert.equal(document.querySelector('.webui-page').hidden, false);
  assert.equal(document.querySelector('input').value, 'Retained draft');
  assert.equal(document.querySelector('input').disabled, false);
  assert.equal(document.querySelector('[data-cid="local"]').disabled, true);
  document.querySelector('[data-cid="action"]').click();
  assert.equal(sent.filter(message => message.event === 'activate').length, 1);
});

for (const restriction of ['disabled', 'hidden']) {
  test(`${restriction} controls retain lifecycle notifications while ordinary interactions stay blocked`, t => {
    const { dom, receive, sent } = fixture(); t.after(() => dom.window.close());
    const { document, Event, MouseEvent } = dom.window;
    receive({ type: 'hello', pages: [{ address: 'lifecycle' }] });
    receive({ type: 'render', page: 'lifecycle', generation: 1,
      bindings: { field: ['focus', 'change'], notes: ['blur', 'change'], surface: ['pointer_press'], action: ['activate'] },
      tree: { type: 'page', cid: 'root', props: { disabled: restriction === 'disabled',
        presentation: { hidden: restriction === 'hidden' } }, children: [
        { type: 'text_input', cid: 'field', props: { value: '', change_mode: 'input' } },
        { type: 'textarea', cid: 'notes', props: { value: 'Retained' } },
        { type: 'group', cid: 'surface', props: { pointer_events: true }, children: [] },
        { type: 'button', cid: 'action', props: { label: 'Action' } }
      ] } });
    const field = document.querySelector('input'), notes = document.querySelector('textarea');
    // Programmatic events exercise notification delivery even when browser input
    // is suppressed by disabled/inert/hidden presentation.
    field.dispatchEvent(new Event('focus'));
    field.dispatchEvent(new Event('input'));
    notes.dispatchEvent(new Event('blur'));
    document.querySelector('[data-cid="surface"]').dispatchEvent(new MouseEvent('pointerdown', { bubbles: true, button: 0 }));
    document.querySelector('[data-cid="action"]').dispatchEvent(new Event('click'));
    assert.deepEqual(sent.filter(message => message.type === 'event').map(message => message.event), ['focus', 'blur', 'pointer_press']);
    assert.equal(sent.find(message => message.event === 'blur').payload.value, 'Retained');
  });

  test(`an open context menu still dismisses after becoming ${restriction}`, t => {
    const { dom, receive, sent } = fixture(); t.after(() => dom.window.close());
    const { document, MouseEvent } = dom.window;
    receive({ type: 'hello', pages: [{ address: 'menu-lifecycle' }] });
    const render = changed => receive({ type: 'render', page: 'menu-lifecycle', generation: changed ? 2 : 1,
      bindings: { menu: ['dismiss'], action: ['activate'] },
      tree: { type: 'page', cid: 'root', props: { presentation: { hidden: changed && restriction === 'hidden' } }, children: [
        { type: 'group', cid: 'menu', props: { menu: 'context', key: 'actions', open: true,
          disabled: changed && restriction === 'disabled' }, children: [
          { type: 'button', cid: 'action', props: { label: 'Action' } }
        ] }
      ] } });
    render(false);
    render(true);
    assert.equal(document.querySelector('.webui-context-menu').style.display, 'block');
    document.body.dispatchEvent(new MouseEvent('pointerdown', { bubbles: true }));
    assert.equal(document.querySelector('.webui-context-menu').style.display, 'none');
    assert.deepEqual(sent.filter(message => message.type === 'event').map(message => message.event), ['dismiss']);
  });
}


test('scroll allocation retains a requested viewport minimum in fixed and expanding layouts', () => {
  const { dom, page } = fixture();
  for (const fill of [false, true]) {
    const element = dom.window.LichWebUI.render(page, {
      type: 'scroll', cid: 'minimum', props: { height: 75, min_height: 535, fill }, children: []
    });
    assert.equal(element.style.minHeight, '535px');
    assert.equal(element.style.height, fill ? '0px' : '75px');
  }
  const reset = dom.window.LichWebUI.render(page, {
    type: 'scroll', cid: 'reset', props: { min_height: 0, fill: true }, children: []
  });
  assert.equal(reset.style.minHeight, '0px');
  dom.window.close();
});


test('same-page text row drags send identities only and ignore foreign or cancelled drops', t => {
  const { dom, receive, sent } = fixture(); t.after(() => dom.window.close());
  receive({ type: 'hello', pages: [{ address: 'spells' }] });
  receive({ type: 'render', page: 'spells', generation: 1, bindings: { target: ['row_drop'] }, tree: {
    type: 'page', cid: 'root', props: {}, children: [
      { type: 'table', cid: 'source', props: { transfer_group: 'gtk-string-move', columns: [{ key: 'name', label: 'Spell' }],
        rows: [{ key: '102', cells: { name: 'Spirit Barrier' } }] } },
      { type: 'table', cid: 'target', props: { transfer_group: 'gtk-string-move', columns: [{ key: 'other', label: 'Cast' }], rows: [] } }
    ] }
  });
  const row = dom.window.document.querySelector('[data-cid="source"] tbody tr');
  const target = dom.window.document.querySelector('[data-cid="target"]');
  const data = new Map();
  const transfer = { setData: (key, value) => data.set(key, value), getData: key => data.get(key) || '' };
  function event(type, element) {
    const e = new dom.window.Event(type, { bubbles: true, cancelable: true });
    Object.defineProperty(e, 'dataTransfer', { value: transfer });
    element.dispatchEvent(e);
  }
  event('dragstart', row);
  assert.equal(transfer.effectAllowed, 'move');
  assert.deepEqual(JSON.parse(data.get('application/x-lich-row')), { page: 'spells', group: 'gtk-string-move', source: 'source', row: '102' });
  event('dragend', row);
  assert.equal(sent.filter(message => message.event === 'row_drop').length, 0);
  const original = data.get('application/x-lich-row');
  data.set('application/x-lich-row', JSON.stringify({ page: 'foreign', group: 'gtk-string-move', source: 'source', row: '102' }));
  event('drop', target);
  assert.equal(sent.filter(message => message.event === 'row_drop').length, 0);
  data.set('application/x-lich-row', original);
  event('drop', target);
  assert.deepEqual(sent.filter(message => message.event === 'row_drop').map(message => message.payload), [{ source: 'source', row: '102' }]);
});

test('table pointer notifications distinguish normal presses and double presses', t => {
  const { dom, receive, sent } = fixture(); t.after(() => dom.window.close());
  receive({ type: 'hello', pages: [{ address: 'pointer-table' }] });
  receive({ type: 'render', page: 'pointer-table', generation: 1, bindings: { table: ['pointer_press'] }, tree: {
    type: 'page', cid: 'root', props: {}, children: [{ type: 'table', cid: 'table', props: {
      pointer_events: true, columns: [{ key: 'name', label: 'Spell' }], rows: [{ key: '102', cells: { name: 'Barrier' } }]
    } }]
  } });
  const cell = dom.window.document.querySelector('tbody td');
  for (const type of ['pointerdown', 'dblclick']) {
    cell.dispatchEvent(new dom.window.MouseEvent(type, { bubbles: true, button: 0 }));
  }
  assert.deepEqual(sent.filter(message => message.event === 'pointer_press').map(message => message.payload.click_count), [1, 2]);
});

test('table pointer callbacks cannot replace a row while its drag gesture is active', async t => {
  const { dom, receive } = fixture(); t.after(() => dom.window.close());
  receive({ type: 'hello', pages: [{ address: 'drag-held' }] });
  function render(generation, name) {
    receive({ type: 'render', page: 'drag-held', generation, bindings: { table: ['pointer_press'] }, tree: {
      type: 'page', cid: 'root', props: {}, children: [{ type: 'table', cid: 'table', props: {
        transfer_group: 'gtk-string-move', pointer_events: true, columns: [{ key: 'name', label: 'Spell' }],
        rows: [{ key: '102', cells: { name } }]
      } }]
    } });
  }
  render(1, 'Barrier');
  const row = dom.window.document.querySelector('tbody tr');
  row.dispatchEvent(new dom.window.MouseEvent('pointerdown', { bubbles: true, button: 0 }));
  render(2, 'Updated');
  assert.equal(row.isConnected, true, 'the drag source survives callback renders');
  row.dispatchEvent(new dom.window.Event('dragend', { bubbles: true }));
  await new Promise(resolve => dom.window.setTimeout(resolve, 5));
  assert.equal(row.isConnected, false);
  assert.equal(dom.window.document.querySelector('tbody tr').textContent, 'Updated');
});

test('palette popovers open locally, retain a callback render, and dismiss with Escape or outside press', t => {
  const a = fixture(), b = fixture();
  t.after(() => { a.dom.window.close(); b.dom.window.close(); });
  const tree = { type: 'page', cid: 'root', props: {}, children: [{ type: 'group', cid: 'palette', props: {
    menu: 'popover', menu_position: 'top', menu_icon: true, label: 'Palette'
  }, children: [{ type: 'text', cid: 'icon', props: { content: '\u{1f3a8}' } }, { type: 'stack', cid: 'panel', props: {}, children: [
    { type: 'button', cid: 'choice', props: { label: 'Dark' } }
  ] }] }] };
  const draw = (f, generation) => f.receive({ type: 'render', page: 'palettes', generation, tree, bindings: { choice: ['activate'] } });
  for (const f of [a, b]) { f.receive({ type: 'hello', pages: [{ address: 'palettes' }] }); draw(f, 1); }
  const { document, KeyboardEvent, Event } = a.dom.window;
  let trigger = document.querySelector('.submenu-trigger');
  assert.equal(trigger.textContent, '\u{1f3a8}');
  trigger.getBoundingClientRect = () => ({ left: 30, right: 60, top: 90, bottom: 110 });
  document.querySelector('.submenu-items').getBoundingClientRect = () => ({ width: 100, height: 50 });
  trigger.click();
  assert.equal(document.querySelector('.submenu-items').style.top, '40px');
  assert.equal(trigger.getAttribute('aria-expanded'), 'true');
  assert.equal(b.dom.window.document.querySelector('.submenu-trigger').getAttribute('aria-expanded'), 'false');
  document.querySelector('[data-cid="choice"]').click();
  assert.equal(a.sent.filter(message => message.event === 'activate').length, 1);
  draw(a, 2);
  trigger = document.querySelector('.submenu-trigger');
  assert.equal(trigger.getAttribute('aria-expanded'), 'true', 'callback rerender retains this viewer panel');
  trigger.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
  assert.equal(trigger.getAttribute('aria-expanded'), 'false');
  assert.equal(document.activeElement, trigger);
  trigger.click();
  document.body.dispatchEvent(new Event('pointerdown', { bubbles: true }));
  assert.equal(trigger.getAttribute('aria-expanded'), 'false');
  assert.equal(a.sent.filter(message => message.event === 'activate').length, 1, 'open/close never synthesizes script actions');
});

for (const gesture of ['click', 'ArrowRight']) {
  test(`closing a palette through sibling ${gesture} does not reopen it on render`, t => {
    const { dom, receive, sent } = fixture(); t.after(() => dom.window.close());
    const tree = { type: 'page', cid: 'root', props: {}, children: [
      { type: 'group', cid: 'palette', props: { menu: 'popover', label: 'Palette' }, children: [
        { type: 'text', cid: 'color', props: { content: 'Color' } }
      ] },
      { type: 'group', cid: 'branch', props: { menu: 'submenu', label: 'Branch' }, children: [
        { type: 'button', cid: 'action', props: { label: 'Action' } }
      ] }
    ] };
    receive({ type: 'hello', pages: [{ address: 'palettes' }] });
    const draw = generation => receive({ type: 'render', page: 'palettes', generation, tree, bindings: {} });
    const palette = () => dom.window.document.querySelector('[data-cid="palette"] > button');
    draw(1);
    palette().click();
    const sibling = dom.window.document.querySelector('[data-cid="branch"] > button');
    // Neither keyboard activation nor a programmatic click fires pointerdown.
    if (gesture === 'click') sibling.click();
    else sibling.dispatchEvent(new dom.window.KeyboardEvent('keydown', { key: gesture, bubbles: true }));
    assert.equal(palette().getAttribute('aria-expanded'), 'false');
    draw(2);
    assert.equal(palette().getAttribute('aria-expanded'), 'false', 'a closed palette must stay closed after redraw');
    palette().click();
    draw(3);
    assert.equal(palette().getAttribute('aria-expanded'), 'true', 'an explicitly reopened palette remains open');
    assert.equal(sent.filter(message => message.type === 'event').length, 0);
  });
}

test('flow grids fit natural child widths below their maximum and preserve insertion order', async t => {
  const { dom, receive } = fixture(); t.after(() => dom.window.close());
  receive({ type: 'hello', pages: [{ address: 'flow' }] });
  receive({ type: 'render', page: 'flow', generation: 1, tree: { type: 'page', cid: 'root', props: {}, children: [
    { type: 'grid', cid: 'flow-grid', props: { flow: true, cols: 3, homogeneous: false, gap: 0, column_gap: 10 }, children:
      ['A', 'B', 'C', 'D'].map((content, i) => ({ type: 'text', cid: `c${i}`, props: { content } })) }
  ] } });
  const grid = dom.window.document.querySelector('.webui-grid');
  let available = 230;
  Object.defineProperty(grid, 'clientWidth', { get: () => available });
  [...grid.children].forEach(child => {
    child.style.width = '45px';
    child.getBoundingClientRect = () => {
      assert.ok([...grid.children].every(cell => cell.style.width === 'max-content'), 'batch all width writes before reading layout');
      return { width: 100, height: 20 };
    };
  });
  await new Promise(resolve => dom.window.setTimeout(resolve, 25));
  assert.equal(grid.style.gridTemplateColumns, 'repeat(2, max-content)');
  assert.deepEqual([...grid.children].map(child => child.textContent), ['A', 'B', 'C', 'D']);
  assert.equal(grid.children[0].style.gridRow, '', 'automatic flow does not retain explicit row spans');
  available = 500; dom.window.dispatchEvent(new dom.window.Event('resize'));
  assert.equal(grid.style.gridTemplateColumns, 'repeat(3, max-content)', 'maximum remains authoritative');
  available = 40; dom.window.dispatchEvent(new dom.window.Event('resize'));
  assert.equal(grid.style.gridTemplateColumns, 'repeat(1, max-content)', 'one oversized child stays scrollable');
  assert.equal(grid.style.columnGap, '10px');
  assert.ok([...grid.children].every(cell => cell.style.width === '45px'), 'restore authored widths after measuring');
});

for (const alignment of ['start', 'center', 'end', 'stretch']) {
  test(`single-child scroller allocates ${alignment} on the vertical grid axis`, t => {
    const { dom, receive } = fixture(); t.after(() => dom.window.close());
    receive({ type: 'hello', pages: [{ address: 'alignment' }] });
    const draw = (generation, vertical) => receive({ type: 'render', page: 'alignment', generation, tree: {
      type: 'page', cid: 'root', props: {}, children: [{ type: 'scroll', cid: 'viewport', props: { fill: true }, children: [
        { type: 'stack', cid: 'content', props: { fill: true, vertical_align: vertical }, children: [
          { type: 'text', cid: 'row', props: { content: 'Content remains reachable' } }
        ] }
      ] }]
    } });
    draw(1, alignment);
    let viewport = dom.window.document.querySelector('[data-cid="viewport"]');
    let content = dom.window.document.querySelector('[data-cid="content"]');
    assert.equal(viewport.style.display, 'grid');
    assert.equal(viewport.style.gridTemplateRows, 'minmax(min-content, 1fr)', 'overflow grows the row rather than centering above its scroll origin');
    assert.equal(viewport.style.gridTemplateColumns, 'minmax(0, 1fr)');
    assert.equal(content.style.alignSelf, alignment);
    assert.equal(content.style.height, 'auto', 'a filling stack must not collapse to zero in the grid');
    draw(2, undefined);
    viewport = dom.window.document.querySelector('[data-cid="viewport"]');
    content = dom.window.document.querySelector('[data-cid="content"]');
    assert.equal(viewport.style.display, '', 'live reset restores the ordinary scroller');
    assert.equal(content.style.alignSelf, '');
    assert.equal(content.style.height, '0px');
  });
}

for (const completion of ['dragend', 'drop', 'blur']) {
  test(`native row drag survives pointercancel until ${completion}`, async t => {
    const { dom, receive } = fixture(); t.after(() => dom.window.close());
    receive({ type: 'hello', pages: [{ address: 'models' }] });
    modelTable(receive, 1, { transfer_group: 'spells', rows: [{ key: 'barrier', cells: { name: 'Spirit Barrier' } }] });
    const row = dom.window.document.querySelector('tbody tr');
    row.dispatchEvent(new dom.window.Event('pointerdown', { bubbles: true }));
    const drag = new dom.window.Event('dragstart', { bubbles: true });
    drag.dataTransfer = { setData() {} };
    row.dispatchEvent(drag);
    // Chrome hands the pointer to HTML drag-and-drop by cancelling its pointer stream.
    row.dispatchEvent(new dom.window.Event('pointercancel', { bubbles: true }));
    modelTable(receive, 2, { transfer_group: 'spells', rows: [{ key: 'barrier', cells: { name: 'Updated' } }] });
    await new Promise(resolve => dom.window.setTimeout(resolve, 10));
    assert.equal(row.isConnected, true, 'a native drag still owns this exact DOM source');
    (completion === 'blur' ? dom.window : row).dispatchEvent(new dom.window.Event(completion, { bubbles: true }));
    await new Promise(resolve => dom.window.setTimeout(resolve, 10));
    assert.equal(row.isConnected, false);
    assert.equal(dom.window.document.querySelector('tbody tr').textContent, 'Updated');
  });
}

test('a delayed release from the previous gesture cannot clear a new pointer hold', async t => {
  const { dom, receive } = fixture(); t.after(() => dom.window.close());
  receive({ type: 'hello', pages: [{ address: 'models' }] });
  modelTable(receive, 1, { rows: [{ key: 'a', cells: { name: 'Before' } }] });
  const row = dom.window.document.querySelector('tbody tr');
  row.dispatchEvent(new dom.window.Event('pointerdown', { bubbles: true }));
  row.dispatchEvent(new dom.window.Event('pointerup', { bubbles: true }));
  row.dispatchEvent(new dom.window.Event('pointerdown', { bubbles: true }));
  modelTable(receive, 2, { rows: [{ key: 'a', cells: { name: 'After' } }] });
  await new Promise(resolve => dom.window.setTimeout(resolve, 10));
  assert.equal(row.isConnected, true);
  row.dispatchEvent(new dom.window.Event('pointerup', { bubbles: true }));
  await new Promise(resolve => dom.window.setTimeout(resolve, 10));
  assert.equal(row.isConnected, false);
  assert.equal(dom.window.document.querySelector('tbody tr').textContent, 'After');
});
