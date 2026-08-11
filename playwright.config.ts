import { defineConfig, devices } from '@playwright/test';
export default defineConfig({ testDir: './tests/e2e', fullyParallel: true, retries: 0, reporter: 'list', use: { baseURL: 'http://127.0.0.1:3100', trace: 'retain-on-failure' }, webServer: { command: 'npm run build && npm start -- --hostname 127.0.0.1 --port 3100', url: 'http://127.0.0.1:3100/es', reuseExistingServer: false, timeout: 180_000 }, projects: [
  { name: '320', use: { ...devices['Desktop Chrome'], viewport: { width: 320, height: 800 } } },
  { name: '375', use: { ...devices['Desktop Chrome'], viewport: { width: 375, height: 812 } } },
  { name: '390', use: { ...devices['Desktop Chrome'], viewport: { width: 390, height: 844 } } },
  { name: '768', use: { ...devices['Desktop Chrome'], viewport: { width: 768, height: 900 } } },
  { name: '1024', use: { ...devices['Desktop Chrome'], viewport: { width: 1024, height: 900 } } },
  { name: '1440', use: { ...devices['Desktop Chrome'], viewport: { width: 1440, height: 1000 } } },
] });
