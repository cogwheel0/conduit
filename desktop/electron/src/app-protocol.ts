import { net, protocol } from 'electron'
import { join, normalize, sep } from 'node:path'
import { pathToFileURL } from 'node:url'

/** The origin the renderer runs on, and the only one the daemon accepts. */
export const APP_ORIGIN = 'app://conduit'

/**
 * Declares `app:` before the app is ready.
 *
 * Must run at module load: Electron only reads the privileged-scheme list
 * during startup. `standard` is what gives the scheme a real origin (so
 * `Origin: app://conduit` is sent and CSP works), and `secure` puts it in a
 * secure context so service workers, crypto and media APIs behave as they do
 * over https.
 */
export function registerAppScheme(): void {
  protocol.registerSchemesAsPrivileged([
    {
      scheme: 'app',
      privileges: {
        standard: true,
        secure: true,
        supportFetchAPI: true,
        corsEnabled: true,
        stream: true,
      },
    },
  ])
}

/**
 * Serves the Jaspr bundle from [APP_ORIGIN].
 *
 * A custom scheme rather than `file://` for two reasons: `file://` pages are
 * an opaque origin, so they cannot be pinned by CSP and send `Origin: null`,
 * which the daemon rejects; and it keeps the renderer from being able to read
 * arbitrary paths off the disk.
 */
export function serveAppScheme(webRoot: string): void {
  const root = normalize(webRoot)
  protocol.handle('app', async (request) => {
    const url = new URL(request.url)
    if (url.host !== 'conduit') {
      return new Response('not found', { status: 404 })
    }

    const requested = decodeURIComponent(url.pathname)
    const relative = requested === '/' || requested === '' ? '/index.html' : requested
    const resolved = normalize(join(root, relative))

    // Containment check. `normalize` collapses `..`, so comparing prefixes
    // here is what stops `app://conduit/../../etc/passwd` from escaping.
    // The trailing separator matters: `/rootevil` must not match `/root`.
    if (resolved !== root && !resolved.startsWith(root + sep)) {
      return new Response('forbidden', { status: 403 })
    }

    return net.fetch(pathToFileURL(resolved).toString())
  })
}
