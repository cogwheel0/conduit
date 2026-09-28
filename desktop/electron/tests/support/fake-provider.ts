import { createServer, type IncomingMessage } from 'node:http'
import type { AddressInfo } from 'node:net'
import type { Page } from '@playwright/test'

/**
 * An OpenAI-compatible provider on localhost that answers every chat with
 * the same markdown, for specs that need a conversation without a server.
 */
export async function fakeProvider(
  answer = '## An answer\n\nWith **markdown**, a list:\n\n- one\n- two\n\n```dart\nfinal x = 1;\n```\n',
) {
  const server = createServer(async (request, response) => {
    if (request.url?.endsWith('/models')) {
      response.setHeader('content-type', 'application/json')
      response.end(JSON.stringify({ data: [{ id: 'echo-model', object: 'model' }] }))
      return
    }
    await jsonBody(request)
    response.setHeader('content-type', 'text/event-stream; charset=utf-8')
    response.write(`data: ${JSON.stringify({ choices: [{ index: 0, delta: { content: answer } }] })}\n\n`)
    response.end('data: [DONE]\n\n')
  })
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve))
  const port = (server.address() as AddressInfo).port
  return { baseUrl: `http://127.0.0.1:${port}/v1`, close: () => server.close() }
}

async function jsonBody(request: IncomingMessage): Promise<any> {
  const chunks: Buffer[] = []
  for await (const chunk of request) chunks.push(chunk as Buffer)
  return JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}')
}

/** Client-side navigation, as the router does it. */
export async function go(page: Page, path: string): Promise<void> {
  await page.evaluate((to) => {
    history.pushState(null, '', to)
    dispatchEvent(new PopStateEvent('popstate'))
  }, path)
}
