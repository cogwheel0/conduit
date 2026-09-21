import { defineConfig } from '@playwright/test'

export default defineConfig({
  testDir: './tests',
  // Electron launches are serial by nature: each one spawns a daemon that
  // takes the single-instance lock on the same userData directory.
  workers: 1,
  fullyParallel: false,
  // A cold start compiles nothing but does spawn a process and bind a port.
  timeout: 60_000,
  expect: { timeout: 15_000 },
  reporter: process.env['CI'] === undefined ? 'list' : [['list'], ['github']],
})
