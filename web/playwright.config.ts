import { defineConfig } from '@playwright/test';

// End-to-end tests drive the real Go server (serving web/dist) with two or
// three isolated browser contexts. Run `npm run build` first.
const port = 18081;

export default defineConfig({
  testDir: 'tests/e2e',
  timeout: 120_000,
  workers: 1,
  retries: 0,
  reporter: [['list']],
  use: {
    baseURL: `http://127.0.0.1:${port}`,
    channel: process.env.PW_CHANNEL ?? 'chromium',
    launchOptions: {
      args: [
        '--use-fake-device-for-media-stream',
        '--use-fake-ui-for-media-stream',
        '--auto-select-desktop-capture-source=Entire screen',
      ],
    },
  },
  webServer: {
    command: 'go run ./cmd/server',
    cwd: '..',
    url: `http://127.0.0.1:${port}/healthz`,
    reuseExistingServer: false,
    timeout: 120_000,
    env: {
      MSGR_ADDR: `127.0.0.1:${port}`,
      MSGR_DATA_DIR: 'web/test-results/data',
      MSGR_REGISTRATION: 'open',
      MSGR_WEB_DIR: 'web/dist',
    },
  },
});
