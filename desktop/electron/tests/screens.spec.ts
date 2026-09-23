import { mkdirSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { _electron as electron, expect, test, type ElectronApplication, type Page } from '@playwright/test'
import { fakeProvider, go } from './support/fake-provider'

/**
 * Every screen a setup with no server reaches, in light and in dark, as
 * screenshots in screenshots/screens/ for review (docs/desktop/REDESIGN.md).
 * It asserts only that each screen rendered; judging them is a person's job.
 */

const shotDir = join(__dirname, '..', 'screenshots', 'screens')

let app: ElectronApplication
let userDataDir: string

test.beforeEach(async () => {
  userDataDir = mkdtempSync(join(tmpdir(), 'conduit-screens-'))
  app = await electron.launch({
    args: ['.', `--user-data-dir=${userDataDir}`, '--no-sandbox'],
    cwd: join(__dirname, '..'),
  })
})

test.afterEach(async () => {
  await app.close().catch(() => undefined)
  rmSync(userDataDir, { recursive: true, force: true })
})

async function shoot(page: Page, name: string): Promise<void> {
  for (const mode of ['light', 'dark']) {
    await page.evaluate((m) => document.documentElement.setAttribute('data-mode', m), mode)
    await page.waitForTimeout(250)
    await page.screenshot({ path: join(shotDir, `${name}-${mode}.png`) })
  }
  await page.evaluate(() => document.documentElement.setAttribute('data-mode', 'system'))
}

test('every screen, light and dark', async () => {
  test.setTimeout(240_000)
  mkdirSync(shotDir, { recursive: true })
  const fake = await fakeProvider()
  try {
    const page = await app.firstWindow()
    await page.setViewportSize({ width: 1280, height: 800 })
    await expect
      .poll(() => page.evaluate(() => location.pathname).catch(() => ''), { timeout: 30_000 })
      .toBe('/onboarding')
    await shoot(page, '01-onboarding')

    await page.getByRole('button', { name: /^connect directly/i }).click()
    await page.getByRole('button', { name: /^connect provider$/i }).click()
    await shoot(page, '02-direct-connection')
    const editor = page.getByRole('group', { name: /connection details/i })
    await editor.getByLabel(/^connection name$/i).fill('Echo')
    await editor.getByLabel(/^base url$/i).fill(fake.baseUrl)
    await editor.getByLabel(/model ids/i).fill('echo-model')
    await editor.getByRole('button', { name: /^save$/i }).click()
    await expect.poll(() => page.evaluate(() => location.pathname), { timeout: 30_000 }).toBe('/')
    await shoot(page, '03-chat-empty')

    const composer = page.getByPlaceholder('Ask Conduit')
    await composer.fill('Show me markdown')
    await composer.press('Enter')
    await expect(page.getByRole('log')).toContainText('An answer', { timeout: 30_000 })
    await shoot(page, '04-chat-answer')

    const tabs = ['appearance', 'audio', 'keyboard', 'desktop', 'connections', 'direct', 'mcp', 'hermes', 'data', 'about']
    for (const [index, tab] of tabs.entries()) {
      await go(page, `/settings/${tab}`)
      await shoot(page, `${String(10 + index)}-settings-${tab}`)
    }
    await go(page, '/notes')
    await shoot(page, '30-notes')
    await go(page, '/terminal')
    await shoot(page, '31-terminal')

    const panelOpened = app.waitForEvent('window')
    await app.evaluate(() => {
      ;(globalThis as { conduitDesktop?: { toggleQuickAsk(): void } }).conduitDesktop?.toggleQuickAsk()
    })
    const panel = await panelOpened
    await expect(panel.getByRole('dialog', { name: /^quick ask$/i })).toBeVisible({ timeout: 30_000 })
    await shoot(panel, '40-quick-ask')
  } finally {
    fake.close()
  }
})
