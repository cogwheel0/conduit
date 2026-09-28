#!/usr/bin/env node
// Gathers what electron-builder packs next to the app:
//
//   build/stage/conduitd/   the daemon bundle `dart build cli` wrote for
//                           this machine's OS and architecture
//   build/stage/web/        the renderer, without source maps
//   build/stage/icon.png    the tray icon
//   build/stage/THIRD_PARTY_NOTICES.md
//
// A staging step because the daemon's directory is named for Dart's target
// (`macos_arm64`), which electron-builder's `${os}_${arch}` does not spell
// the same way; and because a package should not carry source maps.
//
// Run after `npm run build`. Each build machine packages its own
// architecture: the daemon is native code.
import { cpSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const electronDir = resolve(here, '..')
const repoRoot = resolve(electronDir, '..', '..')
const stage = join(electronDir, 'build', 'stage')

function dartTarget() {
  const os = { darwin: 'macos', win32: 'windows', linux: 'linux' }[process.platform]
  const arch = { x64: 'x64', arm64: 'arm64' }[process.arch]
  if (os === undefined || arch === undefined) {
    throw new Error(`no Dart target for ${process.platform}/${process.arch}`)
  }
  return `${os}_${arch}`
}

function need(path, hint) {
  if (!existsSync(path)) {
    console.error(`missing ${path}\n${hint}`)
    process.exit(1)
  }
}

rmSync(stage, { recursive: true, force: true })
mkdirSync(stage, { recursive: true })

const daemon = join(repoRoot, 'apps', 'daemon', 'build', 'cli', dartTarget(), 'bundle')
need(daemon, 'run `npm run build:daemon` first')
cpSync(daemon, join(stage, 'conduitd'), { recursive: true })

const web = join(repoRoot, 'apps', 'desktop_ui', 'web')
need(join(web, 'main.dart.js'), 'run `npm run build:ui -- --release` first')
cpSync(web, join(stage, 'web'), {
  recursive: true,
  filter: (source) => !source.endsWith('.map') && !source.endsWith('.deps'),
})

cpSync(join(repoRoot, 'assets', 'icons', 'icon.png'), join(stage, 'icon.png'))

// The JavaScript the renderer ships from node_modules, with each licence.
const vendored = [
  'katex',
  'mermaid',
  'chart.js',
  'quill',
  '@xterm/xterm',
  '@xterm/addon-fit',
]
const sections = ['# Third-party notices', '', 'Conduit Desktop includes the following software.', '']
for (const name of vendored) {
  const dir = join(electronDir, 'node_modules', name)
  const manifest = JSON.parse(readFileSync(join(dir, 'package.json'), 'utf8'))
  const licenceFile = ['LICENSE', 'LICENSE.md', 'LICENSE.txt', 'license']
    .map((file) => join(dir, file))
    .find((file) => existsSync(file))
  sections.push(`## ${name} ${manifest.version}`, '', `License: ${manifest.license ?? 'see below'}`, '')
  if (licenceFile !== undefined) {
    sections.push('```', readFileSync(licenceFile, 'utf8').trim(), '```', '')
  }
}
// whisper.cpp, when the local speech engine is in the bundle.
const whisperLicence = [
  join(repoRoot, 'apps', 'daemon', 'build', 'whisper', dartTarget(), '_deps', 'whisper-src', 'LICENSE'),
  process.env.WHISPER_SOURCE_DIR && join(process.env.WHISPER_SOURCE_DIR, 'LICENSE'),
].find((file) => file && existsSync(file))
if (existsSync(join(stage, 'conduitd', 'lib'))) {
  const hasWhisper = ['libconduit_whisper.so', 'libconduit_whisper.dylib', 'conduit_whisper.dll'].some(
    (name) => existsSync(join(stage, 'conduitd', 'lib', name)),
  )
  if (hasWhisper) {
    if (whisperLicence === undefined) {
      console.error('the bundle has whisper.cpp but its LICENSE was not found for the notices')
      process.exit(1)
    }
    sections.push('## whisper.cpp and ggml', '', 'License: MIT', '')
    sections.push('```', readFileSync(whisperLicence, 'utf8').trim(), '```', '')
  }
}
writeFileSync(join(stage, 'THIRD_PARTY_NOTICES.md'), sections.join('\n'))

console.log(`staged ${dartTarget()} into ${stage}`)
