import { contextBridge, ipcRenderer } from 'electron'

/**
 * What the renderer is allowed to know.
 *
 * Deliberately data-only for now. `contextIsolation` is on and
 * `nodeIntegration` is off, so this object is the entire surface between the
 * Jaspr bundle and the OS; every function added here is a capability granted
 * to anything the renderer ends up executing, including model output.
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
}

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
}

contextBridge.exposeInMainWorld('conduit', bridge)

// The daemon's port changes when it restarts. Rather than expose a setter,
// the main process asks the window to reload, which re-runs this preload with
// fresh arguments and lets the renderer reconnect from a known-good state.
ipcRenderer.on('conduit:core-restarted', () => {
  location.reload()
})
