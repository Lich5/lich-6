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
