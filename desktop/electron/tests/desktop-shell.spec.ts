import { spawn } from 'node:child_process'
import { existsSync, mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import {
  _electron as electron,
  expect,
  test,
  type ElectronApplication,
  type Page,
} from '@playwright/test'
import electronBinary from 'electron'

/**
 * The app on the desktop, with no server needed: a `conduit://` link
 * from a second launch, a reload on a deep route, rebinding a shortcut,
 * closing to the tray, and the quick-ask panel.
 */
let app: ElectronApplication
let userDataDir: string
const cwd = join(__dirname, '..')
const args = (dir: string) => ['.', `--user-data-dir=${dir}`, '--no-sandbox']

test.beforeEach(async () => {
  userDataDir = mkdtempSync(join(tmpdir(), 'conduit-shell-'))
  app = await electron.launch({ args: args(userDataDir), cwd })
})

test.afterEach(async () => {
  await app.close().catch(() => undefined)
  rmSync(userDataDir, { recursive: true, force: true })
})

async function mainWindow(): Promise<Page> {
  const page = await app.firstWindow()
  await expect.poll(() => page.url(), { timeout: 30_000 }).toMatch(/^app:\/\/conduit\//)
  await page.waitForLoadState('domcontentloaded')
  return page
}

const pathname = (page: Page) => page.evaluate(() => window.location.pathname)

async function go(page: Page, path: string): Promise<void> {
  await page.evaluate((to) => {
    window.history.pushState(null, '', to)
    window.dispatchEvent(new PopStateEvent('popstate'))
  }, path)
}

test('a link from a second launch opens in this window', async () => {
  const page = await mainWindow()
  await expect.poll(() => pathname(page), { timeout: 30_000 }).toBe('/onboarding')
  // What the OS does with a clicked `conduit://` link while the app runs:
  // launch it again, with the link, into the single-instance lock.
  const second = spawn(electronBinary as unknown as string, [...args(userDataDir), 'conduit://settings/audio'], {
    cwd,
    stdio: 'ignore',
  })
  await new Promise((resolve) => second.once('exit', resolve))
  await expect.poll(() => pathname(page), { timeout: 30_000 }).toBe('/settings/audio')
  await expect(page.getByRole('link', { name: /^audio$/i })).toHaveAttribute('aria-current', 'page')

  // A reload on a route, as after a daemon restart, finds the app again.
  await page.reload()
  await expect(page.getByRole('link', { name: /^audio$/i })).toHaveAttribute('aria-current', 'page', {
    timeout: 30_000,
  })
})

test('a shortcut is rebound, and a taken key is refused', async () => {
  const page = await mainWindow()
  await expect.poll(() => pathname(page), { timeout: 30_000 }).toBe('/onboarding')
  await go(page, '/settings/keyboard')
  const row = page.locator('li[data-shortcut="newChat"]')
  await row.getByRole('button', { name: /^change the shortcut for new chat$/i }).click()
  await expect(page.locator('#shortcut-capture')).toBeFocused()
  // The primary modifier is Cmd on macOS and Ctrl elsewhere, and the keys
  // are written the way each platform writes them.
  const mac = process.platform === 'darwin'
  const mod = mac ? 'Meta' : 'Control'
  // Mod+K belongs to search: refused, and the reason given.
  await page.keyboard.press(`${mod}+k`)
  await expect(page.getByText(/is already used by search conversations and commands/i)).toBeVisible()
  await page.keyboard.press(`${mod}+j`)
  await expect(row.locator('kbd')).toHaveText(mac ? '⌘J' : 'Ctrl+J')
  const saved = JSON.parse(readFileSync(join(userDataDir, 'shell-settings.json'), 'utf8'))
  expect(saved.shortcuts).toEqual({ newChat: 'mod+j' })
  await row.getByRole('button', { name: /^reset$/i }).click()
  await expect(row.locator('kbd')).toHaveText(mac ? '⌘⇧O' : 'Ctrl+Shift+O')
})

test('with close to tray on, closing the window keeps the app', async () => {
  const page = await mainWindow()
  await expect.poll(() => pathname(page), { timeout: 30_000 }).toBe('/onboarding')
  await go(page, '/settings/desktop')
  await page.getByLabel(/^keep running when the window is closed$/i).check()
  await expect
    .poll(() => {
      const file = join(userDataDir, 'shell-settings.json')
      return existsSync(file) && JSON.parse(readFileSync(file, 'utf8')).closeToTray
    })
    .toBe(true)
  await app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0]?.close())
  await expect
    .poll(() => app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0]?.isVisible()))
    .toBe(false)
  // Still running: the tray (here, the shell itself) brings it back.
  await app.evaluate(() => {
    ;(globalThis as { conduitDesktop?: { showMain(): void } }).conduitDesktop?.showMain()
  })
  await expect
    .poll(() => app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0]?.isVisible()))
    .toBe(true)
})

test('quick ask opens its own panel, which says to set up first', async () => {
  await mainWindow()
  const panelOpened = app.waitForEvent('window')
  await app.evaluate(() => {
    ;(globalThis as { conduitDesktop?: { toggleQuickAsk(): void } }).conduitDesktop?.toggleQuickAsk()
  })
  const panel = await panelOpened
  await expect(panel.getByRole('dialog', { name: /^quick ask$/i })).toBeVisible({ timeout: 30_000 })
  const kind = await panel.evaluate(
    () => (globalThis as unknown as { conduit: { windowKind: string } }).conduit.windowKind,
  )
  expect(kind).toBe('quickAsk')
  await expect(panel.getByText(/finish setting it up first/i)).toBeVisible()
})

test('About links open in the system browser, not in the app', async () => {
  const page = await mainWindow()
  await expect.poll(() => pathname(page), { timeout: 30_000 }).toBe('/onboarding')
  await app.evaluate(({ shell }) => {
    ;(globalThis as { __opened?: string[] }).__opened = []
    shell.openExternal = async (url: string) => {
      ;(globalThis as unknown as { __opened: string[] }).__opened.push(url)
    }
  })
  await go(page, '/settings/about')
  await page.getByRole('link', { name: /^github repository$/i }).click()
  await expect
    .poll(() => app.evaluate(() => (globalThis as { __opened?: string[] }).__opened ?? []))
    .toEqual(['https://github.com/cogwheel0/conduit'])
  expect(await pathname(page)).toBe('/settings/about')
  await expect(page.getByRole('region', { name: /^support conduit$/i })).toBeVisible()
})
