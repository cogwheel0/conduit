import {
  BrowserWindow,
  ipcMain,
  type BrowserWindowConstructorOptions,
  type IpcMainEvent,
} from 'electron'

/**
 * The main window's custom frame.
 *
 * The renderer draws its own title bar. On macOS the traffic lights stay
 * the system's, inset into that bar; on Windows and Linux there is no
 * system frame, and the renderer draws minimize, maximize and close,
 * which call back here.
 */

/** Height of the renderer's title bar, which the traffic lights centre in. */
export const TITLE_BAR_HEIGHT = 40

/** The frame options for a window of [kind] on [platform]. */
export function frameOptions(
  platform: NodeJS.Platform,
  kind: 'main' | 'quickAsk',
): BrowserWindowConstructorOptions {
  if (kind === 'quickAsk') return { frame: false }
  if (platform === 'darwin') {
    return {
      titleBarStyle: 'hidden',
      // The lights are 12 px tall; centred in the bar.
      trafficLightPosition: { x: 14, y: (TITLE_BAR_HEIGHT - 12) / 2 - 2 },
    }
  }
  return { frame: false }
}

/** What the renderer is told about its window, to draw the controls. */
export interface WindowFrameState {
  readonly maximized: boolean
  readonly fullscreen: boolean
  readonly focused: boolean
}

export function frameState(window: BrowserWindow): WindowFrameState {
  return {
    maximized: window.isMaximized(),
    fullscreen: window.isFullScreen(),
    focused: window.isFocused(),
  }
}

/** Sends the window's state to its page whenever it changes. */
export function reportFrameState(window: BrowserWindow): void {
  const send = (): void => {
    if (!window.isDestroyed()) window.webContents.send('conduit:window-state', frameState(window))
  }
  for (const event of [
    'maximize',
    'unmaximize',
    'enter-full-screen',
    'leave-full-screen',
    'focus',
    'blur',
  ] as const) {
    window.on(event as 'maximize', send)
  }
}

export type WindowAction = 'minimize' | 'toggleMaximize' | 'close' | 'state'

/**
 * Carries out a window control for the app's own pages. Anything else
 * asking -- a frame loaded from elsewhere -- is ignored.
 */
export function registerWindowFrameChannel(appOrigin: string): void {
  ipcMain.on('conduit:window', (event: IpcMainEvent, action: unknown) => {
    if (!(event.senderFrame?.url.startsWith(appOrigin) ?? false)) return
    const window = BrowserWindow.fromWebContents(event.sender)
    if (window === null) return
    switch (action) {
      case 'minimize':
        window.minimize()
        break
      case 'toggleMaximize':
        if (window.isMaximized()) window.unmaximize()
        else window.maximize()
        break
      case 'close':
        window.close()
        break
      case 'state':
        event.sender.send('conduit:window-state', frameState(window))
        break
    }
  })
}
