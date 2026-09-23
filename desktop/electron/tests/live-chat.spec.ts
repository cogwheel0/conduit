import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs'
import { tmpdir } from 'node:os'
import { basename, join } from 'node:path'
import {
  _electron as electron,
  expect,
  request as http,
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

/**
 * Waits until the conversation is not generating.
 *
 * The composer shows Stop while a turn streams and Send when it does not,
 * so the button is the state. Sending into a chat that is still generating
 * is refused -- correctly, one turn per chat -- and the test would be
 * asserting on that refusal instead of on what it came to check.
 */
async function idle(page: Page): Promise<void> {
  await expect(
    page.getByRole('button', { name: /^send$/i }),
  ).toBeVisible({ timeout: 180_000 })
}

/**
 * The open conversation is highlighted and first under Today.
 *
 * It had fallen behind for a whole session. Each `chats.list` awaited a
 * full sync pull, each `chats.changed` restarted it, and the events arrived
 * faster than a pull finished, so the sidebar never caught up with the
 * conversation in progress.
 */
async function openChatLeadsSidebar(page: Page): Promise<void> {
  const current = page.locator('nav[aria-label] button[aria-current="true"]')
  await expect(current).toHaveCount(1, { timeout: 15_000 })
  const today = page
    .locator('nav[aria-label] section')
    .filter({ has: page.getByRole('heading', { name: /^today$/i }) })
  await expect(
    today.locator('li button[aria-current]').first(),
  ).toHaveAttribute('aria-current', 'true', { timeout: 15_000 })
}

/**
 * The server's own API, signed in, for setting up and tearing down what a
 * step needs -- a prompt to pick, an evaluation to delete. Never for the
 * thing under test, which goes through the app.
 */
async function serverApi(credentials: Credentials) {
  const api = await http.newContext({ baseURL: credentials.url })
  const signIn = await api.post('/api/v1/auths/signin', {
    data: { email: credentials.email, password: credentials.password },
  })
  const { token } = (await signIn.json()) as { token: string }
  return { api, auth: { authorization: `Bearer ${token}` } }
}

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
      if (
        message.text().startsWith('[event]') ||
        message.type() === 'error' ||
        message.type() === 'warning'
      ) {
        process.stderr.write(`[renderer:${message.type()}] ${message.text()}\n`)
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
    // What the composer offers depends on the account, so it is looked at,
    // not asserted: open the tool list if there is one, and capture it.
    const toolsChip = page.getByRole('button', { name: /^tools/i })
    // `waitFor`, not `isVisible`: the latter ignores its timeout and
    // answers immediately, before the options have arrived.
    if (
      await toolsChip
        .waitFor({ state: 'visible', timeout: 30_000 })
        .then(() => true, () => false)
    ) {
      await toolsChip.click()
      await shot(page, '03b-composer-features')
      await toolsChip.click()
    }

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
    await page.getByLabel(/search conversations/i).fill('the')
    // Hits, not merely "a different number of rows": while the debounced
    // query was in flight the sidebar showed no rows at all, so `not.toBe`
    // passed on the empty pane and the search itself was never checked.
    const hits = page.locator('nav[aria-label] li')
    // Up to two minutes: on a fresh install the index is still filling from
    // the first sync, and the results update as it lands. That is the
    // behaviour under test, not something to wait out beforehand.
    await expect.poll(() => hits.count(), { timeout: 120_000 })
      .toBeGreaterThan(0)
    // The index returns the matching text, which is the point of searching
    // the database rather than filtering the loaded page.
    await expect(hits.first()).toContainText(/the/i)
    await shot(page, '05-search')
    await page.getByLabel(/search conversations/i).fill('')
    // The sections come back. Not "the same number of rows as before": the
    // list keeps growing while the first sync lands, so that count is not
    // expected to hold.
    // Any date heading. Which ones exist depends on when the account was
    // last used; "Today" in particular is absent until this run sends
    // something, which it has not yet.
    await expect(
      page
        .locator('nav[aria-label]')
        .getByRole('heading', {
          name: /^(today|yesterday|previous \d+ days|older)$/i,
        })
        .first(),
    ).toBeVisible({ timeout: 30_000 })

    const transcript = page.getByRole('log')
    // Opening one of the account's existing conversations shows its
    // transcript. The sidebar's rows are envelopes with no message bodies,
    // so reading messages off one gave an empty pane for every chat not
    // created in this session -- the app could list two hundred and open
    // none of them.
    // A chat row, not the first button in the list -- which is now a
    // folder's toggle whenever the account has folders.
    //
    // The first few rows are tried, and the first with a real exchange is
    // used. A conversation on this account can legitimately hold a single
    // message: a lone question, or a history an earlier client left
    // broken. Showing it as it is is correct. It just doesn't test that
    // a transcript loads.
    const rows = page
      .locator('nav[aria-label] section')
      .filter({
        has: page.getByRole('heading', {
          // Anchored: an unanchored /older/ matches "Folders".
          name: /^(today|yesterday|previous \d+ days|older)$/i,
        }),
      })
      .locator('li > div > button')
    let opened = false
    for (let i = 0; i < 6 && !opened; i++) {
      await rows.nth(i).click()
      // A conversation can be empty -- the daemon's live suite makes one
      // briefly -- so an empty one moves on to the next rather than failing.
      const loaded = await transcript
        .locator('article')
        .first()
        .waitFor({ timeout: 30_000 })
        .then(
          () => true,
          () => false,
        )
      if (!loaded) continue
      opened = await expect
        .poll(() => transcript.locator('article').count(), { timeout: 10_000 })
        .toBeGreaterThan(1)
        .then(() => true, () => false)
    }
    expect(opened, 'none of the first six conversations opened with a reply')
      .toBe(true)
    await shot(page, '06-existing-chat')
    // Back to a blank one for the send below, via the shortcut rather than
    // the button: this account has conversations *titled* "New Chat", so
    // the accessible name is ambiguous -- and pressing the key exercises
    // the binding while it is at it.
    await page.keyboard.press('Control+Shift+O')
    await expect
      .poll(() => transcript.locator('article').count(), { timeout: 15_000 })
      .toBe(0)

    // 7. The keyboard layer (WP-3.7). Ctrl+/ is bound at the document, so
    // it has to work with focus wherever the last step left it.
    await page.keyboard.press('Control+Slash')
    const overlay = page.getByRole('dialog', { name: /keyboard shortcuts/i })
    await expect(overlay).toBeVisible()
    await expect(overlay).toContainText('Ctrl+K')
    await shot(page, '07-shortcuts')
    // Esc closes what is in front before it reaches anything behind it.
    await page.keyboard.press('Escape')
    await expect(overlay).toBeHidden()

    // 7b. The command palette (WP-3.1). Ctrl+K from anywhere opens it with
    // the caret in its field, and Enter runs the highlighted row -- here a
    // command, found by a fragment of its name.
    await page.keyboard.press('Control+k')
    const palette = page.getByRole('dialog', { name: /command palette/i })
    await expect(palette).toBeVisible()
    const paletteInput = palette.getByRole('combobox')
    await expect(paletteInput).toBeFocused()
    await expect(palette).toContainText(/recent conversations/i)
    await shot(page, '07b-palette')
    await page.keyboard.type('shortcuts')
    await expect(palette.getByRole('option')).toHaveCount(1)
    await page.keyboard.press('Enter')
    await expect(palette).toBeHidden()
    await expect(overlay).toBeVisible()
    await page.keyboard.press('Escape')
    await expect(overlay).toBeHidden()

    // And a conversation, found through the same search the sidebar uses
    // and opened with the arrow keys. Any conversation will do; one whose
    // title is not also a command's name, so the first row is a chat.
    //
    // A conversation row is the one with an actions group (folders have
    // none), and its title is the one button there without an aria-label.
    const titles = await page
      .locator('nav[aria-label] li:has([role="group"]) button:not([aria-label])')
      .allInnerTexts()
    const title = titles
      .map((text) => text.trim())
      .find((text) => text !== '' && !/^new chat$/i.test(text))
    // Step 6 already needed conversations on this account, so a missing one
    // is the locator being wrong -- which silently skipped this once.
    expect(title, 'no titled conversation in the sidebar').toBeDefined()
    if (title !== undefined) {
      await page.keyboard.press('Control+k')
      await expect(paletteInput).toBeFocused()
      await page.keyboard.type(title)
      const hit = palette.getByRole('option').filter({ hasText: title })
      await expect(hit.first()).toBeVisible({ timeout: 30_000 })
      await shot(page, '07c-palette-search')
      // Down then up: the highlight wraps and comes back to the first row.
      await page.keyboard.press('ArrowDown')
      await page.keyboard.press('ArrowUp')
      await expect(palette.getByRole('option').first()).toHaveAttribute(
        'aria-selected',
        'true',
      )
      // Full-text search may rank another conversation that mentions the
      // title above the one that has it, so the check is on the row chosen.
      const chosen = (
        await palette.getByRole('option').first().locator('div').nth(1).innerText()
      ).trim()
      await page.keyboard.press('Enter')
      await expect(palette).toBeHidden()
      await expect(
        page.locator('nav[aria-label] button[aria-current="true"]'),
      ).toContainText(chosen)
      await page.keyboard.press('Control+Shift+O')
      await expect
        .poll(() => transcript.locator('article').count(), { timeout: 15_000 })
        .toBe(0)
    }

    // 8. Send with Enter rather than the button, which is how the app is
    // actually used, and is a different code path from clicking.
    await page.keyboard.press('Shift+Escape')
    await expect(page.getByPlaceholder('Ask Conduit')).toBeFocused()
    await page.keyboard.type('Reply with exactly the word: pong')
    await page.keyboard.press('Enter')

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

    await openChatLeadsSidebar(page)
    await shot(page, '08-reply')

    // 8b. Regenerate from the UI, then walk back to the answer it replaced
    // (WP-3.8). The first regenerate orphaned the new answer on the server
    // and dropped the question from the conversation. Only a round trip
    // through the real server shows the tree is right.
    await idle(page)
    await transcript
      .getByRole('button', { name: /^regenerate$/i })
      .last()
      .click()
    await idle(page)
    const position = transcript.getByText(/^2\/2$/)
    await expect(position).toBeVisible({ timeout: 90_000 })
    await transcript
      .getByRole('button', { name: /previous answer/i })
      .last()
      .click()
    await expect(transcript.getByText(/^1\/2$/)).toBeVisible()
    await shot(page, '08b-branches')

    // 8b'. Rate the current answer (WP-3.8). A real evaluation is filed on
    // the server, so the step notes which already existed and deletes only
    // the one it made.
    await transcript
      .getByRole('button', { name: /next answer/i })
      .last()
      .click()
    await expect(transcript.getByText(/^2\/2$/)).toBeVisible()
    {
      const { api: evals, auth: evalAuth } = await serverApi(credentials!)
      const listFeedback = async () => {
        const res = await evals.get('/api/v1/evaluations/feedbacks/user', {
          headers: evalAuth,
        })
        const body = (await res.json()) as
          | { id: string }[]
          | { items?: { id: string }[] }
        return Array.isArray(body) ? body : (body.items ?? [])
      }
      const existing = new Set((await listFeedback()).map((f) => f.id))
      const made = async () =>
        (await listFeedback()).filter((f) => !existing.has(f.id))
      try {
        const good = transcript
          .getByRole('button', { name: /good response/i })
          .last()
        await good.click()
        await expect(good).toHaveAttribute('aria-pressed', 'true')
        await expect
          .poll(async () => (await made()).length, { timeout: 30_000 })
          .toBe(1)
        // Still pressed once the stored copy is back, not only while the
        // window remembers the click.
        await idle(page)
        await expect(good).toHaveAttribute('aria-pressed', 'true')
        await shot(page, '08bb-rated')
      } finally {
        for (const feedback of await made()) {
          await evals.delete(`/api/v1/evaluations/feedback/${feedback.id}`, {
            headers: evalAuth,
          })
        }
        await evals.dispose()
      }
    }

    // 8d. Tag the conversation (WP-3.8), find it by the tag, untag it. The
    // name is unique to this run, and the server drops a tag once no
    // conversation carries it, so nothing is left behind.
    const tagName = `e2e ${process.pid}`
    await page.getByRole('button', { name: /add tag/i }).click()
    await expect(page.getByLabel(/^tag name$/i)).toBeFocused()
    await page.keyboard.type(tagName)
    await page.keyboard.press('Enter')
    const tagChip = page.locator('header').getByRole('button', {
      name: tagName,
      exact: true,
    })
    await expect(tagChip).toBeVisible({ timeout: 30_000 })
    await tagChip.click()
    await expect(page.getByLabel(/search conversations/i)).toHaveValue(
      `tag:${tagName}`,
    )
    // The sidebar now lists what carries the tag: this conversation.
    const tagged = page
      .locator('nav[aria-label]')
      .getByRole('button', { name: /reply with exactly the word: pong/i })
    await expect(tagged.first()).toBeVisible({ timeout: 30_000 })
    await shot(page, '08d-tagged')
    await page
      .getByRole('button', { name: new RegExp(`remove tag ${tagName}`, 'i') })
      .click()
    await expect(tagChip).toBeHidden({ timeout: 30_000 })
    await page.getByLabel(/search conversations/i).fill('')

    // 8e. A right-click menu on the open conversation's row, and sharing
    // (WP-3.1). The link is deleted again before the step ends: a share is
    // a public URL, and a test has no business leaving one up.
    await page
      .locator('nav[aria-label] button[aria-current="true"]')
      .click({ button: 'right' })
    const menu = page.getByRole('menu')
    await expect(menu).toBeVisible()
    await expect(menu.getByRole('menuitem').first()).toBeFocused()
    await shot(page, '08e-context-menu')
    await page.keyboard.press('Escape')
    await expect(menu).toBeHidden()

    const runStartedAt = Date.now() / 1000 - 600
    try {
    await page.locator('header').getByRole('button', { name: /^share chat$/i }).click()
    const share = page.getByRole('dialog', { name: /share chat/i })
    await expect(share).toBeVisible()
    await share.getByRole('button', { name: /^copy link$/i }).click()
    const link = share.getByRole('textbox', { name: /copy link/i })
    const server = url.replace(/\/$/, '').replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
    await expect(link).toHaveValue(new RegExp(`^${server}/s/[\\w-]+$`), {
      timeout: 30_000,
    })
    await shot(page, '08f-shared')
    await share.getByRole('button', { name: /^close$/i }).click()
    await expect(share).toBeHidden()
    // Reopened, it knows the conversation is shared and offers to delete.
    await page.locator('header').getByRole('button', { name: /^share chat$/i }).click()
    await expect(share.getByText(/shared this chat before/i)).toBeVisible({
      timeout: 30_000,
    })
    await share.getByRole('button', { name: /delete this link/i }).click()
    await expect(share.getByText(/shared chat link deleted/i)).toBeVisible()
    await share.getByRole('button', { name: /^close$/i }).click()
    } finally {
      // Should the step fail between sharing and deleting, the link would
      // otherwise stay public. Only conversations this run made are looked
      // at: the test's own title, created in the last few minutes.
      const { api: cleanup, auth: cleanupAuth } = await serverApi(credentials!)
      const recent = (await (
        await cleanup.get('/api/v1/chats/?page=1', { headers: cleanupAuth })
      ).json()) as { id: string; title: string; created_at: number }[]
      for (const chat of recent) {
        if (
          chat.title !== 'Reply with exactly the word: pong' ||
          chat.created_at < runStartedAt
        ) {
          continue
        }
        const full = (await (
          await cleanup.get(`/api/v1/chats/${chat.id}`, { headers: cleanupAuth })
        ).json()) as { share_id?: string | null }
        if (full.share_id) {
          await cleanup.delete(`/api/v1/chats/${chat.id}/share`, {
            headers: cleanupAuth,
          })
        }
      }
      await cleanup.dispose()
    }

    // 8f. Into a folder and back out (WP-3.1): the context menu one way,
    // a drag the other. Only when the account has a folder to use; the
    // conversation is this run's, and it ends where it started.
    const foldersSection = page
      .locator('nav[aria-label] section')
      .filter({ has: page.getByRole('heading', { name: /^folders$/i }) })
    // A folder row is two buttons: the arrow (labelled) and the name.
    const folderRows = foldersSection.locator(
      ':scope > ul > li > div > button:not([aria-label])',
    )
    const folderToggles = foldersSection.locator(
      ':scope > ul > li > div > button[aria-label]',
    )
    // Loud rather than skipped: a heading with no rows found is the
    // locator being wrong, which once skipped this whole step silently.
    if ((await foldersSection.count()) > 0) {
      expect(await folderRows.count()).toBeGreaterThan(0)
    }
    if ((await folderRows.count()) > 0) {
      const folderName = (
        await folderRows.first().locator('span').first().innerText()
      ).trim()
      const current = page.locator('nav[aria-label] button[aria-current="true"]')
      await current.click({ button: 'right' })
      await page
        .getByRole('menuitem', { name: `Move to ${folderName}` })
        .click()
      // Now inside the folder, which opens to show it.
      const folderItem = page
        .locator('nav[aria-label] section')
        .filter({ has: page.getByRole('heading', { name: /^folders$/i }) })
        .locator(':scope > ul > li')
        .first()
      if ((await folderToggles.first().getAttribute('aria-expanded')) !== 'true') {
        await folderToggles.first().click()
      }
      await expect(
        folderItem.locator('button[aria-current="true"]'),
      ).toBeVisible({ timeout: 30_000 })
      await shot(page, '08g-in-folder')
      // Dragged out onto the recent list.
      const today = page
        .locator('nav[aria-label] section')
        .filter({ has: page.getByRole('heading', { name: /^today$/i }) })
      await folderItem
        .locator('button[aria-current="true"]')
        .dragTo(today.getByRole('heading', { name: /^today$/i }))
      await expect(
        folderItem.locator('button[aria-current="true"]'),
      ).toBeHidden({ timeout: 30_000 })
      await expect(today.locator('button[aria-current="true"]')).toBeVisible()

      // The folder's own page, by its name: everything in it, sortable.
      await folderRows.first().click()
      await expect(page.getByLabel(/^sort by$/i)).toBeVisible()
      await expect(page.locator('header').getByText(folderName)).toBeVisible()
      await shot(page, '08g-folder-page')
      // Back to the conversation from the sidebar, which closes the page.
      await today.locator('li button:not([aria-label])').first().click()
      await expect(page.getByLabel(/^sort by$/i)).toBeHidden()
    }

    // 8g. Several at once (WP-3.8): archive this run's conversation from
    // the selection mode, then bring it back the same way. Found by its id,
    // which the checkbox carries, never by a title other chats could share.
    await openChatLeadsSidebar(page)
    await page.getByRole('button', { name: /^select$/i }).click()
    const todayBoxes = page
      .locator('nav[aria-label] section')
      .filter({ has: page.getByRole('heading', { name: /^today$/i }) })
      .getByRole('checkbox')
    const ownId = (await todayBoxes.first().getAttribute('id'))!
    await page.locator(`#${ownId}`).check()
    await expect(page.getByText(/^1 selected$/)).toBeVisible()
    await shot(page, '08h-selection')
    await page.getByRole('toolbar').getByRole('button', { name: /^archive$/i }).click()
    await expect(page.getByRole('button', { name: /^select$/i })).toBeVisible({
      timeout: 30_000,
    })
    await expect(page.locator(`#${ownId}`)).toHaveCount(0)
    // Out of the archive again.
    const archivedToggle = page.getByRole('button', { name: /^archived \(\d+\)$/i })
    if ((await archivedToggle.getAttribute('aria-expanded')) !== 'true') {
      await archivedToggle.click()
    }
    await page.getByRole('button', { name: /^select$/i }).click()
    await page.locator(`#${ownId}`).check({ timeout: 30_000 })
    await page.getByRole('toolbar').getByRole('button', { name: /^unarchive$/i }).click()
    await expect(page.getByRole('button', { name: /^select$/i })).toBeVisible({
      timeout: 30_000,
    })
    // Closed again if it is still there -- with nothing left archived, the
    // toggle goes away with the section.
    if ((await archivedToggle.count()) > 0) await archivedToggle.click()
    await openChatLeadsSidebar(page)

    // 8h. The controls pane (WP-3.4): this conversation's own system
    // prompt, saved to the server and read back, then cleared again.
    await page.locator('header').getByRole('button', { name: /^controls$/i }).click()
    const controls = page.getByRole('complementary', { name: /controls/i })
    await expect(controls).toBeVisible()
    const promptField = controls.getByLabel(/system prompt/i)
    await promptField.fill('Answer in one word.')
    await controls.getByRole('button', { name: /^save$/i }).click()
    await expect(controls.getByText(/^saved$/i)).toBeVisible({ timeout: 30_000 })
    await expect(promptField).toHaveValue('Answer in one word.')
    await shot(page, '08i-controls')
    await promptField.fill('')
    await controls.getByRole('button', { name: /^save$/i }).click()
    await expect(controls.getByText(/^saved$/i)).toBeVisible({ timeout: 30_000 })

    // The overview (WP-3.4): both answers the regeneration left, one
    // current. Switching to the other and back goes through the server.
    {
      const overview = controls.getByRole('region', { name: /^overview$/i })
      const answers = overview.getByRole('button', { name: /^pong/i })
      await expect(answers).toHaveCount(2, { timeout: 30_000 })
      // By position, which the tree keeps stable: a locator that means
      // "the one not current" would follow the highlight around.
      const firstIsCurrent =
        (await answers.nth(0).getAttribute('aria-current')) === 'true'
      const older = answers.nth(firstIsCurrent ? 1 : 0)
      const newer = answers.nth(firstIsCurrent ? 0 : 1)
      await older.click()
      await expect(older).toHaveAttribute('aria-current', 'true', {
        timeout: 30_000,
      })
      await shot(page, '08j-overview')
      await newer.click()
      await expect(newer).toHaveAttribute('aria-current', 'true', {
        timeout: 30_000,
      })
    }
    await controls.getByRole('button', { name: /^close$/i }).click()
    await expect(controls).toBeHidden()

    // 8c. Edit the question in place (WP-3.2). The conversation should read
    // as the edited question and a new answer, with the original gone from
    // view but kept on the server as the branch it was.
    await idle(page)
    await transcript.getByRole('button', { name: /^edit$/i }).first().click()
    const editor = transcript.locator('textarea')
    await expect(editor).toHaveValue(/pong/)
    await editor.fill('Reply with exactly the word: ping')
    await transcript.getByRole('button', { name: /^send$/i }).click()
    await expect(
      transcript.getByText('Reply with exactly the word: ping'),
    ).toBeVisible({ timeout: 30_000 })
    await idle(page)
    await expect(
      transcript.getByText('Reply with exactly the word: pong'),
    ).toHaveCount(0, { timeout: 60_000 })
    await openChatLeadsSidebar(page)
    await shot(page, '08c-edited')
    await page.keyboard.press('Shift+Escape')

    // 9. A code block, highlighted and copyable (WP-3.5). The prompt is
    // narrow because a 1B model will happily write an essay around it.
    await idle(page)
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
    await shot(page, '09-code')

    // 10. A markup block offers an inert preview, and nothing else does.
    await idle(page)
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
      frame.contentFrame().getByRole('heading', { name: 'Conduit' }),
    ).toBeVisible({ timeout: 15_000 })
    await shot(page, '10-preview')

    // 11. Math, drawn by KaTeX inside the sandbox.
    //
    // Whether a formula arrives at all is the model's choice: asked for
    // `$E = mc^2$` it sometimes answers with the text and sometimes wraps
    // it in a code fence, and a fenced formula is correctly *not* math.
    // So the frame is asserted only when the model produced one -- the
    // check never fails for the model's phrasing, and never passes a
    // frame that failed to draw.
    await page.keyboard.press('Shift+Escape')
    await expect(page.getByPlaceholder('Ask Conduit')).toBeFocused()
    await idle(page)
    await page.keyboard.type(
      'Reply with only this and nothing else, with no code fence: ' +
        '$E = mc^2$',
    )
    const repliesBefore = await transcript.locator('article').count()
    await page.keyboard.press('Enter')
    await expect
      .poll(() => transcript.locator('article').count(), { timeout: 120_000 })
      .toBeGreaterThan(repliesBefore + 1)

    const math = transcript.locator('iframe[src="/sandbox.html"]')
    if ((await math.count()) > 0) {
      const frame = math.last()
      // KaTeX ran: its output carries the class it always emits, and the
      // frame grew past the placeholder height it starts at.
      await expect(
        frame.contentFrame().locator('.katex').first(),
      ).toBeVisible({ timeout: 30_000 })
      await expect
        .poll(() => frame.evaluate((n) => n.getBoundingClientRect().height))
        .toBeGreaterThan(24)
      await shot(page, '11-math')
    }

    // Mermaid and Chart.js are deliberately not exercised here. Both need
    // the model to tag its fence -- ```mermaid, not ``` -- and a 1B model
    // obliges perhaps half the time, which would make this suite flaky
    // without adding coverage: the routing is unit-tested, the rendering
    // is checked inside a real frame in launch.spec.ts, and the math step
    // above already proves the whole path from a reply to a drawn frame.

    // 12. An attachment: picker -> XHR -> the daemon's /upload -> the
    // server -> a turn that refers to it by id. The bytes never enter Dart
    // and never become a JSON string, which is why this is an HTTP route
    // rather than an RPC method -- and why only a real browser can test it.
    await page.keyboard.press('Shift+Escape')
    const attachPath = join(tmpdir(), `conduit-attach-${process.pid}.txt`)
    writeFileSync(
      attachPath,
      'The passphrase is oxbow-lantern-42. Repeat it exactly.\n',
    )
    const chooser = page.waitForEvent('filechooser')
    await page.getByRole('button', { name: /attach files/i }).click()
    await (await chooser).setFiles(attachPath)

    // The chip appears, and the upload finishes: the composer says it is
    // waiting while one is in flight, so its absence is the signal.
    //
    // Scoped to the chip row. The failure message names the file too, so
    // an unscoped text match would find either and the assertion would
    // pass on a *failed* upload.
    const chip = page
      .locator('[aria-label="Attachments"]')
      .getByText(basename(attachPath))
    await expect(chip).toBeVisible()
    await expect(
      page.getByText(/waiting for attachments/i),
    ).toBeHidden({ timeout: 60_000 })
    await expect(page.getByText(/could not attach/i)).toBeHidden()

    await page.keyboard.press('Shift+Escape')
    await idle(page)
    await page.keyboard.type('What is the passphrase in the attached file?')
    const beforeAttachment = await transcript.locator('article').count()
    await page.keyboard.press('Enter')
    // Accepted by the server with the file attached -- an unknown file id
    // is rejected, so the turn arriving at all is the assertion.
    await expect
      .poll(() => transcript.locator('article').count(), { timeout: 120_000 })
      .toBeGreaterThan(beforeAttachment + 1)
    // And the composer emptied of chips along with the text.
    await expect(chip).toBeHidden()
    // The question carries its attachment in the transcript (WP-3.2), once
    // the stored copy is back.
    // `first`: the answer's collapsed Sources list names the file too.
    await expect(transcript.getByText(basename(attachPath)).first()).toBeVisible({
      timeout: 30_000,
    })
    // The pane follows the conversation: the newest message is on screen
    // without the user scrolling for it.
    await expect
      .poll(() =>
        page.locator('#transcript').evaluate((node) =>
          node.scrollHeight - node.scrollTop - node.clientHeight,
        ),
      )
      .toBeLessThan(48)
    await shot(page, '12-attachment')
    rmSync(attachPath, { force: true })

    // 12b. A dropped file and a pasted one take the same path as a picked
    // one. Synthetic events, but carrying a real `DataTransfer` -- which is
    // the part the component tests cannot reach -- and both claimed, so
    // Electron does not also navigate to the file.
    const dragClaimed = await page.evaluate(() => {
      const field = document.querySelector('#composer')!
      const data = new DataTransfer()
      data.items.add(new File(['x'], 'dropped.txt', { type: 'text/plain' }))
      field.dispatchEvent(
        new DragEvent('dragenter', { bubbles: true, cancelable: true, dataTransfer: data }),
      )
      // False when a handler called `preventDefault`: without that on every
      // `dragover`, the browser refuses the drop.
      return !field.dispatchEvent(
        new DragEvent('dragover', { bubbles: true, cancelable: true, dataTransfer: data }),
      )
    })
    expect(dragClaimed).toBe(true)
    await expect(page.getByText(/drop files to attach/i)).toBeVisible()
    await shot(page, '12b-drag-over')
    const results = await page.evaluate(() => {
      const field = document.querySelector('#composer')!
      const transfer = (name: string) => {
        const data = new DataTransfer()
        data.items.add(new File([`${name} contents`], name, { type: 'text/plain' }))
        return data
      }
      // `dispatchEvent` returns false when a handler called
      // `preventDefault`, which is what "claimed" means here.
      const drop = field.dispatchEvent(
        new DragEvent('drop', {
          bubbles: true,
          cancelable: true,
          dataTransfer: transfer('dropped.txt'),
        }),
      )
      const paste = field.dispatchEvent(
        new ClipboardEvent('paste', {
          bubbles: true,
          cancelable: true,
          clipboardData: transfer('pasted.txt'),
        }),
      )
      return { drop, paste }
    })
    expect(results).toEqual({ drop: false, paste: false })
    await expect(page.getByText(/drop files to attach/i)).toBeHidden()
    const chips = page.locator('[aria-label="Attachments"]')
    await expect(chips.getByText('dropped.txt')).toBeVisible()
    await expect(chips.getByText('pasted.txt')).toBeVisible()
    await expect(
      page.getByText(/waiting for attachments/i),
    ).toBeHidden({ timeout: 60_000 })
    await expect(page.getByText(/could not attach/i)).toBeHidden()
    await shot(page, '12c-dropped-and-pasted')
    // Taken back rather than sent: the path to the server is the one the
    // picked file just proved.
    for (const name of ['dropped.txt', 'pasted.txt']) {
      await chips.getByRole('button', { name: new RegExp(name) }).click()
    }
    await expect(chips).toBeHidden()

    // 12d. A saved prompt through the `/` menu (WP-3.3). Created for this
    // run through the server's API and deleted again afterwards, since an
    // account need not have any -- and the one this runs against has none.
    // Skipped when the account may not create prompts.
    const { api, auth } = await serverApi(credentials!)
    const command = `conduit-e2e-${process.pid}`
    const created = await api.post('/api/v1/prompts/create', {
      headers: auth,
      data: {
        command,
        name: 'Conduit e2e',
        content:
          'Plan for {{team | select:options=["Platform","Mobile"]:required=true}} ' +
          'on {{CURRENT_WEEKDAY}}.',
      },
    })
    const promptId = created.ok()
      ? ((await created.json()) as { id: string }).id
      : null
    try {
      if (promptId !== null) {
        const composer = page.getByPlaceholder('Ask Conduit')
        await composer.fill('')
        await composer.focus()
        await page.keyboard.type(`/${command.slice(0, 12)}`)
        const menu = page.getByRole('listbox', { name: /prompts/i })
        await expect(menu).toBeVisible({ timeout: 15_000 })
        await expect(menu.getByRole('option').first()).toContainText(command)
        // Esc closes the menu and only the menu.
        await page.keyboard.press('Escape')
        await expect(menu).toBeHidden()
        // And stays closed for that text only: one more edit, and it is back.
        await page.keyboard.press('Backspace')
        await expect(menu).toBeVisible()
        await shot(page, '12d-prompt-menu')
        await page.keyboard.press('Enter')
        // The prompt asks for its one field before it goes in.
        const fill = page.getByRole('group', { name: /fill in conduit e2e/i })
        await expect(fill).toBeVisible()
        await fill.getByLabel(/team/i).selectOption('Mobile')
        await shot(page, '12e-prompt-fill')
        await fill.getByRole('button', { name: /^insert$/i }).click()
        await expect(fill).toBeHidden()
        // Filled in: the choice, and a weekday rather than a variable.
        await expect(composer).toHaveValue(/^Plan for Mobile on [A-Z][a-z]+day\.$/)
        await expect(composer).toBeFocused()
        await composer.fill('')
      }
    } finally {
      if (promptId !== null) {
        await api.delete(`/api/v1/prompts/id/${promptId}/delete`, {
          headers: auth,
        })
      }
      await api.dispose()
    }

    // 12d'. `@model` (WP-3.3): picks who answers the next message, shown
    // as a chip, and the text loses the mention. Cleared rather than sent.
    {
      const composer = page.getByPlaceholder('Ask Conduit')
      await composer.fill('')
      await composer.focus()
      await page.keyboard.type('@gem')
      const models = page.getByRole('listbox', { name: /^models$/i })
      await expect(models).toBeVisible()
      await expect(models.getByRole('option').first()).toContainText(/gemma/i)
      await page.keyboard.press('Enter')
      await expect(models).toBeHidden()
      await expect(page.getByText(/^next answer from /i)).toBeVisible()
      await expect(composer).toHaveValue('')
      await shot(page, '12g-mention')
      await page.getByRole('button', { name: /use the selected model instead/i }).click()
      await expect(page.getByText(/^next answer from /i)).toBeHidden()
    }

    // 12e. Offline (WP-3.3). The window's own `offline` event, as the
    // browser fires it when the network goes: the banner appears, Send
    // pauses, and both come back with `online`.
    await page.getByPlaceholder('Ask Conduit').fill('Held until online')
    await page.evaluate(() => window.dispatchEvent(new Event('offline')))
    const offline = page.getByText(/you're offline/i)
    await expect(offline).toBeVisible()
    await expect(page.getByRole('button', { name: /^send$/i })).toBeDisabled()
    await shot(page, '12f-offline')
    await page.evaluate(() => window.dispatchEvent(new Event('online')))
    await expect(offline).toBeHidden()
    await expect(page.getByRole('button', { name: /^send$/i })).toBeEnabled()
    await page.getByPlaceholder('Ask Conduit').fill('')

    // 13. Delete the conversation this run created, through the UI.
    //
    // Two reasons. It exercises delete and its confirmation against a real
    // server. And it cleans up: this test runs against someone's actual
    // account, and before this each run left another conversation in their
    // sidebar.
    await idle(page)
    const current = page.locator('nav[aria-label] li').filter({
      has: page.locator('button[aria-current="true"]'),
    })
    await expect(current).toHaveCount(1)
    const currentTitle = (await current
      .locator('button[aria-current="true"]')
      .textContent())!.trim()
    await current.getByRole('button', { name: 'Delete', exact: true }).click()
    const confirm = page.getByRole('alertdialog')
    await expect(confirm).toContainText(/cannot be undone/i)
    await confirm.getByRole('button', { name: 'Delete', exact: true }).click()
    // The open conversation is gone, so the pane goes back to its empty
    // state rather than showing a transcript that no longer exists.
    await expect(page.getByText(/pick a conversation/i)).toBeVisible({
      timeout: 30_000,
    })
    await expect(
      page.locator('nav[aria-label] button[aria-current="true"]'),
    ).toHaveCount(0)
    process.stderr.write(`[cleanup] deleted "${currentTitle}"\n`)

    // 14. A temporary chat (WP-3.4): answered, marked as temporary, and
    // never in the sidebar, because the server was never told about it.
    const rowsBefore = await page.locator('nav[aria-label] li').count()
    await page.getByLabel(/temporary chat/i).check()
    await page.getByPlaceholder('Ask Conduit').click()
    await page.keyboard.type('Reply with exactly the word: temporary')
    await page.keyboard.press('Enter')
    await expect(
      page.locator('header').getByText(/temporary chat/i),
    ).toBeVisible({ timeout: 30_000 })
    await idle(page)
    await expect
      .poll(() => transcript.locator('article').count(), { timeout: 60_000 })
      .toBeGreaterThan(1)
    await expect(
      page.locator('nav[aria-label] button[aria-current="true"]'),
    ).toHaveCount(0)
    expect(await page.locator('nav[aria-label] li').count()).toBe(rowsBefore)
    await shot(page, '12b-temporary')
    await page.keyboard.press('Control+Shift+O')
    await page.getByLabel(/temporary chat/i).uncheck()

    // Settings, which nothing else exercises visually.
    await page.evaluate(() => {
      window.history.pushState(null, '', '/settings/appearance')
      window.dispatchEvent(new PopStateEvent('popstate'))
    })
    await page.waitForTimeout(500)
    await shot(page, '13-settings-appearance')

    await page.evaluate(() => {
      window.history.pushState(null, '', '/settings/connections')
      window.dispatchEvent(new PopStateEvent('popstate'))
    })
    await page.waitForTimeout(500)
    await shot(page, '14-settings-connections')
  })
})
