/// <reference types="vitest/config" />
import { defineConfig } from 'vite';
import preact from '@preact/preset-vite';

export default defineConfig({
  plugins: [preact()],
  server: {
    // During development the Go server runs on :8080; the UI is served by Vite.
    proxy: { '/api': { target: 'http://127.0.0.1:8080', ws: true } },
  },
  build: { target: 'es2022', sourcemap: false },
  test: { include: ['tests/**/*.test.ts'], environment: 'node', testTimeout: 60000 },
});
