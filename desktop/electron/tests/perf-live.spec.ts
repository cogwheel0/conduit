import { execFileSync } from 'node:child_process'
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import {
  _electron as electron,
  expect,
  request as http,
  test,
  type ElectronApplication,
  type Page,
} from '@playwright/test'

/**
 * Big-account performance (WP-10.1), against a real server: a conversation
 * with 10,000 messages and a sidebar of 5,000 conversations, made through the
 * server's API for this run and deleted again by id. Opt-in with
 * CONDUIT_PERF=1, because it writes thousands of rows to the account for a
 * few minutes. Numbers go to `test-results/perf-live.json`.
 */

interface Credentials {
  url: string
  email: string
  password: string
}

function readCredentials(): Credentials | null {
  try {
    const values = new Map<string, string>()
    for (const line of readFileSync(join(__dirname, '..', '..', '..', '.env'), 'utf8').split('\n')) {
      const match = /^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/.exec(line)
      if (match) values.set(match[1]!, match[2]!.replace(/^["']|["']$/g, ''))
    }
    const [url, email, password] = ['OWUI_URL', 'OWUI_EMAIL', 'OWUI_PASSWORD'].map((k) => values.get(k))
    return url && email && password ? { url, email, password } : null
  } catch {
    return null
  }
}

const credentials = readCredentials()
const MESSAGES = 10_000
const CHATS = 5_000
const run = `${Date.now()}`

/** A chat in Open WebUI's shape: a linear history of [count] messages. */
function chatBody(title: string, count: number) {
  const messages: Record<string, any> = {}
  const list: any[] = []
  let parent: string | null = null
  const now = Math.floor(Date.now() / 1000)
  for (let i = 0; i < count; i++) {
    const id = `perf-${run}-${i}`
    const message = {
      id,
      parentId: parent,
      childrenIds: i + 1 < count ? [`perf-${run}-${i + 1}`] : [],
      role: i % 2 === 0 ? 'user' : 'assistant',
      content:
        i % 2 === 0
          ? `Question ${i / 2 + 1}: how does step ${i} work?`
          : `Step ${i} works like this.\n\n- first, the **input** is read\n- then \`transform(${i})\` runs\n\nThat is all.`,
      timestamp: now - (count - i),
      models: ['perf-model'],
    }
    messages[id] = message
    list.push(message)
    parent = id
  }
  return {
    chat: {
      title,
      models: ['perf-model'],
      history: { messages, currentId: parent },
      messages: list,
      tags: [],
      timestamp: now * 1000,
    },
  }
}

async function api() {
  const context = await http.newContext({ baseURL: credentials!.url, timeout: 120_000 })
  const signIn = await context.post('/api/v1/auths/signin', {
    data: { email: credentials!.email, password: credentials!.password },
  })
  const { token } = (await signIn.json()) as { token: string }
  return { context, auth: { authorization: `Bearer ${token}` } }
}

/** The daemon's resident memory, from /proc (Linux only). */
function daemonRssMb(): number | null {
  try {
    const pid = execFileSync('pgrep', ['-n', '-f', 'conduitd'], { encoding: 'utf8' }).trim()
    const status = readFileSync(`/proc/${pid}/status`, 'utf8')
    const kb = /VmRSS:\s+(\d+)/.exec(status)?.[1]
    return kb === undefined ? null : Math.round(Number(kb) / 1024)
  } catch {
    return null
  }
}

/** Frame times while [action] runs. */
async function framesDuring(page: Page, action: () => Promise<void>) {
  await page.evaluate(() => {
    const w = window as unknown as { __frames: number[]; __running: boolean }
    w.__frames = []
    w.__running = true
    let last = performance.now()
    const tick = (now: number) => {
      w.__frames.push(now - last)
      last = now
      if (w.__running) requestAnimationFrame(tick)
    }
    requestAnimationFrame(tick)
  })
  await action()
  return page.evaluate(() => {
    const w = window as unknown as { __frames: number[]; __running: boolean }
    w.__running = false
    const frames = w.__frames.slice(2).sort((a, b) => a - b)
    const at = (q: number) => frames[Math.min(frames.length - 1, Math.floor(q * frames.length))] ?? 0
    return { frames: frames.length, p50: at(0.5), p95: at(0.95), max: frames[frames.length - 1] ?? 0 }
  })
}

test.describe('a big account', () => {
  test.skip(credentials === null || process.env.CONDUIT_PERF !== '1', 'set CONDUIT_PERF=1 with OWUI_* in .env')
  test.setTimeout(1_800_000)

  let app: ElectronApplication
  let userData: string
  const created: string[] = []

  test.beforeAll(async () => {
    // Hooks keep Playwright's own timeout unless told: 5,000 chats take
    // minutes to make, and as long to delete.
    test.setTimeout(900_000)
    const { context, auth } = await api()
    try {
      const big = await context.post('/api/v1/chats/new', {
        headers: auth,
        data: chatBody(`Perf ${run}: ten thousand messages`, MESSAGES),
      })
      expect(big.ok(), await big.text()).toBe(true)
      created.push(((await big.json()) as { id: string }).id)
      // The sidebar's worth, sixteen at a time.
      for (let start = 0; start < CHATS; start += 16) {
        const batch = await Promise.all(
          Array.from({ length: Math.min(16, CHATS - start) }, (_, j) =>
            context.post('/api/v1/chats/new', {
              headers: auth,
              data: chatBody(`Perf ${run} sidebar ${start + j}`, 2),
            }),
          ),
        )
        for (const response of batch) {
          if (response.ok()) created.push(((await response.json()) as { id: string }).id)
        }
      }
    } finally {
      await context.dispose()
    }
    userData = mkdtempSync(join(tmpdir(), 'conduit-perf-live-'))
    app = await electron.launch({
      args: ['.', `--user-data-dir=${userData}`, '--no-sandbox'],
      cwd: join(__dirname, '..'),
    })
  })

  test.afterAll(async () => {
    test.setTimeout(900_000)
    await app?.close().catch(() => undefined)
    if (userData) rmSync(userData, { recursive: true, force: true })
    // Exactly what this run made, by id.
    const { context, auth } = await api()
    try {
      for (let start = 0; start < created.length; start += 16) {
        await Promise.all(
          created
            .slice(start, start + 16)
            .map((id) => context.delete(`/api/v1/chats/${id}`, { headers: auth }).catch(() => undefined)),
        )
      }
    } finally {
      await context.dispose()
    }
  })

  test('opens and scrolls them at speed', async () => {
    const page = await app.firstWindow()
    await expect.poll(() => page.url(), { timeout: 30_000 }).toMatch(/^app:\/\/conduit\//)
    await page.waitForLoadState('domcontentloaded')
    await expect
      .poll(() => page.evaluate(() => location.pathname).catch(() => ''), { timeout: 30_000 })
      .toBe('/onboarding')
    await page.getByRole('button', { name: /^open webui/i }).click()
    await page.getByLabel(/server address/i).fill(credentials!.url)
    await page.getByRole('button', { name: /^connect$/i }).click()
    await expect.poll(() => page.evaluate(() => location.pathname), { timeout: 60_000 }).toBe('/sign-in')
    await page.getByLabel(/email or username/i).fill(credentials!.email)
    await page.locator('#password').fill(credentials!.password)
    const signedInAt = Date.now()
    await page.getByRole('button', { name: /^sign in$/i }).click()
    await expect.poll(() => page.evaluate(() => location.pathname), { timeout: 60_000 }).toBe('/')

    // The sidebar: the newest page, then every page of 5,000.
    const sidebar = page.locator('nav[aria-label]')
    const rows = sidebar.locator('li button')
    await expect(sidebar.getByText(`Perf ${run} sidebar ${CHATS - 1}`)).toBeVisible({ timeout: 300_000 })
    const firstPageMs = Date.now() - signedInAt
    const pagesAt = Date.now()
    const loadMore = page.getByRole('button', { name: /^load more$/i })
    for (let i = 0; i < 30 && (await loadMore.isVisible()); i++) {
      const before = await rows.count()
      await loadMore.click()
      await expect.poll(() => rows.count(), { timeout: 120_000 }).toBeGreaterThan(before)
    }
    const allPagesMs = Date.now() - pagesAt
    const sidebarRows = await rows.count()
    const sidebarScroll = await framesDuring(page, async () => {
      const list = sidebar.locator('[data-chat-list], ul').first()
      for (let i = 0; i < 40; i++) {
        await list.evaluate((el) => {
          const scroller = (el.closest('[class*="overflow-y"]') as HTMLElement | null) ?? el.parentElement!
          scroller.scrollBy(0, 1200)
        })
        await page.waitForTimeout(25)
      }
    })

    // How far the account's full sync has got meanwhile: search sees only
    // what it has pulled, so the big conversation is opened from the list.
    const syncStatus = await page
      .getByRole('status')
      .filter({ hasText: /syncing/i })
      .first()
      .textContent()
      .catch(() => null)

    // The big conversation, the oldest row: open it, then scroll it.
    const row = sidebar.getByRole('button', { name: new RegExp(`^Perf ${run}: ten thousand messages`) }).first()
    await row.scrollIntoViewIfNeeded()
    const openAt = Date.now()
    await row.click()
    const transcript = page.getByRole('log')
    await expect(transcript).toContainText(`Step ${MESSAGES - 1} works like this`, { timeout: 300_000 })
    const openMs = Date.now() - openAt
    const transcriptScroll = await framesDuring(page, async () => {
      for (let i = 0; i < 60; i++) {
        await transcript.evaluate((el) => {
          const scroller = (el.closest('[class*="overflow-y"]') as HTMLElement | null) ?? el
          scroller.scrollBy(0, -4000)
        })
        await page.waitForTimeout(25)
      }
    })
    const heapMb = await page.evaluate(() => {
      const memory = (performance as unknown as { memory?: { usedJSHeapSize: number } }).memory
      return memory ? Math.round(memory.usedJSHeapSize / 1e6) : null
    })
    const processes = await app.evaluate(({ app: electronApp }) =>
      electronApp
        .getAppMetrics()
        .map((m) => ({ type: m.type, workingSetMb: Math.round(m.memory.workingSetSize / 1024) })),
    )
    const result = {
      messages: MESSAGES,
      chats: CHATS,
      firstPageMs,
      allPagesMs,
      sidebarRows,
      syncStatus,
      sidebarScroll,
      openMs,
      transcriptScroll,
      heapMb,
      daemonRssMb: daemonRssMb(),
      processes,
    }
    console.log(`perf-live ${JSON.stringify(result)}`)
    mkdirSync(join(__dirname, '..', 'test-results'), { recursive: true })
    writeFileSync(join(__dirname, '..', 'test-results', 'perf-live.json'), JSON.stringify(result, null, 2))
    expect(sidebarRows).toBeGreaterThanOrEqual(CHATS)
  })
})
