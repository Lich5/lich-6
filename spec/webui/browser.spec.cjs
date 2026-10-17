const { test, expect } = require('@playwright/test');

// Ruby owns the service and verifies the resulting script-side state. Each run
// starts with a fresh browser cookie jar and the actual private file bootstrap.
const scenario = process.env.WEBUI_TEST_SCENARIO;

// Compact websocket/console record, printed only when the test fails. Traces
// do not capture websocket frames, so without this a lost event (for example a
// Close that never reaches the server) leaves no evidence in CI.
const wire = [];
const wireStart = Date.now();
function record(direction, data) {
  const raw = String(data).slice(0, 200);
  let summary = raw;
  // Only websocket frames are condensed; console text is kept as written.
  if (direction !== 'console') {
    try {
      const message = JSON.parse(data);
      summary = ['type', 'event', 'cid', 'page', 'generation', 'request', 'reason']
        .filter(key => message[key] !== undefined)
        .map(key => `${key}=${typeof message[key] === 'string' ? message[key].slice(0, 40) : message[key]}`)
        .join(' ') || raw;
    } catch (_error) { /* non-JSON frame: keep the truncated text */ }
  }
  wire.push(`${String(Date.now() - wireStart).padStart(6)}ms ${direction} ${summary}`);
  if (wire.length > 200) wire.shift();
}

test.afterEach(async ({}, testInfo) => {
  if (testInfo.status === testInfo.expectedStatus) return;
  const body = wire.join('\n');
  console.log(`WebUI wire log (${scenario}, last ${wire.length} entries):\n${body}`);
  await testInfo.attach('webui-wire.log', { body, contentType: 'text/plain' });
});

test(`WebUI ${scenario || 'missing fixture'}`, async ({ page, context }) => {
  page.on('websocket', socket => {
    socket.on('framesent', frame => record('->', frame.payload));
    socket.on('framereceived', frame => record('<-', frame.payload));
    socket.on('close', () => record('--', 'socket closed'));
  });
  page.on('console', message => record('console', `${message.type()}: ${message.text()}`));
  const target = process.env.WEBUI_TEST_URL;
  expect(target, 'Run through the browser-tagged RSpec fixtures').toMatch(/^file:\/\//);
  expect(['priority15-notebook', 'priority15-log-style', 'priority15-followup', 'priority15-tree-text', 'buttonbox-empty-id', 'frame-scroller', 'three-compatibility', 'priority14-controls', 'priority11-labels', 'native-bmp', 'shim-layout', 'shim-fixed-events-focus', 'shim-abyssx', 'shim-compass', 'shim-eloot-stance', 'shim-gemstonev-difficulty', 'shim-scheduled-visibility', 'shim-repository-scheduling', 'shim-sail2-scheduling', 'shim-geometry-cursors', 'native-progress-sizing', 'shim-manatimer', 'shim-tpick-information', 'shim-tpick-settings', 'shim-headerbar', 'shim-tpick-welcome', 'shim-entry', 'shim-separator', 'shim-controls', 'shim-progress-style', 'shim-models', 'shim-builder', 'shim-ewaggle', 'shim-ebounty', 'shim-eherbs', 'shim-blackarts', 'shim-eloot-corrected', 'shim-bigshot-corrected', 'shim-repository', 'shim-go2', 'shim-huntplan', 'native-bootstrap']).toContain(scenario);
  const errors = [];
  const documents = [];
  page.on('pageerror', error => errors.push(error.message));
  page.on('response', response => {
    if (response.request().resourceType() === 'document') documents.push(response);
  });
  if (scenario === 'shim-manatimer') {
    // Chrome verifies the existing presentation request; native host behavior is
    // checked separately in the actual macOS WebKit window.
    await page.addInitScript(() => {
      window.fixturePresentation = {};
      window.lichNativeWindow = { present: props => { window.fixturePresentation = props; } };
    });
  }
  if (scenario === 'shim-builder') {
    // Redeliver an accepted tree on demand to force the CI focus/Enter race.
    // This fixture hook changes neither the production protocol nor callbacks.
    await page.addInitScript(() => {
      const NativeWebSocket = window.WebSocket;
      window.WebSocket = class extends NativeWebSocket {
        constructor(...args) {
          super(...args);
          this.addEventListener('message', event => {
            let message;
            try { message = JSON.parse(event.data); } catch { return; }
            if (message.type === 'render') {
              window.fixtureRedraw = () => this.dispatchEvent(new MessageEvent('message', { data: event.data }));
            }
          });
        }
      };
    });
  }
  if (scenario === 'shim-ewaggle') {
    // Capture the actual native drag source, not a locator resolved before a redraw.
    await page.addInitScript(() => {
      // Observe reassembled messages; Playwright's frame events can contain only
      // part of a valid JSON message when the transport fragments large renders.
      const NativeWebSocket = window.WebSocket;
      window.WebSocket = class extends NativeWebSocket {
        constructor(...args) {
          super(...args);
          this.addEventListener('message', event => {
            let message;
            try { message = JSON.parse(event.data); } catch { return; }
            if (message?.type === 'render' && message.tree?.props?.title === 'EWaggle drag fixture complete') {
              window.fixtureDragRenderBatchFinished = true;
            }
          });
        }
      };
      document.addEventListener('dragstart', event => {
        window.fixtureDragSource = event.target;
      }, true);
    });
  }
  await page.goto(target);
  await expect(page).toHaveURL(/^http:\/\/127\.0\.0\.1:\d+\/\?page=/);
  await expect(page.locator('.webui-page')).toBeVisible();

  // No fabricated Cookie/Origin/Fetch Metadata headers: Chrome must redeem the
  // bootstrap, commit /auth, and send its Strict cookie on the final document.
  const auth = documents.find(response => new URL(response.url()).pathname === '/auth');
  expect(auth, 'The browser must visit the authentication intermediate document').toBeTruthy();
  expect(auth.status()).toBe(200);
  const final = documents.find(response => response.url() === page.url());
  expect(final.status()).toBe(200);
  const cookies = await context.cookies(page.url());
  expect(cookies).toEqual(expect.arrayContaining([
    expect.objectContaining({ name: `lich_webui_${new URL(page.url()).port}`, httpOnly: true, sameSite: 'Strict' }),
  ]));
  expect(new URL(page.url()).searchParams.has('token')).toBe(false);

  if (scenario === 'priority15-notebook') {
    const main = page.getByRole('tab', { name: 'Main', exact: true });
    const bag = page.getByRole('tab', { name: 'Bag', exact: true });
    await expect(main).toHaveCSS('color', 'rgb(255, 0, 0)');
    await bag.click({ button: 'middle' });
    await expect(page.getByText('Bag middle command', { exact: true })).toBeVisible();
    await expect(main).toHaveAttribute('aria-selected', 'true');
    await bag.click();
    await expect(bag).toHaveAttribute('aria-selected', 'true');
    await expect(page.getByText('Bag contents', { exact: true })).toBeVisible();
    await main.focus(); await main.press('Enter');
    await expect(main).toHaveAttribute('aria-selected', 'true');
    await bag.click({ button: 'right' });
    await expect(bag).toHaveCount(0);
    await expect(page.getByText('Bag closed', { exact: true })).toBeVisible();
    await page.getByRole('button', { name: 'Green tab', exact: true }).click();
    await expect(main).toHaveCSS('color', 'rgb(0, 255, 0)');
    await page.getByRole('button', { name: 'Reopen bag', exact: true }).click();
    await expect(bag).toHaveAttribute('aria-selected', 'true');
    await expect(page.getByText('Bag contents', { exact: true })).toBeVisible();
    await main.click({ button: 'middle' });
    await expect(page.getByText('Main middle command', { exact: true })).toBeVisible();
    await expect(bag).toHaveAttribute('aria-selected', 'true');
    await main.click({ button: 'right' });
    await expect(bag).toHaveCount(0);
    await expect(main).toHaveAttribute('aria-selected', 'true');
    await expect(main).toHaveCSS('color', 'rgb(0, 255, 0)');
  } else if (scenario === 'priority15-log-style') {
    const custom = page.getByTitle('Custom selection', { exact: true }).locator('table');
    const fallback = page.getByTitle('Default selection', { exact: true }).locator('table');
    const selected = custom.locator('tr[aria-selected="true"]');
    const defaultSelected = fallback.locator('tr[aria-selected="true"]');
    await expect(selected).toHaveCSS('background-color', 'rgb(51, 102, 153)');
    await expect(defaultSelected).toHaveCSS('background-color', 'rgb(53, 132, 228)');
    await expect(selected.locator('td')).toHaveCSS('background-image', 'linear-gradient(rgb(51, 102, 153), rgb(51, 102, 153))');
    await expect(selected.locator('td')).toHaveCSS('color', 'rgb(255, 0, 0)');
    const scroll = page.locator('.webui-scroll').filter({ has: page.locator('.webui-log') });
    expect(await scroll.evaluate(el => el.scrollHeight > el.clientHeight)).toBe(true);
    await scroll.evaluate(el => { el.scrollTop = 0; });
    await page.getByRole('button', { name: 'Append marked line', exact: true }).click();
    await expect(selected).toHaveCSS('background-color', 'rgb(0, 255, 0)');
    await expect(selected.locator('td')).toHaveCSS('background-image', 'linear-gradient(rgb(0, 255, 0), rgb(0, 255, 0))');
    await expect.poll(() => scroll.evaluate(el => el.scrollHeight - el.clientHeight - el.scrollTop)).toBeLessThanOrEqual(2);
    await expect(page.locator('.webui-log')).toContainText('Marked final line');
    expect(await scroll.evaluate(el => {
      const text = el.querySelector('.webui-log').firstChild;
      const start = text.textContent.lastIndexOf('Marked final line');
      const range = document.createRange(); range.setStart(text, start); range.setEnd(text, start + 17);
      const line = range.getBoundingClientRect(), bounds = el.getBoundingClientRect();
      return line.top >= bounds.top && line.bottom <= bounds.bottom;
    })).toBe(true);
    await expect(defaultSelected).toHaveCSS('background-color', 'rgb(53, 132, 228)');
    await custom.getByRole('cell', { name: 'Second', exact: true }).click();
    await expect(selected).toContainText('Second');
    const first = custom.getByRole('cell', { name: 'First', exact: true });
    await expect(first.locator('..')).toHaveAttribute('aria-selected', 'false');
    await expect(first).toHaveCSS('background-color', 'rgb(255, 255, 255)');
    await expect(first).toHaveCSS('background-image', 'none');
    await page.getByRole('button', { name: 'Clear log', exact: true }).click();
    await expect(page.locator('.webui-log')).toHaveText('');
    await expect(selected).toHaveCSS('background-color', 'rgb(0, 255, 0)');
    await page.locator('.webui-page').evaluate(el => { el.dataset.theme = 'dark'; el.dataset.density = 'normal'; });
    await expect(selected).toHaveCSS('background-color', 'rgb(0, 255, 0)');
    await expect(selected.locator('td')).toHaveCSS('background-image', 'linear-gradient(rgb(0, 255, 0), rgb(0, 255, 0))');
    await expect(selected.locator('td')).toHaveCSS('color', 'rgb(255, 0, 0)');
  } else if (scenario === 'priority15-followup') {
    const split = page.locator('.webui-split');
    const panes = split.locator(':scope > .split-pane');
    const divider = split.locator(':scope > .split-handle');
    const table = split.locator('table');
    const allowed = table.getByRole('row').filter({ has: page.getByRole('cell', { name: 'Allowed', exact: true }) });
    const denied = table.getByRole('row').filter({ has: page.getByRole('cell', { name: 'Denied', exact: true }) });
    const failing = table.getByRole('row').filter({ has: page.getByRole('cell', { name: 'Failing', exact: true }) });
    const rightWidth = () => panes.last().evaluate(el => el.getBoundingClientRect().width);
    const initial = await rightWidth();
    expect(initial).toBeGreaterThan(50);
    await allowed.click();
    await expect(allowed).toHaveAttribute('aria-selected', 'true');
    await expect(page.getByText('Accepted: Allowed', { exact: true })).toBeVisible();
    await denied.click();
    await expect(denied).toHaveAttribute('aria-selected', 'false');
    await expect(allowed).toHaveAttribute('aria-selected', 'true');
    await failing.click();
    await expect(failing).toHaveAttribute('aria-selected', 'false');
    await expect(allowed).toHaveAttribute('aria-selected', 'true');
    expect(Math.abs(await rightWidth() - initial)).toBeLessThanOrEqual(2);
    await page.setViewportSize({ width: 1100, height: 700 });
    expect(Math.abs(await rightWidth() - initial)).toBeLessThanOrEqual(2);
    await divider.focus();
    await divider.press('ArrowLeft');
    await expect.poll(rightWidth).toBeGreaterThan(initial + 2);
    const dragged = await rightWidth();
    await page.setViewportSize({ width: 1000, height: 650 });
    await expect.poll(async () => Math.abs(await rightWidth() - dragged)).toBeLessThanOrEqual(2);
  } else if (scenario === 'priority15-tree-text') {
    const table = page.getByTitle('Inventory help', { exact: true }).locator('table');
    const header = table.getByRole('columnheader');
    const resize = table.getByRole('separator', { name: 'Resize Custom order' });
    const literal = table.getByRole('cell', { name: '<b>Alpha</b>', exact: true });
    const rowKey = await literal.locator('..').getAttribute('data-row-key');
    await expect(literal).toHaveCSS('color', 'rgb(255, 0, 0)');
    await expect(literal.locator('b')).toHaveCount(0);
    await expect(header).toHaveAttribute('title', 'Custom header help');
    await resize.focus();
    for (let index = 0; index < 20; index++) await resize.press('ArrowLeft');
    expect(await header.evaluate(el => el.getBoundingClientRect().width)).toBeGreaterThanOrEqual(160);
    await page.setViewportSize({ width: 640, height: 700 });
    await table.getByRole('button', { name: 'Custom order', exact: true }).click();
    await expect(table.getByRole('cell').first()).toHaveText('Beta');
    await expect(table.getByRole('cell').last()).toHaveText('Zulu');
    await expect(table.getByRole('cell').last().locator('..')).toHaveAttribute('data-row-key', rowKey);
    await expect(table.getByRole('cell').last()).toHaveCSS('color', 'rgb(255, 0, 0)');
    expect(await header.evaluate(el => el.getBoundingClientRect().width)).toBeGreaterThanOrEqual(240);
    expect(Number(await resize.getAttribute('aria-valuenow'))).toBeGreaterThanOrEqual(240);
    const log = page.getByRole('log');
    const editor = page.locator('textarea');
    await expect(log).toHaveCSS('overflow-wrap', 'anywhere');
    await expect(editor).toHaveCSS('overflow-wrap', 'anywhere');
    expect(await log.evaluate(el => el.scrollWidth <= el.clientWidth + 1)).toBe(true);
    await expect(log).toHaveAttribute('title', 'Wrapped log');
    await page.getByRole('button', { name: 'Disable wrap' }).click();
    await expect(log).toHaveCSS('white-space', 'pre');
    await expect(editor).toHaveAttribute('wrap', 'off');
    expect(await log.evaluate(el => el.scrollWidth > el.clientWidth)).toBe(true);
  } else if (scenario === 'buttonbox-empty-id') {
    const save = page.getByRole('button', { name: 'Save & Close', exact: true });
    const cancel = page.getByRole('button', { name: 'Cancel', exact: true });
    const footer = save.locator('..');
    const combo = page.getByRole('combobox');
    const cid = await save.getAttribute('data-cid');
    const checkFooter = async gap => {
      const sizes = await footer.evaluate(el => ({
        right: el.getBoundingClientRect().right,
        buttons: [...el.querySelectorAll('button')].map(button => {
          const rect = button.getBoundingClientRect(); return { left: rect.left, right: rect.right };
        }),
      }));
      expect(sizes.buttons).toHaveLength(2);
      expect(Math.abs(sizes.buttons[1].left - sizes.buttons[0].right - gap)).toBeLessThanOrEqual(1);
      expect(Math.abs(sizes.right - sizes.buttons[1].right)).toBeLessThanOrEqual(1);
    };
    await expect(combo.locator('option:checked')).toHaveText('-- select spell --');
    await checkFooter(10);
    await page.setViewportSize({ width: 640, height: 480 });
    await checkFooter(10);
    await combo.selectOption({ label: 'Spell' });
    await expect(page.getByText('Choice: "spell"', { exact: true })).toBeVisible();
    await save.focus();
    await save.press('Enter');
    await expect(page.getByText('Saved: "spell"', { exact: true })).toBeVisible();
    await expect(combo.locator('option')).toHaveCount(4);
    await expect(save).toHaveAttribute('data-cid', cid);
    await checkFooter(18);
    await combo.selectOption({ label: '-- select spell --' });
    await expect(page.getByText('Choice: ""', { exact: true })).toBeVisible();
    await combo.selectOption({ label: 'Extra' });
    await expect(page.getByText('Choice: "extra"', { exact: true })).toBeVisible();
    await cancel.click();
    await expect(page.getByText('Reset: ""', { exact: true })).toBeVisible();
    await expect(combo.locator('option:checked')).toHaveText('-- select spell --');
    await checkFooter(18);
  } else if (scenario === 'frame-scroller') {
    const frame = page.locator('fieldset.webui-group');
    const field = page.getByTitle('Draft entry', { exact: true });
    const entry = field.locator('input');
    const cid = await field.getAttribute('data-cid');
    await expect(frame.locator('legend')).toHaveText('Initial frame');
    await expect(frame).toHaveCSS('border-top-width', '1px');
    await entry.fill('Retained draft');
    await page.getByRole('button', { name: 'Rename frame', exact: true }).click();
    await expect(frame.locator('legend')).toHaveText('Updated frame');
    await expect(entry).toHaveValue('Retained draft');
    await expect(field).toHaveAttribute('data-cid', cid);
    await page.getByRole('button', { name: 'Remove border', exact: true }).click();
    await expect(frame).toHaveCSS('border-top-width', '0px');
    await expect(frame).toHaveAttribute('data-borderless', 'true');
    await page.getByRole('button', { name: 'Restore border', exact: true }).click();
    await expect(frame).toHaveCSS('border-top-width', '1px');
    await expect(frame).not.toHaveAttribute('data-borderless');
    await page.getByRole('button', { name: 'Empty caption', exact: true }).click();
    await expect(frame.locator('legend')).toHaveCount(0);
    await expect(frame).toHaveAttribute('data-empty-label', 'true');
    await expect(entry).toHaveValue('Retained draft');
    await entry.press('Enter');
    await expect(page.getByText('Submitted: Retained draft', { exact: true })).toBeVisible();
  } else if (scenario === 'three-compatibility') {
    const field = page.getByTitle('Fill entry', { exact: true });
    const checkFill = async () => {
      const dimensions = await field.evaluate(el => ({ width: el.getBoundingClientRect().width,
        input: el.querySelector('input').getBoundingClientRect().width, parent: el.parentElement.getBoundingClientRect().width,
        columns: el.style.gridColumn, margin: getComputedStyle(el).marginLeft }));
      expect(dimensions.columns).toContain('span 4');
      expect(dimensions.margin).toBe('40px');
      expect(Math.abs(dimensions.width + 40 - dimensions.parent)).toBeLessThanOrEqual(2);
      expect(Math.abs(dimensions.input - dimensions.width)).toBeLessThanOrEqual(2);
    };
    await expect(field).toBeVisible();
    await checkFill();
    await page.setViewportSize({ width: 900, height: 700 });
    await checkFill();
    await page.setViewportSize({ width: 640, height: 480 });
    const mono = page.getByText('Mono caption', { exact: true });
    await expect(mono).toHaveCSS('font-family', 'monospace');
    const disabled = page.locator('a').filter({ hasText: 'Open wiki' });
    await expect(disabled).not.toHaveAttribute('href');
    await expect(disabled).toHaveAttribute('aria-disabled', 'true');
    await page.getByRole('button', { name: 'Select spell', exact: true }).click();
    const active = page.getByRole('link', { name: 'Open selected wiki' });
    await expect(active).toHaveAttribute('href', 'https://example.invalid/spell');
    await active.evaluate(el => el.addEventListener('click', event => {
      event.preventDefault(); el.dataset.keyboardActivated = 'true';
    }));
    await active.focus();
    await active.press('Enter');
    await expect(active).toHaveAttribute('data-keyboard-activated', 'true');
    await page.getByRole('button', { name: 'Clear selection', exact: true }).click();
    await expect(page.locator('a').filter({ hasText: 'Open selected wiki' })).not.toHaveAttribute('href');
    const up = page.getByRole('button', { name: 'Up', exact: true });
    const down = page.getByRole('button', { name: 'Down', exact: true });
    await expect(up).toBeDisabled();
    await down.click();
    await expect(page.getByText('Second, First', { exact: true })).toBeVisible();
    await expect(down).toBeDisabled();
    await up.click();
    await expect(page.getByText('First, Second', { exact: true })).toBeVisible();
    await expect(up).toBeDisabled();
  } else if (scenario === 'priority14-controls') {
    const profileMargin = page.locator('input[title="Profile name"], [title="Profile name"] input').first();
    await expect(profileMargin).toHaveCSS('margin-left', '12px');
    await expect(profileMargin).toHaveCSS('margin-top', '3px');
    await expect(page.locator('.webui-stack[title="Container help"]')).toBeVisible();
    await expect(page.locator('.webui-grid[title="Horizontal help"]')).toBeVisible();

    const profile = page.getByTitle('Profile name', { exact: true });
    await expect(profile.locator('.webui-editable-select')).toHaveCSS('width', '400px');
    await expect(profile.locator('input')).toHaveValue('Profile A');
    await expect(page.getByTitle('Material help').locator('option:checked')).toHaveText('bronze');
    await page.getByRole('button', { name: 'Update controls', exact: true }).click();
    const updated = page.getByTitle('Updated profile', { exact: true });
    await expect(updated.locator('.webui-editable-select')).toHaveCSS('width', '320px');
    await expect(updated.locator('input')).toHaveValue('Profile A');
    await expect(updated.locator('input')).toHaveCSS('margin-left', '0px');
    await expect(updated).toHaveCSS('margin-left', '20px');
    await expect(page.getByTitle('Material help').locator('option:checked')).toHaveText('iron');
    await expect(page.getByText('Updated profile / iron', { exact: true })).toBeVisible();
  } else if (scenario === 'priority11-labels') {
    const mixed = page.locator('.webui-text').filter({ hasText: 'Attack  (optional)' });
    await expect(mixed).toBeVisible();
    await expect(mixed.locator('.webui-text-fragment').first()).toHaveCSS('font-weight', '700');
    await expect(mixed.locator('.webui-text-fragment').last()).toHaveCSS('font-style', 'italic');
    const warning = page.locator('.webui-text-fragment').filter({ hasText: 'Cleric-only' });
    await expect(warning).toHaveCSS('color', 'rgb(255, 191, 64)');
    expect(await warning.evaluate(el => el.style.fontSize)).toBe('1.2em');
    const bonus = page.getByLabel('A long service bonus description '.repeat(8), { exact: true });
    await expect(bonus).toHaveCSS('text-overflow', 'ellipsis');
    expect(await bonus.evaluate(el => el.scrollWidth > el.clientWidth)).toBe(true);
    await page.getByRole('button', { name: 'Reset label', exact: true }).click();
    const plain = page.getByText('Plain replacement', { exact: true });
    await expect(plain).toBeVisible();
    await expect(plain.locator('.webui-text-fragment')).toHaveCount(0);
  } else if (scenario === 'shim-abyssx') {
    const controls = JSON.parse(process.env.WEBUI_TEST_CONTROLS);
    await page.locator(`[data-cid="${controls.entry_lootsack}"] input`).fill('browser sack');
    await page.locator(`[data-cid="${controls.entry_spell}"] input`).fill('901');
    await page.getByRole('radio', { name: 'Spam spell', exact: true }).check();
    await expect(page.getByRole('radio', { name: 'Use bigshot quick', exact: true })).not.toBeChecked();
    await page.getByRole('button', { name: 'Save & Close', exact: true }).click();
    await expect(page.locator('.webui-page')).toHaveCount(0);
  } else if (scenario === 'shim-compass') {
    const controls = JSON.parse(process.env.WEBUI_TEST_CONTROLS);
    const tattoo = page.locator(`[data-cid="${controls.tattoo}"] input`);
    await tattoo.fill('tattoo;look');
    const save = page.getByRole('button', { name: 'Save', exact: true });
    await save.scrollIntoViewIfNeeded();
    expect(await page.locator('.webui-scroll').evaluate(el => el.scrollHeight > el.clientHeight)).toBe(true);
    await save.click();
    await expect(page.getByText('Enter a tattoo name or one RUB command; no semicolons or extra lines.', { exact: true })).toBeVisible();
    await tattoo.fill('my tattoo');
    await save.click();
    await expect(page.locator('.webui-page')).toHaveCount(0);
  } else if (scenario === 'shim-eloot-stance') {
    const controls = JSON.parse(process.env.WEBUI_TEST_CONTROLS);
    const stance = page.locator(`[data-cid="${controls.stance}"] select`);
    await expect(stance.locator('option:checked')).toHaveText('No change');
    await expect(stance.locator('option')).toHaveCount(8); // Includes the shim's empty selection.
    await stance.selectOption({ label: 'Defensive' });
    await page.getByRole('button', { name: 'Close', exact: true }).click();
    await expect(page.locator('.webui-page')).toHaveCount(0);
  } else if (scenario === 'shim-gemstonev-difficulty') {
    for (const name of ['Easy', 'Medium', 'Hard']) {
      await expect(page.getByRole('button', { name, exact: true })).toBeVisible();
    }
    await page.getByRole('button', { name: 'Easy', exact: true }).click();
    await expect(page.locator('.webui-page')).toHaveCount(0);
  } else if (scenario === 'shim-repository-scheduling') {
    await page.setViewportSize({ width: 1200, height: 650 });
    await page.getByRole('cell', { name: 'alpha.lic', exact: true }).click();
    const download = page.getByRole('button', { name: 'alpha.lic', exact: true });
    await download.click();
    await expect(download).toBeDisabled();
    // An actual ten-second source runs; no test clock or source rewrite.
    await expect(download).toBeEnabled({ timeout: 15_000 });
    await page.getByRole('button', { name: 'Close', exact: true }).click();
  } else if (scenario === 'shim-scheduled-visibility') {
    await page.getByRole('textbox').fill('Retained draft');
    await page.getByRole('button', { name: 'Hide for 2 seconds' }).click();
    await expect(page.locator('.webui-page')).toBeHidden();
    await expect(page.locator('.webui-page')).toBeVisible({ timeout: 6_000 });
    await expect(page.getByRole('textbox')).toHaveValue('Retained draft');
    await page.getByRole('button', { name: 'Finish', exact: true }).click();
    await expect(page.locator('.webui-page')).toHaveCount(0);
  } else if (scenario === 'shim-sail2-scheduling') {
    const flag = page.getByRole('checkbox', { name: 'Change ship flag when sailing' });
    const color = page.getByRole('combobox');
    await color.selectOption({ label: 'Black' });
    await flag.uncheck();
    await expect(flag).not.toBeChecked();
    await expect(color).toBeDisabled();
    await flag.check();
    await expect(color).toBeEnabled();
    await expect(color.locator('option:checked')).toHaveText('Black');
    await flag.uncheck();
    await expect(color).toBeDisabled();
    await page.getByRole('button', { name: 'Save', exact: true }).click();
    await page.getByRole('button', { name: 'Close', exact: true }).click();
    await expect(page.locator('.webui-page')).toHaveCount(0);
  } else if (scenario === 'shim-geometry-cursors') {
    for (const name of ['pointer', 'cell', 'copy']) {
      await page.getByRole('button', { name: name[0].toUpperCase() + name.slice(1), exact: true }).click();
      await expect(page.getByText(`Cursor: ${name}`, { exact: true })).toBeVisible();
      await expect(page.getByRole('button', { name: 'Measure screen', exact: true })).toHaveCSS('cursor', name);
    }
    await page.getByRole('button', { name: 'Reset cursor' }).click();
    await expect(page.getByText('Cursor: inherited', { exact: true })).toBeVisible();
    await expect(page.locator('.webui-page')).not.toHaveAttribute('data-cursor-hint');
    await page.getByRole('button', { name: 'Measure screen' }).click();
    await expect(page.getByText(/^Screen: \d+ x \d+ \(browser\)$/)).toBeVisible();
    await page.getByRole('button', { name: 'Finish', exact: true }).click();
  } else if (scenario === 'native-bmp') {
    const image = page.getByRole('img', { name: 'BMP fixture', exact: true });
    await expect.poll(() => image.evaluate(el => el.naturalWidth)).toBe(2);
    expect(await image.evaluate(el => el.naturalHeight)).toBe(1);
    const response = await page.request.get(await image.evaluate(el => el.src));
    expect(response.status()).toBe(200);
    expect(response.headers()['content-type']).toBe('image/bmp');
    expect((await response.body()).subarray(0, 2).toString()).toBe('BM');
  } else if (scenario === 'shim-layout') {
    const hidden = page.getByRole('button', { name: 'Offscreen', exact: true });
    const canvas = page.locator('.webui-overlay');
    await expect(canvas).toHaveCSS('overflow', 'hidden');
    await expect.poll(async () => canvas.evaluate(el => el.offsetHeight)).toBeGreaterThan(80);
    const clipped = await hidden.evaluate(el => {
      const box = el.getBoundingClientRect();
      const hit = document.elementFromPoint(box.x + box.width / 2, box.y + box.height / 2);
      return !hit || hit.closest('button') !== el;
    });
    expect(clipped).toBe(true);
    await page.getByRole('button', { name: 'Move into canvas', exact: true }).click();
    await expect(hidden).toHaveCSS('left', '100px');
    expect(await hidden.evaluate(el => {
      const box = el.getBoundingClientRect();
      return document.elementFromPoint(box.x + box.width / 2, box.y + box.height / 2)?.closest('button') === el;
    })).toBe(true);
  } else if (scenario === 'shim-fixed-events-focus') {
    const first = page.getByPlaceholder('First field'), second = page.getByPlaceholder('Second field');
    await expect(first).toBeFocused();
    const surface = page.getByText('Pointer surface', { exact: true });
    const root = page.locator('.webui-overlay');
    const position = async (target, x, y) => {
      const outer = await root.boundingBox(), child = await target.boundingBox();
      expect(child.x - outer.x).toBeCloseTo(x, 0);
      expect(child.y - outer.y).toBeCloseTo(y, 0);
      await expect.poll(async () => {
        const measured = await root.boundingBox(), contents = await target.boundingBox();
        return measured.width - (contents.x - measured.x + contents.width);
      }).toBeGreaterThanOrEqual(-1);
      await expect.poll(async () => {
        const measured = await root.boundingBox(), contents = await target.boundingBox();
        return measured.height - (contents.y - measured.y + contents.height);
      }).toBeGreaterThanOrEqual(-1);
    };
    await position(surface, 300, 0);
    await second.fill('Changed second');
    await expect(page.getByText('Edited second', { exact: true })).toBeVisible();
    await expect(second).toBeFocused();
    await surface.click();
    const clicked = page.getByText('Pointer 1', { exact: true });
    await expect(clicked).toBeVisible();
    await position(clicked, 350, 40);
    await page.getByRole('button', { name: 'Refocus', exact: true }).click();
    await expect(first).toBeFocused();
    await page.getByRole('button', { name: 'Finish', exact: true }).click();
    await expect(first).toHaveCount(0);
  } else if (scenario === 'native-progress-sizing') {
    const control = key => page.locator(`[data-cid$="progress:${key}"]`);
    const sizes = async () => {
      for (const height of [18, 24, 36]) {
        for (const kind of ['plain', 'colored']) {
          const root = control(`${kind}-${height}`);
          const track = root.locator('progress');
          const box = await track.boundingBox();
          expect(box.width).toBeCloseTo(300, 0);
          expect(box.height).toBeCloseTo(height, 0);
          await expect(track).toHaveJSProperty('value', 0.5);
          await expect(track).toHaveCSS('appearance', 'none');
        }
      }
    };
    await sizes();
    const painted = control('colored-24').locator('progress');
    await expect(painted).toHaveCSS('--progress-fill', 'rgba(176, 224, 230, 1)');
    const labeled = control('labeled');
    const textBox = await labeled.locator('span').boundingBox();
    const trackBox = await labeled.locator('progress').boundingBox();
    expect(textBox.height).toBeGreaterThan(0);
    expect(trackBox.height).toBeGreaterThan(0);
    expect(trackBox.y).toBeGreaterThanOrEqual(textBox.y + textBox.height);
    expect((await labeled.boundingBox()).height).toBeCloseTo(48, 0);
    expect((await control('default').locator('progress').boundingBox()).height).toBeCloseTo(18, 0);
    const pending = control('pending').locator('progress');
    await expect(pending).not.toHaveAttribute('value');
    await expect(pending).toHaveCSS('animation-name', 'webui-progress-pending');
    await page.emulateMedia({ reducedMotion: 'reduce' });
    await expect(pending).toHaveCSS('animation-name', 'none');
    await page.emulateMedia({ reducedMotion: 'no-preference' });
    await page.getByRole('button', { name: 'Toggle colors', exact: true }).click();
    await expect(painted).toHaveCSS('--progress-fill', '');
    await sizes();
    await page.getByRole('button', { name: 'Finish', exact: true }).click();
    await expect(page.locator('.webui-page')).toHaveCount(0);
  } else if (scenario === 'shim-manatimer') {
    const overlay = page.locator('.webui-overlay');
    const label = overlay.locator('.webui-text');
    const bar = overlay.locator('progress');
    await page.getByRole('button', { name: 'Next tick', exact: true }).click();
    await expect(label).toHaveText('01:00');
    await expect(bar).toHaveJSProperty('value', 0.5);
    await expect(overlay.locator('.webui-progress > span')).toHaveCount(0);
    const bounds = await Promise.all([label.boundingBox(), bar.boundingBox()]);
    expect(bounds[1].height).toBeCloseTo(18, 0);
    expect(Math.abs(bounds[0].y + bounds[0].height / 2 - bounds[1].y - bounds[1].height / 2)).toBeLessThan(2);
    expect(Math.abs(bounds[0].x + bounds[0].width / 2 - bounds[1].x - bounds[1].width / 2)).toBeLessThan(2);
    const center = () => label.boundingBox().then(box => ({ x: box.x + box.width / 2, y: box.y + box.height / 2 }));
    let point = await center();
    await page.mouse.click(point.x, point.y, { button: 'right' });
    await expect.poll(() => page.evaluate(() => window.fixturePresentation.borderless)).toBe(true);
    await page.getByRole('button', { name: 'Toggle pass-through', exact: true }).click();
    await expect(label).not.toHaveAttribute('data-overlay-pass-through', 'true');
    point = await center();
    const presses = wire.filter(entry => entry.includes('->') && entry.includes('event=pointer_press')).length;
    await page.mouse.click(point.x, point.y, { button: 'right' });
    await page.getByRole('button', { name: 'Next tick', exact: true }).click();
    await expect(bar).toHaveJSProperty('value', 0.5);
    expect(wire.filter(entry => entry.includes('->') && entry.includes('event=pointer_press')).length).toBe(presses);
    await expect.poll(() => page.evaluate(() => window.fixturePresentation.borderless)).toBe(true);
    await page.getByRole('button', { name: 'Finish', exact: true }).click();
    await expect(page.locator('.webui-page')).toHaveCount(0);
  } else if (scenario === 'shim-headerbar') {
    const title = page.getByText('Header actions', { exact: true });
    const close = page.getByRole('button', { name: 'Close', exact: true });
    const entry = page.getByRole('textbox');
    await expect(title).toBeVisible();
    const titleBounds = await title.boundingBox();
    const closeBounds = await close.boundingBox();
    const contentBounds = await entry.boundingBox();
    expect(Math.abs(titleBounds.y - closeBounds.y)).toBeLessThan(25);
    expect(contentBounds.y).toBeGreaterThan(titleBounds.y);
    await page.getByRole('button', { name: 'Header action', exact: true }).click();
    await expect(page.getByText('Header action worked', { exact: true })).toBeVisible();
    await entry.fill('Unsaved draft');
    await close.click();
    await expect(page.getByText('Close vetoed', { exact: true })).toBeVisible();
    await expect(entry).toHaveValue('Unsaved draft');
    await close.click();
    await expect(page.locator('.webui-page')).toHaveCount(0);
  } else if (scenario === 'shim-tpick-information') {
    await page.setViewportSize({ width: 1100, height: 850 });
    await page.getByRole('tab', { name: 'Messages', exact: true }).click();
    await expect(page.getByRole('log')).toContainText('Fixture update');
    await page.getByRole('tab', { name: 'Stats', exact: true }).click();
    await page.getByRole('tab', { name: 'Lockpicking', exact: true }).click();
    await expect(page.getByRole('tab', { name: 'Traps', exact: true })).toBeVisible();
    await page.getByRole('tab', { name: 'Settings', exact: true }).click();
    await expect(page.getByRole('button', { name: 'Save', exact: true })).toBeVisible();
    await page.getByRole('tab', { name: 'Main', exact: true }).click();
    await page.getByRole('button', { name: 'Start', exact: true }).click();
    await page.getByRole('button', { name: 'Close', exact: true }).click();
    await expect(page.locator('.webui-page')).toHaveCount(0);
  } else if (scenario === 'shim-tpick-settings') {
    const ids = JSON.parse(process.env.WEBUI_TEST_CONTROLS);
    const entry = page.locator(`[data-cid="${ids.vaalin}"] input`);
    await page.setViewportSize({ width: 1100, height: 850 });
    for (const name of ['Lockpicks', 'Repair', 'Containers', 'Other', 'Rogues Only', 'Spells', 'Experience', 'Speech', 'Popping', 'Pool']) {
      await page.getByRole('tab', { name, exact: true }).click();
      await expect(page.getByRole('tab', { name, exact: true })).toHaveAttribute('aria-selected', 'true');
    }
    await page.getByRole('tab', { name: 'Main', exact: true }).click();
    await page.getByRole('combobox').selectOption({label: 'Second'});
    await page.getByRole('button', { name: 'Load', exact: true }).click();
    await page.getByRole('tab', { name: 'Lockpicks', exact: true }).click();
    await expect(entry).toHaveValue('second pick');
    const grid = entry.locator('xpath=ancestor::*[contains(@class,"webui-grid")][1]');
    await expect(grid).toHaveCSS('display', 'grid');
    const label = page.getByText('2.50 mod (Vaalin Lockpick)', {exact: true});
    const fieldBounds = await entry.boundingBox(), labelBounds = await label.boundingBox();
    expect(Math.abs(fieldBounds.y + fieldBounds.height / 2 - labelBounds.y - labelBounds.height / 2)).toBeLessThan(3);
    expect(fieldBounds.x).toBeGreaterThan(labelBounds.x);

    await expect(page.getByText('2.50 mod (Vaalin Lockpick)', {exact: true})).toHaveCSS('color', 'rgb(255, 77, 77)');
    await page.getByRole('tab', { name: 'Main', exact: true }).click();
    await page.getByRole('button', { name: 'Defaults', exact: true }).click();
    await page.getByRole('tab', { name: 'Lockpicks', exact: true }).click();
    await expect(entry).toHaveValue('');
    await entry.fill('WebKit acceptance pick');
    await page.getByRole('tab', { name: 'Main', exact: true }).click();
    await page.getByRole('button', { name: 'Save', exact: true }).click();
    await page.getByRole('button', { name: 'Close', exact: true }).click();
    await expect(page.locator('.webui-page')).toHaveCount(0);
  } else if (scenario === 'shim-tpick-welcome') {
    await expect(page.getByText('WELCOME TO TPICK!', { exact: true })).toBeVisible();
    await expect(page.getByRole('log')).toContainText('Welcome to ;tpick!');
    await page.getByRole('button', { name: 'Close', exact: true }).click();
    await expect(page.locator('.webui-page')).toHaveCount(0);
  } else if (scenario === 'shim-progress-style') {
    const bar = page.locator('.webui-progress');
    const progress = bar.locator('progress');
    const cid = await bar.getAttribute('data-cid');
    const sibling = page.getByText('Unstyled sibling', { exact: true });
    const weight = await sibling.evaluate(element => getComputedStyle(element).fontWeight);
    await expect(page.locator('.required-setting')).toHaveCount(0);
    await expect(sibling).not.toHaveCSS('font-weight', '700');
    await expect(sibling).not.toHaveCSS('font-family', /Courier New/);
    await expect(progress).toHaveCSS('appearance', 'none');
    await expect(progress).toHaveCSS('height', '24px');
    await expect(bar).toHaveCSS('height', '24px');
    await expect(progress).toHaveCSS('--progress-fill', 'rgba(0, 0, 255, 1)');
    await page.getByRole('button', { name: 'Reload style', exact: true }).click();
    await expect(progress).toHaveCSS('--progress-fill', 'rgba(255, 215, 0, 1)');
    await expect(progress).toHaveJSProperty('value', 0.75);
    const cssRequests = [];
    page.on('request', request => {
      if (new URL(request.url()).hostname === 'invalid') cssRequests.push(request.url());
    });
    await page.getByRole('button', { name: 'Omit style', exact: true }).click();
    await expect(progress).toHaveCSS('appearance', 'none');
    await expect(progress).toHaveCSS('height', '18px');
    await expect.poll(() => bar.evaluate(element => element.style.height)).toBe('');
    await expect.poll(() => progress.evaluate(element => element.style.getPropertyValue('--progress-fill'))).toBe('');
    await expect(bar).toHaveAttribute('data-cid', cid);
    await expect(progress).toHaveJSProperty('value', 0.75);
    await expect(sibling).toHaveCSS('font-weight', weight);
    await page.getByRole('button', { name: 'Reload style', exact: true }).click();
    await expect(progress).toHaveCSS('appearance', 'none');
    await expect(progress).toHaveCSS('height', '24px');
    await expect(bar).toHaveCSS('height', '24px');
    await expect(progress).toHaveCSS('--progress-fill', 'rgba(255, 215, 0, 1)');
    await page.getByRole('button', { name: 'Remove style', exact: true }).click();
    await expect(progress).toHaveCSS('appearance', 'none');
    await expect(progress).toHaveCSS('height', '18px');
    await expect.poll(() => bar.evaluate(element => element.style.height)).toBe('');
    await expect.poll(() => progress.evaluate(element => element.style.getPropertyValue('--progress-fill'))).toBe('');
    await expect(bar).toHaveAttribute('data-cid', cid);
    await expect(progress).toHaveJSProperty('value', 0.75);
    await expect(sibling).toHaveCSS('font-weight', weight);
    await page.getByRole('button', { name: 'Close progress fixture', exact: true }).click();
    await expect(progress).toHaveCount(0);
    expect(cssRequests).toEqual([]);
  } else if (['shim-repository', 'shim-go2'].includes(scenario)) {
    const ids = JSON.parse(process.env.WEBUI_TEST_CONTROLS);
    const widget = name => page.locator(`[data-cid="${ids[name]}"]`);
    if (scenario === 'shim-repository') {
      // The script requests an 800px list plus its comments pane; headless
      // Chrome cannot honor the renderer's native window resize request.
      await page.setViewportSize({ width: 1200, height: 650 });
      await expect(page.getByRole('tab')).toHaveCount(0);
      const table = widget('repository');
      await expect(table.locator('tbody tr')).toHaveCount(42);
      const listScroll = table.locator('..');
      const heading = table.locator('th').first();
      const headerTop = (await heading.boundingBox()).y;
      await listScroll.evaluate(element => { element.scrollTop = 300; });
      await expect.poll(async () => Math.abs((await heading.boundingBox()).y - headerTop)).toBeLessThan(2);
      await listScroll.evaluate(element => { element.scrollTop = 0; });
      const lastHeader = table.locator('th').last();
      const grip = lastHeader.getByRole('separator', { name: 'Resize Tags' });
      // Do not scroll or focus the edge into view: the first display must expose
      // the last column and its actual mouse target, even with long cell text.
      await expect.poll(() => grip.evaluate(element => {
        const rect = element.getBoundingClientRect();
        return document.elementFromPoint(rect.x + rect.width / 2, rect.y + 10) === element;
      })).toBe(true);
      expect(await listScroll.evaluate(element => element.scrollLeft)).toBe(0);
      const oldWidth = (await lastHeader.boundingBox()).width;
      const edge = await grip.boundingBox();
      await page.mouse.move(edge.x + edge.width / 2, edge.y + 10);
      await page.mouse.down();
      await page.mouse.move(edge.x + edge.width / 2 + 30, edge.y + 10, { steps: 6 });
      await page.mouse.up();
      expect((await lastHeader.boundingBox()).width).toBeGreaterThan(oldWidth + 28);
      await grip.focus();
      await grip.press('ArrowRight');
      const resizedWidth = (await lastHeader.boundingBox()).width;
      expect(resizedWidth).toBeGreaterThan(oldWidth + 38);
      await listScroll.evaluate(element => { element.scrollLeft = 0; });
      await table.getByRole('button', { name: 'Size', exact: true }).click();
      await expect(table.locator('tbody tr').first()).toContainText('zeta.lic');
      await table.getByText('zeta.lic', { exact: true }).click();
      await expect(widget('comments')).toHaveText('');
      const search = widget('search_entry').locator('input');
      await search.click();
      await search.pressSequentially('Dreaven', { delay: 480 });
      await expect(search).toHaveValue('Dreaven');
      await expect(table.locator('tbody tr')).toHaveCount(1);
      expect(await search.evaluate(element => element.selectionStart)).toBe(7);
      expect((await lastHeader.boundingBox()).width).toBeCloseTo(resizedWidth, 0);
      await widget('search_entry').fill('travel');
      await expect(table.locator('tbody tr')).toHaveCount(1);
      await table.getByText('alpha.lic', { exact: true }).click();
      await expect(widget('comments')).toHaveText('Alpha comments Dreaven' + ' more details.'.repeat(1000));
      const commentsScroll = widget('comments').locator('xpath=ancestor::*[contains(concat(" ", normalize-space(@class), " "), " webui-scroll ")][1]');
      expect((await commentsScroll.boundingBox()).height).toBeLessThanOrEqual(510);
      expect(Math.abs((await listScroll.boundingBox()).y - (await commentsScroll.boundingBox()).y)).toBeLessThan(2);
      await commentsScroll.evaluate(element => { element.scrollTop = element.scrollHeight; });
      expect(await commentsScroll.evaluate(element => element.scrollTop)).toBeGreaterThan(1000);
      await expect(widget('download_link')).toHaveText('alpha.lic');
      await widget('download_link').click();
    } else {
      const fragments = page.getByText('Minimum fragments before using', { exact: true });
      if (await widget('portals_passes_frame').isVisible()) {
        await expect(fragments).toBeVisible();
        await fragments.scrollIntoViewIfNeeded();
        const heading = page.getByText('Hinterwilds Travel Options', { exact: true });
        expect(Math.abs((await fragments.boundingBox()).x - (await heading.boundingBox()).x)).toBeLessThan(2);
      }
      await widget('delay').fill('7');
      await widget('echo_input').uncheck();
    }
    await page.getByRole('button', { name: 'Close', exact: true }).click();
    await expect(page.locator('.webui-page')).toHaveCount(0);
  } else if (scenario === 'shim-huntplan') {
    const ids = JSON.parse(process.env.WEBUI_TEST_CONTROLS);
    const widget = name => page.locator(`[data-cid="${ids[name]}"]`);
    await expect(page.getByRole('tab')).toHaveCount(0);
    await widget('default_profile').fill('fixture-default');
    await widget('bounty_profile').fill('fixture-bounty');
    const slot = widget('ebounty_slot').locator('input');
    await slot.fill('');
    await slot.pressSequentially('zz');
    await expect(slot).toHaveValue('z');
    await page.getByRole('button', { name: 'Save & Exit', exact: true }).click();
    await expect(widget('status_label')).toHaveText('invalid ebounty profile slot: z');
    await slot.fill('j');
    await page.getByRole('button', { name: 'Save & Exit', exact: true }).click();
    await expect(page.locator('.webui-page')).toHaveCount(0);
  } else if (scenario === 'native-bootstrap') {
    await page.getByRole('button', { name: 'Activate' }).click();
    await expect(page.getByText('Callback received', { exact: true })).toBeVisible();
    // Real line rectangles establish both line justification and placement;
    // checking CSS alone would miss moving the whole label to the wrong edge.
    for (const align of ['start', 'center', 'end']) {
      const geometry = await page.locator(`[data-cid$="text:justified-${align}"]`).evaluate(label => {
        const lines = label.firstElementChild, text = lines.firstChild;
        const range = document.createRange();
        range.setStart(text, 0); range.setEnd(text, 11);
        const first = range.getBoundingClientRect();
        range.setStart(text, 12); range.setEnd(text, 17);
        const second = range.getBoundingClientRect();
        const box = lines.getBoundingClientRect(), outer = label.getBoundingClientRect();
        return { firstRight: first.right, secondRight: second.right, secondTop: second.top, firstTop: first.top,
          left: box.left - outer.left, right: outer.right - box.right };
      });
      expect(Math.abs(geometry.firstRight - geometry.secondRight)).toBeLessThan(1);
      expect(geometry.secondTop).toBeGreaterThan(geometry.firstTop);
      if (align === 'start') expect(geometry.left).toBeLessThan(1);
      if (align === 'end') expect(geometry.right).toBeLessThan(1);
      if (align === 'center') expect(Math.abs(geometry.left - geometry.right)).toBeLessThan(1);
    }
    const wrapped = await page.locator('[data-cid$="text:justified-wrap"]').evaluate(label => {
      const text = label.firstElementChild.firstChild, range = document.createRange();
      const edges = new Map();
      // pre-wrap preserves hanging spaces at a soft break. Measure visible
      // words, since those spaces are not part of the justified ink edge.
      for (const word of text.textContent.matchAll(/\S+/g)) {
        range.setStart(text, word.index); range.setEnd(text, word.index + word[0].length);
        for (const rect of range.getClientRects()) edges.set(rect.top, Math.max(edges.get(rect.top) || 0, rect.right));
      }
      const box = label.getBoundingClientRect();
      return { count: edges.size, right: box.right, edges: [...edges.values()] };
    });
    expect(wrapped.count).toBeGreaterThan(1);
    expect(wrapped.edges.every(right => Math.abs(right - wrapped.right) < 1)).toBe(true);
  } else if (['shim-ebounty', 'shim-eherbs', 'shim-blackarts', 'shim-eloot-corrected', 'shim-bigshot-corrected'].includes(scenario)) {
    const ids = JSON.parse(process.env.WEBUI_TEST_CONTROLS);
    const widget = name => page.locator(`[data-cid="${ids[name]}"]`);
    const reveal = async name => {
      const parents = await widget(name).evaluate(element => {
        const result = [];
        for (let panel = element.closest('[role="tabpanel"]'); panel; panel = panel.parentElement.closest('[role="tabpanel"]')) {
          result.unshift({ cid: panel.parentElement.dataset.cid,
            index: [...panel.parentElement.children].filter(child => child.matches('[role="tabpanel"]')).indexOf(panel) });
        }
        return result;
      });
      for (const parent of parents) {
        await page.locator(`[data-cid="${parent.cid}"] > .tab-list > button`).nth(parent.index).click();
      }
      const expanders = await widget(name).evaluate(element => {
        const result = [];
        for (let parent = element.parentElement; parent; parent = parent.parentElement) {
          if (parent.tagName === 'DETAILS') result.unshift(parent.dataset.cid);
        }
        return result;
      });
      for (const cid of expanders) {
        const details = page.locator(`details[data-cid="${cid}"]`);
        if (!(await details.evaluate(element => element.open))) await details.locator(':scope > summary').click();
      }
      await expect(widget(name)).toBeVisible();
      return widget(name);
    };
    await page.setViewportSize(scenario === 'shim-eherbs' ? { width: 800, height: 700 } : { width: 1000, height: 850 });
    if (scenario === 'shim-bigshot-corrected') {
      await page.setViewportSize({ width: 1200, height: 900 });
      await (await reveal('resting_room_id')).locator('input').fill('1234');
      await (await reveal('wander_wait')).locator('input').fill('0.7');
      await (await reveal('attack_drop')).locator('input').fill('Guarded');
      await widget('attack_drop').locator('input').press('Tab');
      await (await reveal('fog_return')).locator('select').selectOption({ label: 'Custom' });
      await expect(widget('custom_fog').locator('input')).toBeEnabled();
      await widget('fog_return').locator('select').selectOption({ label: 'None' });
      await expect(widget('custom_fog').locator('input')).toBeDisabled();
      await (await reveal('boons_all:flee')).locator('input').check();
      await expect(widget('immunity:flee').locator('input')).toBeChecked();
      await (await reveal('immunity:crit_death_immune_ignore')).locator('input').check();
      await expect(widget('immunity:crit_death_immune_flee').locator('input')).not.toBeChecked();
      await expect(widget('boons_all:flee').locator('input')).not.toBeChecked();
      await (await reveal('notes')).locator('textarea').fill('Acceptance notes\nsecond line');
      await widget('notes').locator('textarea').press('Tab');
      await (await reveal('save_profile_name')).locator('input').fill('browser-profile');
      await widget('profile_save').click();
      await expect(widget('profile_current').locator('input')).toHaveValue('browser-profile');
      await expect(widget('profile_current').locator('input')).toHaveAttribute('readonly', '');
    } else if (scenario === 'shim-eloot-corrected') {
      await (await reveal('sell_locksmith')).locator('input').check();
      await expect(widget('locksmith_priority').locator('select')).toBeEnabled();
      await widget('locksmith_priority').locator('select').selectOption({ label: 'Locksmith First' });
      await widget('use_incremental_tipping').locator('input').check();
      await expect(widget('use_standard_tipping').locator('input')).not.toBeChecked();
      await widget('alpha_rate').locator('input').fill('3.5');
      await (await reveal('sell_exclude_entry')).locator('input').fill('fixture exclusion');
      const listGeometry = await widget('sell_exclude_entry').evaluate(element => {
        const input = element.getBoundingClientRect(), frame = element.closest('fieldset').getBoundingClientRect();
        const grid = element.parentElement.getBoundingClientRect();
        return { width: input.width, top: grid.top - frame.top, bottom: frame.bottom - grid.bottom };
      });
      expect(listGeometry.width).toBeGreaterThan(100);
      expect(listGeometry.top).toBeGreaterThanOrEqual(0);
      expect(listGeometry.bottom).toBeGreaterThanOrEqual(0);
      await widget('sell_exclude_add').click();
      await expect(widget('sell_exclude').locator('tbody tr')).toHaveCount(1);
      await widget('sell_exclude').getByText('fixture exclusion', { exact: true }).click();
      await widget('sell_exclude_delete').click();
      await expect(widget('sell_exclude').locator('tbody tr')).toHaveCount(0);
      await (await reveal('loot_types:alchemy')).locator('input').check();
      await (await reveal('skin_enable')).locator('input').check();
      await (await reveal('gem_horde')).locator('input').check();
      await widget('gem_only_list').locator('input').check();
      await expect(widget('gem_everything_list').locator('input')).not.toBeChecked();
      await widget('gem_list_entry').locator('input').fill('ruby');
      await widget('gem_list_add').click();
      await expect(widget('gem_list').locator('tbody tr')).toHaveCount(1);
      await widget('gem_horde_locker').locator('input').check();
      await expect(widget('gem_locker').locator('select')).toBeEnabled();
      await widget('gem_horde_locker_che').locator('input').check();
      await expect(widget('gem_locker').locator('select')).toBeDisabled();
      await expect(widget('gem_horde_che_rooms').locator('input')).toBeEnabled();
      await widget('gem_horde_che_rooms').locator('input').fill('1234');
    } else if (scenario === 'shim-ebounty') {
      await (await reveal('culling_max')).locator('input').fill('25');
      await widget('culling_max').locator('input').press('Tab');
      await (await reveal('selling_script')).locator('input').fill('fixture-sell');
      await widget('selling_script').locator('input').press('Tab');
      await (await reveal('once_and_done')).locator('input').check();
      await expect(widget('new_bounty_on_exit').locator('input')).toBeEnabled();
      await widget('new_bounty_on_exit').locator('input').check();
      await widget('once_and_done').locator('input').uncheck();
      await expect(widget('new_bounty_on_exit').locator('input')).toBeDisabled();
      await expect(widget('new_bounty_on_exit').locator('input')).not.toBeChecked();
      await (await reveal('keep_hunting')).locator('input').check();
      await widget('exp_pause').locator('input').check();
      await expect(widget('keep_hunting').locator('input')).not.toBeChecked();
      await (await reveal('creature_exclude_entry')).locator('input').fill('fixture creature');
      await widget('creature_exclude_add').click();
      await expect(widget('creature_exclude').locator('tbody tr')).toHaveCount(1);
      await widget('creature_exclude').locator('tbody tr').click();
      await widget('creature_exclude_delete').click();
      await expect(widget('creature_exclude').locator('tbody tr')).toHaveCount(0);
      // A quarter-turn must contribute a vertical footprint instead of merely
      // painting rotated text over neighboring grid cells.
      const rotation = page.locator('.webui-rotated-text');
      const rotationPanel = await rotation.evaluate(el => [...el.closest('.tab-panel').parentElement.children]
        .filter(child => child.matches('.tab-panel')).indexOf(el.closest('.tab-panel')));
      await page.getByRole('tab').nth(rotationPanel).click();
      await expect(rotation).toBeVisible();
      const box = await rotation.boundingBox();
      expect(box.height).toBeGreaterThan(box.width);
    } else if (scenario === 'shim-eherbs') {
      await (await reveal('herb_container')).locator('input').fill('herb sack');
      await widget('herb_container').locator('input').press('Tab');
      await widget('buy_missing').locator('input').check();
      await expect(widget('use650').locator('input')).toBeDisabled();
    } else {
      await (await reveal('guild_pause')).locator('input').fill('25');
      await widget('guild_pause').locator('input').press('Tab');
      await expect((await reveal('shadow_drop_item')).locator('input')).toBeDisabled();
      await expect((await reveal('use_wracking')).locator('input')).toBeDisabled();
      // The internal GTK entry has no separate focus target. The shared combo
      // remains operable by both keyboard text input and named option selection.
      const profile = (await reveal('profile_a')).locator('input');
      await profile.focus();
      await expect(profile).toBeFocused();
      await profile.fill('travel');
      await profile.press('Tab');
      const guild = (await reveal('home_guild')).locator('input');
      await guild.fill("Wehnimer's Landing");
      await guild.press('Tab');
      for (const [key, reset] of [['item_include', 'btn_reset'], ['consignment_include', 'btn_consignment_reset']]) {
        const table = await reveal(key);
        const count = await table.locator('tbody tr').count();
        await widget(`${key}_entry`).locator('input').fill('fixture reagent');
        await widget(`${key}_add`).click();
        await expect(table.locator('tbody tr')).toHaveCount(count + 1);
        await table.getByText('fixture reagent', { exact: true }).click();
        await widget(`${key}_delete`).click();
        await expect(table.locator('tbody tr')).toHaveCount(count);
        await widget(`${key}_entry`).locator('input').fill('fixture reset');
        await widget(`${key}_add`).click();
        await expect(table.locator('tbody tr')).toHaveCount(count + 1);
        await widget(reset).click();
        await expect(table.locator('tbody tr')).toHaveCount(count);
      }
      const reset = widget('btn_consignment_reset');
      await expect(reset).toBeVisible();
      await expect(reset).toHaveCSS('min-height', '20px');
      expect((await reset.boundingBox()).height).toBeGreaterThan(20);
      expect(await reset.evaluate(button => button.scrollWidth <= button.clientWidth)).toBe(true);
    }
    await page.screenshot({ path: require('path').join(__dirname, 'test-results', `${scenario}.png`), fullPage: true });
    await page.getByRole('button', { name: 'Close', exact: true }).click();
    await expect(page.locator('.webui-page')).toHaveCount(0);
  } else if (scenario === 'shim-ewaggle') {
    await page.setViewportSize({ width: 730, height: 800 });
    await expect.poll(() => page.evaluate(() => {
      const fields = [...document.querySelectorAll('.field.inline')].map(field => {
        const rect = field.getBoundingClientRect();
        const frame = field.closest('fieldset')?.getBoundingClientRect();
        return { rect, frame };
      });
      return fields.every(({ rect, frame }, index) => (!frame || rect.right <= frame.right + 1) &&
        fields.slice(index + 1).every(({ rect: other }) =>
          Math.min(rect.right, other.right) - Math.max(rect.left, other.left) <= 1 ||
          Math.min(rect.bottom, other.bottom) - Math.max(rect.top, other.top) <= 1));
    })).toBe(true);
    const tables = page.locator('.webui-table-wrap');
    await expect(tables).toHaveCount(2);
    const available = tables.filter({ hasText: '102  Spirit Barrier' });
    const casting = tables.filter({ hasText: '101  Spirit Warding I' });
    const row = available.locator('tbody tr').first();
    await row.focus();
    await page.keyboard.type('102');
    await expect(available.locator('tr[aria-selected="true"]')).toContainText('Spirit Barrier');
    // The bottom blank area must be a target, not just the populated row.
    const blankArea = async target => {
      let box;
      await expect.poll(async () => {
        box = await target.boundingBox();
        return box?.height || 0;
      }).toBeGreaterThan(200);
      return { x: box.width / 2, y: box.height - 20 };
    };
    await row.dragTo(casting, { targetPosition: await blankArea(casting) });
    await expect(tables.nth(0).locator('tbody tr')).toHaveCount(2);
    const destination = tables.nth(0);
    const empty = tables.nth(1);
    await expect(empty.locator('tbody tr')).toHaveCount(0);
    await destination.locator('tbody tr').filter({ hasText: 'Spirit Barrier' }).dragTo(empty,
      { targetPosition: await blankArea(empty) });
    await expect(empty.locator('tbody tr')).toHaveCount(1);
    // Hold the third native gesture across background server renders. Chrome
    // emits pointercancel on handoff to HTML drag-and-drop; that is not dragend.
    const visibleBox = async locator => {
      let box;
      await expect.poll(async () => {
        box = await locator.boundingBox();
        return !!box && box.width > 0 && box.height > 0;
      }, { message: 'drag geometry must be visible after background redraws' }).toBe(true);
      return box;
    };
    const sourceBox = await visibleBox(empty.locator('tbody tr'));
    await page.mouse.move(sourceBox.x + sourceBox.width / 2, sourceBox.y + sourceBox.height / 2);
    await page.mouse.down();
    await page.mouse.move(sourceBox.x + sourceBox.width / 2 + 15, sourceBox.y + sourceBox.height / 2, { steps: 5 });
    // Wait for the finite server-render batch while still holding the native
    // gesture. Finish churn before dropping, preserving the one-stale-retry contract.
    await expect.poll(() => page.evaluate(() => window.fixtureDragRenderBatchFinished === true)).toBe(true);
    expect(await page.evaluate(() => window.fixtureDragSource?.isConnected), 'the third drag source must survive background renders').toBe(true);
    const targetBox = await visibleBox(destination);
    await page.mouse.move(targetBox.x + targetBox.width / 2, targetBox.y + targetBox.height - 20, { steps: 5 });
    await page.mouse.up();
    await expect(destination.locator('tbody tr')).toHaveCount(2);
    const barrier = destination.locator('tbody tr').filter({ hasText: 'Spirit Barrier' });
    await barrier.dragTo(destination);
    await expect(destination.locator('tbody tr')).toHaveCount(3);
    await destination.locator('tbody tr').filter({ hasText: 'Spirit Barrier' }).first().dblclick();
    await expect(destination.locator('tbody tr')).toHaveCount(2);
    await tables.nth(1).locator('tbody tr').filter({ hasText: 'Spirit Barrier' }).dblclick();
    await expect(destination.locator('tbody tr')).toHaveCount(3);
    await page.getByLabel('Choose option').selectOption({ label: 'Full Plate (20)' });
    const spin = page.locator('input[type="number"]').first();
    await spin.fill('90');
    await spin.press('Tab');
    await expect(page.getByRole('link')).toHaveCount(3);
    await expect(page.getByRole('link').first()).toHaveAttribute('rel', 'noopener noreferrer');
    await page.getByRole('button', { name: 'Close', exact: true }).click();
    await expect(page.locator('.webui-page')).toHaveCount(0);
  } else if (scenario === 'shim-builder') {
    await expect(page.getByRole('tab', { name: 'General', exact: true })).toBeVisible();
    for (const viewport of [{ width: 650, height: 675 }, { width: 1000, height: 850 }]) {
      await page.setViewportSize(viewport);
      await expect.poll(() => page.evaluate(() => {
        const root = document.querySelector('.webui-page');
        const ranges = [...root.querySelectorAll('.field.inline')].map(field => {
          const text = field.querySelector('.field-label');
          const input = field.querySelector('input');
          if (!text || !input) return null;
          const range = document.createRange();
          range.selectNodeContents(text);
          const a = input.getBoundingClientRect(), b = range.getBoundingClientRect();
          return { label: text.textContent, left: Math.min(a.left, b.left), right: Math.max(a.right, b.right),
            top: Math.min(a.top, b.top), bottom: Math.max(a.bottom, b.bottom) };
        }).filter(Boolean);
        const overlaps = ranges.flatMap((a, i) => ranges.slice(i + 1).filter(b =>
          Math.min(a.right, b.right) - Math.max(a.left, b.left) > 1 &&
          Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top) > 1).map(b => `${a.label} / ${b.label}`));
        const close = [...root.querySelectorAll('button')].find(button => button.textContent === 'Close');
        const footer = close.getBoundingClientRect();
        return { overlaps, horizontalOverflow: root.scrollWidth > innerWidth + 1,
          footerVisible: footer.top >= 0 && footer.bottom <= innerHeight + 1,
          footerOutsideScroll: !close.closest('.webui-scroll') };
      })).toEqual({ overlaps: [], horizontalOverflow: false, footerVisible: true, footerOutsideScroll: true });
    }
    const scripts = page.getByPlaceholder('list of scripts to pause eg - bigshot, eloot, go2');
    await expect(scripts).toHaveValue('bigshot');
    expect(await scripts.evaluate(control => control.getBoundingClientRect().width)).toBeGreaterThan(400);
    await scripts.fill('hunting, travel');
    await scripts.press('Enter');
    // receives-default on Close must not promote it to a page-wide Enter action.
    const close = page.getByRole('button', { name: 'Close', exact: true });
    await expect(close).toBeVisible();
    await expect(page.getByRole('checkbox', { name: 'Cure Disease', exact: true })).toBeDisabled();
    const poison = page.getByRole('checkbox', { name: 'Cure Poison', exact: true });
    await poison.focus();
    await poison.press('Space');
    await expect(poison).toBeChecked();
    await poison.press('Enter');
    await expect(poison).toBeChecked();
    const stance = page.getByRole('checkbox', { name: 'Stunman Stance1', exact: true });
    await stance.check();
    await page.getByRole('checkbox', { name: 'Stunman Flee', exact: true }).check();
    await expect(stance).not.toBeChecked();
    await expect(page.getByText('To save properly, exit with the close button and not the X window -->', { exact: true })).toHaveCSS('font-style', 'italic');
    await close.focus();
    await page.evaluate(() => window.fixtureRedraw());
    await expect(close).toBeFocused();
    await close.press('Enter');
    // Keep the transport alive through save/close callbacks and any stale-event
    // retry. A dispatched DOM click is not server confirmation of completion.
    await expect(page.locator('.webui-page')).toHaveCount(0);
  } else if (scenario === 'shim-models') {
    await expect(page.locator('tbody tr')).toHaveCount(1);
    await page.getByRole('button', { name: 'Expand Parent' }).click();
    await expect(page.locator('tbody tr')).toHaveCount(2);
    const childKey = await page.locator('tbody tr').filter({ hasText: 'Child' }).getAttribute('data-row-key');
    const child = page.locator(`tr[data-row-key="${childKey}"]`);
    await child.locator('td').first().click();
    const editor = child.locator('input[type="text"]');
    await editor.fill('Edited child');
    await editor.press('Enter');
    const edited = page.locator('tbody tr').filter({ hasText: 'Edited child' });
    await edited.getByRole('checkbox', { name: 'Enabled' }).check();
    await expect(edited.getByRole('checkbox', { name: 'Enabled' })).toBeChecked();
    await page.locator('.webui-choice-picker select').selectOption({ index: 2 });
    // Choose rows without entering an editor, then retain both across the Save render.
    await edited.click({ position: { x: 2, y: 2 } });
    await page.locator('tbody tr').first().click({ position: { x: 2, y: 2 }, modifiers: ['ControlOrMeta'] });
    await expect(page.locator('tbody tr[aria-selected="true"]')).toHaveCount(2);
    await page.getByRole('button', { name: 'Read models' }).click();
    await expect(page.getByText('Edited child / true / second / true / 2', { exact: true })).toBeVisible();
    await expect(page.locator('tbody tr')).toHaveCount(2);
  } else if (scenario === 'shim-controls') {
    const first = page.getByRole('radio', { name: 'First' });
    const second = page.getByRole('radio', { name: 'Second' });
    await expect(first).toBeChecked();
    await second.check();
    await expect(first).not.toBeChecked();
    await expect(second).toBeChecked();
    const toggle = page.getByRole('button', { name: 'Enabled' });
    await toggle.click();
    await expect(toggle).toHaveAttribute('aria-pressed', 'true');
    const spin = page.getByRole('spinbutton');
    await expect(spin).toHaveValue('0.5');
    await spin.fill('2.75');
    await page.getByRole('button', { name: 'Increase' }).click();
    await expect(spin).toHaveValue('2.9');
    await page.getByRole('searchbox').fill('query');
    await page.locator('summary', { hasText: 'Details' }).click();
    const text = page.locator('textarea');
    await expect(text).toBeVisible();
    await text.focus();
    // Force a server redraw without moving focus or depending on delivery timing.
    // Ruby must receive only the later, genuine blur when Details is collapsed.
    await page.getByRole('button', { name: 'Redraw fixture' }).evaluate(button => button.click());
    await expect(page.getByText('Redraw received', { exact: true })).toBeVisible();
    await expect(text).toBeFocused();
    await text.fill('line one\nline two');
    await page.locator('summary', { hasText: 'Details' }).click();
    await expect(text).not.toBeVisible();
    const image = page.locator('img[title="Fixture image"]');
    await expect(image).toBeVisible();
    await expect.poll(() => image.evaluate(element => element.naturalWidth)).toBe(1);
    const actions = page.getByText('Actions', { exact: true });
    await actions.click({ button: 'right' });
    const menuCheck = page.getByRole('menuitemcheckbox', { name: 'Menu enabled' });
    await expect(menuCheck).toBeFocused();
    // Real browser key activation complements DOM tests, which cannot synthesize
    // the browser's default Enter/Space click behavior.
    await page.keyboard.press('Space');
    await actions.click({ button: 'right' });
    await expect(menuCheck).toHaveAttribute('aria-checked', 'true');
    await page.keyboard.press('ArrowDown');
    await expect(page.getByRole('menuitem', { name: 'Choices', exact: true })).toBeFocused();
    await page.keyboard.press('ArrowRight');
    await expect(page.getByRole('menuitemradio', { name: 'Menu first' })).toBeFocused();
    await page.keyboard.press('ArrowDown');
    await expect(page.getByRole('menuitemradio', { name: 'Menu second' })).toBeFocused();
    await page.keyboard.press('Enter');
    await actions.click({ button: 'right' });
    await page.getByRole('menuitem', { name: 'Choices', exact: true }).click();
    await expect(page.getByRole('menuitemradio', { name: 'Menu first' })).toHaveAttribute('aria-checked', 'false');
    await expect(page.getByRole('menuitemradio', { name: 'Menu second' })).toHaveAttribute('aria-checked', 'true');
    await page.keyboard.press('Escape');
    await page.getByRole('menuitem', { name: 'Clear image', exact: true }).click();
    await expect(image).not.toBeVisible();
    await page.getByRole('button', { name: 'Save', exact: true }).click();
    await expect(spin).toHaveCount(0);
  } else {
    const entry = page.getByRole('textbox');
    await expect(entry).toHaveValue('');
    if (scenario === 'shim-entry') {
      const checkbox = page.getByRole('checkbox', { name: 'Shim checked' });
      await expect(checkbox).not.toBeChecked();
      await checkbox.check();
      await expect(checkbox).toBeChecked();
      await entry.fill('shim value');
    } else {
      const divider = page.locator('.webui-divider');
      await expect(divider).toBeVisible();
      await expect(divider).toHaveCSS('border-top-width', '1px');
      await expect(divider).toHaveCSS('margin-top', '0px');
      await expect(divider).toHaveCSS('margin-bottom', '0px');
      await entry.fill('shim separator');
    }
    await entry.press('Enter');
    await expect(entry).toHaveCount(0);
  }
  expect(errors).toEqual([]);
});
