// DOM unit checks, independent of a browser or live account. Uses the owner's
// existing jsdom installation, resolved through NODE_PATH; installs nothing.
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
