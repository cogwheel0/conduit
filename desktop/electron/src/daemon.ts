import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process'
import { EventEmitter } from 'node:events'
import { existsSync } from 'node:fs'
import { join } from 'node:path'
import type { CoreSecrets } from './secrets.js'

/** At most five restarts inside a minute, then give up. */
const MAX_RESTARTS = 5
const RESTART_WINDOW_MS = 60_000

/** How long `system.shutdown` gets to flush the outbox and checkpoint. */
export const GRACEFUL_SHUTDOWN_MS = 5_000

export interface DaemonReady {
  readonly port: number
}

type DaemonEvents = {
  ready: [DaemonReady]
  /** The daemon died and a restart is coming. */
  restarting: [{ attempt: number; delayMs: number }]
  /** Restarts exhausted; the UI shows a terminal error. */
  failed: [{ reason: string }]
  log: [string]
}

/**
 * Spawns and supervises `conduitd`.
 *
 * The daemon owns all state, so keeping it alive *is* keeping the app alive:
 * close-to-tray leaves it running so sync, sockets and notifications continue
 * with no window open.
 */
export class DaemonSupervisor extends EventEmitter<DaemonEvents> {
  private child: ChildProcessWithoutNullStreams | null = null
  private restartTimestamps: number[] = []
  private stopping = false
  private currentPort: number | null = null

  constructor(
    private readonly executablePath: string,
    private readonly userDataDir: string,
    private readonly secrets: CoreSecrets,
  ) {
    super()
  }

  get port(): number | null {
    return this.currentPort
  }

  get isRunning(): boolean {
    return this.child !== null && this.child.exitCode === null
  }

  start(): void {
    if (this.child !== null) return
    if (!existsSync(this.executablePath)) {
      this.emit('failed', {
        reason: `conduitd not found at ${this.executablePath}. Run \`npm run build:daemon\`.`,
      })
      return
    }

    const child = spawn(this.executablePath, ['--user-data', this.userDataDir], {
      // Secrets go over stdin, never argv or env: both are readable by any
      // other process on the machine.
      stdio: ['pipe', 'pipe', 'pipe'],
      windowsHide: true,
    })
    this.child = child
    this.currentPort = null

    child.stdin.write(
      `${JSON.stringify({
        sessionToken: this.secrets.sessionToken,
        masterKey: this.secrets.masterKey,
        userDataDir: this.userDataDir,
      })}\n`,
    )

    // stdout carries exactly one line: the readiness handshake. Anything else
    // there is a bug in the daemon, and treating it as noise would hide it.
    let stdoutBuffer = ''
    child.stdout.setEncoding('utf8')
    child.stdout.on('data', (chunk: string) => {
      stdoutBuffer += chunk
      let newline = stdoutBuffer.indexOf('\n')
      while (newline !== -1) {
        const line = stdoutBuffer.slice(0, newline).trim()
        stdoutBuffer = stdoutBuffer.slice(newline + 1)
        newline = stdoutBuffer.indexOf('\n')
        if (line === '') continue
        try {
          const parsed = JSON.parse(line) as { ready?: boolean; port?: number }
          if (parsed.ready === true && typeof parsed.port === 'number') {
            this.currentPort = parsed.port
            this.emit('ready', { port: parsed.port })
            continue
          }
        } catch {
          // fall through to logging
        }
        this.emit('log', `conduitd stdout: ${line}`)
      }
    })

    child.stderr.setEncoding('utf8')
    child.stderr.on('data', (chunk: string) => {
      for (const line of chunk.split('\n')) {
        if (line.trim() !== '') this.emit('log', line.trimEnd())
      }
    })

    child.on('exit', (code, signal) => {
      this.child = null
      this.currentPort = null
      if (this.stopping) return
      this.scheduleRestart(`exited with code=${code} signal=${signal}`)
    })

    child.on('error', (error) => {
      this.emit('log', `conduitd spawn error: ${error.message}`)
    })
  }

  private scheduleRestart(reason: string): void {
    const now = Date.now()
    this.restartTimestamps = this.restartTimestamps.filter((t) => now - t < RESTART_WINDOW_MS)
    if (this.restartTimestamps.length >= MAX_RESTARTS) {
      this.emit('failed', {
        reason: `conduitd ${reason}; ${MAX_RESTARTS} restarts in the last minute`,
      })
      return
    }
    this.restartTimestamps.push(now)
    const attempt = this.restartTimestamps.length
    // Exponential, capped: a daemon that cannot bind a port should not be
    // respawned in a tight loop.
    const delayMs = Math.min(250 * 2 ** (attempt - 1), 8_000)
    this.emit('restarting', { attempt, delayMs })
    setTimeout(() => {
      if (!this.stopping) this.start()
    }, delayMs)
  }

  /**
   * Closes stdin and waits for the daemon to exit on its own.
   *
   * The daemon treats a closed stdin as "the parent is gone" and runs its own
   * graceful shutdown, so this is the normal path. `system.shutdown` over RPC
   * is the richer one (it reports whether the outbox flushed) and is sent by
   * the window before this runs.
   */
  async stop(timeoutMs = GRACEFUL_SHUTDOWN_MS): Promise<void> {
    const child = this.child
    this.stopping = true
    if (child === null) return

    const exited = new Promise<void>((resolve) => child.once('exit', () => resolve()))
    child.stdin.end()

    const timedOut = await Promise.race([
      exited.then(() => false),
      new Promise<boolean>((resolve) => setTimeout(() => resolve(true), timeoutMs)),
    ])

    if (timedOut) {
      this.emit('log', 'conduitd did not exit in time; terminating')
      child.kill(process.platform === 'win32' ? undefined : 'SIGTERM')
      const killTimer = setTimeout(() => child.kill('SIGKILL'), 2_000)
      await exited
      clearTimeout(killTimer)
    }
    this.child = null
    this.currentPort = null
  }
}

/**
 * Where the daemon binary lives.
 *
 * Packaged builds get it from `extraResources`; a dev checkout uses whatever
 * `dart compile exe` last produced.
 */
export function resolveDaemonPath(options: {
  isPackaged: boolean
  resourcesPath: string
  repoRoot: string
}): string {
  const name = process.platform === 'win32' ? 'conduitd.exe' : 'conduitd'
  return options.isPackaged
    ? join(options.resourcesPath, 'conduitd', 'bin', name)
    : join(
        options.repoRoot,
        'apps',
        'daemon',
        'build',
        'cli',
        dartBuildTarget(),
        'bundle',
        'bin',
        name,
      )
}

/**
 * The `<os>_<arch>` directory `dart build cli` writes its bundle into.
 *
 * `dart compile exe` produced a single self-contained file and would have
 * needed none of this, but it refuses to run once any dependency has build
 * hooks — which `drift` introduced by way of `sqlite3`. The bundle keeps the
 * native library in a sibling `lib/`, so the binary cannot be lifted out of
 * it on its own.
 */
export function dartBuildTarget(
  platform: NodeJS.Platform = process.platform,
  arch: string = process.arch,
): string {
  const os =
    platform === 'win32' ? 'windows' : platform === 'darwin' ? 'macos' : 'linux'
  const cpu = arch === 'arm64' ? 'arm64' : 'x64'
  return `${os}_${cpu}`
}
