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
 * The M9 additions are bounded the same way: the main process checks
 * every argument, and the worst any of them does is show a notification,
 * open a chat, or change a shell setting the user can see and change back.
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

  /**
   * The shell's own settings (M9), changed by [patch] when given. The main
   * process keeps only known keys of the right type.
   */
  shellSettings(patch?: Record<string, unknown>): Promise<Record<string, unknown>>

  /** An OS notification; clicking it opens [open] in the main window. */
  notify(request: { title: string; body?: string; open?: unknown }): Promise<boolean>

  /**
   * Hears what the window is asked to open -- a `conduit://` link, a
   * notification, the tray -- and says it is ready, so links that came
   * first arrive now.
   */
  onOpen(callback: (request: unknown) => void): void

  /** From the quick-ask panel: continue in the main window. */
  openInMain(request: unknown): void

  /** Hides this window (the quick-ask panel's Escape). */
  hideWindow(): void
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
  shellSettings: (patch) =>
    ipcRenderer.invoke('conduit:shell-settings', patch ?? null) as Promise<
      Record<string, unknown>
    >,
  notify: (request) => ipcRenderer.invoke('conduit:notify', request) as Promise<boolean>,
  onOpen: (callback) => {
    ipcRenderer.on('conduit:open', (_event, request: unknown) => callback(request))
    ipcRenderer.send('conduit:open-ready')
  },
  openInMain: (request) => ipcRenderer.send('conduit:open-in-main', request),
  hideWindow: () => ipcRenderer.send('conduit:hide-window'),
}

contextBridge.exposeInMainWorld('conduit', bridge)

// The daemon's port changes when it restarts. Rather than expose a setter,
// the main process asks the window to reload, which re-runs this preload with
// fresh arguments and lets the renderer reconnect from a known-good state.
ipcRenderer.on('conduit:core-restarted', () => {
  location.reload()
})
