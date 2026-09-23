import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'

/**
 * The shell's own preferences (M9): how the app lives on the desktop.
 *
 * Kept by the main process rather than the daemon because they are needed
 * before any window exists -- at login, a tray-only start -- and nothing but
 * the shell reads them. The renderer's settings page edits them over IPC.
 */
export interface ShellSettings {
  /** Closing the last window leaves the app in the tray. */
  closeToTray: boolean
  /** Starts with the system session, into the tray. */
  launchAtLogin: boolean
  /** Whether the quick-ask shortcut is registered. */
  quickAskEnabled: boolean
  /** An Electron accelerator. */
  quickAskShortcut: string
  /** Notifications when an answer finishes out of sight. */
  notifyAnswers: boolean
  /** Notifications for channel messages out of sight. */
  notifyChannels: boolean
  /**
   * The window's own shortcuts, rebound (WP-9.4): action name to a stroke
   * as the renderer encodes it, e.g. `mod+shift+o`.
   */
  shortcuts: Record<string, string>
  /** The version whose "What's new" the user has seen; empty before any. */
  lastSeenVersion: string
}

export const DEFAULT_SHELL_SETTINGS: ShellSettings = {
  closeToTray: false,
  launchAtLogin: false,
  quickAskEnabled: true,
  quickAskShortcut: 'CommandOrControl+Shift+Space',
  notifyAnswers: true,
  notifyChannels: true,
  shortcuts: {},
  lastSeenVersion: '',
}

/**
 * Keeps only known keys of the right type. What the renderer sends is
 * untrusted input: it displays model output, and this file decides whether
 * the app starts at login.
 */
export function sanitizeShellSettings(raw: unknown, base: ShellSettings): ShellSettings {
  const next = { ...base }
  if (raw === null || typeof raw !== 'object') return next
  const source = raw as Record<string, unknown>
  for (const key of Object.keys(DEFAULT_SHELL_SETTINGS) as Array<keyof ShellSettings>) {
    const value = source[key]
    if (value === undefined) continue
    if (key === 'quickAskShortcut') {
      if (typeof value === 'string' && isAccelerator(value)) next.quickAskShortcut = value
    } else if (key === 'shortcuts') {
      next.shortcuts = sanitizeShortcuts(value)
    } else if (key === 'lastSeenVersion') {
      if (typeof value === 'string' && /^[0-9A-Za-z.+-]{0,32}$/.test(value)) next.lastSeenVersion = value
    } else if (typeof value === 'boolean') {
      next[key] = value
    }
  }
  return next
}

/** At most 64 bindings of short, plain strings: this is written to disk. */
function sanitizeShortcuts(raw: unknown): Record<string, string> {
  const result: Record<string, string> = {}
  if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) return result
  for (const [action, stroke] of Object.entries(raw as Record<string, unknown>).slice(0, 64)) {
    if (!/^[a-zA-Z]{1,40}$/.test(action)) continue
    if (typeof stroke !== 'string' || !/^((mod|shift|alt)\+){0,3}[^\s]{1,12}$/.test(stroke)) continue
    result[action] = stroke
  }
  return result
}

const MODIFIERS = new Set([
  'Command',
  'Cmd',
  'Control',
  'Ctrl',
  'CommandOrControl',
  'CmdOrCtrl',
  'Alt',
  'Option',
  'AltGr',
  'Shift',
  'Super',
  'Meta',
])

/**
 * Whether [value] is an accelerator worth registering: at least one
 * modifier, then one key. A bare key would be swallowed system-wide.
 */
export function isAccelerator(value: string): boolean {
  if (value.length > 64) return false
  const parts = value.split('+')
  if (parts.length < 2) return false
  const key = parts[parts.length - 1] ?? ''
  const modifiers = parts.slice(0, -1)
  return (
    modifiers.every((part) => MODIFIERS.has(part)) &&
    /^([A-Z0-9]|F([1-9]|1[0-9]|2[0-4])|Space|Enter|Tab|Up|Down|Left|Right|[`\-=[\];',./\\])$/.test(key)
  )
}

export class ShellSettingsStore {
  private readonly file: string
  private current: ShellSettings

  constructor(userDataDir: string) {
    this.file = join(userDataDir, 'shell-settings.json')
    this.current = this.read()
  }

  get value(): ShellSettings {
    return { ...this.current }
  }

  update(patch: unknown): ShellSettings {
    this.current = sanitizeShellSettings(patch, this.current)
    try {
      mkdirSync(dirname(this.file), { recursive: true })
      writeFileSync(this.file, JSON.stringify(this.current, null, 2))
    } catch {
      // Unwritable: the setting holds for this run, which is still better
      // than refusing it.
    }
    return this.value
  }

  private read(): ShellSettings {
    try {
      return sanitizeShellSettings(JSON.parse(readFileSync(this.file, 'utf8')), DEFAULT_SHELL_SETTINGS)
    } catch {
      return { ...DEFAULT_SHELL_SETTINGS }
    }
  }
}
