import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { screen, type BrowserWindow, type Rectangle } from 'electron'

export interface WindowState {
  bounds: Rectangle
  maximized: boolean
}

const DEFAULTS: Record<string, WindowState> = {
  main: { bounds: { x: 0, y: 0, width: 1280, height: 860 }, maximized: false },
  quickAsk: { bounds: { x: 0, y: 0, width: 720, height: 320 }, maximized: false },
}

/**
 * Remembers each window's geometry across launches.
 *
 * Kept per window *kind*, not per window: the quick-ask panel and the main
 * window have nothing to say about each other's size.
 */
export class WindowStateStore {
  private readonly file: string
  private state: Record<string, WindowState>

  constructor(userDataDir: string) {
    this.file = join(userDataDir, 'window-state.json')
    this.state = this.read()
  }

  private read(): Record<string, WindowState> {
    try {
      return JSON.parse(readFileSync(this.file, 'utf8')) as Record<string, WindowState>
    } catch {
      // Missing or corrupt: fall back to defaults rather than failing to
      // open a window over a cosmetic preference.
      return {}
    }
  }

  /**
   * Bounds for [kind], clamped to a display that currently exists.
   *
   * Without the clamp, unplugging the external monitor a window was last on
   * leaves it positioned off-screen with no way to drag it back.
   */
  boundsFor(kind: string): WindowState {
    const fallback = DEFAULTS[kind] ?? DEFAULTS['main']!
    const saved = this.state[kind]
    if (saved === undefined) return fallback

    const visible = screen.getAllDisplays().some((display) => {
      const area = display.workArea
      return (
        saved.bounds.x < area.x + area.width &&
        saved.bounds.x + saved.bounds.width > area.x &&
        saved.bounds.y < area.y + area.height &&
        saved.bounds.y + saved.bounds.height > area.y
      )
    })
    return visible ? saved : { ...fallback, maximized: saved.maximized }
  }

  /** Persists geometry on move, resize and close. */
  track(kind: string, window: BrowserWindow): void {
    const save = (): void => {
      if (window.isDestroyed()) return
      // `getBounds` reports the maximized rectangle while maximized, which
      // would make restore-down forget the real size. Keep the normal one.
      const bounds = window.isMaximized() || window.isMinimized()
        ? (this.state[kind]?.bounds ?? window.getNormalBounds())
        : window.getBounds()
      this.state[kind] = { bounds, maximized: window.isMaximized() }
      this.flush()
    }

    let timer: NodeJS.Timeout | null = null
    const debounced = (): void => {
      if (timer !== null) clearTimeout(timer)
      timer = setTimeout(save, 250)
    }

    window.on('resize', debounced)
    window.on('move', debounced)
    window.on('maximize', save)
    window.on('unmaximize', save)
    window.on('close', () => {
      if (timer !== null) clearTimeout(timer)
      save()
    })
  }

  private flush(): void {
    try {
      mkdirSync(dirname(this.file), { recursive: true })
      writeFileSync(this.file, JSON.stringify(this.state, null, 2))
    } catch {
      // A read-only profile should not crash the app on window move.
    }
  }
}
