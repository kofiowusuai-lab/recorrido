import { expect, test } from '@playwright/test';

test('localized landing page is complete and has no overflow or console errors', async ({ page }, testInfo) => {
  const errors: string[] = []; page.on('console', (message) => { if (message.type() === 'error') errors.push(message.text()); });
  await page.goto('/es'); await expect(page.getByRole('heading', { level: 1 })).toContainText('Convierte fotos');
  await expect(page.locator('#product')).toBeVisible(); await expect(page.locator('#pricing')).toContainText('$22');
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= document.documentElement.clientWidth)).toBe(true);
  expect(errors).toEqual([]); await page.screenshot({ path: `test-results/${testInfo.project.name}-landing.png`, fullPage: true });
});

test('navigation, locale, pricing, modal focus and fail-closed checkout work', async ({ page }) => {
  await page.goto('/es'); if ((await page.viewportSize())!.width <= 800) await page.getByRole('button', { name: /menu/i }).click();
  await page.getByRole('link', { name: 'PT' }).click(); await expect(page).toHaveURL(/\/pt$/);
  await page.locator('#pricing').scrollIntoViewIfNeeded(); await page.getByRole('button', { name: 'Anual' }).click(); await expect(page.locator('.plans')).toContainText('$320');
  await page.locator('.plan.featured').getByRole('button').click(); const dialog = page.getByRole('dialog'); await expect(dialog).toBeVisible(); await expect(dialog.locator('input[name=name]')).toBeFocused();
  await dialog.locator('input[name=name]').fill('Bia Lima'); await dialog.locator('input[name=email]').fill('bia@example.com'); await dialog.locator('input[name=whatsapp]').fill('11999999999'); await dialog.getByRole('button', { name: /pagamento/i }).click(); await expect(dialog.getByRole('alert')).toBeVisible();
  await page.keyboard.press('Escape'); await expect(dialog).not.toBeVisible();
});

test('reduced motion renders a static equivalent and routes survive history', async ({ browser }) => {
  const context = await browser.newContext({ reducedMotion: 'reduce', viewport: { width: 390, height: 844 } }); const page = await context.newPage();
  await page.goto('/en'); await expect(page.locator('.route-progress')).toHaveCSS('transform', 'matrix(1, 0, 0, 1, 0, 0)'); await page.goto('/en/privacy'); await page.goBack(); await expect(page.getByRole('heading', { level: 1 })).toBeVisible(); await context.close();
});
