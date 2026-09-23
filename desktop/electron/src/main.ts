import { app, BrowserWindow, ipcMain, session, shell } from 'electron'
import { join, resolve } from 'node:path'
import { APP_ORIGIN, registerAppScheme, serveAppScheme } from './app-protocol.js'
import {
  AuthWindowRejected,
  isAuthWindowContents,
  runAuthWindow,
  type AuthWindowRequest,
  type AuthWindowResult,
} from './auth-window.js'
import { DaemonSupervisor, resolveDaemonPath } from './daemon.js'
import { loadOrCreateSecrets, type CoreSecrets } from './secrets.js'
import { WindowStateStore } from './window-state.js'

/**
 * Distinct from the mobile bundle id on purpose, so keychain entries, deep
 * links and notifications from the two apps never collide.
 */
const APP_ID = 'app.cogwheel.conduit.desktop'

// Must run before `app.whenReady`.
registerAppScheme()
app.setAppUserModelId(APP_ID)

const repoRoot = resolve(__dirname, '..', '..', '..')
const webRoot = app.isPackaged
  ? join(process.resourcesPath, 'web')
  : join(repoRoot, 'apps', 'desktop_ui', 'web')

let supervisor: DaemonSupervisor | null = null
let secrets: CoreSecrets | null = null
let windowState: WindowStateStore | null = null

/**
 * Only one copy of the app may own the user's data directory: two daemons
 * against one SQLite file is corruption waiting to happen.
 */
if (!app.requestSingleInstanceLock()) {
  app.quit()
} else {
  app.on('second-instance', () => {
    const [existing] = BrowserWindow.getAllWindows()
    if (existing !== undefined) {
      if (existing.isMinimized()) existing.restore()
      existing.focus()
    }
  })

  app.whenReady().then(main).catch((error: unknown) => {
    console.error('failed to start Conduit', error)
    app.exit(1)
  })
}

async function main(): Promise<void> {
  const userDataDir = app.getPath('userData')
  secrets = loadOrCreateSecrets(userDataDir)
  windowState = new WindowStateStore(userDataDir)

  if (secrets.masterKeyIsPlaintext) {
    // Section 11: warn, but keep working. Refusing to run would strand every
    // Linux user without a keyring daemon.
    console.warn(
      'No OS keyring available; the master key is stored with weak protection. ' +
        'Install gnome-keyring or kwallet for full protection at rest.',
    )
  }

  serveAppScheme(webRoot)
  installPermissionPolicy()
  installAuthHeaderInjection()
  hardenNavigation()
  registerAuthWindowChannel()

  supervisor = new DaemonSupervisor(
    resolveDaemonPath({
      isPackaged: app.isPackaged,
      resourcesPath: process.resourcesPath,
      repoRoot,
    }),
    userDataDir,
    secrets,
  )

  supervisor.on('log', (line) => console.log(line))
  supervisor.on('restarting', ({ attempt, delayMs }) => {
    console.warn(`conduitd restarting (attempt ${attempt}) in ${delayMs}ms`)
  })
  supervisor.on('failed', ({ reason }) => console.error(reason))

  const firstReady = new Promise<number>((resolvePort) => {
    supervisor?.once('ready', ({ port }) => resolvePort(port))
  })
  supervisor.start()

  // Later readiness events are restarts: the port changed, so the renderer
  // must reconnect with fresh preload arguments.
  supervisor.on('ready', ({ port }) => {
    for (const window of BrowserWindow.getAllWindows()) {
      const current = window.webContents.getURL()
      if (current !== '') {
        window.webContents.send('conduit:core-restarted', { port })
      }
    }
  })

  const port = await firstReady
  createMainWindow(port)

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0 && supervisor?.port != null) {
      createMainWindow(supervisor.port)
    }
  })
}

function createMainWindow(port: number): BrowserWindow {
  const state = windowState!.boundsFor('main')
  const window = new BrowserWindow({
    ...state.bounds,
    minWidth: 720,
    minHeight: 480,
    show: false,
    backgroundColor: '#000000',
    titleBarStyle: process.platform === 'darwin' ? 'hiddenInset' : 'default',
    webPreferences: {
      preload: join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      webSecurity: true,
      // The renderer learns its port and token synchronously, before it runs
      // a line of Dart. An IPC round trip here would mean rendering a
      // "connecting" state that is only ever an artifact of our own plumbing.
      additionalArguments: [
        `--conduit-rpc-port=${port}`,
        `--conduit-token=${secrets!.sessionToken}`,
        '--conduit-window-kind=main',
        `--conduit-app-version=${app.getVersion()}`,
      ],
    },
  })

  if (state.maximized) window.maximize()
  windowState!.track('main', window)

  // Avoids the white flash between window creation and first paint.
  window.once('ready-to-show', () => window.show())
  // The clean path, not /index.html: the renderer's router matches on
  // pathname, and deep links (conduit://chat/<id>) will push paths in the
  // same shape.
  void window.loadURL(`${APP_ORIGIN}/`)
  return window
}

/**
 * What a page may ask the system for (M5).
 *
 * Electron grants every permission request unless told otherwise. The app
 * origin needs exactly these: the microphone, for a note's recording (and
 * audio only -- never the camera or the screen); the clipboard, for a
 * prompt's `{{CLIPBOARD}}`; and fullscreen, for video. Anything else, and
 * anything asked by another origin -- the sandboxed renders, an auth
 * window -- is refused.
 */
function installPermissionPolicy(): void {
  const allowed = new Set(['media', 'clipboard-read', 'clipboard-sanitized-write', 'fullscreen'])
  const fromApp = (url: string | undefined): boolean =>
    url !== undefined && (url === APP_ORIGIN || url.startsWith(`${APP_ORIGIN}/`))
  session.defaultSession.setPermissionRequestHandler((_contents, permission, callback, details) => {
    if (!allowed.has(permission) || !fromApp(details.requestingUrl)) {
      callback(false)
      return
    }
    if (permission === 'media') {
      const types = (details as { mediaTypes?: string[] }).mediaTypes ?? []
      callback(types.length > 0 && types.every((type) => type === 'audio'))
      return
    }
    callback(true)
  })
  session.defaultSession.setPermissionCheckHandler((_contents, permission, requestingOrigin) =>
    allowed.has(permission) && fromApp(requestingOrigin),
  )
}

/**
 * Adds the bearer token to renderer requests aimed at the daemon.
 *
 * This is what makes `<img src="http://127.0.0.1:port/files/...">` and
 * `<audio src=".../tts/...">` work: the renderer never holds a credential in
 * markup, and the daemon still refuses anonymous callers.
 */
function installAuthHeaderInjection(): void {
  session.defaultSession.webRequest.onBeforeSendHeaders(
    { urls: ['http://127.0.0.1/*', 'http://127.0.0.1:*/*'] },
    (details, callback) => {
      const port = supervisor?.port
      const token = secrets?.sessionToken
      if (port === null || port === undefined || token === undefined) {
        callback({ requestHeaders: details.requestHeaders })
        return
      }
      // Scope to the daemon's exact port. Another local service on 127.0.0.1
      // must never be handed our token.
      const url = new URL(details.url)
      if (url.port !== String(port)) {
        callback({ requestHeaders: details.requestHeaders })
        return
      }
      callback({
        requestHeaders: { ...details.requestHeaders, Authorization: `Bearer ${token}` },
      })
    },
  )
}

/**
 * The renderer's one way to open an external sign-in.
 *
 * This is the only *function* on the bridge; everything else there is data.
 * That is worth being deliberate about, because the renderer eventually
 * displays model output, and every callable is a capability granted to
 * whatever ends up executing there.
 *
 * What it grants is bounded by the window itself rather than by a check here:
 * the flow gets a fresh in-memory session, so the cookies it can capture are
 * only ones it created. Naming someone else's origin returns an empty jar,
 * not their session. The residual capability is "show the user a browser
 * window", which `shell.openExternal` already allows for any link.
 */
function registerAuthWindowChannel(): void {
  ipcMain.handle(
    'conduit:auth-window',
    async (event, request: AuthWindowRequest): Promise<AuthWindowResult> => {
      // Only the app origin may ask. A frame that somehow got loaded
      // elsewhere in this window must not be able to start a flow and read
      // back what it captures.
      if (!event.senderFrame?.url.startsWith(APP_ORIGIN)) {
        throw new Error('auth windows may only be opened by the app origin')
      }
      const parent = BrowserWindow.fromWebContents(event.sender)
      try {
        return await runAuthWindow(
          request,
          parent === null ? {} : { parent },
        )
      } catch (error) {
        if (error instanceof AuthWindowRejected) throw error
        throw new Error('the sign-in window could not be opened')
      }
    },
  )
}

/** Whether [url] is a file on the running daemon's `/files/` route. */
function isDaemonFileUrl(url: string): boolean {
  const port = supervisor?.port
  if (port === null || port === undefined) return false
  try {
    const parsed = new URL(url)
    return (
      parsed.protocol === 'http:' &&
      parsed.hostname === '127.0.0.1' &&
      parsed.port === String(port) &&
      parsed.pathname.startsWith('/files/')
    )
  } catch {
    return false
  }
}

/**
 * A window that shows one file from the daemon, with Chromium's own PDF
 * viewer.
 *
 * Nothing of the app's: no preload, sandboxed, no Node. It shares the
 * default session only so the daemon token is added to its one request,
 * as it is for the app's `<img>` tags. What it can load is decided by the
 * daemon's `Content-Type`: a PDF shows, anything else is opaque bytes
 * (served `nosniff`), never a page that runs.
 */
function openFileViewer(url: string): void {
  const viewer = new BrowserWindow({
    width: 900,
    height: 1000,
    autoHideMenuBar: true,
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      webSecurity: true,
      // Chromium's PDF viewer is a plugin; nothing else uses one.
      plugins: true,
    },
  })
  void viewer.loadURL(url)
}

/**
 * Keeps the app origin from becoming a browser.
 *
 * Model output can contain links. Opening one in-place would replace the app
 * with an attacker-influenced page that still has the preload bridge; sending
 * it to the real browser instead keeps the boundary intact.
 */
function hardenNavigation(): void {
  app.on('web-contents-created', (_event, contents) => {
    contents.setWindowOpenHandler(({ url }) => {
      // A file the daemon serves -- a PDF on a message -- opens in a viewer
      // of our own. The real browser would get it without the daemon's
      // token, which only this app's session adds, and answer 401.
      if (isDaemonFileUrl(url)) {
        openFileViewer(url)
        return { action: 'deny' }
      }
      if (url.startsWith('https://') || url.startsWith('http://')) {
        void shell.openExternal(url)
      }
      // Denied even for auth windows. Some providers try to open a popup;
      // sending it to the real browser breaks the flow visibly rather than
      // creating a second window with no session continuity, and the user
      // can still complete it there and return.
      return { action: 'deny' }
    })

    contents.on('will-navigate', (event, url) => {
      // An auth window is a browser on purpose, for the length of one
      // sign-in: a proxy or an identity provider bounces through origins we
      // do not know in advance. It has no preload and its own throwaway
      // session, so letting it navigate grants nothing the app origin has.
      if (isAuthWindowContents(contents)) return
      if (!url.startsWith(APP_ORIGIN)) {
        event.preventDefault()
        if (url.startsWith('https://') || url.startsWith('http://')) {
          void shell.openExternal(url)
        }
      }
    })

    contents.on('will-attach-webview', (event) => {
      // Nothing in Conduit uses <webview>; model-generated HTML renders in a
      // sandboxed iframe instead.
      event.preventDefault()
    })
  })
}

app.on('window-all-closed', () => {
  // M0 quits with the last window. WP-9.2 makes this conditional on the
  // close-to-tray setting, which is the whole point of the daemon outliving
  // the window.
  if (process.platform !== 'darwin') app.quit()
})

app.on('will-quit', (event) => {
  if (supervisor === null || !supervisor.isRunning) return
  event.preventDefault()
  void supervisor.stop().finally(() => {
    supervisor = null
    app.quit()
  })
})
