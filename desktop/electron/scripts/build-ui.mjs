#!/usr/bin/env node
// Builds the renderer bundle: palette CSS, Tailwind, then Dart -> JS.
//
// Ordering matters. theme.css must exist before Tailwind runs (styles.css
// imports it), and both must exist before Electron loads index.html.
import { spawnSync } from 'node:child_process'
import { existsSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const repoRoot = resolve(here, '..', '..', '..')
const uiDir = join(repoRoot, 'apps', 'desktop_ui')
const release = process.argv.includes('--release')

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    stdio: 'inherit',
    cwd: options.cwd ?? repoRoot,
    shell: process.platform === 'win32',
  })
  if (result.status !== 0) {
    console.error(`\n${command} ${args.join(' ')} failed with ${result.status}`)
    process.exit(result.status ?? 1)
  }
}

// The standalone Tailwind CLI, pinned in package.json. jaspr_tailwind would
// normally wrap this, but it depends on build_modules, which caps at Dart
// <3.13 and cannot resolve in this workspace.
const tailwindBin = join(
  here,
  '..',
  'node_modules',
  '.bin',
  process.platform === 'win32' ? 'tailwindcss.cmd' : 'tailwindcss',
)

console.log('> theme.css')
run('dart', ['run', 'conduit_theme:generate_theme_css'])

console.log('> tailwind')
if (!existsSync(tailwindBin)) {
  console.error(`Tailwind CLI not found at ${tailwindBin}. Run \`npm install\` first.`)
  process.exit(1)
}
run(tailwindBin, [
  '--input',
  join(here, '..', 'styles', 'app.css'),
  '--output',
  join(uiDir, 'web', 'app.css'),
  ...(release ? ['--minify'] : []),
])

console.log('> dart compile js')
run(
  'dart',
  [
    'compile',
    'js',
    release ? '-O2' : '-O1',
    '-o',
    join(uiDir, 'web', 'main.dart.js'),
    join(uiDir, 'lib', 'main.dart'),
  ],
  { cwd: uiDir },
)

console.log('renderer bundle ready')
