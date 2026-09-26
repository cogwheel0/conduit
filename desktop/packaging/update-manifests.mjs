#!/usr/bin/env node
// Points the package manifests at one release:
//
//   node desktop/packaging/update-manifests.mjs <version> [artifacts-dir]
//
// Every version string becomes <version>, and when [artifacts-dir] holds
// the release's files, each artifact's SHA-256 replaces the sum beside its
// URL. Artifact names are electron-builder's:
// Conduit-<version>-<os>-<arch>.<ext>.
import { createHash } from 'node:crypto'
import { existsSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const [version, artifacts] = process.argv.slice(2)
if (!/^\d+\.\d+\.\d+([-.][0-9A-Za-z.]+)?$/.test(version ?? '')) {
  console.error('usage: update-manifests.mjs <version> [artifacts-dir]')
  process.exit(1)
}
const here = dirname(fileURLToPath(import.meta.url))

function sha(name) {
  if (artifacts === undefined) return null
  const file = join(artifacts, name)
  return existsSync(file) ? createHash('sha256').update(readFileSync(file)).digest('hex') : null
}

const artifact = (os, arch, ext) => `Conduit-${version}-${os}-${arch}.${ext}`

const edits = {
  'homebrew/conduit.rb': (text) => {
    text = text.replace(/version "[^"]+"/, `version "${version}"`)
    const arm = sha(artifact('mac', 'arm64', 'dmg'))
    const intel = sha(artifact('mac', 'x64', 'dmg'))
    if (arm) text = text.replace(/arm:\s+"[0-9a-f]{64}"/, `arm:   "${arm}"`)
    if (intel) text = text.replace(/intel: "[0-9a-f]{64}"/, `intel: "${intel}"`)
    return text
  },
  'winget/cogwheel.Conduit.yaml': (text) => {
    text = text
      .replace(/PackageVersion: .+/, `PackageVersion: ${version}`)
      .replace(/desktop-v[^/]+\/Conduit-[^-]+-/g, `desktop-v${version}/Conduit-${version}-`)
    for (const arch of ['x64', 'arm64']) {
      const sum = sha(artifact('win', arch, 'exe'))
      if (sum) {
        text = text.replace(
          new RegExp(`(win-${arch}\\.exe\\n\\s+InstallerSha256: )[0-9a-f]{64}`),
          `$1${sum}`,
        )
      }
    }
    return text
  },
  'aur/PKGBUILD': (text) => {
    text = text.replace(/^pkgver=.+$/m, `pkgver=${version.replace(/-/g, '_')}`)
    const x64 = sha(artifact('linux', 'x64', 'deb'))
    const arm = sha(artifact('linux', 'arm64', 'deb'))
    if (x64) text = text.replace(/sha256sums_x86_64=\('[0-9a-f]{64}'\)/, `sha256sums_x86_64=('${x64}')`)
    if (arm) text = text.replace(/sha256sums_aarch64=\('[0-9a-f]{64}'\)/, `sha256sums_aarch64=('${arm}')`)
    return text
  },
  'flathub/app.cogwheel.conduit.desktop.yml': (text) => {
    text = text.replace(/desktop-v[^/]+\/Conduit-[^-]+-/g, `desktop-v${version}/Conduit-${version}-`)
    for (const arch of ['x64', 'arm64']) {
      const sum = sha(artifact('linux', arch, 'deb'))
      if (sum) {
        text = text.replace(
          new RegExp(`(linux-${arch}\\.deb\\n\\s+sha256: )[0-9a-f]{64}`),
          `$1${sum}`,
        )
      }
    }
    return text
  },
}

for (const [file, edit] of Object.entries(edits)) {
  const path = join(here, file)
  writeFileSync(path, edit(readFileSync(path, 'utf8')))
  console.log(`updated ${file}`)
}
