import { mkdirSync, mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import {
  _electron as electron,
  expect,
  test,
  type ElectronApplication,
  type Page,
} from '@playwright/test'

/**
 * The whole app, against a real Open WebUI server.
 *
 * Everything else in this directory proves the shell starts. This proves the
 * product works: onboarding, sign-in, a model list, a sent message and a
 * streamed reply, through the daemon and the real server.
 *
 * Skipped unless credentials are present, so it never fails a clean clone or
 * a CI job without a server. Set them in a `.env` at the repository root:
 *
 *   OWUI_URL=https://chat.example.com
 *   OWUI_EMAIL=you@example.com
 *   OWUI_PASSWORD=...
 *   OWUI_MODEL=llama3.2:1b          # optional
 *
 * `OWUI_MODEL` is worth setting on a server that offers models the account
 * cannot actually use. Without it the daemon falls back to the first model
 * the server lists, and a refusal ("your plan does not include this model")
 * is a real failure the test would report as one.
 *
 * The password is typed into a `type=password` field and never logged. The
 * file is gitignored, as is `test-results/`.
 */
interface Credentials {
  readonly url: string
  readonly email: string
  readonly password: string
  readonly model: string | undefined
}

function readCredentials(): Credentials | null {
  // The repo root from desktop/electron/tests.
  const envPath = join(__dirname, '..', '..', '..', '.env')
  let raw: string
  try {
    raw = readFileSync(envPath, 'utf8')
  } catch {
    return null
  }
  const values = new Map<string, string>()
  for (const line of raw.split('\n')) {
    const match = /^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/.exec(line)
    if (match === null) continue
    // Strip one layer of quoting, which is how a value with spaces is
    // written and is not part of the value.
    values.set(match[1]!, match[2]!.replace(/^["']|["']$/g, ''))
  }
  const url = values.get('OWUI_URL')
  const email = values.get('OWUI_EMAIL')
  const password = values.get('OWUI_PASSWORD')
  if (url === undefined || email === undefined || password === undefined) {
    return null
  }
  // Read from the same file, not from `process.env`: nothing exports these
  // into the shell, so reaching for the environment quietly meant the model
  // was never chosen and the run used whatever the server listed first.
  return { url, email, password, model: values.get('OWUI_MODEL') }
}

const credentials = readCredentials()

/// Where screenshots land for review.
///
/// Outside `test-results/`, which is wiped between runs, and gitignored for
/// the same reason that directory is: these are pictures of a signed-in app.
const shotDir = join(__dirname, '..', 'screenshots')

async function shot(page: Page, name: string): Promise<void> {
  mkdirSync(shotDir, { recursive: true })
  await page.screenshot({ path: join(shotDir, `${name}.png`) })
}

test.describe('against a real server', () => {
  test.skip(credentials === null, 'no OWUI_* credentials in .env')
  // A cold start, a sign-in round trip and a model reply.
  test.setTimeout(180_000)

  let app: ElectronApplication
  let userData: string

  test.beforeAll(async () => {
    userData = mkdtempSync(join(tmpdir(), 'conduit-live-'))
    app = await electron.launch({
      args: [
        '.',
        `--user-data-dir=${userData}`,
        // CI containers have no user namespaces for the Chromium sandbox.
        '--no-sandbox',
      ],
      cwd: join(__dirname, '..'),
    })
    // The daemon logs to stderr and Electron inherits it; surfacing it here
    // is the difference between "Login failed" and knowing why.
    app.process().stderr?.on('data', (chunk: Buffer) => {
      process.stderr.write(`[daemon] ${chunk.toString()}`)
    })
  })

  test.afterAll(async () => {
    await app?.close()
    rmSync(userData, { recursive: true, force: true })
  })

  async function window(): Promise<Page> {
    const page = await app.firstWindow()
    page.on('console', (message) => {
      if (message.text().startsWith('[event]')) {
        process.stderr.write(`[renderer] ${message.text()}\n`)
      }
    })
    await expect
      .poll(() => page.url(), { timeout: 30_000 })
      .toContain('app://conduit')
    await page.waitForLoadState('domcontentloaded')
    return page
  }

  test('onboards, signs in, and streams a reply', async () => {
    const page = await window()
    const { url, email, password, model } = credentials!

    // 1. Onboarding. The session guard should already have put us here.
    await expect
      .poll(() => page.evaluate(() => window.location.pathname), {
        timeout: 30_000,
      })
      .toBe('/onboarding')

    await shot(page, '01-onboarding')
    await page.getByLabel(/server address/i).fill(url)
    await page.getByRole('button', { name: /^connect$/i }).click()

    // 2. Sign-in, which the guard routes to once a server is active.
    await expect
      .poll(() => page.evaluate(() => window.location.pathname), {
        timeout: 60_000,
      })
      .toBe('/sign-in')

    await shot(page, '02-sign-in')
    await page.getByLabel(/email or username/i).fill(email)
    await page.locator('#password').fill(password)
    await page.getByRole('button', { name: /^sign in$/i }).click()

    // 3. The chat vertical.
    await expect
      .poll(() => page.evaluate(() => window.location.pathname), {
        timeout: 60_000,
      })
      .toBe('/')
    await expect(page.getByPlaceholder('Ask Conduit')).toBeVisible()

    await shot(page, '03-chat-empty')

    // 4. A model list the daemon fetched from the server.
    const picker = page.locator('#model')
    await expect(picker).toBeVisible({ timeout: 30_000 })
    const values = await picker
      .locator('option')
      .evaluateAll((nodes) => nodes.map((n) => (n as HTMLOptionElement).value))
    expect(values.length).toBeGreaterThan(0)

    // By value, not label: the picker shows a model's display name while the
    // daemon addresses it by id, and they differ for most of them.
    //
    // Picked explicitly because the daemon's fallback is "the first model
    // offered", which on a real server is as likely as not to be one the
    // account cannot use.
    if (model !== undefined) {
      expect(values, `OWUI_MODEL=${model} is not offered by the server`)
        .toContain(model)
      await picker.selectOption(model)
    }

    // 5. The sidebar shows the account's real conversations, which only
    // happens once the daemon has certified the account and pulled.
    await expect
      .poll(
        () => page.locator('nav[aria-label] li').count(),
        { timeout: 60_000 },
      )
      .toBeGreaterThan(0)

    // 6. Search runs against the database's index, not the loaded page.
    await shot(page, '04-sidebar')
    const before = await page.locator('nav[aria-label] li').count()
    await page.getByLabel(/search conversations/i).fill('the')
    // Hits, not merely "a different number of rows": while the debounced
    // query was in flight the sidebar showed no rows at all, so `not.toBe`
    // passed on the empty pane and the search itself was never checked.
    const hits = page.locator('nav[aria-label] li')
    await expect.poll(() => hits.count(), { timeout: 30_000 })
      .toBeGreaterThan(0)
    await expect.poll(() => hits.count(), { timeout: 30_000 }).not.toBe(before)
    // The index returns the matching text, which is the point of searching
    // the database rather than filtering the loaded page.
    await expect(hits.first()).toContainText(/the/i)
    await shot(page, '05-search')
    await page.getByLabel(/search conversations/i).fill('')
    await expect
      .poll(() => page.locator('nav[aria-label] li').count(), {
        timeout: 30_000,
      })
      .toBe(before)

    // 7. The keyboard layer (WP-3.7). Ctrl+/ is bound at the document, so
    // it has to work with focus wherever the last step left it.
    await page.keyboard.press('Control+Slash')
    const overlay = page.getByRole('dialog', { name: /keyboard shortcuts/i })
    await expect(overlay).toBeVisible()
    await expect(overlay).toContainText('Ctrl+K')
    await shot(page, '06-shortcuts')
    // Esc closes what is in front before it reaches anything behind it.
    await page.keyboard.press('Escape')
    await expect(overlay).toBeHidden()

    // Ctrl+K from nowhere in particular puts the caret in search.
    await page.keyboard.press('Control+k')
    await expect(page.getByLabel(/search conversations/i)).toBeFocused()

    // 8. Send with Enter rather than the button, which is how the app is
    // actually used, and is a different code path from clicking.
    await page.keyboard.press('Shift+Escape')
    await expect(page.getByPlaceholder('Ask Conduit')).toBeFocused()
    await page.keyboard.type('Reply with exactly the word: pong')
    await page.keyboard.press('Enter')

    const transcript = page.getByRole('log')
    await expect(transcript).toContainText('Reply with exactly', {
      timeout: 30_000,
    })
    // The assistant bubble appears as soon as the first delta lands, so this
    // is the check that streaming reaches the renderer at all.
    await expect
      .poll(async () => (await transcript.innerText()).length, {
        timeout: 120_000,
      })
      .toBeGreaterThan('Reply with exactly the word: pong'.length + 2)

    // Sending clears the field. A textarea's value stops tracking its
    // markup once it is typed into, so the Dart state going empty is not
    // enough -- and the next message would have carried the last one along.
    // Only a real browser can catch this; the component tester cannot type.
    await expect(page.getByPlaceholder('Ask Conduit')).toHaveValue('')
    await expect(page.getByPlaceholder('Ask Conduit')).toBeFocused()

    await shot(page, '07-reply')

    // 9. A code block, highlighted and copyable (WP-3.5). The prompt is
    // narrow because a 1B model will happily write an essay around it.
    await page.keyboard.type(
      'Reply with only a fenced Python code block that prints hello. ' +
        'No prose.',
    )
    await page.keyboard.press('Enter')
    const block = transcript.locator('pre code').last()
    await expect(block).toBeVisible({ timeout: 120_000 })
    // Tokens, not one text node -- which is what tells us the highlighter
    // ran rather than the block falling back to plain monospace.
    await expect(block.locator('.hljs-string, .hljs-keyword').first())
      .toBeVisible({ timeout: 120_000 })
    // And the colour resolves. A palette variable that does not exist
    // leaves the declaration invalid and the token inheriting, which looks
    // exactly like no highlighting at all.
    const tokenColour = await block
      .locator('.hljs-string, .hljs-keyword')
      .first()
      .evaluate((node) => getComputedStyle(node).color)
    const bodyColour = await page
      .locator('body')
      .evaluate((node) => getComputedStyle(node).color)
    expect(tokenColour).not.toBe(bodyColour)
    await shot(page, '08-code')

    // 10. A markup block offers an inert preview, and nothing else does.
    await page.keyboard.type(
      'Reply with only a fenced html code block containing ' +
        '<h1 style="color:teal">Conduit</h1>. No prose.',
    )
    await page.keyboard.press('Enter')
    const preview = transcript
      .getByRole('button', { name: /^preview$/i })
      .last()
    await expect(preview).toBeVisible({ timeout: 120_000 })
    await preview.click()
    const frame = transcript.locator('iframe').last()
    await expect(frame).toBeVisible()
    await expect(frame).toHaveAttribute('sandbox', '')
    // Rendered, not executed: a heading exists inside the frame.
    //
    // `.first` throughout this section. The model is asked for exact
    // output and usually obliges, but a stray extra element is its
    // prerogative and not something the app got wrong -- a strict-mode
    // violation here would be the test asserting on the model.
    await expect(
      frame.contentFrame().locator('h1').first(),
    ).toBeVisible({ timeout: 15_000 })
    await shot(page, '09-preview')

    // 11. Math, drawn by KaTeX inside the sandbox.
    //
    // Focus first: clicking Preview left it on that button, and typing
    // would have gone there. Shift+Esc is the app's own way back to the
    // composer, so using it here is also what a user would do.
    await page.keyboard.press('Shift+Escape')
    await expect(page.getByPlaceholder('Ask Conduit')).toBeFocused()
    await page.keyboard.type(
      'Reply with only this and nothing else: $E = mc^2$',
    )
    await page.keyboard.press('Enter')
    const math = transcript.locator('iframe[src="/sandbox.html"]').last()
    await expect(math).toBeVisible({ timeout: 120_000 })
    // KaTeX ran: its output carries the class it always emits, and the
    // frame grew past the placeholder height it starts at.
    await expect(
      math.contentFrame().locator('.katex').first(),
    ).toBeVisible({ timeout: 15_000 })
    await expect
      .poll(() => math.evaluate((node) => node.getBoundingClientRect().height))
      .toBeGreaterThan(24)
    await shot(page, '10-math')

    // Mermaid and Chart.js are deliberately not exercised here. Both need
    // the model to tag its fence -- ```mermaid, not ``` -- and a 1B model
    // obliges perhaps half the time, which would make this suite flaky
    // without adding coverage: the routing is unit-tested, the rendering
    // is checked inside a real frame in launch.spec.ts, and the math step
    // above already proves the whole path from a reply to a drawn frame.

    // Settings, which nothing else exercises visually.
    await page.evaluate(() => {
      window.history.pushState(null, '', '/settings/appearance')
      window.dispatchEvent(new PopStateEvent('popstate'))
    })
    await page.waitForTimeout(500)
    await shot(page, '11-settings-appearance')

    await page.evaluate(() => {
      window.history.pushState(null, '', '/settings/connections')
      window.dispatchEvent(new PopStateEvent('popstate'))
    })
    await page.waitForTimeout(500)
    await shot(page, '12-settings-connections')
  })
})
