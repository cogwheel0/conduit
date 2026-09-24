import { existsSync, mkdirSync, mkdtempSync, rmSync } from 'node:fs'
import { createServer, type IncomingMessage } from 'node:http'
import type { AddressInfo } from 'node:net'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { _electron as electron, expect, test, type ElectronApplication } from '@playwright/test'

/**
 * Dictation on this computer, with no server anywhere: a direct
 * connection to chat with, Whisper's smallest model downloaded from Settings
 * → Audio, and the fox sentence through Chromium's fake microphone. Runs
 * when the bundle has the whisper library (`npm run build:whisper`) and
 * CONDUIT_SPEECH_SAMPLE names the sentence as a WAV; downloads 78 MB.
 */

const target = `${{ darwin: 'macos', win32: 'windows', linux: 'linux' }[process.platform as string]}_${process.arch}`
const libraryName =
  process.platform === 'win32'
    ? 'conduit_whisper.dll'
    : process.platform === 'darwin'
      ? 'libconduit_whisper.dylib'
      : 'libconduit_whisper.so'
const bundledLibrary = join(
  __dirname, '..', '..', '..', 'apps', 'daemon', 'build', 'cli', target, 'bundle', 'lib', libraryName,
)
const sample = process.env.CONDUIT_SPEECH_SAMPLE

async function jsonBody(request: IncomingMessage): Promise<any> {
  const chunks: Buffer[] = []
  for await (const chunk of request) chunks.push(chunk as Buffer)
  return JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}')
}

async function echoProvider() {
  const server = createServer(async (request, response) => {
    if (request.url?.endsWith('/models')) {
      response.setHeader('content-type', 'application/json')
      response.end(JSON.stringify({ data: [{ id: 'echo-model', object: 'model' }] }))
      return
    }
    await jsonBody(request)
    response.setHeader('content-type', 'text/event-stream; charset=utf-8')
    response.write(`data: ${JSON.stringify({ choices: [{ index: 0, delta: { content: 'ok' } }] })}\n\n`)
    response.end('data: [DONE]\n\n')
  })
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve))
  const port = (server.address() as AddressInfo).port
  return { baseUrl: `http://127.0.0.1:${port}/v1`, close: () => server.close() }
}

let app: ElectronApplication
let userDataDir: string

test.skip(
  !existsSync(bundledLibrary) || sample === undefined || !existsSync(sample),
  'needs `npm run build:whisper` and CONDUIT_SPEECH_SAMPLE',
)

test.beforeEach(async () => {
  userDataDir = mkdtempSync(join(tmpdir(), 'conduit-local-voice-'))
  app = await electron.launch({
    args: [
      '.',
      `--user-data-dir=${userDataDir}`,
      '--no-sandbox',
      '--use-fake-device-for-media-stream',
      `--use-file-for-fake-audio-capture=${sample}`,
    ],
    cwd: join(__dirname, '..'),
  })
})

test.afterEach(async () => {
  await app.close().catch(() => undefined)
  rmSync(userDataDir, { recursive: true, force: true })
})

test('dictates on this computer with a downloaded model', async () => {
  test.setTimeout(300_000)
  const provider = await echoProvider()
  try {
    const page = await app.firstWindow()
    await expect.poll(() => page.url(), { timeout: 30_000 }).toMatch(/^app:\/\/conduit\//)
    await page.waitForLoadState('domcontentloaded')
    await expect
      .poll(() => page.evaluate(() => location.pathname).catch(() => ''), { timeout: 30_000 })
      .toBe('/onboarding')
    await page.getByRole('button', { name: /^connect directly/i }).click()
    await page.getByRole('button', { name: /^connect provider$/i }).click()
    const editor = page.getByRole('group', { name: /connection details/i })
    await editor.getByLabel(/^connection name$/i).fill('Echo')
    await editor.getByLabel(/^base url$/i).fill(provider.baseUrl)
    await editor.getByLabel(/model ids/i).fill('echo-model')
    await editor.getByRole('button', { name: /^save$/i }).click()
    await expect.poll(() => page.evaluate(() => location.pathname), { timeout: 30_000 }).toBe('/')
    // No server to transcribe, so no microphone yet.
    await expect(page.locator('#dictate')).toBeHidden()

    await page.evaluate(() => {
      history.pushState(null, '', '/settings/audio')
      dispatchEvent(new PopStateEvent('popstate'))
    })
    await page.locator('#stt-engine-local').check()
    const models = page.getByRole('region', { name: /^speech models$/i })
    await models.locator('#download-tiny\\.en').click()
    await expect(models.locator('li[data-model="tiny.en"]').getByText(/^in use$/i)).toBeVisible({
      timeout: 240_000,
    })
    mkdirSync(join(__dirname, '..', 'screenshots'), { recursive: true })
    await page.screenshot({ path: join(__dirname, '..', 'screenshots', 'local-01-models.png') })

    await page.evaluate(() => {
      history.pushState(null, '', '/')
      dispatchEvent(new PopStateEvent('popstate'))
    })
    const dictate = page.locator('#dictate')
    await expect(dictate).toBeVisible({ timeout: 30_000 })
    await dictate.click()
    await expect(page.getByPlaceholder('Ask Conduit')).toHaveValue(/quick brown fox/i, { timeout: 60_000 })
    await page.screenshot({ path: join(__dirname, '..', 'screenshots', 'local-02-dictated.png') })
  } finally {
    provider.close()
  }
})
