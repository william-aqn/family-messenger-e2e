// The browser peer of the app's integration test (app/integration_test):
// no web server here, scripts/app-video-call-test.ps1 starts one and points
// TEST_BASE_URL at it.
import { defineConfig, devices } from '@playwright/test';
import path from 'node:path';

// A silent file for the fake microphone; the default fake input is a loud beep.
const silence = path.resolve(process.cwd(), 'tests/peer/silence.wav');

export default defineConfig({
  testDir: 'tests/peer',
  timeout: 10 * 60_000,
  retries: 0,
  workers: 1,
  reporter: 'line',
  use: {
    baseURL: process.env.TEST_BASE_URL ?? 'http://127.0.0.1:18082',
    ...devices['Desktop Chrome'],
    channel: process.env.PW_CHANNEL ?? 'chromium',
    launchOptions: {
      args: [
        '--use-fake-device-for-media-stream',
        '--use-fake-ui-for-media-stream',
        `--use-file-for-fake-audio-capture=${silence}`,
        '--auto-select-desktop-capture-source=Entire screen',
      ],
    },
  },
});
