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
  // `/` is the chat vertical now (M3). The status page moved to `/core`,
  // where it remains the quickest way to see a handshake, a port and a
  // session id when something is wrong -- which is exactly what this
  // asserts, so the test follows it rather than finding a new proxy for it.
  await window.evaluate(() => {
    window.history.pushState(null, '', '/core')
    window.dispatchEvent(new PopStateEvent('popstate'))
  })
  await expect(window.getByText('Connected to the core')).toBeVisible()
  await expect(window.getByText('1.0.0')).toBeVisible()
})

test('a first run is sent to onboarding once the session resolves', async () => {
  const window = await appWindow(app)
  // The guard cannot answer until `servers.list` and `auth.status` both
  // return, and it deliberately does not redirect on an unknown state --
  // so this is the check that it acts once it *can* answer.
  await expect
    .poll(() => window.evaluate(() => window.location.pathname), {
      timeout: 20_000,
    })
    .toBe('/onboarding')
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
  // The origin, not the exact URL: the session guard legitimately moves the
  // window to /onboarding on a first run, and pinning the path would make
  // this security check fail for an unrelated reason.
  expect(new URL(window.url()).origin).toBe(new URL(APP_URL).origin)
})

test('a previewed reply cannot run a script, twice over', async () => {
  const window = await appWindow(app)
  // The HTML preview (WP-3.5) puts model-written markup in an
  // `<iframe sandbox srcdoc>`. Two independent things must stop a script in
  // it, and this measures both rather than trusting either.
  const result = await window.evaluate(
    () =>
      new Promise<Record<string, string>>((resolve) => {
        const out: Record<string, string> = {}
        const doc = (label: string) =>
          `<!doctype html><html><body><script>parent.postMessage({probe:'${label}'},'*')<\/script></body></html>`

        const probe = (label: string, apply: (f: HTMLIFrameElement) => void) =>
          new Promise<void>((done) => {
            const frame = document.createElement('iframe')
            apply(frame)
            const onMessage = (event: MessageEvent) => {
              if (event.data?.probe === label) {
                out[label] = 'RAN'
                finish()
              }
            }
            const finish = () => {
              out[label] ??= 'blocked'
              window.removeEventListener('message', onMessage)
              frame.remove()
              done()
            }
            window.addEventListener('message', onMessage)
            document.body.appendChild(frame)
            setTimeout(finish, 1_500)
          })

        void (async () => {
          // What the preview actually renders: every restriction on.
          await probe('sandboxed', (f) => {
            f.setAttribute('sandbox', '')
            f.srcdoc = doc('sandboxed')
          })
          // And the second line of defence on its own -- a `srcdoc`
          // document inherits this origin's `script-src 'self' app:`, so an
          // inline script is refused even with the sandbox relaxed. If this
          // ever starts reporting RAN, the preview is resting on one
          // mechanism instead of two.
          await probe('csp-only', (f) => {
            f.setAttribute('sandbox', 'allow-scripts')
            f.srcdoc = doc('csp-only')
          })
          resolve(out)
        })()
      }),
  )
  expect(result).toEqual({ sandboxed: 'blocked', 'csp-only': 'blocked' })
})
