import { contextBridge, ipcRenderer } from 'electron'

/**
 * What the renderer is allowed to know.
 *
 * `contextIsolation` is on and `nodeIntegration` is off, so this object is
 * the entire surface between the Jaspr bundle and the OS; every function
 * added here is a capability granted to anything the renderer ends up
 * executing, including model output. It stayed data-only through M0 for that
 * reason, and [openAuthWindow] is the first exception — see
 * `registerAuthWindowChannel` in main for why that one is safe to grant.
 */
export interface ConduitBridge {
  /** Loopback port `conduitd` bound, or 0 before it reports ready. */
  readonly rpcPort: number
  /** Session token for the RPC subprotocol and HTTP bearer header. */
  readonly token: string
  readonly platform: NodeJS.Platform
  /** `main` | `quickAsk` | `headless`. */
  readonly windowKind: string
  readonly appVersion: string
  /**
   * Runs an external sign-in (SSO, OAuth, reverse proxy) in a separate
   * window and resolves with what that session left behind.
   *
   * The renderer hands the result to `auth.completeExternal`; the daemon
   * validates it against the server before committing, so a window closed
   * halfway through cannot leave a half-authenticated state.
   */
  openAuthWindow(request: AuthWindowRequest): Promise<AuthWindowResult>
}

export interface AuthWindowRequest {
  readonly startUrl: string
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

// The main process injects these as `additionalArguments` at window creation,
// so they are available synchronously — the renderer never has to await an
// IPC round trip before it can open its socket.
function readArgument(name: string, fallback = ''): string {
  const prefix = `--conduit-${name}=`
  const match = process.argv.find((arg) => arg.startsWith(prefix))
  return match === undefined ? fallback : match.slice(prefix.length)
}

const bridge: ConduitBridge = {
  rpcPort: Number.parseInt(readArgument('rpc-port', '0'), 10),
  token: readArgument('token'),
  platform: process.platform,
  windowKind: readArgument('window-kind', 'main'),
  appVersion: readArgument('app-version', '0.0.0'),
  openAuthWindow: (request) =>
    ipcRenderer.invoke('conduit:auth-window', request) as Promise<
      AuthWindowResult
    >,
}

contextBridge.exposeInMainWorld('conduit', bridge)

// The daemon's port changes when it restarts. Rather than expose a setter,
// the main process asks the window to reload, which re-runs this preload with
// fresh arguments and lets the renderer reconnect from a known-good state.
ipcRenderer.on('conduit:core-restarted', () => {
  location.reload()
})
