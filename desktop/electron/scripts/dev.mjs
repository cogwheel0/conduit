#!/usr/bin/env node
// Dev loop: build the daemon and the renderer, then launch Electron against
// the checkout.
//
// `jaspr serve` hot reload is not wired up: jaspr_builder pins analyzer ^12,
// which collides with the root app's riverpod_lint (analyzer >=13) in this
// single-lockfile workspace. Until that is resolved, `--watch` re-runs the
// renderer build on change, which costs a few seconds rather than being
// instant. See docs/BUILDING-DESKTOP.md.
import { spawn, spawnSync } from 'node:child_process'
import { watch } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const electronDir = resolve(here, '..')
const repoRoot = resolve(electronDir, '..', '..')
const uiLib = join(repoRoot, 'apps', 'desktop_ui', 'lib')
const shouldWatch = process.argv.includes('--watch')

function run(command, args, cwd) {
  const result = spawnSync(command, args, {
    stdio: 'inherit',
    cwd,
    shell: process.platform === 'win32',
  })
  if (result.status !== 0) process.exit(result.status ?? 1)
}

console.log('> conduitd')
run(
  'dart',
  ['compile', 'exe', 'bin/conduitd.dart', '-o', 'build/conduitd'],
  join(repoRoot, 'apps', 'daemon'),
)

run('node', [join(here, 'build-ui.mjs')], repoRoot)
run('npx', ['tsc'], electronDir)

const electron = spawn('npx', ['electron', '.'], {
  stdio: 'inherit',
  cwd: electronDir,
  shell: process.platform === 'win32',
})
electron.on('exit', (code) => process.exit(code ?? 0))

if (shouldWatch) {
  let pending = null
  watch(uiLib, { recursive: true }, (_event, filename) => {
    if (filename === null || !filename.endsWith('.dart')) return
    if (pending !== null) clearTimeout(pending)
    pending = setTimeout(() => {
      console.log(`\n> rebuilding renderer (${filename})`)
      spawnSync('node', [join(here, 'build-ui.mjs')], { stdio: 'inherit', cwd: repoRoot })
      console.log('> reload the window with Cmd/Ctrl+R')
    }, 200)
  })
}
