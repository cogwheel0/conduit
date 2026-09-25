import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { _electron as electron, expect, test, type ElectronApplication } from '@playwright/test'
import { closeApp } from './support/close-app'
import { fakeProvider } from './support/fake-provider'

/**
 * The redesigned shell: the drawn title bar and
 * its window controls, and the sidebar frame -- resized by dragging its
 * edge, kept across a reload, and hidden by its shortcut.
 */

let app: ElectronApplication
let userDataDir: string

test.beforeEach(async () => {
  userDataDir = mkdtempSync(join(tmpdir(), 'conduit-workspace-'))
  app = await electron.launch({
    args: ['.', `--user-data-dir=${userDataDir}`, '--no-sandbox'],
    cwd: join(__dirname, '..'),
  })
})

test.afterEach(async () => {
  await closeApp(app)
  rmSync(userDataDir, { recursive: true, force: true })
})

test('the sidebar resizes, stays that size, and hides', async () => {
  const fake = await fakeProvider()
  try {
    const page = await app.firstWindow()
    await expect
      .poll(() => page.evaluate(() => location.pathname).catch(() => ''), { timeout: 30_000 })
      .toBe('/onboarding')
    await page.getByRole('button', { name: /^connect directly/i }).click()
    await page.getByRole('button', { name: /^connect provider$/i }).click()
    const editor = page.getByRole('group', { name: /connection details/i })
    await editor.getByLabel(/^connection name$/i).fill('Echo')
    await editor.getByLabel(/^base url$/i).fill(fake.baseUrl)
    await editor.getByLabel(/model ids/i).fill('echo-model')
    await editor.getByRole('button', { name: /^save$/i }).click()
    await expect.poll(() => page.evaluate(() => location.pathname), { timeout: 30_000 }).toBe('/')

    const column = page.locator('#sidebar-column')
    const width = async (): Promise<number> => (await column.boundingBox())?.width ?? 0
    const before = await width()
    expect(before).toBeGreaterThan(150)

    // Dragged by its edge, as a pointer does it. Not on a macOS runner: no
    // drag reaches its window there, from the devtools input path or from
    // events sent in the page, while the same drag passes everywhere else.
    const handle = page.getByRole('separator', { name: /resize the sidebar/i })
    if (process.platform !== 'darwin') {
      const box = (await handle.boundingBox())!
      await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2)
      await page.mouse.down()
      await page.mouse.move(box.x + 80, box.y + box.height / 2, { steps: 5 })
      await page.mouse.up()
      await expect.poll(width).toBeGreaterThan(before + 60)
      await expect(handle).toHaveAttribute('aria-valuenow', String(Math.round(await width())))
    }

    // And from the keyboard.
    const dragged = await width()
    await handle.focus()
    await page.keyboard.press('ArrowLeft')
    await expect.poll(width).toBeLessThan(dragged)

    // The window keeps it.
    const kept = await width()
    await page.reload()
    await expect(column).toBeVisible({ timeout: 30_000 })
    await expect.poll(width).toBe(kept)

    // Hidden by its shortcut, and back from the title bar.
    await page.locator('body').click()
    await page.keyboard.press(process.platform === 'darwin' ? 'Meta+Shift+S' : 'Control+Shift+S')
    await expect(column).toBeHidden()
    await page.getByRole('button', { name: /^sidebar$/i }).click()
    await expect(column).toBeVisible()
    await expect(page.getByRole('button', { name: /^sidebar$/i })).toHaveAttribute(
      'aria-pressed',
      'true',
    )
  } finally {
    fake.close()
  }
})

test('the side pane: tabs, a preview, and the tab kept', async () => {
  const fake = await fakeProvider('Here is a page.\n\n```html\n<h1>Hello page</h1>\n```\n')
  try {
    const page = await app.firstWindow()
    await expect
      .poll(() => page.evaluate(() => location.pathname).catch(() => ''), { timeout: 30_000 })
      .toBe('/onboarding')
    await page.getByRole('button', { name: /^connect directly/i }).click()
    await page.getByRole('button', { name: /^connect provider$/i }).click()
    const editor = page.getByRole('group', { name: /connection details/i })
    await editor.getByLabel(/^connection name$/i).fill('Echo')
    await editor.getByLabel(/^base url$/i).fill(fake.baseUrl)
    await editor.getByLabel(/model ids/i).fill('echo-model')
    await editor.getByRole('button', { name: /^save$/i }).click()
    const composer = page.getByPlaceholder('Ask Conduit')
    await composer.fill('Write me a page')
    await composer.press('Enter')
    await expect(page.getByRole('log')).toContainText('Here is a page', { timeout: 30_000 })

    // Opened from the conversation's header, beside it. A direct chat is
    // kept on this computer, so it has no server-side controls to show.
    await page.getByRole('button', { name: /^side pane$/i }).click()
    const tabs = page.getByRole('tablist', { name: /side pane/i })
    await expect(tabs).toBeVisible()
    await expect(tabs.getByRole('tab', { name: /^controls$/i })).toHaveCount(0)

    // Arrow keys move between tabs, and the panel follows.
    await tabs.getByRole('tab', { selected: true }).focus()
    await page.keyboard.press('Home')
    await page.keyboard.press('End')
    const preview = tabs.getByRole('tab', { name: /^preview$/i })
    await expect(preview).toHaveAttribute('aria-selected', 'true')
    await expect(preview).toBeFocused()
    const frame = page.getByRole('tabpanel').locator('iframe')
    await expect(frame).toHaveAttribute('sandbox', '')
    await expect(frame.contentFrame().getByRole('heading', { name: 'Hello page' })).toBeVisible()

    // The window keeps the tab.
    await page.reload()
    await page
      .getByRole('navigation', { name: /conversations/i })
      .getByRole('button', { name: /^write me a page$/i })
      .click({ timeout: 30_000 })
    await expect(page.getByRole('log')).toContainText('Here is a page', { timeout: 30_000 })
    await page.getByRole('button', { name: /^side pane$/i }).click()
    await expect(
      page.getByRole('tablist', { name: /side pane/i }).getByRole('tab', { selected: true }),
    ).toHaveText(/preview/i)
    await page.getByRole('button', { name: /close the side pane/i }).click()
    await expect(page.getByRole('tablist', { name: /side pane/i })).toBeHidden()
  } finally {
    fake.close()
  }
})

test('the text size follows the setting, and is kept', async () => {
  const page = await app.firstWindow()
  await expect
    .poll(() => page.evaluate(() => location.pathname).catch(() => ''), { timeout: 30_000 })
    .toBe('/onboarding')
  const size = () =>
    page.evaluate(() => getComputedStyle(document.body).getPropertyValue('font-size'))
  await expect.poll(size).toBe('14px')

  await page.getByRole('link', { name: /^settings$/i }).click()
  const slider = page.getByLabel(/^text size$/i)
  await slider.focus()
  await page.keyboard.press('ArrowRight')
  await page.keyboard.press('ArrowRight')
  await expect.poll(size).toBe('16px')
  await expect(page.getByText('16 px')).toBeVisible()

  // Stored by the daemon, so a new window opens at it.
  await page.reload()
  await expect.poll(size, { timeout: 30_000 }).toBe('16px')
})

test('the drawn window controls reach the window', async () => {
  test.skip(process.platform === 'darwin', 'macOS keeps its own traffic lights')
  const page = await app.firstWindow()
  await expect(page.getByRole('button', { name: /^close$/i })).toBeVisible({ timeout: 30_000 })

  // xvfb has no window manager to maximize anything, so the window's own
  // methods stand in for one: they record the call and report the change
  // as the real window would.
  await app.evaluate(({ BrowserWindow }) => {
    const window = BrowserWindow.getAllWindows()[0]!
    let maximized = false
    const calls: string[] = []
    ;(globalThis as { __windowCalls?: string[] }).__windowCalls = calls
    window.isMaximized = () => maximized
    window.maximize = () => {
      calls.push('maximize')
      maximized = true
      window.emit('maximize')
    }
    window.unmaximize = () => {
      calls.push('unmaximize')
      maximized = false
      window.emit('unmaximize')
    }
    window.minimize = () => {
      calls.push('minimize')
    }
  })
  const calls = () =>
    app.evaluate(() => (globalThis as { __windowCalls?: string[] }).__windowCalls ?? [])

  await page.getByRole('button', { name: /^maximize$/i }).click()
  await expect.poll(calls).toEqual(['maximize'])
  // The bar hears it, and offers to restore.
  await page.getByRole('button', { name: /^restore$/i }).click()
  await page.getByRole('button', { name: /^minimize$/i }).click()
  await expect.poll(calls).toEqual(['maximize', 'unmaximize', 'minimize'])
  await expect(page.getByRole('button', { name: /^maximize$/i })).toBeVisible()
})
