import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: "./tests/browser",
  fullyParallel: true,
  forbidOnly: Boolean(process.env.CI),
  retries: process.env.CI ? 1 : 0,
  reporter: "line",
  // Baselines are rendered on Linux only (see scripts/update-visual-baselines.sh);
  // no platform suffix so the committed files are the single source of truth.
  snapshotPathTemplate: "{testDir}/{testFileDir}/{testFileName}-snapshots/{arg}{ext}",
  use: {
    baseURL: "http://127.0.0.1:4173",
    browserName: "chromium",
    locale: "tr-TR",
    trace: "retain-on-failure"
  },
  webServer: {
    command: "npx vite --host 127.0.0.1 --port 4173",
    url: "http://127.0.0.1:4173",
    reuseExistingServer: !process.env.CI
  }
});
