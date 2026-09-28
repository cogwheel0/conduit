import { app, BrowserWindow, ipcMain, session, shell } from 'electron'
import { autoUpdater } from 'electron-updater'
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
import { DEEP_LINK_SCHEME, deepLinkInArgs, parseDeepLink } from './deep-link.js'
import { DesktopShell } from './desktop-shell.js'
import { filesInArgs, uploadFiles } from './open-files.js'
import { loadOrCreateSecrets, type CoreSecrets } from './secrets.js'
import { ShellSettingsStore } from './shell-settings.js'
import { frameOptions, registerWindowFrameChannel, reportFrameState } from './window-frame.js'
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
let desktop: DesktopShell | null = null

/** Started by the session at login: into the tray, no window yet. */
const startHidden = process.argv.includes('--hidden')

/** A `conduit://` link given before the app was ready to open it. */
let launchLink: string | null = deepLinkInArgs(process.argv)

/**
 * The launch's own arguments start after the executable -- and, run as
 * `electron .`, after the app's path too.
 */
const argsSkip = app.isPackaged ? 1 : 2

/** Files given to open ("Open with Conduit") before the app was ready. */
let launchFiles: string[] = filesInArgs(process.argv, process.cwd(), argsSkip)

/** Uploads [paths] through the daemon and starts a chat with them. */
async function openFiles(paths: string[]): Promise<void> {
  const port = supervisor?.port
  if (desktop === null || port === null || port === undefined || secrets === null) {
    launchFiles.push(...paths)
    return
  }
  if (paths.length === 0) return
  desktop.showMain()
  const files = await uploadFiles(paths, port, secrets.sessionToken)
  if (files.length > 0) desktop.open({ kind: 'newChat', files })
}

/**
 * Only one copy of the app may own the user's data directory: two daemons
 * against one SQLite file is corruption waiting to happen.
 */
if (!app.requestSingleInstanceLock()) {
  app.quit()
} else {
  // A second launch is the user asking for this one -- with a link, on
  // Windows and Linux, as the link's arguments.
  app.on('second-instance', (_event, argv, workingDirectory) => {
    const link = deepLinkInArgs(argv)
    const request = link === null ? null : parseDeepLink(link)
    const files = filesInArgs(argv, workingDirectory, argsSkip)
    if (desktop === null) {
      launchLink = link ?? launchLink
      launchFiles.push(...files)
      return
    }
    if (request !== null) desktop.open(request)
    else if (files.length > 0) void openFiles(files)
    else desktop.showMain()
  })
  // macOS hands files over as events too, one at a time.
  app.on('open-file', (event, path) => {
    event.preventDefault()
    void openFiles([path])
  })
  // macOS hands links over as an event, possibly before `ready`.
  app.on('open-url', (event, url) => {
    event.preventDefault()
    const request = parseDeepLink(url)
    if (desktop === null) launchLink = url
    else if (request !== null) desktop.open(request)
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
    // Warn, but keep working. Refusing to run would strand every
    // Linux user without a keyring daemon.
    console.warn(
      'No OS keyring available; the master key is stored with weak protection. ' +
        'Install gnome-keyring or kwallet for full protection at rest.',
    )
  }

  // Only an installed app registers the scheme: a development build would
  // point the whole system's `conduit://` at a bare Electron binary.
  if (app.isPackaged) app.setAsDefaultProtocolClient(DEEP_LINK_SCHEME)

  serveAppScheme(webRoot)
  installPermissionPolicy()
  installAuthHeaderInjection()
  hardenNavigation()
  registerAuthWindowChannel()
  registerWindowFrameChannel(APP_ORIGIN)

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
  desktop = new DesktopShell(
    new ShellSettingsStore(userDataDir),
    (kind) => createWindow(kind, supervisor?.port ?? port),
    app.isPackaged ? join(process.resourcesPath, 'icon.png') : join(repoRoot, 'assets', 'icons', 'icon.png'),
  )
  desktop.install()
  // For the end-to-end tests, which cannot press a global shortcut or
  // click a tray icon. Main-process only; no page can reach it.
  ;(globalThis as { conduitDesktop?: DesktopShell }).conduitDesktop = desktop
  if (!(startHidden && desktop.keepsRunning)) createWindow('main', port)
  const link = launchLink === null ? null : parseDeepLink(launchLink)
  launchLink = null
  if (link !== null) desktop.open(link)
  const files = launchFiles
  launchFiles = []
  void openFiles(files)

  app.on('activate', () => {
    desktop?.showMain()
  })

  checkForUpdates()
}

/**
 * Updates from the GitHub release this build came from: checked
 * at start and every six hours, downloaded in the background, and applied
 * on the next quit, with the OS's own notification when one is ready.
 * Installed builds only; `CONDUIT_NO_UPDATES` turns it off (tests, and
 * package managers that update the app themselves).
 */
function checkForUpdates(): void {
  if (!app.isPackaged || process.env.CONDUIT_NO_UPDATES !== undefined) return
  // Until the desktop joins the `v*` releases every build of it
  // is a `desktop-v*` prerelease, so that is where updates are. A newer
  // mobile release in the same repository has no desktop files; the check
  // then fails, is logged, and the next one tries again.
  autoUpdater.allowPrerelease = true
  const check = (): void => {
    autoUpdater.checkForUpdatesAndNotify().catch((error: unknown) => {
      console.warn('update check failed', error)
    })
  }
  check()
  setInterval(check, 6 * 60 * 60 * 1000).unref()
}

function createWindow(kind: 'main' | 'quickAsk', port: number): BrowserWindow {
  const state = windowState!.boundsFor(kind)
  const quickAsk = kind === 'quickAsk'
  const window = new BrowserWindow({
    ...state.bounds,
    minWidth: quickAsk ? 480 : 720,
    minHeight: quickAsk ? 200 : 480,
    show: false,
    backgroundColor: '#000000',
    // The renderer draws the title bar (window-frame.ts).
    ...frameOptions(process.platform, kind),
    // The quick-ask panel floats over whatever the user was doing, and
    // is not a window to switch to.
    ...(quickAsk ? { alwaysOnTop: true, skipTaskbar: true, fullscreenable: false } : {}),
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
        `--conduit-window-kind=${kind}`,
        `--conduit-app-version=${app.getVersion()}`,
      ],
    },
  })

  if (state.maximized && !quickAsk) window.maximize()
  windowState!.track(kind, window)
  if (quickAsk) {
    // Out of the way as soon as the user looks elsewhere.
    window.on('blur', () => window.hide())
  } else {
    desktop?.manage(window)
    reportFrameState(window)
    // Avoids the white flash between window creation and first paint.
    window.once('ready-to-show', () => window.show())
  }
  // The clean path, not /index.html: the renderer's router matches on
  // pathname, and deep links (conduit://chat/<id>) will push paths in the
  // same shape.
  void window.loadURL(`${APP_ORIGIN}/`)
  return window
}

/**
 * What a page may ask the system for.
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
  // With close-to-tray the app, and the daemon with it, outlive the
  // window: that is the point of the setting.
  if (desktop?.keepsRunning) return
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
