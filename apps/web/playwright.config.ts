import { defineConfig } from "@playwright/test";
const basePath = process.env.NEXT_PUBLIC_BASE_PATH || "";
export default defineConfig({
  testDir: "./tests", fullyParallel: true, retries: 0, workers: 2,
  reporter: "list",
  use: { baseURL: `http://127.0.0.1:4173${basePath}/`, trace: "retain-on-failure" },
  projects: [
    { name: "desktop-light", use: { browserName: "chromium", viewport: { width: 1440, height: 960 }, colorScheme: "light" } },
    { name: "mobile-dark", use: { browserName: "chromium", viewport: { width: 390, height: 844 }, colorScheme: "dark", isMobile: true, hasTouch: true } },
    { name: "webkit", use: { browserName: "webkit", viewport: { width: 1280, height: 900 }, colorScheme: "dark", reducedMotion: "reduce" } },
  ],
  webServer: { command: "npm run preview", port: 4173, reuseExistingServer: !process.env.CI },
});
