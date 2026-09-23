import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process'
import { randomBytes } from 'node:crypto'
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  realpathSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs'
import { createServer, type IncomingMessage, type Server } from 'node:http'
import type { AddressInfo } from 'node:net'
import { tmpdir } from 'node:os'
import { basename, join, resolve as resolvePath } from 'node:path'
import {
  _electron as electron,
  expect,
  request as http,
  test,
  type ElectronApplication,
  type Page,
} from '@playwright/test'
import electronBinary from 'electron'
import { WebSocketServer } from 'ws'

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

/** A one-page PDF saying [text], with a correct cross-reference table. */
function tinyPdf(text: string): Buffer {
  const content = `BT /F1 18 Tf 20 100 Td (${text}) Tj ET`
  const objects = [
    '<</Type/Catalog/Pages 2 0 R>>',
    '<</Type/Pages/Kids[3 0 R]/Count 1>>',
    '<</Type/Page/Parent 2 0 R/MediaBox[0 0 300 144]/Contents 4 0 R' +
      '/Resources<</Font<</F1 5 0 R>>>>>>',
    `<</Length ${content.length}>>stream\n${content}\nendstream`,
    '<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>',
  ]
  let body = '%PDF-1.4\n'
  const offsets: number[] = []
  objects.forEach((object, i) => {
    offsets.push(body.length)
    body += `${i + 1} 0 obj${object}endobj\n`
  })
  const xref = body.length
  body += `xref\n0 ${objects.length + 1}\n0000000000 65535 f \n`
  for (const offset of offsets) {
    body += `${String(offset).padStart(10, '0')} 00000 n \n`
  }
  body += `trailer<</Size ${objects.length + 1}/Root 1 0 R>>\nstartxref\n${xref}\n%%EOF\n`
  return Buffer.from(body, 'latin1')
}

/** The body of a request, parsed as JSON. */
async function jsonBody(request: IncomingMessage): Promise<any> {
  const chunks: Buffer[] = []
  for await (const chunk of request) chunks.push(chunk as Buffer)
  return JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}')
}

async function listen(server: Server): Promise<number> {
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve))
  return (server.address() as AddressInfo).port
}

/**
 * An OpenAI-compatible provider that calls the first tool it is offered
 * with `{"value": "hi"}`, then answers with what the tool returned. A real
 * model that calls tools reliably is not something a test can count on.
 */
async function fakeToolProvider(): Promise<{ baseUrl: string; close: () => void }> {
  const server = createServer(async (request, response) => {
    if (request.url?.endsWith('/models')) {
      response.setHeader('content-type', 'application/json')
      response.end(JSON.stringify({ data: [{ id: 'fake-model', object: 'model' }] }))
      return
    }
    const body = await jsonBody(request)
    const toolResult = [...(body.messages ?? [])].reverse().find((m: any) => m.role === 'tool')
    response.setHeader('content-type', 'text/event-stream; charset=utf-8')
    const chunk = (delta: object, finish: string | null = null) =>
      response.write(
        `data: ${JSON.stringify({
          id: 'c',
          object: 'chat.completion.chunk',
          choices: [{ index: 0, delta, finish_reason: finish }],
        })}\n\n`,
      )
    if (!toolResult && Array.isArray(body.tools) && body.tools.length > 0) {
      chunk(
        {
          role: 'assistant',
          tool_calls: [
            {
              index: 0,
              id: 'call_1',
              type: 'function',
              function: {
                name: body.tools[0].function.name,
                arguments: JSON.stringify({ value: 'hi' }),
              },
            },
          ],
        },
        'tool_calls',
      )
    } else {
      const text =
        typeof toolResult?.content === 'string'
          ? toolResult.content
          : (toolResult?.content ?? []).map((p: any) => p.text ?? '').join('')
      chunk({ role: 'assistant', content: toolResult ? `echoed: ${text}` : 'no tool' })
      chunk({}, 'stop')
    }
    response.end('data: [DONE]\n\n')
  })
  const port = await listen(server)
  return { baseUrl: `http://127.0.0.1:${port}/v1`, close: () => server.close() }
}

/** Enough of Ollama for its model-memory actions: two models, one loaded. */
async function fakeOllama(): Promise<{ baseUrl: string; close: () => void }> {
  const running = new Set<string>(['big:70b'])
  const server = createServer(async (request, response) => {
    const body = request.method === 'POST' ? await jsonBody(request) : {}
    let reply: unknown
    switch (request.url) {
      case '/api/tags':
        reply = { models: ['tiny:1b', 'big:70b'].map((name) => ({ name, model: name })) }
        break
      case '/api/show':
        reply = { capabilities: ['completion'] }
        break
      case '/api/ps':
        reply = { models: [...running].map((name) => ({ name, model: name })) }
        break
      case '/api/version':
        reply = { version: '0.9.0' }
        break
      case '/api/chat':
        if (body.keep_alive === 0) running.delete(body.model)
        else running.add(body.model)
        reply = { model: body.model, done: true }
        break
      default:
        response.statusCode = 404
        response.end()
        return
    }
    response.setHeader('content-type', 'application/json')
    response.end(JSON.stringify(reply))
  })
  const port = await listen(server)
  return { baseUrl: `http://127.0.0.1:${port}`, close: () => server.close() }
}

/** A minimal MCP server with one `echo` tool, as the daemon's tests use. */
async function fakeMcpServer(): Promise<{ endpoint: string; calls: number; close: () => void }> {
  const state = { endpoint: '', calls: 0, close: () => {} }
  const server = createServer(async (request, response) => {
    if (request.method !== 'POST' || request.url !== '/mcp') {
      response.statusCode = 405
      response.end()
      return
    }
    const body = await jsonBody(request)
    let result: any
    switch (body.method) {
      case 'server/discover':
        result = {
          supportedVersions: ['2026-07-28'],
          capabilities: {
            tools: { listChanged: false },
            prompts: { listChanged: false },
            resources: { listChanged: false, subscribe: false },
          },
          ttlMs: 0,
          cacheScope: 'private',
          _meta: { 'io.modelcontextprotocol/serverInfo': { name: 'fixture', version: '1.0.0' } },
        }
        break
      case 'tools/list':
        result = {
          tools: [
            {
              name: 'echo',
              description: 'Returns its value.',
              inputSchema: { type: 'object', properties: { value: { type: 'string' } } },
            },
          ],
          ttlMs: 0,
          cacheScope: 'private',
        }
        break
      case 'prompts/list':
        result = { prompts: [], ttlMs: 0, cacheScope: 'private' }
        break
      case 'resources/list':
        result = {
          resources: [{ uri: 'file:///notes/today.md', name: 'today.md', mimeType: 'text/markdown' }],
          ttlMs: 0,
          cacheScope: 'private',
        }
        break
      case 'resources/templates/list':
        result = { resourceTemplates: [], ttlMs: 0, cacheScope: 'private' }
        break
      case 'resources/read':
        result = {
          contents: [
            { uri: body.params?.uri, mimeType: 'text/markdown', text: '# Today\nWater the plants.' },
          ],
          ttlMs: 0,
          cacheScope: 'private',
        }
        break
      case 'tools/call':
        state.calls++
        result = {
          content: [{ type: 'text', text: String(body.params?.arguments?.value ?? '') }],
          isError: false,
        }
        break
      default:
        response.statusCode = 400
        response.end()
        return
    }
    result.resultType ??= 'complete'
    response.setHeader('content-type', 'application/json')
    response.end(JSON.stringify({ jsonrpc: '2.0', id: body.id, result }))
  })
  const port = await listen(server)
  state.endpoint = `http://127.0.0.1:${port}/mcp`
  state.close = () => server.close()
  return state
}

/**
 * A terminal server in the shape of Open WebUI's open-terminal (M7): REST
 * for files and ports, and a WebSocket shell. The shell is a real `sh`
 * over pipes -- no pty, so this server echoes keystrokes itself and turns
 * Enter into a newline -- in a temporary folder that is also the files
 * panel's home. Loopback only, behind a random key.
 */
async function fakeTerminal(): Promise<{
  url: string
  key: string
  home: string
  close: () => void
}> {
  const key = `e2e-${randomBytes(12).toString('hex')}`
  const home = realpathSync(mkdtempSync(join(tmpdir(), 'conduit-terminal-')))
  const shells: ChildProcessWithoutNullStreams[] = []
  // Paths arrive absolute, as open-terminal's are; anything outside the
  // home folder is refused.
  const inside = (path: string) => {
    const resolved = resolvePath(home, path)
    if (resolved !== home && !resolved.startsWith(`${home}/`)) throw new Error('outside')
    return resolved
  }
  const server = createServer(async (request, response) => {
    const url = new URL(request.url ?? '/', 'http://localhost')
    const send = (status: number, body: unknown) => {
      response.writeHead(status, { 'content-type': 'application/json' })
      response.end(JSON.stringify(body))
    }
    if (request.headers.authorization !== `Bearer ${key}`) return send(401, { detail: 'key' })
    try {
      const route = `${request.method} ${url.pathname}`
      if (route === 'GET /api/config') return send(200, { features: { terminal: true } })
      if (route === 'POST /api/terminals') return send(200, { id: randomBytes(4).toString('hex') })
      if (route === 'GET /files/cwd') return send(200, { cwd: home })
      if (route === 'POST /files/cwd') {
        await jsonBody(request)
        return send(200, { ok: true })
      }
      if (route === 'GET /files/list') {
        const dir = inside(url.searchParams.get('directory') ?? home)
        const entries = readdirSync(dir, { withFileTypes: true }).map((entry) => {
          const stat = statSync(join(dir, entry.name))
          return {
            name: entry.name,
            type: entry.isDirectory() ? 'directory' : 'file',
            size: stat.size,
            modified: Math.floor(stat.mtimeMs / 1000),
          }
        })
        return send(200, { dir, entries })
      }
      if (route === 'GET /files/read') {
        return send(200, { content: readFileSync(inside(url.searchParams.get('path') ?? ''), 'utf8') })
      }
      if (route === 'GET /files/view') {
        const path = inside(url.searchParams.get('path') ?? '')
        response.writeHead(200, {
          'content-type': 'application/octet-stream',
          'content-disposition': `attachment; filename="${basename(path)}"`,
        })
        return response.end(readFileSync(path))
      }
      if (route === 'POST /files/upload') {
        const chunks: Buffer[] = []
        for await (const chunk of request) chunks.push(chunk as Buffer)
        const raw = Buffer.concat(chunks)
        const text = raw.toString('latin1')
        const name = /filename="([^"]+)"/.exec(text)?.[1]
        const start = text.indexOf('\r\n\r\n') + 4
        const end = text.lastIndexOf('\r\n--')
        if (!name || start < 4 || end < start) return send(400, { detail: 'form' })
        writeFileSync(join(inside(url.searchParams.get('directory') ?? home), basename(name)), raw.subarray(start, end))
        return send(200, { ok: true })
      }
      if (route === 'POST /files/mkdir') {
        mkdirSync(inside(((await jsonBody(request)) as { path: string }).path), { recursive: true })
        return send(200, { ok: true })
      }
      if (route === 'DELETE /files/delete') {
        rmSync(inside(url.searchParams.get('path') ?? ''), { recursive: true, force: true })
        return send(200, { ok: true })
      }
      if (route === 'POST /files/move') {
        const move = (await jsonBody(request)) as { source: string; destination: string }
        renameSync(inside(move.source), inside(move.destination))
        return send(200, { ok: true })
      }
      if (route === 'GET /ports') return send(200, { ports: [{ port: 3000, pid: 1, process: 'devserver' }] })
      if (url.pathname.startsWith('/proxy/3000')) {
        response.writeHead(200, { 'content-type': 'text/html' })
        return response.end(`<h1>preview ${url.pathname.slice('/proxy/3000'.length)}</h1>`)
      }
      send(404, { detail: 'not found' })
    } catch {
      send(400, { detail: 'bad path' })
    }
  })
  const sockets = new WebSocketServer({ server, path: undefined })
  sockets.on('connection', (socket) => {
    let shell: ChildProcessWithoutNullStreams | undefined
    socket.on('message', (data, isBinary) => {
      if (!isBinary) {
        const frame = JSON.parse(data.toString()) as { type: string; token?: string }
        if (shell === undefined) {
          if (frame.type !== 'auth' || frame.token !== key) {
            socket.close(4401, 'bad auth')
            return
          }
          shell = spawn('sh', [], { cwd: home, env: { PATH: process.env.PATH ?? '/usr/bin:/bin', HOME: home, PS1: '$ ' } })
          shells.push(shell)
          const out = (chunk: Buffer) => socket.send(Buffer.from(chunk.toString().replace(/\n/g, '\r\n')))
          shell.stdout.on('data', out)
          shell.stderr.on('data', out)
          shell.on('exit', (code, signal) => {
            process.stderr.write(`[fake terminal] shell exited ${code} ${signal}\n`)
            socket.close()
          })
          socket.send(Buffer.from('$ '))
        }
        return
      }
      if (shell === undefined) return
      const typed = (data as Buffer).toString()
      // No pty: echo what is typed, as a terminal's line discipline would.
      socket.send(Buffer.from(typed.replace(/\r/g, '\r\n')))
      shell.stdin.write(typed.replace(/\r/g, '\n'))
      if (typed.includes('\r')) setTimeout(() => socket.send(Buffer.from('$ ')), 150)
    })
    socket.on('close', (code, reason) => {
      process.stderr.write(`[fake terminal] socket closed ${code} ${reason.toString()}\n`)
      shell?.kill()
    })
  })
  const port = await listen(server)
  return {
    url: `http://127.0.0.1:${port}`,
    key,
    home,
    close: () => {
      for (const shell of shells) shell.kill()
      sockets.close()
      server.close()
      rmSync(home, { recursive: true, force: true })
    },
  }
}

async function shot(page: Page, name: string): Promise<void> {
  mkdirSync(shotDir, { recursive: true })
  await page.screenshot({ path: join(shotDir, `${name}.png`) })
}

const speechSample =
  process.env.CONDUIT_SPEECH_SAMPLE && existsSync(process.env.CONDUIT_SPEECH_SAMPLE)
    ? process.env.CONDUIT_SPEECH_SAMPLE
    : null

test.describe('against a real server', () => {
  test.skip(credentials === null, 'no OWUI_* credentials in .env')
  // A cold start, a sign-in round trip and a model reply.
  test.setTimeout(300_000)

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
        // A microphone for a note's recording: Chromium's fake device, since
        // a CI box has none. The app's own permission policy still decides.
        '--use-fake-device-for-media-stream',
        // Spoken words instead of the fake device's beep, when a WAV of
        // "The quick brown fox jumps over the lazy dog." is given (M8).
        ...(speechSample ? [`--use-file-for-fake-audio-capture=${speechSample}`] : []),
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

    // First the choice of backend; this spec is about a server.
    await shot(page, '01-onboarding')
    await page.getByRole('button', { name: /^open webui/i }).click()
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
    // The stored answer, not the live one it replaces: only a stored answer
    // carries its usage. Clicking Regenerate on the live bubble just as the
    // stored one swaps in can land on an element that is already gone.
    await expect(
      transcript.getByRole('group', { name: /response statistics/i }).last(),
    ).toBeVisible({ timeout: 60_000 })
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
    // A folder row is two buttons: the arrow (labelled) and the name. The
    // section's list sits in the body its heading folds.
    const folderRows = foldersSection.locator(
      ':scope > div > ul > li > div > button:not([aria-label])',
    )
    const folderToggles = foldersSection.locator(
      ':scope > div > ul > li > div > button[aria-label]',
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
        .locator(':scope > div > ul > li')
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
    // And a PDF alongside, to open from the transcript afterwards.
    const pdfPath = join(tmpdir(), `conduit-attach-${process.pid}.pdf`)
    writeFileSync(pdfPath, tinyPdf('Conduit PDF'))
    const chooser = page.waitForEvent('filechooser')
    await page.getByRole('button', { name: /attach files/i }).click()
    await (await chooser).setFiles([attachPath, pdfPath])

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

    // 12a. The PDF opens in the shell's own viewer window: through the
    // daemon, with its token, as a PDF -- not in the real browser, which
    // would have no token.
    const pdfLink = transcript.getByRole('link', { name: basename(pdfPath) })
    await expect(pdfLink).toBeVisible({ timeout: 30_000 })
    const [viewer] = await Promise.all([
      app.waitForEvent('window'),
      pdfLink.click(),
    ])
    await expect
      .poll(() => viewer.url(), { timeout: 30_000 })
      .toMatch(/^http:\/\/127\.0\.0\.1:\d+\/files\//)
    await expect
      .poll(() => viewer.evaluate(() => document.contentType), {
        timeout: 30_000,
      })
      .toBe('application/pdf')
    await viewer.close()
    rmSync(pdfPath, { force: true })

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

    // 12d''. `#knowledge` (WP-3.3): a knowledge base this run creates,
    // chosen from the menu into a chip, then taken off again and deleted.
    // Skipped when the account may not create one.
    {
      const { api: kb, auth: kbAuth } = await serverApi(credentials!)
      const kbName = `Conduit e2e ${process.pid}`
      const made = await kb.post('/api/v1/knowledge/create', {
        headers: kbAuth,
        data: { name: kbName, description: 'Created by a test' },
      })
      const kbId = made.ok() ? ((await made.json()) as { id: string }).id : null
      try {
        if (kbId !== null) {
          const composer = page.getByPlaceholder('Ask Conduit')
          await composer.fill('')
          await composer.focus()
          // One word: a space ends the token.
          await composer.fill('#Conduit')
          const menu = page.getByRole('listbox', { name: /^knowledge$/i })
          await expect(menu).toBeVisible({ timeout: 15_000 })
          await menu.getByRole('option', { name: new RegExp(kbName) }).click()
          const chip = page.getByText(`# ${kbName}`)
          await expect(chip).toBeVisible()
          await expect(composer).toHaveValue('')
          await shot(page, '12h-knowledge')
          await page
            .getByRole('button', { name: new RegExp(`remove ${kbName}`, 'i') })
            .click()
          await expect(chip).toBeHidden()
        }
      } finally {
        if (kbId !== null) {
          await kb.delete(`/api/v1/knowledge/${kbId}/delete`, { headers: kbAuth })
        }
        await kb.dispose()
      }
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

    // 15. A direct connection (WP-4.2): the test server's own OpenAI-
    // compatible API, with this session's token as its key. Tested, saved,
    // shown without its key, and deleted. It lives in this run's throwaway
    // profile, so nothing outlives the run even if a step fails.
    await page.evaluate(() => {
      window.history.pushState(null, '', '/settings/direct')
      window.dispatchEvent(new PopStateEvent('popstate'))
    })
    const settingsDialog = page.getByRole('dialog')
    await settingsDialog.getByRole('button', { name: /^connect provider$/i }).click()
    const directEditor = settingsDialog.getByRole('group', { name: /connection details/i })
    await directEditor.getByLabel(/^connection name$/i).fill('Open WebUI API')
    await directEditor.getByLabel(/^base url$/i).fill(`${url.replace(/\/$/, '')}/api`)
    const { api: tokenApi, auth: tokenAuth } = await serverApi(credentials!)
    await tokenApi.dispose()
    await directEditor
      .getByLabel(/^api key$/i)
      .fill(tokenAuth.authorization.replace(/^Bearer /, ''))
    await directEditor.getByRole('button', { name: /^test connection$/i }).click()
    await expect(directEditor.getByText(/^connected/i)).toBeVisible({ timeout: 30_000 })
    await shot(page, '15-direct-test')
    await directEditor.getByRole('button', { name: /^save$/i }).click()
    await expect(directEditor).toBeHidden({ timeout: 30_000 })
    await expect(settingsDialog.getByText('Open WebUI API')).toBeVisible()
    await shot(page, '15b-direct-list')

    // 15c. A chat through it (M4): the daemon is the client, the answer is
    // stored here and mirrored to the account, where the chat is found and
    // deleted by its unique question.
    await page.evaluate(() => {
      window.history.pushState(null, '', '/')
      window.dispatchEvent(new PopStateEvent('popstate'))
    })
    await expect(settingsDialog).toBeHidden()
    await page.keyboard.press('Shift+Escape')
    const directModel = `:${Buffer.from(model ?? 'gemma3:1b').toString('base64url').replace(/=+$/, '')}`
    // Discovered over the network after the save, so they arrive a moment
    // later -- announced by `models.changed`.
    let directValue: string | undefined
    await expect
      .poll(
        async () => {
          directValue = await page
            .locator('#model option')
            .evaluateAll(
              (nodes, suffix) =>
                nodes
                  .map((n) => (n as HTMLOptionElement).value)
                  .find((v) => v.startsWith('direct:') && v.endsWith(suffix)),
              directModel,
            )
          return directValue
        },
        { message: 'the direct connection offers the model', timeout: 60_000 },
      )
      .toBeTruthy()
    await page.locator('#model').selectOption(directValue!)
    const directQuestion = `Direct check ${Date.now()}: reply with the word omega`
    try {
      const composer = page.getByPlaceholder('Ask Conduit')
      await composer.fill(directQuestion)
      await composer.press('Enter')
      await expect(transcript).toContainText(directQuestion, { timeout: 30_000 })
      // The stored answer: only a finished one reports its statistics.
      await expect(
        transcript.getByRole('group', { name: /response statistics/i }),
      ).toBeVisible({ timeout: 90_000 })
      await shot(page, '15c-direct-chat')
    } finally {
      // Mirrored to the account, so found there by its unique question and
      // deleted -- even when a step above failed, since the chat exists as
      // soon as it was sent.
      const { api, auth } = await serverApi(credentials!)
      try {
        const deadline = Date.now() + 60_000
        let found: { id: string } | undefined
        while (found === undefined && Date.now() < deadline) {
          const list = (await (
            await api.get('/api/v1/chats/?page=1', { headers: auth })
          ).json()) as Array<{ id: string; title: string }>
          found = list.find(
            (chat) =>
              // Shortened with an ellipsis when it was made.
              chat.title.length > 12 &&
              directQuestion.startsWith(chat.title.replace(/…$/, '')),
          )
          if (found === undefined) await page.waitForTimeout(1_000)
        }
        expect(found, 'the direct chat reached the account').toBeDefined()
        await api.delete(`/api/v1/chats/${found!.id}`, { headers: auth })
        console.log(`[cleanup] deleted "${directQuestion}"`)
      } finally {
        await api.dispose()
      }
    }
    await page.evaluate(() => {
      window.history.pushState(null, '', '/settings/direct')
      window.dispatchEvent(new PopStateEvent('popstate'))
    })
    await settingsDialog.getByRole('button', { name: /^delete$/i }).click()
    await settingsDialog
      .getByRole('alertdialog')
      .getByRole('button', { name: /^delete$/i })
      .click()
    await expect(settingsDialog.getByText('Open WebUI API')).toBeHidden({
      timeout: 30_000,
    })

    // 16. MCP tools on a direct model (M4): a server added in settings,
    // chosen in the composer, and a call that waits for the user's yes.
    // The provider and the MCP server run in this process; the history
    // stays on this computer, so the account is not touched.
    const provider = await fakeToolProvider()
    const mcpServer = await fakeMcpServer()
    try {
      await settingsDialog.getByLabel(/keep direct chats on this computer only/i).check()
      await settingsDialog.getByRole('button', { name: /^connect provider$/i }).click()
      const toolsEditor = settingsDialog.getByRole('group', { name: /connection details/i })
      await toolsEditor.getByLabel(/^connection name$/i).fill('Tool provider')
      await toolsEditor.getByLabel(/^base url$/i).fill(provider.baseUrl)
      await toolsEditor.getByLabel(/model ids/i).fill('fake-model')
      await toolsEditor.getByRole('button', { name: /^save$/i }).click()
      await expect(toolsEditor).toBeHidden({ timeout: 30_000 })

      await page.evaluate(() => {
        window.history.pushState(null, '', '/settings/mcp')
        window.dispatchEvent(new PopStateEvent('popstate'))
      })
      await settingsDialog.getByRole('button', { name: /^add mcp server$/i }).click()
      const mcpEditor = settingsDialog.getByRole('group', { name: /add mcp server/i })
      await mcpEditor.getByLabel(/^server name$/i).fill('Fixture')
      await mcpEditor.getByLabel(/streamable http endpoint/i).fill(mcpServer.endpoint)
      await mcpEditor.getByRole('button', { name: /^test connection$/i }).click()
      await expect(mcpEditor.getByText(/1 tool found/i)).toBeVisible({ timeout: 30_000 })
      await shot(page, '16-mcp-editor')
      await mcpEditor.getByRole('button', { name: /^save$/i }).click()
      await expect(settingsDialog.getByText('Fixture')).toBeVisible({ timeout: 30_000 })
      await shot(page, '16b-mcp-list')

      await page.evaluate(() => {
        window.history.pushState(null, '', '/')
        window.dispatchEvent(new PopStateEvent('popstate'))
      })
      // A new conversation, so this one's history stays local.
      // The sidebar's own button; account chats can be titled the same.
      await page.getByRole('button', { name: /^new chat$/i }).first().click()
      await expect(transcript).not.toContainText('Direct check')
      const fakeSuffix = `:${Buffer.from('fake-model').toString('base64url').replace(/=+$/, '')}`
      let fakeValue: string | undefined
      await expect
        .poll(
          async () => {
            fakeValue = await page
              .locator('#model option')
              .evaluateAll(
                (nodes, suffix) =>
                  nodes
                    .map((n) => (n as HTMLOptionElement).value)
                    .find((v) => v.startsWith('direct:') && v.endsWith(suffix)),
                fakeSuffix,
              )
            return fakeValue
          },
          { timeout: 60_000 },
        )
        .toBeTruthy()
      await page.locator('#model').selectOption(fakeValue!)
      // The chips re-render for a direct model -- its MCP content joins
      // them -- so wait for that before clicking one of them.
      await expect(page.getByRole('button', { name: /^mcp content$/i })).toBeVisible()
      // Open unless an earlier step left it open.
      const toolsButton = page.getByRole('button', { name: /^tools/i })
      if ((await toolsButton.getAttribute('aria-expanded')) !== 'true') {
        await toolsButton.click()
      }
      await page.getByLabel(/^fixture$/i).check()
      const toolComposer = page.getByPlaceholder('Ask Conduit')
      await toolComposer.fill('Echo hi, please')
      await toolComposer.press('Enter')

      const approval = page.getByRole('alertdialog', { name: /server is asking/i })
      await expect(approval).toContainText('echo', { timeout: 60_000 })
      await expect(approval).toContainText('"value":"hi"')
      await shot(page, '16c-mcp-approval')
      expect(mcpServer.calls).toBe(0)
      await approval.getByRole('button', { name: /^allow once$/i }).click()
      await expect(transcript).toContainText('echoed: hi', { timeout: 60_000 })
      expect(mcpServer.calls).toBe(1)
      await shot(page, '16d-mcp-answer')

      // The same server's resources, inserted into the draft as text.
      await page.getByRole('button', { name: /^mcp content$/i }).click()
      const sheet = page.getByRole('dialog', { name: /mcp content/i })
      await sheet.getByRole('button', { name: /today\.md/ }).click()
      await sheet.getByRole('button', { name: /^preview$/i }).click()
      await expect(sheet).toContainText('Water the plants.', { timeout: 30_000 })
      await shot(page, '16e-mcp-content')
      await sheet.getByRole('button', { name: /^insert$/i }).click()
      await expect(sheet).toBeHidden()
      await expect(toolComposer).toHaveValue(/Water the plants\./)
      await toolComposer.fill('')

      // 17. Ollama's model memory (M4), with the connection's models.
      const ollama = await fakeOllama()
      try {
        await page.evaluate(() => {
          window.history.pushState(null, '', '/settings/direct')
          window.dispatchEvent(new PopStateEvent('popstate'))
        })
        await settingsDialog.getByRole('button', { name: /^connect provider$/i }).click()
        const ollamaEditor = settingsDialog.getByRole('group', { name: /connection details/i })
        await ollamaEditor.getByLabel(/^connection name$/i).fill('Home Ollama')
        await ollamaEditor.getByLabel(/^provider type$/i).selectOption('ollama')
        await ollamaEditor.getByLabel(/^base url$/i).fill(ollama.baseUrl)
        await ollamaEditor.getByRole('button', { name: /^save$/i }).click()
        await expect(ollamaEditor).toBeHidden({ timeout: 30_000 })
        await settingsDialog.getByRole('button', { name: /^model memory$/i }).click()
        const memory = settingsDialog.getByRole('group', { name: /^model memory$/i })
        await expect(memory.getByText('big:70b')).toBeVisible({ timeout: 30_000 })
        await expect(memory.getByText(/^loaded$/i)).toBeVisible()
        await shot(page, '17-ollama-memory')
        await memory.getByRole('button', { name: /^unload model$/i }).click()
        await expect(memory.getByText(/^loaded$/i)).toBeHidden({ timeout: 30_000 })
        await memory.getByLabel(/keep alive: tiny:1b/i).selectOption('30m')
        await expect(memory.getByLabel(/keep alive: tiny:1b/i)).toHaveValue('30m')
      } finally {
        ollama.close()
      }

      // 18. Notes (M5): the account's notes, edited in Quill, saved as the
      // markdown the web client reads. This run's note is deleted in the UI,
      // and again through the API should any step fail first.
      await page.evaluate(() => {
        window.history.pushState(null, '', '/')
        window.dispatchEvent(new PopStateEvent('popstate'))
      })
      await page.getByRole('link', { name: /^notes$/i }).click()
      await expect
        .poll(() => page.evaluate(() => window.location.pathname), { timeout: 30_000 })
        .toBe('/notes')
      const notesList = page.getByRole('navigation', { name: /^notes$/i })
      await expect(notesList).toBeVisible()
      await shot(page, '18-notes')
      let noteId: string | undefined
      let recordingIds: string[] = []
      try {
        await notesList.getByRole('button', { name: /^create note$/i }).click()
        await expect
          .poll(() => page.evaluate(() => window.location.pathname), { timeout: 30_000 })
          .toMatch(/^\/notes\/.+/)
        noteId = (await page.evaluate(() => window.location.pathname)).split('/').pop()
        const noteTitle = `Live note ${Date.now()}`
        await page.locator('#note-title').fill(noteTitle)
        const quill = page.locator('#note-editor-host .ql-editor')
        await expect(quill).toBeVisible({ timeout: 30_000 })
        await quill.click()
        await page.keyboard.type('Buy milk and ')
        await page.keyboard.press('Control+b')
        await page.keyboard.type('eggs')
        await page.keyboard.press('Control+b')
        await expect(page.getByRole('status').filter({ hasText: /^saved$/i })).toBeVisible({
          timeout: 30_000,
        })
        await expect(notesList.getByText(noteTitle)).toBeVisible({ timeout: 30_000 })

        // A recording, attached to the note and playable in place.
        await page.getByRole('button', { name: /^record audio$/i }).click()
        await expect(page.getByRole('status').filter({ hasText: /^recording/i })).toBeVisible()
        await page.waitForTimeout(1_500)
        await page.getByRole('button', { name: /^stop recording$/i }).click()
        const attachmentsList = page.getByRole('list', { name: /^attachments$/i })
        await expect(attachmentsList.locator('audio')).toHaveCount(1, { timeout: 30_000 })
        await shot(page, '18b-note')
        // As the web client will read it.
        const { api, auth } = await serverApi(credentials!)
        try {
          await expect
            .poll(
              async () => {
                const note = (await (
                  await api.get(`/api/v1/notes/${noteId}`, { headers: auth })
                ).json()) as { title?: string; data?: { content?: { md?: string } } }
                return `${note.title}|${note.data?.content?.md ?? ''}`
              },
              { timeout: 30_000 },
            )
            .toContain('Buy milk and **eggs**')
          // The recording, in the note's files where the web client finds it.
          await expect
            .poll(
              async () => {
                const note = (await (
                  await api.get(`/api/v1/notes/${noteId}`, { headers: auth })
                ).json()) as { data?: { files?: Array<{ id: string }> } }
                recordingIds = (note.data?.files ?? []).map((file) => file.id)
                return recordingIds.length
              },
              { timeout: 30_000 },
            )
            .toBe(1)
        } finally {
          await api.dispose()
        }
        // Within the note, never the page: the sidebar beside it has a
        // Delete on every conversation.
        await page.getByRole('main').getByRole('button', { name: /^delete$/i }).first().click()
        await page
          .getByRole('alertdialog')
          .getByRole('button', { name: /^delete$/i })
          .click()
        await expect
          .poll(() => page.evaluate(() => window.location.pathname), { timeout: 30_000 })
          .toBe('/notes')
        await expect(notesList.getByText(noteTitle)).toBeHidden({ timeout: 30_000 })
        noteId = undefined
      } finally {
        // The note (if the UI did not delete it) and the recording's file,
        // which outlives the note on the server.
        const { api, auth } = await serverApi(credentials!)
        if (noteId !== undefined) {
          await api.delete(`/api/v1/notes/${noteId}/delete`, { headers: auth }).catch(() => undefined)
        }
        for (const fileId of recordingIds) {
          await api.delete(`/api/v1/files/${fileId}`, { headers: auth }).catch(() => undefined)
        }
        await api.dispose()
      }

      // 19. Channels (M5): a channel of this run's own -- a post, a
      // reaction, a reply in its thread -- then deleted.
      await page.getByRole('link', { name: /^back$/i }).click()
      await page.getByRole('link', { name: /^channels$/i }).click()
      await expect
        .poll(() => page.evaluate(() => window.location.pathname), { timeout: 30_000 })
        .toBe('/channels')
      const channelsList = page.getByRole('navigation', { name: /^channels$/i })
      const channelName = `e2e-${Date.now()}`
      try {
        await channelsList.getByRole('button', { name: /^create channel$/i }).click()
        const createForm = channelsList.getByRole('group', { name: /^create channel$/i })
        await createForm.getByLabel(/^channel name$/i).fill(channelName)
        await createForm.getByRole('button', { name: /^create channel$/i }).click()
        await channelsList.getByRole('link', { name: new RegExp(channelName) }).click()
        await expect
          .poll(() => page.evaluate(() => window.location.pathname), { timeout: 30_000 })
          .toMatch(/^\/channels\/.+/)
        const channelComposer = page.locator('#channel-composer')
        await channelComposer.fill('Deploy is done')
        await channelComposer.press('Enter')
        const channelLog = page.getByRole('log', { name: /^channels$/i })
        const posted = channelLog.getByRole('article').filter({ hasText: 'Deploy is done' })
        await expect(posted).toBeVisible({ timeout: 30_000 })
        await posted.hover()
        await posted.getByRole('button', { name: /^react$/i }).click()
        await posted.getByRole('button', { name: '👍' }).click()
        await expect(posted.getByRole('button', { name: /👍 1/ })).toBeVisible({ timeout: 30_000 })
        await posted.hover()
        await posted.getByRole('button', { name: /^reply$/i }).click()
        const threadPanel = page.getByRole('complementary', { name: /^thread$/i })
        await expect(threadPanel).toBeVisible()
        const replyBox = threadPanel.locator('textarea')
        await replyBox.fill('Thanks!')
        await replyBox.press('Enter')
        await expect(threadPanel.getByRole('log').getByText('Thanks!')).toBeVisible({
          timeout: 30_000,
        })
        await expect(posted.getByRole('button', { name: /thread \(1\)/i })).toBeVisible({
          timeout: 30_000,
        })
        await shot(page, '19-channel')
        await page.getByRole('button', { name: /^delete channel$/i }).click()
        await page.getByRole('alertdialog').getByRole('button', { name: /^delete$/i }).click()
        await expect(channelsList.getByRole('link', { name: new RegExp(channelName) })).toBeHidden({
          timeout: 30_000,
        })
      } finally {
        const { api, auth } = await serverApi(credentials!)
        const channels = (await (await api.get('/api/v1/channels/', { headers: auth })).json()) as Array<{
          id: string
          name: string
        }>
        for (const channel of channels.filter((c) => c.name === channelName)) {
          await api.delete(`/api/v1/channels/${channel.id}/delete`, { headers: auth }).catch(() => undefined)
        }
        await api.dispose()
      }

      // 20. The workspace (M6): a prompt made, versioned, compared,
      // exported, shared and deleted; a knowledge base with a folder and a
      // file uploaded into it. Everything is this run's own, and deleted
      // through the API as well should a step fail first.
      const pathname = () => page.evaluate(() => window.location.pathname)
      await page.evaluate(() => {
        window.history.pushState(null, '', '/')
        window.dispatchEvent(new PopStateEvent('popstate'))
      })
      await page.getByRole('link', { name: /^workspace$/i }).click()
      await expect.poll(pathname, { timeout: 30_000 }).toBe('/workspace/models')
      const sections = page.getByRole('navigation', { name: /^workspace$/i })
      await expect(page.getByRole('heading', { name: /^models/i })).toBeVisible({ timeout: 30_000 })
      await shot(page, '20-workspace')
      const stamp = Date.now()
      const promptName = `Live e2e prompt ${stamp}`
      const command = `live-e2e-prompt-${stamp}`
      const knowledgeName = `Live e2e knowledge ${stamp}`
      const knowledgeFile = join(tmpdir(), `conduit-knowledge-${stamp}.txt`)
      writeFileSync(knowledgeFile, 'The deploy window is Tuesday at nine.\n')
      // Exports are downloads; the main process is told where to put them
      // rather than asking, as it would a person.
      const downloads = mkdtempSync(join(tmpdir(), 'conduit-downloads-'))
      await app.evaluate(({ session }, dir) => {
        session.defaultSession.on('will-download', (_event, item) => {
          item.setSavePath(`${dir}/${item.getFilename()}`)
        })
      }, downloads)
      const modelId = `live-e2e-model-${stamp}`
      // A 2x2 PNG for the model's picture; the app scales it on a canvas.
      const imagePath = join(tmpdir(), `conduit-model-${stamp}.png`)
      writeFileSync(
        imagePath,
        Buffer.from(
          'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEElEQVR4nGM4YWMDRAwQCgAlPgUBdJmUYAAAAABJRU5ErkJggg==',
          'base64',
        ),
      )
      try {
        // A model over a base, with a system prompt and a picture.
        await page.locator('#workspace-create').click()
        await expect.poll(pathname).toBe('/workspace/models/new')
        await page.locator('#model-name').fill(`Live e2e model ${stamp}`)
        await expect(page.locator('#model-id')).toHaveValue(modelId)
        await expect(page.locator('#model-base option')).not.toHaveCount(1, { timeout: 30_000 })
        await page.locator('#model-base').selectOption({ index: 1 })
        await page.locator('#model-system').fill('Answer in one word.')
        const imageChooser = page.waitForEvent('filechooser')
        await page.getByRole('button', { name: /^change image$/i }).click()
        await (await imageChooser).setFiles(imagePath)
        await expect(page.getByRole('img', { name: /^profile image$/i })).toBeVisible({
          timeout: 30_000,
        })
        await page.locator('#workspace-save').click()
        await expect
          .poll(pathname, { timeout: 30_000 })
          .toBe(`/workspace/models/${modelId}`)
        {
          const { api, auth } = await serverApi(credentials!)
          try {
            const model = (await (
              await api.get(`/api/v1/models/model?id=${encodeURIComponent(modelId)}`, {
                headers: auth,
              })
            ).json()) as {
              base_model_id?: string
              params?: { system?: string }
              meta?: { profile_image_url?: string }
            }
            expect(model.base_model_id).toBeTruthy()
            expect(model.params?.system).toBe('Answer in one word.')
            expect(model.meta?.profile_image_url ?? '').toMatch(/^data:image\/png;base64,/)
          } finally {
            await api.dispose()
          }
        }
        await shot(page, '20a-model')
        await page.locator('#workspace-delete').click()
        await page.getByRole('alertdialog').getByRole('button', { name: /^delete$/i }).click()
        await expect.poll(pathname, { timeout: 30_000 }).toBe('/workspace/models')

        await sections.getByRole('button', { name: /^prompts$/i }).click()
        await expect.poll(pathname).toBe('/workspace/prompts')
        await page.locator('#workspace-create').click()
        await expect.poll(pathname).toBe('/workspace/prompts/new')
        await page.locator('#prompt-name').fill(promptName)
        // The command follows the name until it is typed.
        await expect(page.locator('#prompt-command')).toHaveValue(`/${command}`)
        await page.locator('#prompt-content').fill('Say hello to {{USER_NAME}}.')
        await page.locator('#workspace-save').click()
        await expect
          .poll(pathname, { timeout: 30_000 })
          .toMatch(/^\/workspace\/prompts\/(?!new$).+/)
        await expect(page.getByRole('heading', { name: promptName })).toBeVisible({
          timeout: 30_000,
        })

        // A second version, with a message, compared with the first.
        await page.locator('#prompt-content').fill('Say hello warmly to {{USER_NAME}}.')
        await page.locator('#prompt-commit').fill('Warmer')
        await page.locator('#workspace-save').click()
        await expect(
          page.getByRole('status').filter({ hasText: /^prompt saved$/i }),
        ).toBeVisible({ timeout: 30_000 })
        await page.locator('#workspace-history').click()
        const history = page.getByRole('region', { name: /^version history$/i })
        await expect(history.getByText('Warmer')).toBeVisible({ timeout: 30_000 })
        await history.getByRole('button', { name: /^compare with production$/i }).click()
        const diffDialog = page.getByRole('dialog', { name: /^version comparison$/i })
        await expect(diffDialog.getByText('+Say hello warmly to {{USER_NAME}}.')).toBeVisible({
          timeout: 30_000,
        })
        await expect(diffDialog.getByText('-Say hello to {{USER_NAME}}.')).toBeVisible()
        await shot(page, '20b-prompt-diff')
        await diffDialog.getByRole('button', { name: /^close$/i }).click()

        // Exported as the file Open WebUI imports.
        await page.getByRole('button', { name: /^export$/i }).click()
        const exportedPath = join(downloads, `${command}.json`)
        await expect
          .poll(() => {
            try {
              return JSON.parse(readFileSync(exportedPath, 'utf8'))[0]?.command
            } catch {
              return undefined
            }
          }, { timeout: 30_000 })
          .toBe(command)

        // Who may use it.
        await page.locator('#workspace-access').click()
        const accessDialog = page.getByRole('dialog', { name: /^sharing & access$/i })
        await expect(accessDialog.getByLabel(/^public$/i)).toBeVisible()
        await shot(page, '20c-access')
        await accessDialog.getByRole('button', { name: /^cancel$/i }).click()

        // And gone.
        await page.locator('#workspace-delete').click()
        await page.getByRole('alertdialog').getByRole('button', { name: /^delete$/i }).click()
        await expect.poll(pathname, { timeout: 30_000 }).toBe('/workspace/prompts')
        await expect(page.getByText(promptName)).toBeHidden({ timeout: 30_000 })

        // A knowledge base: a folder, and a file uploaded into it.
        await sections.getByRole('button', { name: /^knowledge$/i }).click()
        await expect.poll(pathname).toBe('/workspace/knowledge')
        await page.locator('#workspace-create').click()
        await page.locator('#knowledge-name').fill(knowledgeName)
        await page.locator('#workspace-save').click()
        await expect
          .poll(pathname, { timeout: 30_000 })
          .toMatch(/^\/workspace\/knowledge\/(?!new$).+/)
        const files = page.getByRole('region', { name: /^files$/i })
        await expect(files).toBeVisible({ timeout: 30_000 })
        await page.locator('#knowledge-new-folder').click()
        await page.locator('#knowledge-folder-name').fill('Guides')
        await page.locator('#knowledge-folder-save').click()
        await files.getByRole('button', { name: /guides/i }).click()
        await expect(files.getByRole('navigation').getByRole('button', { name: /^guides$/i })).toBeVisible({
          timeout: 30_000,
        })
        const chooser = page.waitForEvent('filechooser')
        await page.locator('#knowledge-upload').click()
        await (await chooser).setFiles(knowledgeFile)
        // Its row, in the folder -- not the "Uploading" line, which names it
        // too and would pass before the upload had finished.
        await expect(
          files.locator('li[data-file]').filter({ hasText: basename(knowledgeFile) }),
        ).toBeVisible({ timeout: 90_000 })
        await shot(page, '20d-knowledge')
        await page.locator('#workspace-delete').click()
        await page.getByRole('alertdialog').getByRole('button', { name: /^delete$/i }).click()
        await expect.poll(pathname, { timeout: 30_000 }).toBe('/workspace/knowledge')
        await expect(page.getByText(knowledgeName)).toBeHidden({ timeout: 30_000 })
      } finally {
        const { api, auth } = await serverApi(credentials!)
        const prompts = (await (await api.get('/api/v1/prompts/', { headers: auth }))
          .json()
          .catch(() => [])) as Array<{ id: string; command: string }>
        // Not a list when the server refused; the test's own failure, if
        // there was one, is the one to report.
        for (const prompt of (Array.isArray(prompts) ? prompts : []).filter((p) => p.command === command)) {
          await api.delete(`/api/v1/prompts/id/${prompt.id}/delete`, { headers: auth }).catch(() => undefined)
        }
        const knowledge = (await (await api.get('/api/v1/knowledge/', { headers: auth })).json()) as {
          items?: Array<{ id: string; name: string }>
        }
        for (const base of (knowledge.items ?? []).filter((k) => k.name === knowledgeName)) {
          await api.delete(`/api/v1/knowledge/${base.id}/delete`, { headers: auth }).catch(() => undefined)
        }
        // The uploaded file outlives the knowledge base it was put in.
        const uploaded = (await (
          await api.get(`/api/v1/files/search?filename=${encodeURIComponent(basename(knowledgeFile))}`, {
            headers: auth,
          })
        )
          .json()
          .catch(() => [])) as Array<{ id: string }>
        for (const file of Array.isArray(uploaded) ? uploaded : []) {
          await api.delete(`/api/v1/files/${file.id}`, { headers: auth }).catch(() => undefined)
        }
        await api
          .post('/api/v1/models/model/delete', { headers: auth, data: { id: modelId } })
          .catch(() => undefined)
        await api.dispose()
        rmSync(downloads, { recursive: true, force: true })
        rmSync(knowledgeFile, { force: true })
        rmSync(imagePath, { force: true })
      }

      // 21. The terminal (M7): a terminal server added to the account's
      // settings for this step -- a real `sh` behind open-terminal's API --
      // then the shell, its files and a port, and the server removed again.
      const terminal = await fakeTerminal()
      const terminalSettings = async (
        edit: (servers: Array<Record<string, unknown>>) => Array<Record<string, unknown>>,
      ) => {
        const { api, auth } = await serverApi(credentials!)
        try {
          const settings = ((await (
            await api.get('/api/v1/users/user/settings', { headers: auth })
          ).json()) ?? {}) as { ui?: Record<string, unknown> }
          const ui = { ...(settings.ui ?? {}) }
          ui.terminalServers = edit((ui.terminalServers as Array<Record<string, unknown>>) ?? [])
          await api.post('/api/v1/users/user/settings/update', {
            headers: auth,
            data: { ...settings, ui },
          })
        } finally {
          await api.dispose()
        }
      }
      try {
        await terminalSettings((servers) => [
          ...servers,
          { url: terminal.url, key: terminal.key, name: 'E2E shell', enabled: false, config: { enable: true } },
        ])
        // The window read the account's terminals when it started.
        await page.evaluate(() => {
          window.history.pushState(null, '', '/')
          window.dispatchEvent(new PopStateEvent('popstate'))
        })
        await page.reload()
        await page.getByRole('link', { name: /^terminal$/i }).click({ timeout: 60_000 })
        await expect.poll(pathname, { timeout: 30_000 }).toBe('/terminal')
        await expect(page.getByRole('status').filter({ hasText: /^connected$/i })).toBeVisible({
          timeout: 30_000,
        })
        const shell = page.locator('#terminal-host')
        await shell.click()
        await page.keyboard.type('echo conduit-$((6*7)) > answer.txt; cat answer.txt\r')
        await expect(shell.locator('.xterm-rows')).toContainText('conduit-42', { timeout: 30_000 })
        // Ctrl+K is the shell's here, not the command palette's.
        await page.keyboard.press('Control+k')
        await expect(page.getByRole('dialog', { name: /command/i })).toBeHidden()

        // The file the shell made, in the files panel.
        const panel = page.getByRole('navigation', { name: /^terminal$/i })
        await panel.getByRole('button', { name: /^home directory$/i }).click()
        await panel.getByRole('button', { name: '📄 answer.txt', exact: true }).click()
        const preview = page.getByRole('dialog', { name: 'answer.txt' })
        await expect(preview.getByText('conduit-42')).toBeVisible({ timeout: 30_000 })
        await preview.getByRole('button', { name: /^close$/i }).click()

        // A folder, and a file uploaded into this one.
        await page.locator('#terminal-new-folder').click()
        await page.locator('#terminal-folder-name').fill('Guides')
        await page.locator('#terminal-folder-name-save').click()
        await expect(panel.getByRole('button', { name: '📁 Guides', exact: true })).toBeVisible({
          timeout: 30_000,
        })
        const upload = join(tmpdir(), `conduit-terminal-upload-${process.pid}.txt`)
        writeFileSync(upload, 'uploaded through the daemon\n')
        const uploadChooser = page.waitForEvent('filechooser')
        await page.locator('#terminal-upload').click()
        await (await uploadChooser).setFiles(upload)
        await expect(panel.getByRole('button', { name: `📄 ${basename(upload)}`, exact: true })).toBeVisible({
          timeout: 30_000,
        })
        expect(readFileSync(join(terminal.home, basename(upload)), 'utf8')).toBe(
          'uploaded through the daemon\n',
        )
        rmSync(upload, { force: true })
        await shot(page, '21-terminal')

        // A port, previewed through the daemon: the address goes to the
        // system browser, which is caught here instead.
        await app.evaluate(({ shell }) => {
          ;(globalThis as { __opened?: string[] }).__opened = []
          shell.openExternal = async (url: string) => {
            ;(globalThis as unknown as { __opened: string[] }).__opened.push(url)
          }
        })
        await panel.getByRole('button', { name: /^open in browser$/i }).click()
        await expect
          .poll(() => app.evaluate(() => (globalThis as { __opened?: string[] }).__opened?.length ?? 0))
          .toBe(1)
        const opened = await app.evaluate(() => (globalThis as unknown as { __opened: string[] }).__opened[0])
        const keyed = await fetch(opened, { redirect: 'manual' })
        expect(keyed.status).toBe(302)
        const cookie = (keyed.headers.get('set-cookie') ?? '').split(';')[0]
        const shown = await fetch(new URL('/docs', opened), { headers: { cookie } })
        expect(await shown.text()).toBe('<h1>preview /docs</h1>')
        expect((await fetch(new URL('/docs', opened))).status).toBe(403)

        await page.locator('#terminal-fullscreen').click()
        await expect(panel).toBeHidden()
        await shot(page, '21b-terminal-fullscreen')
        await page.locator('#terminal-fullscreen').click()

        // Chats use it once chosen in the composer, which marks it in the
        // account's settings as the web client does.
        await page.getByRole('link', { name: /^back$/i }).click()
        await expect.poll(pathname, { timeout: 30_000 }).toBe('/')
        // A server model: a direct one answers here, without Open WebUI's
        // terminal, and the composer offers none for it.
        await page.locator('#model').selectOption(credentials!.model ?? { index: 0 })
        const chooser = page.getByRole('group', { name: /^select a terminal server$/i })
        // The chips re-render as the new model's options arrive, and a click
        // mid-shuffle lands on the chip beside it. Until the chooser is open.
        await expect(async () => {
          if (!(await chooser.isVisible())) {
            await page.getByRole('button', { name: /^terminal$/i }).click()
          }
          await expect(chooser).toBeVisible({ timeout: 2_000 })
        }).toPass({ timeout: 30_000 })
        await chooser.getByRole('button', { name: 'E2E shell' }).click()
        await expect(page.getByRole('button', { name: /^terminal: e2e shell$/i })).toBeVisible({
          timeout: 30_000,
        })
        {
          const { api, auth } = await serverApi(credentials!)
          try {
            const settings = (await (
              await api.get('/api/v1/users/user/settings', { headers: auth })
            ).json()) as { ui?: { terminalServers?: Array<{ url: string; enabled?: boolean }> } }
            expect(
              settings.ui?.terminalServers?.find((s) => s.url === terminal.url)?.enabled,
            ).toBe(true)
          } finally {
            await api.dispose()
          }
        }
        await shot(page, '21c-composer-terminal')
      } finally {
        await terminalSettings((servers) => servers.filter((s) => s.url !== terminal.url)).catch(
          () => undefined,
        )
        terminal.close()
      }

      // M8: voice. Settings → Audio, then dictation and a call through the
      // server's transcription -- with real words when a sample is given --
      // and an answer read aloud.
      {
        await page.goto('app://conduit/settings/audio')
        await expect(page.getByRole('region', { name: /^speech to text$/i })).toBeVisible({
          timeout: 30_000,
        })
        await expect(page.locator('#tts-engine-device')).toBeChecked()
        await shot(page, '22-audio-settings')
        await page.goto('app://conduit/')
        await page.locator('#model').selectOption(credentials!.model ?? { index: 0 })
        const composer = page.getByPlaceholder('Ask Conduit')
        const dictate = page.locator('#dictate')
        await expect(dictate).toBeVisible({ timeout: 30_000 })
        if (speechSample) {
          await dictate.click()
          await expect(dictate).toHaveAttribute('aria-pressed', 'true')
          await shot(page, '22b-dictating')
          await expect(composer).toHaveValue(/quick brown fox/i, { timeout: 60_000 })
          await composer.fill('')

          // A call: it hears the question, sends it, and reads the answer.
          await page.locator('#voice-call').click()
          const call = page.getByRole('region', { name: /^voice call$/i })
          await expect(call).toBeVisible()
          await expect(call.getByText(/you said: .*quick brown fox/i)).toBeVisible({
            timeout: 60_000,
          })
          await shot(page, '22c-call')
          const transcript = page.getByRole('log')
          await expect(transcript).toContainText(/quick brown fox/i, { timeout: 30_000 })
          await page.locator('#call-end').click()
          await expect(call).toBeHidden()
        } else {
          // Without a sample there is no call, so no answer to read: ask
          // for one in writing.
          await composer.fill('Say hello in five words.')
          await composer.press('Enter')
          await expect(page.getByRole('log')).toContainText(/hello/i, { timeout: 60_000 })
        }

        // Read aloud: the system's voice, and stopped again. A CI box has no
        // voices, and an engine with none ends every sentence at once, so
        // the engine is replaced by one that only listens.
        await page.evaluate(() => {
          const heard: string[] = []
          ;(window as unknown as { __heard: string[] }).__heard = heard
          window.speechSynthesis.speak = (utterance) => {
            heard.push(utterance.text)
          }
        })
        const listen = page.locator('[data-read-aloud]').last()
        await expect(listen).toBeAttached({ timeout: 30_000 })
        await listen.click({ force: true })
        await expect(listen).toHaveAttribute('aria-pressed', 'true')
        await expect
          .poll(() => page.evaluate(() => (window as unknown as { __heard: string[] }).__heard.length))
          .toBeGreaterThan(0)
        await listen.click()
        await expect(listen).toHaveAttribute('aria-pressed', 'false')
      }

      // M9: "Open with Conduit". A second launch with a file, as the OS
      // does, uploads it through the daemon and starts a chat with it.
      {
        const name = `conduit-e2e-open-${process.pid}.txt`
        const file = join(tmpdir(), name)
        writeFileSync(file, 'Opened with Conduit.\n')
        try {
          const second = spawn(
            electronBinary as unknown as string,
            ['.', `--user-data-dir=${userData}`, '--no-sandbox', file],
            { cwd: join(__dirname, '..'), stdio: 'ignore' },
          )
          await new Promise((resolve) => second.once('exit', resolve))
          const chips = page.locator('[aria-label="Attachments"]')
          await expect(chips.getByText(name)).toBeVisible({ timeout: 30_000 })
          await shot(page, '23-open-with')
        } finally {
          rmSync(file, { force: true })
          const { api, auth } = await serverApi(credentials!)
          try {
            const found = (await (
              await api.get(`/api/v1/files/search?filename=${encodeURIComponent(name)}`, { headers: auth })
            )
              .json()
              .catch(() => [])) as Array<{ id: string }>
            for (const uploaded of Array.isArray(found) ? found : []) {
              await api.delete(`/api/v1/files/${uploaded.id}`, { headers: auth }).catch(() => undefined)
            }
          } finally {
            await api.dispose()
          }
        }
      }
    } finally {
      provider.close()
      mcpServer.close()
    }
  })
})
