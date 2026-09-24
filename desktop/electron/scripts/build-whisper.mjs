#!/usr/bin/env node
// Builds libconduit_whisper: whisper.cpp and a small C face on it,
// for transcribing speech on this computer. Needs CMake and a C/C++
// compiler; fetches whisper.cpp at the tag pinned in the CMake file.
//
// The library lands next to the daemon, in the `dart build cli` bundle's
// lib/ -- where conduitd looks for it, and where packaging picks it up with
// the rest of the bundle. Run it after `npm run build:daemon`, which
// rewrites the bundle.
//
// Set WHISPER_SOURCE_DIR to build from a whisper.cpp checkout on disk.
import { spawnSync } from 'node:child_process'
import { copyFileSync, existsSync, mkdirSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const repoRoot = resolve(here, '..', '..', '..')
const source = join(repoRoot, 'apps', 'daemon', 'native', 'whisper')

const os = { darwin: 'macos', win32: 'windows', linux: 'linux' }[process.platform]
const arch = { x64: 'x64', arm64: 'arm64' }[process.arch]
const target = `${os}_${arch}`
const build = join(repoRoot, 'apps', 'daemon', 'build', 'whisper', target)
const name =
  process.platform === 'win32'
    ? 'conduit_whisper.dll'
    : process.platform === 'darwin'
      ? 'libconduit_whisper.dylib'
      : 'libconduit_whisper.so'

function run(args) {
  const result = spawnSync('cmake', args, { stdio: 'inherit', shell: process.platform === 'win32' })
  if (result.error?.code === 'ENOENT') {
    console.error('cmake is not installed; it builds the local speech engine.')
    process.exit(1)
  }
  if (result.status !== 0) process.exit(result.status ?? 1)
}

mkdirSync(build, { recursive: true })
run([
  '-S',
  source,
  '-B',
  build,
  '-DCMAKE_BUILD_TYPE=Release',
  ...(process.env.WHISPER_SOURCE_DIR ? [`-DFETCHCONTENT_SOURCE_DIR_WHISPER=${process.env.WHISPER_SOURCE_DIR}`] : []),
])
run(['--build', build, '--config', 'Release', '--parallel'])

// Single-config generators write to the build directory; Visual Studio's
// multi-config one to Release/.
const built = [join(build, name), join(build, 'Release', name)].find((path) => existsSync(path))
if (built === undefined) {
  console.error(`the build did not produce ${name}`)
  process.exit(1)
}
const bundleLib = join(repoRoot, 'apps', 'daemon', 'build', 'cli', target, 'bundle', 'lib')
if (!existsSync(dirname(bundleLib))) {
  console.error('no daemon bundle to put it in: run `npm run build:daemon` first')
  process.exit(1)
}
mkdirSync(bundleLib, { recursive: true })
copyFileSync(built, join(bundleLib, name))
console.log(`${name} built into ${bundleLib}`)
