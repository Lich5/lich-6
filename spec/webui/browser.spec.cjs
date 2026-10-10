const { test, expect } = require('@playwright/test');

// Ruby owns the service and verifies the resulting script-side state. Each run
// starts with a fresh browser cookie jar and the actual private file bootstrap.
const scenario = process.env.WEBUI_TEST_SCENARIO;
test(`WebUI ${scenario || 'missing fixture'}`, async ({ page, context }) => {
  const target = process.env.WEBUI_TEST_URL;
  expect(target, 'Run through the browser-tagged RSpec fixtures').toMatch(/^file:\/\//);
  expect(['shim-entry', 'shim-separator', 'shim-controls', 'shim-models', 'shim-builder', 'shim-ewaggle', 'shim-ebounty', 'shim-eherbs', 'shim-blackarts', 'shim-repository', 'shim-go2', 'native-bootstrap']).toContain(scenario);
  const errors = [];
  const documents = [];
  page.on('pageerror', error => errors.push(error.message));
  page.on('response', response => {
    if (response.request().resourceType() === 'document') documents.push(response);
  });
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

  if (['shim-repository', 'shim-go2'].includes(scenario)) {
    const ids = JSON.parse(process.env.WEBUI_TEST_CONTROLS);
    const widget = name => page.locator(`[data-cid="${ids[name]}"]`);
    if (scenario === 'shim-repository') {
      await expect(page.getByRole('tab')).toHaveCount(0);
      const table = widget('repository');
      await expect(table.locator('tbody tr')).toHaveCount(2);
      await table.getByRole('button', { name: 'Size', exact: true }).click();
      await expect(table.locator('tbody tr').first()).toContainText('zeta.lic');
      await widget('search_entry').fill('travel');
      await expect(table.locator('tbody tr')).toHaveCount(1);
      await table.getByText('alpha.lic', { exact: true }).click();
      await expect(widget('comments')).toHaveText('Alpha comments');
      await expect(widget('download_link')).toHaveText('alpha.lic');
      await widget('download_link').click();
    } else {
      await widget('delay').fill('7');
      await widget('echo_input').uncheck();
    }
    await page.getByRole('button', { name: 'Close', exact: true }).click();
    await expect(page.locator('.webui-page')).toHaveCount(0);
  } else if (scenario === 'native-bootstrap') {
    await page.getByRole('button', { name: 'Activate' }).click();
    await expect(page.getByText('Callback received', { exact: true })).toBeVisible();
  } else if (['shim-ebounty', 'shim-eherbs', 'shim-blackarts'].includes(scenario)) {
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
      await expect(widget(name)).toBeVisible();
      return widget(name);
    };
    await page.setViewportSize(scenario === 'shim-eherbs' ? { width: 800, height: 700 } : { width: 1000, height: 850 });
    if (scenario === 'shim-ebounty') {
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
    await empty.locator('tbody tr').dragTo(destination, { targetPosition: await blankArea(destination) });
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
