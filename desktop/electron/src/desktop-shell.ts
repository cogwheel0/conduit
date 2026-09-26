import { existsSync, mkdirSync, rmSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import {
  app,
  BrowserWindow,
  globalShortcut,
  ipcMain,
  Menu,
  nativeImage,
  Notification,
  screen,
  Tray,
  type IpcMainEvent,
  type IpcMainInvokeEvent,
} from 'electron'
import { APP_ORIGIN } from './app-protocol.js'
import { sanitizeOpenRequest, type OpenRequest } from './deep-link.js'
import type { ShellSettings, ShellSettingsStore } from './shell-settings.js'

/** Makes an app window of [kind]; the caller supplies port and token. */
export type WindowFactory = (kind: 'main' | 'quickAsk') => BrowserWindow

/**
 * How the app lives on the desktop: the tray, closing to it, starting
 * at login, the quick-ask panel and its global shortcut, notifications,
 * and `conduit://` links reaching the window.
 */
export class DesktopShell {
  private tray: Tray | null = null
  private quickAsk: BrowserWindow | null = null
  private registeredShortcut: string | null = null
  private quitting = false

  /** Links that arrived before the main window could take them. */
  private readonly pending: OpenRequest[] = []
  private readonly readyWindows = new Set<number>()

  constructor(
    private readonly settings: ShellSettingsStore,
    private readonly makeWindow: WindowFactory,
    private readonly iconPath: string,
  ) {}

  /** The main window, if it exists. */
  mainWindow(): BrowserWindow | null {
    return (
      BrowserWindow.getAllWindows().find(
        (window) => window !== this.quickAsk && !window.isDestroyed() && isAppWindow(window),
      ) ?? null
    )
  }

  install(): void {
    app.on('before-quit', () => {
      this.quitting = true
    })
    app.on('will-quit', () => globalShortcut.unregisterAll())
    this.registerIpc()
    this.apply(this.settings.value)
  }

  /** Whether closing the last window should leave the app running. */
  get keepsRunning(): boolean {
    return this.settings.value.closeToTray && !this.quitting
  }

  /** Watches [window] so a close with close-to-tray on only hides it. */
  manage(window: BrowserWindow): void {
    window.on('close', (event) => {
      if (this.keepsRunning) {
        event.preventDefault()
        window.hide()
      }
    })
    window.webContents.on('destroyed', () => this.readyWindows.delete(window.webContents.id))
  }

  /** Shows the main window, making it if it was closed. */
  showMain(): BrowserWindow {
    const existing = this.mainWindow()
    const window = existing ?? this.makeWindow('main')
    if (existing !== null) {
      if (window.isMinimized()) window.restore()
      window.show()
      window.focus()
    }
    return window
  }

  /** Opens [request] in the main window, now or once it is ready. */
  open(request: OpenRequest): void {
    const window = this.showMain()
    if (this.readyWindows.has(window.webContents.id)) {
      window.webContents.send('conduit:open', request)
    } else {
      this.pending.push(request)
    }
  }

  private apply(next: ShellSettings): void {
    this.applyTray(next)
    this.applyLoginItem(next)
    this.applyShortcut(next)
  }

  private applyTray(next: ShellSettings): void {
    if (!next.closeToTray) {
      this.tray?.destroy()
      this.tray = null
      return
    }
    if (this.tray !== null) return
    try {
      const icon = nativeImage.createFromPath(this.iconPath).resize({ width: 18, height: 18 })
      const tray = new Tray(icon)
      tray.setToolTip('Conduit')
      tray.setContextMenu(
        Menu.buildFromTemplate([
          { label: 'Open Conduit', click: () => this.showMain() },
          { label: 'New Chat', click: () => this.open({ kind: 'newChat' }) },
          { label: 'Quick Ask', click: () => this.toggleQuickAsk() },
          { type: 'separator' },
          { label: 'Quit Conduit', click: () => app.quit() },
        ]),
      )
      tray.on('click', () => this.showMain())
      this.tray = tray
    } catch (error) {
      // Some Linux desktops have no tray at all; the app still works, and
      // close-to-tray then only hides the window until the next launch.
      console.warn('no system tray available', error)
    }
  }

  private applyLoginItem(next: ShellSettings): void {
    // Only an installed app: a development build would register the
    // Electron binary itself to start with the session.
    if (!app.isPackaged) return
    if (process.platform === 'linux') {
      writeAutostartEntry(next.launchAtLogin)
      return
    }
    app.setLoginItemSettings({ openAtLogin: next.launchAtLogin, args: ['--hidden'] })
  }

  private applyShortcut(next: ShellSettings): void {
    const wanted = next.quickAskEnabled ? next.quickAskShortcut : null
    if (wanted === this.registeredShortcut) return
    if (this.registeredShortcut !== null) globalShortcut.unregister(this.registeredShortcut)
    this.registeredShortcut = null
    if (wanted === null) return
    try {
      if (globalShortcut.register(wanted, () => this.toggleQuickAsk())) {
        this.registeredShortcut = wanted
      } else {
        // Another app owns it. The settings page says so from `status`.
        console.warn(`quick-ask shortcut ${wanted} is taken`)
      }
    } catch (error) {
      console.warn('quick-ask shortcut could not be registered', error)
    }
  }

  /** Shows the quick-ask panel on the display under the pointer, or hides it. */
  toggleQuickAsk(): void {
    const existing = this.quickAsk
    if (existing !== null && !existing.isDestroyed() && existing.isVisible()) {
      existing.hide()
      return
    }
    const window =
      existing !== null && !existing.isDestroyed() ? existing : (this.quickAsk = this.makeWindow('quickAsk'))
    const display = screen.getDisplayNearestPoint(screen.getCursorScreenPoint())
    const [width = 720] = window.getSize()
    window.setPosition(
      Math.round(display.workArea.x + (display.workArea.width - width) / 2),
      Math.round(display.workArea.y + display.workArea.height / 5),
    )
    window.show()
    window.focus()
  }

  private registerIpc(): void {
    const fromApp = (event: IpcMainInvokeEvent | IpcMainEvent): boolean =>
      event.senderFrame?.url.startsWith(APP_ORIGIN) ?? false

    ipcMain.handle('conduit:shell-settings', (event, patch: unknown) => {
      if (!fromApp(event)) throw new Error('not the app')
      if (patch !== undefined && patch !== null) this.apply(this.settings.update(patch))
      return {
        ...this.settings.value,
        // Whether the shortcut is actually held, which is not the same as
        // asked for: another app may own it.
        quickAskRegistered: this.registeredShortcut !== null,
        platform: process.platform,
      }
    })

    ipcMain.handle('conduit:notify', (event, raw: unknown) => {
      if (!fromApp(event) || !Notification.isSupported()) return false
      const request = raw as { title?: unknown; body?: unknown; open?: unknown } | null
      const title = typeof request?.title === 'string' ? request.title.slice(0, 200) : ''
      const body = typeof request?.body === 'string' ? request.body.slice(0, 500) : ''
      if (title === '') return false
      // The quick-ask panel in front is where the user is looking; its own
      // answer needs no notification from the window behind it.
      const panel = this.quickAsk
      if (panel !== null && !panel.isDestroyed() && panel.isVisible() && panel.isFocused()) {
        return false
      }
      const target = sanitizeOpenRequest(request?.open)
      const notification = new Notification({ title, body, silent: false })
      notification.on('click', () => {
        if (target !== null) this.open(target)
        else this.showMain()
      })
      notification.show()
      return true
    })

    // The window says it can take links; anything queued goes to it now.
    ipcMain.on('conduit:open-ready', (event) => {
      if (!fromApp(event)) return
      this.readyWindows.add(event.sender.id)
      const window = BrowserWindow.fromWebContents(event.sender)
      if (window === null || window === this.quickAsk) return
      for (const request of this.pending.splice(0)) event.sender.send('conduit:open', request)
    })

    // From the quick-ask panel: continue in the main window, and hide.
    ipcMain.on('conduit:open-in-main', (event, raw: unknown) => {
      if (!fromApp(event)) return
      const request = sanitizeOpenRequest(raw)
      this.quickAsk?.hide()
      if (request !== null) this.open(request)
    })

    ipcMain.on('conduit:hide-window', (event) => {
      if (!fromApp(event)) return
      BrowserWindow.fromWebContents(event.sender)?.hide()
    })
  }
}

function isAppWindow(window: BrowserWindow): boolean {
  try {
    return window.webContents.getURL().startsWith(APP_ORIGIN)
  } catch {
    return false
  }
}

/** `~/.config/autostart/conduit.desktop`, the XDG way to start at login. */
function writeAutostartEntry(enabled: boolean): void {
  const dir = join(process.env.XDG_CONFIG_HOME ?? join(homedir(), '.config'), 'autostart')
  const file = join(dir, 'conduit.desktop')
  try {
    if (!enabled) {
      if (existsSync(file)) rmSync(file)
      return
    }
    mkdirSync(dir, { recursive: true })
    // An AppImage moves; `APPIMAGE` is where it is now.
    const exec = process.env.APPIMAGE ?? process.execPath
    writeFileSync(
      file,
      [
        '[Desktop Entry]',
        'Type=Application',
        'Name=Conduit',
        `Exec="${exec.replace(/"/g, '\\"')}" --hidden`,
        'X-GNOME-Autostart-enabled=true',
        '',
      ].join('\n'),
    )
  } catch (error) {
    console.warn('could not update the autostart entry', error)
  }
}
