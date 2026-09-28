import { BrowserWindow, session, type Session, type WebContents } from 'electron'
import { randomUUID } from 'node:crypto'
import {
  AuthWindowRejected,
  originOf,
  requireHttpOrigin,
  requireHttpUrl,
} from './auth-url.js'

export { AuthWindowRejected } from './auth-url.js'

/** What the renderer asks for when a sign-in needs a real browser. */
export interface AuthWindowRequest {
  /** Where the flow begins. Often the server's `/auth`, but an SSO provider's
   *  authorize endpoint for a provider-initiated flow. */
  readonly startUrl: string
  /** The Open WebUI origin. Cookies are only ever captured for this. */
  readonly serverUrl: string
  readonly title?: string
  readonly timeoutMs?: number
}

export type AuthWindowResult =
  | {
      readonly status: 'completed'
      readonly origin: string
      readonly cookies: Record<string, string>
      readonly token?: string
    }
  | { readonly status: 'cancelled' | 'timeout' }

const DEFAULT_TIMEOUT_MS = 5 * 60_000

/** Auth windows, so `hardenNavigation` knows to leave them alone. */
const authContents = new WeakSet<WebContents>()

/** Whether [contents] is an auth window, which is allowed to be a browser. */
export function isAuthWindowContents(contents: WebContents): boolean {
  return authContents.has(contents)
}

/**
 * Runs an external sign-in in a real browser window and captures what it left.
 *
 * Reverse proxies (oauth2-proxy, Authelia, Authentik, Pangolin, Cloudflare
 * Tunnel) and SSO providers need a browser: a redirect chain, third-party
 * cookies, sometimes a hardware key. None of that can happen inside the
 * renderer, and none of it should — the app origin holds the preload bridge.
 *
 * Three properties this leans on, each load-bearing:
 *
 *  * **A fresh in-memory partition per flow.** Not `persist:`, so it is
 *    discarded with the window. It also means the only cookies that can be
 *    captured are ones this flow created — a renderer that names some other
 *    origin gets an empty jar rather than that site's real session, so the
 *    capture is safe by construction rather than by a checked allowlist.
 *  * **No preload, no node integration, sandboxed.** This window loads pages
 *    we do not control; it must have strictly less power than a browser tab,
 *    not more.
 *  * **Cookies are read from the main process**, via the session API. The
 *    mobile app injects JavaScript into the page to scrape `document.cookie`,
 *    because a WebView gives it no other option. Here that would be running
 *    our script in a third-party document for no benefit. It also means
 *    `HttpOnly` cookies are captured, which `document.cookie` cannot see —
 *    and a proxy session cookie is normally `HttpOnly`.
 *
 * Completion is "navigated back to the server's origin", and no further
 * inspection. The daemon's `prevalidateProxySession` then decides whether the
 * session is real, which is the right place for it: the window cannot tell an
 * authenticated Open WebUI page from a proxy's error page, and the daemon can
 * simply ask the server.
 */
export async function runAuthWindow(
  request: AuthWindowRequest,
  options: { readonly parent?: BrowserWindow } = {},
): Promise<AuthWindowResult> {
  const serverOrigin = requireHttpOrigin(request.serverUrl, 'serverUrl')
  const startUrl = requireHttpUrl(request.startUrl, 'startUrl')

  const partition = `conduit-auth-${randomUUID()}`
  const authSession = session.fromPartition(partition, { cache: false })

  const window = new BrowserWindow({
    // Spread rather than `parent: options.parent`: `exactOptionalPropertyTypes`
    // is on, so an explicit `undefined` is not the same as an absent key.
    ...(options.parent === undefined ? {} : { parent: options.parent, modal: true }),
    width: 520,
    height: 700,
    title: request.title ?? 'Sign in',
    autoHideMenuBar: true,
    webPreferences: {
      session: authSession,
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      webSecurity: true,
      // No `preload`. Nothing in this window may reach the bridge.
    },
  })
  authContents.add(window.webContents)

  try {
    return await new Promise<AuthWindowResult>((resolve) => {
      let settled = false
      const settle = (result: AuthWindowResult): void => {
        if (settled) return
        settled = true
        resolve(result)
      }

      const timer = setTimeout(
        () => settle({ status: 'timeout' }),
        request.timeoutMs ?? DEFAULT_TIMEOUT_MS,
      )

      const onNavigated = (url: string): void => {
        if (settled) return
        if (originOf(url) !== serverOrigin) return
        void capture(authSession, serverOrigin).then((captured) =>
          settle({ status: 'completed', origin: serverOrigin, ...captured }),
        )
      }

      // Both events, because the two differ: an SPA that routes after login
      // fires only the in-page one, and a server-rendered redirect fires only
      // the other.
      window.webContents.on('did-navigate', (_event, url) => onNavigated(url))
      window.webContents.on('did-navigate-in-page', (_event, url) =>
        onNavigated(url),
      )

      // Closing the window is how a user cancels, and it is not an error.
      window.on('closed', () => {
        clearTimeout(timer)
        settle({ status: 'cancelled' })
      })

      void window.loadURL(startUrl)
    })
  } finally {
    if (!window.isDestroyed()) window.destroy()
    // The partition is in-memory, but clearing is explicit rather than
    // implied: a captured session lives on in the daemon's jar now, and two
    // copies of one credential is one more than necessary.
    await authSession.clearStorageData()
  }
}

async function capture(
  authSession: Session,
  origin: string,
): Promise<{ cookies: Record<string, string>; token?: string }> {
  const jar = await authSession.cookies.get({ url: origin })
  const cookies: Record<string, string> = {}
  for (const cookie of jar) {
    cookies[cookie.name] = cookie.value
  }
  // Open WebUI issues `token` when a trusted-header proxy has already
  // authenticated the user, which is what lets the sign-in form be skipped.
  // Its absence is not a failure — it means the proxy let us through and the
  // server still wants credentials.
  const token = cookies.token
  return token === undefined || token.length === 0 ? { cookies } : { cookies, token }
}
