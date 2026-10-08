const { defineConfig } = require('@playwright/test');

module.exports = defineConfig({
  testDir: __dirname,
  testMatch: 'browser.spec.cjs',
  workers: 1,
  retries: 0,
  timeout: 30_000,
  globalTimeout: 60_000,
  expect: { timeout: 10_000 },
  reporter: 'line',
  use: {
    browserName: 'chromium',
    channel: 'chrome',
    headless: true,
    viewport: { width: 640, height: 480 },
    actionTimeout: 10_000,
    navigationTimeout: 10_000,
    screenshot: 'only-on-failure',
    trace: 'retain-on-failure',
  },
});
