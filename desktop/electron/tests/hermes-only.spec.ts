import { mkdirSync, mkdtempSync, rmSync } from 'node:fs'
import { createServer, type IncomingMessage, type ServerResponse } from 'node:http'
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
 * The app with Hermes Agent as its only backend: chosen on the
 * welcome screen, tested and saved, then a conversation -- one turn asking
 * the user's approval -- and the Hermes page's conversations and schedules.
 * Hermes is a fake of its API server in this process, in the shapes a real
 * one answers.
 */

async function jsonBody(request: IncomingMessage): Promise<any> {
  const chunks: Buffer[] = []
  for await (const chunk of request) chunks.push(chunk as Buffer)
  return JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}')
}

async function fakeHermes(key: string): Promise<{
  baseUrl: string
  sessions: Map<string, any>
  jobs: Map<string, any>
  close: () => void
}> {
  const sessions = new Map<string, any>()
  const messages = new Map<string, any[]>()
  const jobs = new Map<string, any>()
  const runs = new Map<string, any>()
  const waiting = new Map<string, (approved: boolean) => void>()
  let next = 0
  const id = (prefix: string) => `${prefix}_${String(++next).padStart(6, '0')}`
  const send = (response: ServerResponse, body: unknown, status = 200) => {
    response.writeHead(status, { 'content-type': 'application/json' })
    response.end(JSON.stringify(body))
  }
  const server = createServer(async (request, response) => {
    const path = new URL(request.url ?? '/', 'http://localhost').pathname
    if (path === '/health') return send(response, { status: 'ok' })
    if (request.headers.authorization !== `Bearer ${key}`) {
      return send(response, { error: 'unauthorized' }, 401)
    }
    const route = `${request.method} ${path}`
    if (route === 'GET /health/detailed') return send(response, { active_sessions: sessions.size })
    if (route === 'GET /v1/capabilities') {
      return send(response, {
        features: {
          run_approval_response: true,
          skills_api: true,
          toolsets: true,
          jobs: true,
          jobs_admin: true,
          session_resources: true,
        },
      })
    }
    if (route === 'GET /v1/skills') {
      return send(response, { skills: [{ name: 'review', description: 'Reviews code' }] })
    }
    if (route === 'GET /v1/toolsets') {
      return send(response, {
        toolsets: [{ name: 'web', label: 'Web', enabled: true, tools: ['search', 'fetch'] }],
      })
    }
    if (route === 'GET /v1/models') return send(response, { data: [{ id: 'hermes-agent' }] })
    if (route === 'POST /api/sessions') {
      const sessionId = id('sess')
      const body = await jsonBody(request)
      sessions.set(sessionId, {
        id: sessionId,
        title: body.title ?? 'Untitled',
        updated_at: new Date().toISOString(),
      })
      messages.set(sessionId, [])
      return send(response, { id: sessionId })
    }
    if (route === 'GET /api/sessions') return send(response, { sessions: [...sessions.values()] })
    if (route === 'POST /v1/runs') {
      const runId = id('run')
      runs.set(runId, await jsonBody(request))
      return send(response, { run_id: runId, status: 'queued' })
    }
    if (route === 'GET /api/jobs') return send(response, { jobs: [...jobs.values()] })
    if (route === 'POST /api/jobs') {
      const jobId = id('job')
      jobs.set(jobId, { ...(await jsonBody(request)), id: jobId, enabled: true })
      return send(response, jobs.get(jobId))
    }
    const segments = path.split('/').filter(Boolean)
    if (segments[0] === 'api' && segments[1] === 'sessions' && sessions.has(segments[2])) {
      if (segments[3] === 'messages') return send(response, { messages: messages.get(segments[2]) })
      if (request.method === 'DELETE') {
        sessions.delete(segments[2])
        return send(response, { ok: true })
      }
    }
    if (segments[0] === 'v1' && segments[1] === 'runs' && runs.has(segments[2])) {
      const runId = segments[2]
      const run = runs.get(runId)
      if (segments[3] === 'approval') {
        const answer = await jsonBody(request)
        waiting.get(runId)?.(answer.choice !== 'deny')
        waiting.delete(runId)
        return send(response, { ok: true })
      }
      if (segments[3] === 'events') {
        response.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache' })
        const event = (body: Record<string, unknown>) =>
          response.write(`data: ${JSON.stringify({ ...body, run_id: runId })}\n\n`)
        const input = String(run.input ?? '')
        let answer = `Echo: ${input}`
        if (input.includes('approve')) {
          const approved = new Promise<boolean>((resolve) => waiting.set(runId, resolve))
          event({ event: 'approval.request', command: 'rm -rf build', description: 'Clean the build folder' })
          answer = (await approved) ? 'Approved and done.' : 'Not approved.'
        }
        const words = answer.split(' ')
        for (const [index, word] of words.entries()) {
          event({ event: 'message.delta', delta: index === words.length - 1 ? word : `${word} ` })
          await new Promise((resolve) => setTimeout(resolve, 30))
        }
        event({ event: 'run.completed', output: answer })
        response.end()
        const log = messages.get(run.session_id)
        log?.push({ id: id('msg'), role: 'user', content: input })
        log?.push({ id: id('msg'), role: 'assistant', content: answer })
        return
      }
      return send(response, { run_id: runId, status: 'completed' })
    }
    send(response, { error: 'not found' }, 404)
  })
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve))
  const port = (server.address() as AddressInfo).port
  return {
    baseUrl: `http://127.0.0.1:${port}/v1`,
    sessions,
    jobs,
    close: () => server.close(),
  }
}

const shotDir = join(__dirname, '..', 'screenshots')

async function shot(page: Page, name: string): Promise<void> {
  mkdirSync(shotDir, { recursive: true })
  await page.screenshot({ path: join(shotDir, `${name}.png`) })
}

let app: ElectronApplication
let userDataDir: string

test.beforeEach(async () => {
  userDataDir = mkdtempSync(join(tmpdir(), 'conduit-hermes-'))
  app = await electron.launch({
    args: ['.', `--user-data-dir=${userDataDir}`, '--no-sandbox'],
    cwd: join(__dirname, '..'),
  })
})

test.afterEach(async () => {
  await app.close().catch(() => undefined)
  rmSync(userDataDir, { recursive: true, force: true })
})

test('talks to Hermes Agent with no server, approvals and all', async () => {
  test.setTimeout(150_000)
  const key = 'e2e-hermes-key'
  const hermes = await fakeHermes(key)
  try {
    const page = await app.firstWindow()
    await expect.poll(() => page.url(), { timeout: 30_000 }).toBe('app://conduit/')
    await page.waitForLoadState('domcontentloaded')
    const pathname = () => page.evaluate(() => window.location.pathname)
    await expect.poll(pathname, { timeout: 30_000 }).toBe('/onboarding')

    await page.getByRole('button', { name: /^hermes agent/i }).click()
    const form = page.getByRole('region', { name: /^connection details$/i })
    await form.getByLabel(/^server url$/i).fill(hermes.baseUrl)
    await form.getByLabel(/^api key$/i).fill('not-the-key')
    await form.getByRole('button', { name: /^test connection$/i }).click()
    await expect(form.getByText(/refused the key/i)).toBeVisible({ timeout: 30_000 })
    await form.getByLabel(/^api key$/i).fill(key)
    await form.getByRole('button', { name: /^test connection$/i }).click()
    await expect(form.getByText(/^connected to hermes\.$/i)).toBeVisible({ timeout: 30_000 })
    await shot(page, 'hermes-01-setup')
    await form.getByRole('button', { name: /^save$/i }).click()

    // A usable Hermes is a setup: straight to the chat, with the agent.
    await expect.poll(pathname, { timeout: 30_000 }).toBe('/')
    await expect
      .poll(
        () =>
          page
            .locator('#model option')
            .evaluateAll((nodes) =>
              nodes.map((n) => (n as HTMLOptionElement).value).find((v) => v.startsWith('hermes:agent:')),
            ),
        { timeout: 30_000 },
      )
      .toBeTruthy()
    const agent = await page
      .locator('#model option')
      .evaluateAll((nodes) =>
        nodes.map((n) => (n as HTMLOptionElement).value).find((v) => v.startsWith('hermes:agent:')),
      )
    await page.locator('#model').selectOption(agent!)

    const composer = page.getByPlaceholder('Ask Conduit')
    // Its skills are the `/` menu, and Open WebUI's switches stay away.
    await composer.fill('/')
    await expect(page.getByRole('option', { name: /\/review/ })).toBeVisible({ timeout: 30_000 })
    await expect(page.getByRole('button', { name: /^web search$/i })).toBeHidden()
    await composer.fill('Hello Hermes')
    await composer.press('Enter')
    const transcript = page.getByRole('log')
    await expect(transcript).toContainText('Echo: Hello Hermes', { timeout: 30_000 })
    expect(hermes.sessions.size).toBe(1)
    // Finished, not only shown: a message sent while the turn is still
    // closing is refused as one turn at a time.
    await expect(page.getByRole('button', { name: /^send$/i })).toBeVisible({ timeout: 30_000 })

    // The agent asks before it acts; the answer goes back to it.
    await composer.fill('Please approve the cleanup')
    await composer.press('Enter')
    const card = page.getByRole('alertdialog').filter({ hasText: /approval required/i })
    await expect(card.getByText('Clean the build folder')).toBeVisible({ timeout: 30_000 })
    await shot(page, 'hermes-02-approval')
    await card.getByRole('button', { name: /^allow once$/i }).click()
    await expect(transcript).toContainText('Approved and done.', { timeout: 30_000 })
    // Listed under the chat list, which has none of its own to show.
    const recent = page.getByRole('region', { name: /^hermes agent$/i })
    await expect(recent.getByRole('button', { name: /^hello hermes$/i })).toBeVisible({
      timeout: 30_000,
    })
    await expect(page.getByText(/^syncing/i)).toBeHidden()
    await shot(page, 'hermes-03-chat')

    // Its conversations and schedules.
    await page.getByRole('link', { name: /^hermes agent$/i }).click()
    await expect.poll(pathname, { timeout: 30_000 }).toBe('/hermes')
    const conversations = page.getByRole('region', { name: /^conversations$/i })
    await expect(conversations.getByRole('button', { name: /^hello hermes$/i })).toBeVisible({
      timeout: 30_000,
    })
    await page.locator('#hermes-new-job').click()
    await page.locator('#hermes-job-name').fill('Morning brief')
    await page.locator('#hermes-job-prompt').fill('Summarise the news')
    await page.locator('#hermes-job-schedule').fill('0 8 * * *')
    await page.locator('#hermes-job-save').click()
    const schedules = page.getByRole('region', { name: /^scheduled agents$/i })
    await expect(schedules.getByText('Morning brief')).toBeVisible({ timeout: 30_000 })
    expect([...hermes.jobs.values()].map((j) => j.schedule)).toEqual(['0 8 * * *'])
    await shot(page, 'hermes-04-page')

    // A conversation opens back in the chat, from Hermes's own record.
    await conversations.getByRole('button', { name: /^hello hermes$/i }).click()
    await expect.poll(pathname, { timeout: 30_000 }).toBe('/')
    await expect(transcript).toContainText('Approved and done.', { timeout: 30_000 })
  } finally {
    hermes.close()
  }
})
