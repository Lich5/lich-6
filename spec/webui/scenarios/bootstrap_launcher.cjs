// Scenario callbacks are inert until the Ruby-owned browser run selects one.

async function runNativeBootstrap({ page, expect }) {
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
}

async function runLauncherUnlock({ page, expect }) {
    const dialog = page.getByRole('dialog');
    const password = dialog.locator('input[type="password"]');
    await expect(password).toBeVisible();
    await password.fill('fixture-password');
    await expect(password).toBeFocused();
    await dialog.getByRole('button', { name: 'Unlock', exact: true }).click();
    await expect(dialog).toContainText('Master password was not accepted.');
    await expect(password).toBeEditable();
    await dialog.getByRole('button', { name: 'Cancel', exact: true }).click();
    await expect(dialog).toHaveCount(0);
    await expect(page.getByText('Unlock cancelled')).toBeVisible();
}

module.exports = [
  { id: 'launcher-unlock', run: runLauncherUnlock },
  { id: 'native-bootstrap', run: runNativeBootstrap },
];
