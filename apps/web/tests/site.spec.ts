import { test, expect } from "@playwright/test";
import AxeBuilder from "@axe-core/playwright";

const routes = ["", "how-it-works/", "download/", "compatibility/", "security/", "privacy/", "support/", "releases/", "impressum/"];

test("all static routes render with accessible structure, local assets and valid internal links", async ({ page, baseURL }) => {
  const errors: string[] = [];
  const remoteRequests: string[] = [];
  page.on("pageerror", error => errors.push(error.message));
  page.on("console", message => { if (message.type() === "error") errors.push(message.text()); });
  page.on("request", request => { if (!request.url().startsWith("http://127.0.0.1:")) remoteRequests.push(request.url()); });
  const links = new Set<string>();
  for (const route of routes) {
    const response = await page.goto(route || "./");
    expect(response?.status()).toBe(200);
    await expect(page.locator("h1")).toBeVisible();
    await expect(page.locator('link[rel="canonical"]')).toHaveAttribute("href", new RegExp(`/${route}$`));
    await expect(page.locator('meta[http-equiv="Content-Security-Policy"]')).toHaveCount(1);
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    for (const image of await page.locator("img:visible").all()) {
      await image.scrollIntoViewIfNeeded();
      await expect.poll(() => image.evaluate(node => node instanceof HTMLImageElement && node.complete && node.naturalWidth > 0)).toBe(true);
    }
    const findings = await new AxeBuilder({ page }).withTags(["wcag2a", "wcag2aa", "wcag21aa"]).analyze();
    expect(findings.violations).toEqual([]);
    for (const href of await page.locator('a[href]').evaluateAll(items => items.map(item => (item as HTMLAnchorElement).href))) {
      if (href.startsWith(baseURL!)) links.add(href.split("#")[0]);
    }
  }
  for (const href of links) expect((await page.request.get(href)).status(), href).toBe(200);
  expect(errors).toEqual([]);
  expect(remoteRequests).toEqual([]);
  expect(await page.context().cookies()).toEqual([]);
  expect(await page.evaluate(() => localStorage.length)).toBe(0);
});

test("simulation is reversible and explicitly distinct from hardware access", async ({ page }) => {
  await page.goto("./");
  await expect(page.getByRole("status")).toContainText("USB connection selected");
  await page.getByRole("button", { name: "Simulate removal" }).click();
  await expect(page.getByRole("status")).toContainText("Lock requested");
  await expect(page.getByText("Browser simulation only.", { exact: false })).toBeVisible();
  await page.getByRole("button", { name: "Reset demo" }).click();
  await expect(page.getByRole("status")).toContainText("USB connection selected");
  const faq = page.getByText("Can I use Pullock for protection today?", { exact: true });
  await faq.click();
  await expect(page.getByText("No. The current build", { exact: false })).toBeVisible();
});

test("keyboard navigation and missing-page recovery work", async ({ page, browserName }) => {
  await page.goto("./");
  // macOS WebKit follows Safari's default Option-Tab navigation for links.
  await page.keyboard.press(browserName === "webkit" && process.platform === "darwin" ? "Alt+Tab" : "Tab");
  await expect(page.getByRole("link", { name: "Skip to content" })).toBeFocused();
  await page.keyboard.press("Enter");
  expect(await page.evaluate(() => location.hash)).toBe("#main");
  const response = await page.goto("does-not-exist/");
  expect(response?.status()).toBe(404);
  await page.getByRole("link", { name: "Back to Pullock" }).click();
  await expect(page.locator("h1")).toHaveText("Pull the key.Lock the Device.");
});
