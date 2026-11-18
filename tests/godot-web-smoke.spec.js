const { test, expect } = require('@playwright/test');

test('Godot Web loads, accepts keyboard input, and has no uncaught page errors', async ({ page }) => {
  const pageErrors = [];
  page.on('pageerror', (error) => pageErrors.push(error.message));

  const response = await page.goto('http://127.0.0.1:8080/', {
    waitUntil: 'domcontentloaded',
    timeout: 30000,
  });
  expect(response?.ok(), 'Web server should return a successful response').toBeTruthy();

  const canvas = page.locator('canvas');
  await expect(canvas).toBeVisible({ timeout: 60000 });
  await expect.poll(async () => canvas.evaluate((el) => el.width > 0 && el.height > 0), {
    timeout: 30000,
    message: 'Godot canvas should have nonzero dimensions',
  }).toBe(true);

  await canvas.click();
  await page.keyboard.down('w');
  await page.waitForTimeout(500);
  await page.keyboard.up('w');
  await page.keyboard.press('ArrowRight');

  expect(pageErrors, pageErrors.join('\n')).toEqual([]);
});
