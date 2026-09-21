import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import {
  _electron as electron,
  expect,
  test,
  type ElectronApplication,
  type Page,
} from '@playwright/test'

const APP_URL = 'app://conduit/'

/**
 * Waits for the renderer to actually be on the app origin.
 *
 * `firstWindow()` resolves the moment a BrowserWindow is constructed, which
 * is before `loadURL` has navigated it — at that point `url()` is still the
 * empty initial document and `waitForLoadState` returns immediately.
 */
async function appWindow(app: ElectronApplication): Promise<Page> {
  const window = await app.firstWindow()
  await expect.poll(() => window.url(), { timeout: 30_000 }).toBe(APP_URL)
  await window.waitForLoadState('domcontentloaded')
  return window
}

/**
 * The end-to-end check that the shell works (section 10).
 *
 * It exercises the whole chain in one go: Electron spawns conduitd, the
 * daemon binds a loopback port and reports it on stdout, the preload bridge
 * hands the port and session token to the renderer, the renderer opens a
 * WebSocket that passes the origin and token checks, and `system.handshake`
 * agrees on a protocol version. Any broken link shows up as a failure here.
 */
let app: ElectronApplication
let userDataDir: string

test.beforeEach(async () => {
  // A fresh profile per test: the single-instance lock and the SQLite file
  // are both per-userData, and a leaked one makes the next run flaky.
  userDataDir = mkdtempSync(join(tmpdir(), 'conduit-e2e-'))
  app = await electron.launch({
    args: [
      '.',
      `--user-data-dir=${userDataDir}`,
      // CI containers have no user namespaces for the Chromium sandbox.
      '--no-sandbox',
    ],
    cwd: join(__dirname, '..'),
  })
})

test.afterEach(async () => {
  await app.close().catch(() => undefined)
  rmSync(userDataDir, { recursive: true, force: true })
})

test('serves the renderer from the app:// origin', async () => {
  // A `file://` page would be an opaque origin and the daemon would reject
  // its socket, so the scheme itself is part of the contract.
  await appWindow(app)
})

test('hands the renderer a port and token through the preload bridge', async () => {
  const window = await appWindow(app)
  const bridge = await window.evaluate(() => {
    const value = (globalThis as unknown as { conduit?: Record<string, unknown> }).conduit
    return value === undefined ? null : { ...value }
  })
  expect(bridge).not.toBeNull()
  expect(bridge?.['rpcPort']).toBeGreaterThan(0)
  expect(String(bridge?.['token'] ?? '')).toHaveLength(43)
  expect(bridge?.['windowKind']).toBe('main')
})

test('connects to the core and reports the handshake', async () => {
  const window = await appWindow(app)
  // The status page only renders this once system.handshake has returned.
  await expect(window.getByText('Connected to the core')).toBeVisible()
  await expect(window.getByText('1.0.0')).toBeVisible()
})

test('keeps Node out of the renderer', async () => {
  const window = await appWindow(app)
  const exposed = await window.evaluate(() => ({
    hasRequire: typeof (globalThis as { require?: unknown }).require !== 'undefined',
    hasProcess: typeof (globalThis as { process?: unknown }).process !== 'undefined',
  }))
  // contextIsolation + sandbox + nodeIntegration:false. Model output renders
  // in this origin, so a leak here is a remote code execution primitive.
  expect(exposed.hasRequire).toBe(false)
  expect(exposed.hasProcess).toBe(false)
})

test('refuses to navigate the app origin away to the web', async () => {
  const window = await appWindow(app)
  // Chromium may tear the execution context down as it begins the navigation
  // that `will-navigate` then vetoes, so the evaluate itself can reject. What
  // matters is where the window ends up.
  await window
    .evaluate(() => {
      globalThis.location.assign('https://example.com/')
    })
    .catch(() => undefined)
  await window.waitForTimeout(1_000)
  expect(window.url()).toBe(APP_URL)
})
