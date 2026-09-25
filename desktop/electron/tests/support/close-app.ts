import type { ElectronApplication } from '@playwright/test'

/**
 * Closes [app], and ends it if it will not go.
 *
 * Bounded: a macOS runner has left the app running after a quit, more than
 * once and from more than one spec. Unbounded, that timed out the test, then
 * the worker's teardown, and took the specs after it down too.
 */
export async function closeApp(app: ElectronApplication): Promise<void> {
  const closed = app.close().then(
    () => true,
    () => true,
  )
  const quit = await Promise.race([
    closed,
    new Promise<boolean>((resolve) => setTimeout(() => resolve(false), 20_000)),
  ])
  if (!quit) {
    console.warn('the app did not quit within 20 s; killing it')
    app.process().kill('SIGKILL')
    await closed
  }
}
