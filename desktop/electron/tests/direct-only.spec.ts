import { mkdirSync, mkdtempSync, rmSync } from 'node:fs'
import { createServer, type IncomingMessage } from 'node:http'
import type { AddressInfo } from 'node:net'
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
 * The app with no Open WebUI server at all: the welcome screen's
 * "Connect directly", one connection, and a chat. The provider is a fake
 * OpenAI-compatible endpoint in this process, so the spec needs nothing
 * outside the machine.
 */

async function jsonBody(request: IncomingMessage): Promise<any> {
  const chunks: Buffer[] = []
  for await (const chunk of request) chunks.push(chunk as Buffer)
  return JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}')
}

/** Answers every chat with the last thing the user said, reversed. */
async function fakeProvider(): Promise<{ baseUrl: string; close: () => void }> {
  const server = createServer(async (request, response) => {
    if (request.url?.endsWith('/models')) {
      response.setHeader('content-type', 'application/json')
      response.end(JSON.stringify({ data: [{ id: 'echo-model', object: 'model' }] }))
      return
    }
    const body = await jsonBody(request)
    const last = [...(body.messages ?? [])].reverse().find((m: any) => m.role === 'user')
    const text = typeof last?.content === 'string'
      ? last.content
      : (last?.content ?? []).map((p: any) => p.text ?? '').join('')
    const reply = `echo: ${[...text].reverse().join('')}`
    response.setHeader('content-type', 'text/event-stream; charset=utf-8')
    for (const delta of [{ role: 'assistant', content: reply }, {}]) {
      response.write(
        `data: ${JSON.stringify({
          id: 'c',
          object: 'chat.completion.chunk',
          choices: [{ index: 0, delta, finish_reason: Object.keys(delta).length ? null : 'stop' }],
        })}\n\n`,
      )
    }
    response.end('data: [DONE]\n\n')
  })
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve))
  const port = (server.address() as AddressInfo).port
  return { baseUrl: `http://127.0.0.1:${port}/v1`, close: () => server.close() }
}

const shotDir = join(__dirname, '..', 'screenshots')

async function shot(page: Page, name: string): Promise<void> {
  mkdirSync(shotDir, { recursive: true })
  await page.screenshot({ path: join(shotDir, `${name}.png`) })
}

let app: ElectronApplication
let userDataDir: string

test.beforeEach(async () => {
  userDataDir = mkdtempSync(join(tmpdir(), 'conduit-direct-'))
  app = await electron.launch({
    args: ['.', `--user-data-dir=${userDataDir}`, '--no-sandbox'],
    cwd: join(__dirname, '..'),
  })
})

test.afterEach(async () => {
  await app.close().catch(() => undefined)
  rmSync(userDataDir, { recursive: true, force: true })
})

test('chats through a direct connection with no server', async () => {
  test.setTimeout(120_000)
  const provider = await fakeProvider()
  try {
    // `firstWindow()` resolves before the window has navigated to the app.
    const page = await app.firstWindow()
    await expect.poll(() => page.url(), { timeout: 30_000 }).toBe('app://conduit/')
    await page.waitForLoadState('domcontentloaded')
    await expect
      .poll(() => page.evaluate(() => window.location.pathname), { timeout: 30_000 })
      .toBe('/onboarding')

    await expect(page.getByRole('heading', { name: /choose how to connect/i })).toBeVisible()
    await shot(page, 'direct-01-chooser')
    await page.getByRole('button', { name: /^connect directly/i }).click()

    await page.getByRole('button', { name: /^connect provider$/i }).click()
    const editor = page.getByRole('group', { name: /connection details/i })
    await editor.getByLabel(/^connection name$/i).fill('Local echo')
    await editor.getByLabel(/^base url$/i).fill(provider.baseUrl)
    await editor.getByLabel(/model ids/i).fill('echo-model')
    await shot(page, 'direct-02-setup')
    // The rarely needed settings, collapsed until asked for.
    await editor.getByRole('button', { name: /advanced settings$/i }).click()
    await editor.getByLabel(/^model tags$/i).fill('local, test')
    await shot(page, 'direct-02b-advanced')
    await editor.getByRole('button', { name: /^save$/i }).click()

    // A working connection is a setup: straight to the chat, no sign-in.
    await expect
      .poll(() => page.evaluate(() => window.location.pathname), { timeout: 30_000 })
      .toBe('/')
    const composer = page.getByPlaceholder('Ask Conduit')
    await expect(composer).toBeVisible()

    let value: string | undefined
    await expect
      .poll(
        async () => {
          value = await page
            .locator('#model option')
            .evaluateAll((nodes) =>
              nodes.map((n) => (n as HTMLOptionElement).value).find((v) => v.startsWith('direct:')),
            )
          return value
        },
        { timeout: 30_000 },
      )
      .toBeTruthy()
    await page.locator('#model').selectOption(value!)

    await composer.fill('hello there')
    await composer.press('Enter')
    const transcript = page.getByRole('log')
    await expect(transcript).toContainText('echo: ereht olleh', { timeout: 30_000 })
    // Stored on this computer and listed like any other chat.
    await expect(
      page.locator('nav[aria-label]').getByText('hello there'),
    ).toBeVisible({ timeout: 30_000 })
    await shot(page, 'direct-03-chat')

    // A formula draws, and its frame takes the drawing's height once the
    // streamed answer has become the stored one -- which once kept the
    // same frame under a new id and left it empty. The echo reverses, so
    // this asks for `$E = mc^2$`.
    await composer.fill('$2^cm = E$')
    await composer.press('Enter')
    await expect(transcript).toContainText('echo:', { timeout: 30_000 })
    await expect(page.getByRole('button', { name: /^send$/i })).toBeVisible({ timeout: 30_000 })
    const formula = transcript.locator('iframe[src="/sandbox.html"]').last()
    await expect(formula.contentFrame().locator('.katex').first()).toBeVisible({
      timeout: 30_000,
    })
    const drawn = await formula
      .contentFrame()
      .locator('#out')
      .evaluate((n) => Math.ceil(n.getBoundingClientRect().height) + 4)
    await expect
      .poll(() => formula.evaluate((n) => n.getBoundingClientRect().height))
      .toBe(drawn)

    // It stays that way across a restart: no onboarding, no sign-in.
    await page.reload()
    await expect
      .poll(() => page.evaluate(() => window.location.pathname), { timeout: 30_000 })
      .toBe('/')
    await expect(page.locator('nav[aria-label]').getByText('hello there')).toBeVisible({
      timeout: 30_000,
    })
  } finally {
    provider.close()
  }
})
