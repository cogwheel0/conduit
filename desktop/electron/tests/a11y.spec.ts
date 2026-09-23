import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { createServer, type IncomingMessage } from 'node:http'
import type { AddressInfo } from 'node:net'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import AxeBuilder from '@axe-core/playwright'
import { _electron as electron, expect, test, type ElectronApplication, type Page } from '@playwright/test'

/**
 * Accessibility (WP-10.2): axe-core over every screen a setup with no server
 * reaches -- onboarding, each settings tab, a conversation, the quick-ask
 * panel. It catches what a machine can: names, labels, roles, contrast,
 * structure. What only a person with a screen reader can judge is in
 * docs/desktop/ACCESSIBILITY.md.
 */

async function jsonBody(request: IncomingMessage): Promise<any> {
  const chunks: Buffer[] = []
  for await (const chunk of request) chunks.push(chunk as Buffer)
  return JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}')
}

async function provider() {
  const server = createServer(async (request, response) => {
    if (request.url?.endsWith('/models')) {
      response.setHeader('content-type', 'application/json')
      response.end(JSON.stringify({ data: [{ id: 'echo-model', object: 'model' }] }))
      return
    }
    await jsonBody(request)
    response.setHeader('content-type', 'text/event-stream; charset=utf-8')
    const answer = '## An answer\n\nWith **markdown**, a list:\n\n- one\n- two\n\n```dart\nfinal x = 1;\n```\n'
    response.write(`data: ${JSON.stringify({ choices: [{ index: 0, delta: { content: answer } }] })}\n\n`)
    response.end('data: [DONE]\n\n')
  })
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve))
  const port = (server.address() as AddressInfo).port
  return { baseUrl: `http://127.0.0.1:${port}/v1`, close: () => server.close() }
}

let app: ElectronApplication
let userDataDir: string

test.beforeEach(async () => {
  userDataDir = mkdtempSync(join(tmpdir(), 'conduit-a11y-'))
  app = await electron.launch({
    args: ['.', `--user-data-dir=${userDataDir}`, '--no-sandbox'],
    cwd: join(__dirname, '..'),
  })
})

test.afterEach(async () => {
  await app.close().catch(() => undefined)
  rmSync(userDataDir, { recursive: true, force: true })
})

const findings: Record<string, unknown[]> = {}

async function audit(page: Page, screen: string): Promise<void> {
  await page.waitForTimeout(400)
  const results = await new AxeBuilder({ page })
    // Electron cannot open the blank page the default mode merges frame
    // results in; legacy mode runs in each frame instead.
    .setLegacyMode(true)
    .withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa'])
    // Sandboxed renders are model output in a frame of their own.
    .exclude('iframe[sandbox]')
    .analyze()
  findings[screen] = results.violations.map((v) => ({
    id: v.id,
    impact: v.impact,
    help: v.help,
    nodes: v.nodes.map((n) => `${n.target.join(' ')}: ${n.any[0]?.message ?? ''}`).slice(0, 5),
  }))
}

async function go(page: Page, path: string): Promise<void> {
  await page.evaluate((to) => {
    history.pushState(null, '', to)
    dispatchEvent(new PopStateEvent('popstate'))
  }, path)
}

test('every screen passes axe', async () => {
  test.setTimeout(240_000)
  const fake = await provider()
  try {
    const page = await app.firstWindow()
    await expect.poll(() => page.url(), { timeout: 30_000 }).toMatch(/^app:\/\/conduit\//)
    await page.waitForLoadState('domcontentloaded')
    await expect
      .poll(() => page.evaluate(() => location.pathname).catch(() => ''), { timeout: 30_000 })
      .toBe('/onboarding')
    await audit(page, 'onboarding')

    await page.getByRole('button', { name: /^connect directly/i }).click()
    await page.getByRole('button', { name: /^connect provider$/i }).click()
    await audit(page, 'direct connection form')
    const editor = page.getByRole('group', { name: /connection details/i })
    await editor.getByLabel(/^connection name$/i).fill('Echo')
    await editor.getByLabel(/^base url$/i).fill(fake.baseUrl)
    await editor.getByLabel(/model ids/i).fill('echo-model')
    await editor.getByRole('button', { name: /^save$/i }).click()
    await expect.poll(() => page.evaluate(() => location.pathname), { timeout: 30_000 }).toBe('/')
    await audit(page, 'chat, empty')

    const composer = page.getByPlaceholder('Ask Conduit')
    await composer.fill('Show me markdown')
    await composer.press('Enter')
    await expect(page.getByRole('log')).toContainText('An answer', { timeout: 30_000 })
    await audit(page, 'chat, with an answer')

    for (const tab of ['appearance', 'audio', 'keyboard', 'desktop', 'connections', 'direct', 'mcp', 'hermes', 'data', 'about']) {
      await go(page, `/settings/${tab}`)
      await audit(page, `settings/${tab}`)
    }
    await go(page, '/notes')
    await audit(page, 'notes')

    const panelOpened = app.waitForEvent('window')
    await app.evaluate(() => {
      ;(globalThis as { conduitDesktop?: { toggleQuickAsk(): void } }).conduitDesktop?.toggleQuickAsk()
    })
    const panel = await panelOpened
    await expect(panel.getByRole('dialog', { name: /^quick ask$/i })).toBeVisible({ timeout: 30_000 })
    await audit(panel, 'quick ask')
  } finally {
    fake.close()
  }
  mkdirSync(join(__dirname, '..', 'test-results'), { recursive: true })
  writeFileSync(join(__dirname, '..', 'test-results', 'a11y.json'), JSON.stringify(findings, null, 2))
  const serious = Object.entries(findings).flatMap(([screen, list]) =>
    (list as Array<{ id: string; impact: string | null }>)
      .filter((v) => v.impact === 'serious' || v.impact === 'critical')
      .map((v) => `${screen}: ${v.id}`),
  )
  expect(serious, JSON.stringify(findings, null, 2)).toEqual([])
})
