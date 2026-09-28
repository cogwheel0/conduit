#!/usr/bin/env node
// Builds the `conduitd` sidecar the Electron shell spawns.
//
// `dart build cli`, not `dart compile exe`: the latter refuses to run once a
// dependency has build hooks, and drift brings sqlite3, which has them. The
// output is a bundle — the binary plus a sibling lib/ holding libsqlite3 — so
// packaging ships the directory, not just the executable.
//
// Its own script rather than a line in package.json because `dart build` has
// no `--directory`, so the working directory has to be set here. `daemon.ts`
// names `npm run build:daemon` when the binary is missing; before this
// existed that instruction pointed at nothing.
import { spawnSync } from 'node:child_process'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const daemonDir = resolve(here, '..', '..', '..', 'apps', 'daemon')

const result = spawnSync('dart', ['build', 'cli'], {
  stdio: 'inherit',
  cwd: daemonDir,
  shell: process.platform === 'win32',
})
if (result.status !== 0) {
  console.error(`\ndart build cli failed with ${result.status}`)
  process.exit(result.status ?? 1)
}
console.log(`conduitd built in ${join(daemonDir, 'build', 'cli')}`)
