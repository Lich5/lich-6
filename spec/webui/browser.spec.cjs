const { test, expect } = require('@playwright/test');

// Ruby owns the service and verifies the resulting script-side state. Each run
// starts with a fresh browser cookie jar and the actual private file bootstrap.
const scenario = process.env.WEBUI_TEST_SCENARIO;
test(`WebUI ${scenario || 'missing fixture'}`, async ({ page, context }) => {
  const target = process.env.WEBUI_TEST_URL;
  expect(target, 'Run through the browser-tagged RSpec fixtures').toMatch(/^file:\/\//);
  expect(['shim-entry', 'shim-separator', 'native-bootstrap']).toContain(scenario);
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

  if (scenario === 'native-bootstrap') {
    await page.getByRole('button', { name: 'Activate' }).click();
    await expect(page.getByText('Callback received', { exact: true })).toBeVisible();
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
