import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { createServer, type IncomingMessage } from 'node:http'
import type { AddressInfo } from 'node:net'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { _electron as electron, expect, test, type ElectronApplication } from '@playwright/test'
import { closeApp } from './support/close-app'

/**
 * Streaming performance, with no server: a fake provider streams a
 * long answer as fast as a fast model does, and the window's frames are
 * timed while it arrives. The numbers go to `test-results/perf-stream.json`;
 * the assertions are the floor below which
 * streaming stops looking live.
 */

async function jsonBody(request: IncomingMessage): Promise<any> {
  const chunks: Buffer[] = []
  for await (const chunk of request) chunks.push(chunk as Buffer)
  return JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}')
}

/** The answer: prose, lists and code, like a long real one. */
function longAnswer(words: number): string[] {
  const deltas: string[] = []
  for (let i = 0; i < words; i++) {
    if (i % 400 === 0 && i > 0) deltas.push('\n\n```dart\nfinal answer = 42; // block ' + i + '\n```\n\n')
    else if (i % 120 === 0) deltas.push(`\n\n## Section ${i / 120 + 1}\n\n- point one\n- point two\n\n`)
    deltas.push(`word${i} `)
  }
  return deltas
}

async function fastProvider(deltas: string[], intervalMs: number) {
  const server = createServer(async (request, response) => {
    if (request.url?.endsWith('/models')) {
      response.setHeader('content-type', 'application/json')
      response.end(JSON.stringify({ data: [{ id: 'fast-model', object: 'model' }] }))
      return
    }
    await jsonBody(request)
    response.setHeader('content-type', 'text/event-stream; charset=utf-8')
    const send = (delta: object, finish: string | null = null) =>
      response.write(
        `data: ${JSON.stringify({
          id: 'c',
          object: 'chat.completion.chunk',
          choices: [{ index: 0, delta, finish_reason: finish }],
        })}\n\n`,
      )
    send({ role: 'assistant', content: '' })
    for (const delta of deltas) {
      send({ content: delta })
      await new Promise((resolve) => setTimeout(resolve, intervalMs))
    }
    send({}, 'stop')
    response.end('data: [DONE]\n\n')
  })
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve))
  const port = (server.address() as AddressInfo).port
  return { baseUrl: `http://127.0.0.1:${port}/v1`, close: () => server.close() }
}

let app: ElectronApplication
let userDataDir: string

test.beforeEach(async () => {
  userDataDir = mkdtempSync(join(tmpdir(), 'conduit-perf-'))
  app = await electron.launch({
    args: ['.', `--user-data-dir=${userDataDir}`, '--no-sandbox'],
    cwd: join(__dirname, '..'),
  })
})

test.afterEach(async () => {
  await closeApp(app)
  rmSync(userDataDir, { recursive: true, force: true })
})

test('a fast, long answer streams without dropping frames', async () => {
  test.setTimeout(180_000)
  // 3,000 words at 400 deltas a second: faster than most hosted models.
  const deltas = longAnswer(3000)
  const provider = await fastProvider(deltas, 2.5)
  try {
    const page = await app.firstWindow()
    await expect.poll(() => page.url(), { timeout: 30_000 }).toMatch(/^app:\/\/conduit\//)
    await page.waitForLoadState('domcontentloaded')
    await expect
      .poll(() => page.evaluate(() => window.location.pathname).catch(() => ''), { timeout: 30_000 })
      .toBe('/onboarding')
    await page.getByRole('button', { name: /^connect directly/i }).click()
    await page.getByRole('button', { name: /^connect provider$/i }).click()
    const editor = page.getByRole('group', { name: /connection details/i })
    await editor.getByLabel(/^connection name$/i).fill('Fast')
    await editor.getByLabel(/^base url$/i).fill(provider.baseUrl)
    await editor.getByLabel(/model ids/i).fill('fast-model')
    await editor.getByRole('button', { name: /^save$/i }).click()
    await expect
      .poll(() => page.evaluate(() => window.location.pathname), { timeout: 30_000 })
      .toBe('/')
    let model: string | undefined
    await expect
      .poll(async () => {
        model = await page
          .locator('#model option')
          .evaluateAll((nodes) =>
            nodes.map((n) => (n as HTMLOptionElement).value).find((v) => v.startsWith('direct:')),
          )
        return model
      }, { timeout: 30_000 })
      .toBeTruthy()
    await page.locator('#model').selectOption(model!)

    // Frame and long-task timing, from before the send to the end.
    await page.evaluate(() => {
      const w = window as unknown as {
        __frames: number[]
        __long: number[]
        __running: boolean
      }
      w.__frames = []
      w.__long = []
      w.__running = true
      let last = performance.now()
      const tick = (now: number) => {
        w.__frames.push(now - last)
        last = now
        if (w.__running) requestAnimationFrame(tick)
      }
      requestAnimationFrame(tick)
      new PerformanceObserver((list) => {
        for (const entry of list.getEntries()) w.__long.push(entry.duration)
      }).observe({ type: 'longtask', buffered: false })
    })
    const composer = page.getByPlaceholder('Ask Conduit')
    await composer.fill('Write a long answer')
    const started = Date.now()
    await composer.press('Enter')
    const transcript = page.getByRole('log')
    await expect(transcript).toContainText('word2999', { timeout: 120_000 })
    const streamedMs = Date.now() - started
    const metrics = await page.evaluate(() => {
      const w = window as unknown as { __frames: number[]; __long: number[]; __running: boolean }
      w.__running = false
      const frames = w.__frames.slice(2).sort((a, b) => a - b)
      const at = (q: number) => frames[Math.min(frames.length - 1, Math.floor(q * frames.length))] ?? 0
      const memory = (performance as unknown as { memory?: { usedJSHeapSize: number } }).memory
      return {
        frames: frames.length,
        p50: at(0.5),
        p95: at(0.95),
        p99: at(0.99),
        max: frames[frames.length - 1] ?? 0,
        over33: frames.filter((f) => f > 33.4).length,
        longTasks: w.__long.length,
        longTaskMs: w.__long.reduce((a, b) => a + b, 0),
        heapMb: memory ? Math.round(memory.usedJSHeapSize / 1e6) : null,
      }
    })
    const processes = await app.evaluate(({ app: electronApp }) =>
      electronApp.getAppMetrics().map((m) => ({ type: m.type, workingSetMb: Math.round(m.memory.workingSetSize / 1024) })),
    )
    const result = { streamedMs, deltas: deltas.length, ...metrics, processes }
    console.log(`perf-stream ${JSON.stringify(result)}`)
    mkdirSync(join(__dirname, '..', 'test-results'), { recursive: true })
    writeFileSync(join(__dirname, '..', 'test-results', 'perf-stream.json'), JSON.stringify(result, null, 2))

    // The floor: most frames on time, and no frame long enough to see.
    expect(result.p95).toBeLessThan(50)
    expect(result.over33 / result.frames).toBeLessThan(0.1)
  } finally {
    provider.close()
  }
})
