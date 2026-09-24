#!/usr/bin/env node
// Builds the renderer bundle: palette CSS, Tailwind, then Dart -> JS.
//
// Ordering matters. theme.css must exist before Tailwind runs (styles.css
// imports it), and both must exist before Electron loads index.html.
import { spawnSync } from 'node:child_process'
import { cpSync, existsSync, mkdirSync, rmSync } from 'node:fs'
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

// The render sandbox and the libraries it runs. Copied rather than
// bundled: they are loaded by `app://conduit/sandbox.html`, which is framed
// with an opaque origin and has its own CSP, so they must be real URLs under
// the web root and not part of the Dart bundle.
//
// Vendored through npm, never a CDN. The sandbox has no
// `connect-src` at all, so a CDN would not even be reachable from it.
console.log('> sandbox')
const webDir = join(uiDir, 'web')
const vendorDir = join(webDir, 'vendor')
rmSync(vendorDir, { recursive: true, force: true })
mkdirSync(join(vendorDir, 'katex'), { recursive: true })

const katexDist = join(here, '..', 'node_modules', 'katex', 'dist')
if (!existsSync(katexDist)) {
  console.error('KaTeX not found. Run `npm install` in desktop/electron.')
  process.exit(1)
}
for (const file of ['katex.min.js', 'katex.min.css']) {
  cpSync(join(katexDist, file), join(vendorDir, 'katex', file))
}
// The fonts katex.min.css references. Without them every formula falls back
// to the system serif, which renders but reads as broken.
cpSync(join(katexDist, 'fonts'), join(vendorDir, 'katex', 'fonts'), {
  recursive: true,
})
// Loaded on demand from inside the sandbox rather than by sandbox.html:
// mermaid alone is five megabytes, and the common case -- an inline
// formula -- needs neither.
for (const [pkg, dir, file] of [
  ['mermaid', 'mermaid', 'dist/mermaid.min.js'],
  ['chart.js', 'chart.js', 'dist/chart.umd.js'],
]) {
  const from = join(here, '..', 'node_modules', pkg, file)
  if (!existsSync(from)) {
    console.error(`${pkg} not found. Run \`npm install\` in desktop/electron.`)
    process.exit(1)
  }
  mkdirSync(join(vendorDir, dir), { recursive: true })
  cpSync(from, join(vendorDir, dir, file.split('/').pop()))
}

// Quill 2, the notes editor. Unlike the libraries above it runs in the
// app's own origin -- it edits the user's text, not model output -- so it is
// loaded by index.html, not the sandbox.
for (const file of ['quill.js', 'quill.snow.css']) {
  const from = join(here, '..', 'node_modules', 'quill', 'dist', file)
  if (!existsSync(from)) {
    console.error('Quill not found. Run `npm install` in desktop/electron.')
    process.exit(1)
  }
  mkdirSync(join(vendorDir, 'quill'), { recursive: true })
  cpSync(from, join(vendorDir, 'quill', file))
}

// xterm.js, the terminal. App origin like Quill: it draws the shell
// the user types into, and loads from index.html.
for (const [pkg, file] of [
  ['@xterm/xterm', 'lib/xterm.js'],
  ['@xterm/xterm', 'css/xterm.css'],
  ['@xterm/addon-fit', 'lib/addon-fit.js'],
]) {
  const from = join(here, '..', 'node_modules', pkg, file)
  if (!existsSync(from)) {
    console.error(`${pkg} not found. Run \`npm install\` in desktop/electron.`)
    process.exit(1)
  }
  mkdirSync(join(vendorDir, 'xterm'), { recursive: true })
  cpSync(from, join(vendorDir, 'xterm', file.split('/').pop()))
}

cpSync(join(here, '..', 'sandbox', 'sandbox.js'), join(vendorDir, 'sandbox.js'))
cpSync(join(here, '..', 'sandbox', 'sandbox.html'), join(webDir, 'sandbox.html'))

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
