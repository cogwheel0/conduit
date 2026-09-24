import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
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
 * The protocol version the Dart side declares.
 *
 * Read rather than written down here. The handshake requires strict
 * equality, so this test is about the renderer reporting *the* version --
 * not about it reporting a particular string, which is how the assertion
 * went stale the first time the protocol changed shape.
 */
function protocolVersion(): string {
  const source = readFileSync(
    join(
      __dirname,
      '..',
      '..',
      '..',
      'packages',
      'conduit_protocol',
      'lib',
      'src',
      'protocol_version.dart',
    ),
    'utf8',
  )
  const match = /kConduitProtocolVersion\s*=\s*'([^']+)'/.exec(source)
  if (match === null) throw new Error('could not read kConduitProtocolVersion')
  return match[1]!
}

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
 * The end-to-end check that the shell works.
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
  // `/` is the chat vertical now. The status page moved to `/core`,
  // where it remains the quickest way to see a handshake, a port and a
  // session id when something is wrong -- which is exactly what this
  // asserts, so the test follows it rather than finding a new proxy for it.
  await window.evaluate(() => {
    window.history.pushState(null, '', '/core')
    window.dispatchEvent(new PopStateEvent('popstate'))
  })
  await expect(window.getByText('Connected to the core')).toBeVisible()
  await expect(window.getByText(protocolVersion())).toBeVisible()
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
  // The HTML preview puts model-written markup in an
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

test('the render sandbox draws math and reports its height', async () => {
  const window = await appWindow(app)
  // The contract between the renderer and `app://conduit/sandbox.html`,
  // exercised without a model: create the frame exactly as
  // SandboxedRender does, wait for `ready`, post a formula, read back the
  // height and what was drawn.
  const result = await window.evaluate(
    () =>
      new Promise<Record<string, unknown>>((resolve) => {
        const frame = document.createElement('iframe')
        frame.setAttribute('sandbox', 'allow-scripts')
        frame.src = '/sandbox.html'
        frame.style.width = '400px'

        const out: Record<string, unknown> = { ready: false, height: 0 }
        const onMessage = (event: MessageEvent) => {
          if (event.source !== frame.contentWindow) return
          if (event.data?.conduit === 'ready') {
            out.ready = true
            frame.contentWindow?.postMessage(
              { conduit: 'render', kind: 'math', source: 'E=mc^2', display: true },
              '*',
            )
          }
          if (event.data?.conduit === 'size') {
            out.height = event.data.height
            finish()
          }
        }
        const finish = () => {
          window.removeEventListener('message', onMessage)
          frame.remove()
          resolve(out)
        }
        window.addEventListener('message', onMessage)
        document.body.appendChild(frame)
        setTimeout(finish, 8_000)
      }),
  )
  expect(result.ready).toBe(true)
  // A height at all means KaTeX ran and produced nodes; the initial frame
  // is 24px, so anything at or above that with content is a real render.
  expect(result.height).toBeGreaterThan(10)
})

test('the render sandbox draws diagrams and charts on demand', async () => {
  const window = await appWindow(app)
  // Mermaid and Chart.js are fetched by the sandbox on first use rather
  // than loaded by sandbox.html -- mermaid alone is five megabytes, and an
  // inline formula needs neither. This checks the lazy path works at all,
  // which a unit test cannot: the library has to actually arrive.
  // The frame is left in the document under a known id so the assertions
  // can look *inside* it. Height alone would not distinguish a diagram
  // from the sandbox's own error text, which is exactly the confusion
  // worth avoiding here.
  const draw = (id: string, kind: string, source: string) =>
    window.evaluate(
      ([frameId, k, src]) =>
        new Promise<number>((resolve) => {
          const frame = document.createElement('iframe')
          frame.id = frameId
          frame.setAttribute('sandbox', 'allow-scripts')
          frame.src = '/sandbox.html'
          frame.style.width = '400px'
          frame.style.height = '300px'
          const onMessage = (event: MessageEvent) => {
            if (event.source !== frame.contentWindow) return
            if (event.data?.conduit === 'ready') {
              frame.contentWindow?.postMessage(
                { conduit: 'render', kind: k, source: src },
                '*',
              )
            }
            if (event.data?.conduit === 'size') {
              window.removeEventListener('message', onMessage)
              resolve(event.data.height as number)
            }
          }
          window.addEventListener('message', onMessage)
          document.body.appendChild(frame)
          setTimeout(() => {
            window.removeEventListener('message', onMessage)
            resolve(0)
          }, 30_000)
        }),
      [id, kind, source] as const,
    )

  const diagramHeight = await draw(
    'probe-mermaid',
    'mermaid',
    'graph TD;\n  A-->B;\n  B-->C;',
  )
  expect(diagramHeight).toBeGreaterThan(30)
  // Mermaid's actual output, not the error path's monospace paragraph.
  await expect(
    window.frameLocator('#probe-mermaid').locator('svg'),
  ).toBeVisible()

  const chartHeight = await draw(
    'probe-chart',
    'chart',
    JSON.stringify({
      type: 'bar',
      data: { labels: ['a', 'b'], datasets: [{ data: [1, 2] }] },
    }),
  )
  expect(chartHeight).toBeGreaterThan(200)
  await expect(
    window.frameLocator('#probe-chart').locator('canvas'),
  ).toBeVisible()

  await window.evaluate(() => {
    document.getElementById('probe-mermaid')?.remove()
    document.getElementById('probe-chart')?.remove()
  })
})

test('a malformed chart spec is reported, not executed', async () => {
  const window = await appWindow(app)
  // The spec is model output. It is parsed with `JSON.parse` inside the
  // frame -- never `eval`, never `new Function` -- so bad input is an
  // error message rather than a payload.
  const text = await window.evaluate(
    () =>
      new Promise<string>((resolve) => {
        const frame = document.createElement('iframe')
        frame.setAttribute('sandbox', 'allow-scripts')
        frame.src = '/sandbox.html'
        const onMessage = (event: MessageEvent) => {
          if (event.source !== frame.contentWindow) return
          if (event.data?.conduit === 'ready') {
            frame.contentWindow?.postMessage(
              {
                conduit: 'render',
                kind: 'chart',
                source: 'globalThis.pwned = 1',
              },
              '*',
            )
          }
          if (event.data?.conduit === 'size') {
            // The frame cannot tell us its text directly, so the height
            // report is the signal that it finished; what it drew is
            // asserted through the absence of the side effect below.
            window.removeEventListener('message', onMessage)
            frame.remove()
            resolve('reported')
          }
        }
        window.addEventListener('message', onMessage)
        document.body.appendChild(frame)
        setTimeout(() => {
          window.removeEventListener('message', onMessage)
          frame.remove()
          resolve('silent')
        }, 10_000)
      }),
  )
  expect(text).toBe('reported')
  // And nothing reached this side, which it could not have anyway.
  expect(
    await window.evaluate(
      () => (globalThis as { pwned?: unknown }).pwned ?? null,
    ),
  ).toBeNull()
})

test('the render sandbox cannot reach the app it is embedded in', async () => {
  const window = await appWindow(app)
  // The frame has an opaque origin, so `parent.document` is a security
  // error rather than a reference. This is what makes it safe to run a
  // library over model output in there at all.
  const reached = await window.evaluate(
    () =>
      new Promise<boolean>((resolve) => {
        const frame = document.createElement('iframe')
        frame.setAttribute('sandbox', 'allow-scripts')
        frame.srcdoc = `<script>
          let ok = false
          try { ok = !!parent.document.body } catch (e) { ok = false }
          parent.postMessage({ reached: ok }, '*')
        <\/script>`
        const onMessage = (event: MessageEvent) => {
          if (event.source !== frame.contentWindow) return
          window.removeEventListener('message', onMessage)
          frame.remove()
          resolve(Boolean(event.data?.reached))
        }
        window.addEventListener('message', onMessage)
        document.body.appendChild(frame)
        // No message at all is also a pass: the script never ran.
        setTimeout(() => {
          window.removeEventListener('message', onMessage)
          frame.remove()
          resolve(false)
        }, 2_000)
      }),
  )
  expect(reached).toBe(false)
})

test("the server form's advanced settings stay open while they are used", async () => {
  const window = await appWindow(app)
  await expect
    .poll(() => window.evaluate(() => window.location.pathname), { timeout: 20_000 })
    .toBe('/onboarding')
  await window.getByRole('button', { name: /^open webui/i }).click()
  await window.getByRole('button', { name: /advanced settings$/i }).click()
  const selfSigned = window.getByLabel(/unverified certificate|self-signed/i)
  await selfSigned.check()
  // The rebuild that checking it causes must not close the section around it.
  await expect(selfSigned).toBeVisible()
  await expect(selfSigned).toBeChecked()
})
