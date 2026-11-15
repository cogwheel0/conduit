# Building and releasing Conduit Desktop (macOS)

Conduit Desktop is the native macOS app in `desktop/`: Rust on GPUI Kit,
over the Dart daemon `conduitd` (`apps/daemon`). This page covers the
release bundle: building it, signing, notarizing, the DMG, Sparkle updates,
the release workflow and its secrets. For day-to-day development (the dev
app, the gallery, the E2E harnesses) see [`desktop/README.md`](../desktop/README.md).

Release builds are **Apple Silicon only** and need **macOS 14 Sonoma** or
later. They are Developer ID–signed, notarized DMGs on GitHub Releases, and
they update themselves with Sparkle 2 (a stable channel, plus an opt-in
beta channel).

## What ships

```
Conduit.app/Contents/
├── Info.plist                  packaging/macos/Info.plist, filled in by bundle.sh
├── MacOS/Conduit               the Rust app (conduit-desktop), arm64
├── Frameworks/Sparkle.framework    Sparkle 2, thinned to arm64 (release bundles)
└── Resources/
    ├── AppIcon.icns            packaging/macos/AppIcon.icns (macOS 14/15)
    ├── Assets.car              packaging/macos/Assets.car (the icon on macOS 26+)
    ├── THIRD_PARTY_NOTICES.md  made by packaging/notices/notices.sh at bundle time
    └── conduitd/
        ├── bin/conduitd        `dart build cli` of apps/daemon (Dart AOT)
        └── lib/
            ├── libsqlite3.dylib         from the sqlite3 package's build hook
            └── libconduit_whisper.dylib whisper.cpp (apps/daemon/native/whisper)
```

The app finds `Resources/conduitd/bin/conduitd` next to its own executable
and runs in the production flavour: data in
`~/Library/Application Support/Conduit`, logs in `~/Library/Logs/Conduit`,
and the master key in the Keychain item `app.cogwheel.conduit.desktop`.

## Requirements

| | |
| --- | --- |
| Mac | Apple Silicon (the scripts build `aarch64-apple-darwin` only) |
| Xcode | with the Metal toolchain (`xcrun metal --version`; else `xcodebuild -downloadComponent MetalToolchain`) |
| Rust | rustup; `desktop/rust-toolchain.toml` pins 1.99.1 |
| Flutter / Dart | as in [BUILDING.md](BUILDING.md); `dart build cli` builds conduitd |
| CMake | 3.16 or newer, for the whisper library (`CMAKE=/path/to/cmake` if it is not on `PATH`) |
| Python 3 | the notices generator and the appcast summary |
| cargo-about 0.9 | only to regenerate the notices: `cargo install cargo-about --locked --features cli --version 0.9.3` |

The repository needs its `third_party/` submodules, `flutter pub get` and
Dart codegen (`bundle.sh` runs `build_runner` when the core's generated
files are missing).

## Build locally

```sh
desktop/packaging/macos/bundle.sh                    # = all, version 0.0.0, ad-hoc
desktop/packaging/macos/bundle.sh all --version 1.2.0
desktop/packaging/macos/smoke.sh desktop/target/macos/Conduit-1.2.0/Conduit.app --launch
```

Output goes to `desktop/target/macos/Conduit-<version>/` (`Conduit.app`,
`Conduit-<version>.dmg`, the entitlements used, the verification report).
A second run moves the previous folder aside; the scripts never delete.

`bundle.sh` runs these steps, each also available on its own (the release
workflow calls them one by one so secrets reach only the steps that need
them):

| Command | Does |
| --- | --- |
| `build` | `cargo build --release --target aarch64-apple-darwin` (with `MACOSX_DEPLOYMENT_TARGET=14.0`), `dart build cli` for conduitd, CMake for libconduit_whisper, then assembles the `.app` |
| `sign` | signs inside out with the hardened runtime (below) |
| `notarize-app` | zips the app, `xcrun notarytool submit --wait`, `xcrun stapler staple` |
| `dmg` | `hdiutil` image holding `Conduit.app` and an `Applications` link; signed when there is an identity |
| `notarize-dmg` | notarizes and staples the DMG |
| `verify` | `plutil -lint`; minimum OS, URL scheme, document types and icon in Info.plist; every Mach-O arm64-only (`lipo`) and no newer than macOS 14 (`vtool`); conduitd links nothing outside the system and the bundle; `codesign --verify --deep --strict`; `spctl -a -vv`; sizes |

Options: `--version`, `--out DIR`, `--release` (CI: a missing identity,
notarization credentials, Sparkle key or icon fails instead of warning),
`--skip-rust/--skip-daemon/--skip-whisper` to reuse earlier builds.
`--bundle-id` and `--test-env` exist only for local update tests and are
refused with `--release`.

Without `CONDUIT_SIGN_IDENTITY` the bundle is signed ad hoc: it runs on the
Mac that built it, and Gatekeeper (`spctl`) rejects it anywhere else.

## Testing against a local Open WebUI

The daemon's live tests (`apps/daemon/test/live_server_test.dart`), the
signed-in run of `apps/daemon/tool/smoke.dart` and the app's `--e2e` passes
run against a throwaway Open WebUI on this Mac, never a real server:

```sh
tool/local_owui/owui.sh setup     # once: a venv with open-webui 0.13.2
tool/local_owui/owui.sh up        # start it with a fake model, seed it
(cd apps/daemon && dart test test/live_server_test.dart)
(cd desktop && crates/app/run.sh --shots /tmp/shots --e2e chat)
tool/local_owui/owui.sh stop
```

The seed is invented (two users, folders, 40 chats, a shared folder, two
prompts, a file) and its credentials go to an env file the tests read; see
[`tool/local_owui/README.md`](../tool/local_owui/README.md). Without that
file the live tests skip, as in CI, which never starts the server.

## Versions and build numbers

A release is a tag `desktop-v<version>`, where the version is `X.Y.Z` or
`X.Y.Z-beta.N`. `CFBundleShortVersionString` is the version as written;
`CFBundleVersion` (what Sparkle compares) is one integer that orders every
release across both channels:

```
X*1000000 + Y*10000 + Z*100 + (N for beta N, 99 for the stable release)
1.2.0-beta.3 → 1020003   1.2.0 → 1020099   1.2.1-beta.1 → 1020101
```

so Y and Z stay below 100 and a beta number between 1 and 98. The app shows
both in Settings › About (`CONDUIT_VERSION` and `CONDUIT_BUILD` are compiled
in by `bundle.sh`).

## Signing

`CONDUIT_SIGN_IDENTITY` is the codesign identity: a "Developer ID
Application: …" name or its SHA-1 (`security find-identity -v -p codesigning`).
The order, all with `--options runtime` and a secure timestamp:

1. `Resources/conduitd/lib/*.dylib`
2. `Resources/conduitd/bin/conduitd` with `conduitd.entitlements`, identifier `app.cogwheel.conduit.desktop.conduitd`
3. Sparkle, in Sparkle's documented order: `XPCServices/Installer.xpc`,
   `XPCServices/Downloader.xpc` (keeping its entitlements), `Autoupdate`,
   `Updater.app`, then `Sparkle.framework`
4. `Conduit.app` with `Conduit.entitlements`

Entitlements (`desktop/packaging/macos/`):

| File | Keys | Why |
| --- | --- | --- |
| `Conduit.entitlements` | `network.client`, `network.server` | the app is a loopback client and server of conduitd and a client of your servers (enforced only under the App Sandbox, which Conduit does not use) |
| `conduitd.entitlements` | `cs.allow-unsigned-executable-memory` | the Dart VM maps executable memory at run time; `allow-jit` alone is not enough |

Ad-hoc builds add `cs.disable-library-validation` to both, because without a
team ID dyld refuses the bundle's own libraries (libsqlite3, the whisper
library, Sparkle). Developer ID builds keep library validation. Nothing asks
for the microphone yet: there is no `audio-input` entitlement and no
`NSMicrophoneUsageDescription` until dictation lands.

## Notarization

`notarize-app` and `notarize-dmg` use either

- `CONDUIT_NOTARY_PROFILE`: a profile made once with
  `xcrun notarytool store-credentials <name> --key AuthKey_XXXX.p8 --key-id … --issuer …`
  (or with an Apple ID and app-specific password), or
- `CONDUIT_NOTARY_KEY_FILE` + `CONDUIT_NOTARY_KEY_ID` + `CONDUIT_NOTARY_ISSUER`:
  an App Store Connect API key, which is what CI uses.

With neither, or with an ad-hoc signature, both steps are skipped with a
message (`--release` makes that an error). A rejected submission prints
Apple's log. The app is stapled before it goes into the DMG, and the DMG is
stapled too, so both work offline.

## Updates (Sparkle 2)

`release.env` pins the Sparkle release (`SPARKLE_VERSION`, `SPARKLE_SHA256`);
`bundle.sh` downloads it once into `desktop/target/sparkle/` and refuses an
archive whose checksum differs. The framework is embedded only when
`SPARKLE_PUBLIC_ED_KEY` is set, together with these Info.plist keys:

| Key | Value |
| --- | --- |
| `SUFeedURL` | the appcast URL (below) |
| `SUPublicEDKey` | `SPARKLE_PUBLIC_ED_KEY` |
| `SUEnableAutomaticChecks` | `true`: daily checks without the first-run question; Settings › About can turn them off |
| `SUScheduledCheckInterval` | `86400` |
| `SUVerifyUpdateBeforeExtraction` | `true`: check the EdDSA signature before unpacking |

The app loads Sparkle at run time (`crates/app/src/shell/updater.rs`) and
drives `SPUStandardUpdaterController`: **Conduit › Check for Updates…** in the
app menu, and **Settings › About** with Check for Updates…, "Check for
updates automatically" and **"Receive beta updates"** (off by default).
Without the framework (dev builds) the menu item is disabled and About says
updates come with the installed app. Sparkle's decisions go to the app log
(`updates: found …`, `none`, `downloaded`, `installing`, `stopped: …`).

### Channels

One appcast serves both channels. Stable releases are items without a
channel, which every copy is offered. A `-beta.N` release is added with
`generate_appcast --channel beta`, so its item carries
`<sparkle:channel>beta</sparkle:channel>`; the app's updater delegate
answers `allowedChannelsForUpdater:` with `{"beta"}` only while "Receive
beta updates" is on. Turning it off never downgrades: a beta user waits
for the next stable release newer than the beta they have (the build
numbers above make "newer" work across channels).

### Keys

Sparkle signs every update with an EdDSA (ed25519) key pair. **Generate the
release key once, on a trusted Mac, and keep the private half only in the
repository secret and an offline backup.** Sparkle's `generate_keys`
stores the key in the login Keychain, so use a Mac you trust for that:

```sh
d="$(bash -c '. desktop/packaging/macos/lib.sh && sparkle_dir')"   # the pinned Sparkle
"$d/bin/generate_keys" --account conduit-desktop     # prints the public key
"$d/bin/generate_keys" --account conduit-desktop -x sparkle-private-key.txt
```

- The public key goes into the repository **variable**
  `SPARKLE_PUBLIC_ED_KEY` (it is not secret; it ends up in every Info.plist).
- The contents of `sparkle-private-key.txt` go into the **secret**
  `SPARKLE_ED_PRIVATE_KEY`; then remove the file.
- Never commit either. Losing the private key means installed copies can
  only be moved to a new key by an update signed with the old one (or by a
  manual download).

### The appcast

`appcast.sh --dmg … --version …` fetches the current appcast from the feed
URL, adds the new DMG with `generate_appcast` (signing it with the private
key from `SPARKLE_ED_PRIVATE_KEY`, read on stdin), and keeps every earlier
item (`--maximum-versions 0`). Each item's download URL is the DMG on that
version's GitHub release; `--link` and `--full-release-notes-url` point at
the releases page. `--fresh` (or `--allow-new` in CI, on HTTP 404 only)
starts a new feed for the first release; any other fetch failure stops
rather than replace the feed. `publish-appcast.sh appcast.xml --push`
uploads it; without `--push` it only prints what it would do.

### Hosting the appcast

Installed copies read the feed from the URL baked into their Info.plist, so
it must never move. `releases/latest/download/appcast.xml` does not work
here: "latest" skips prereleases (every beta) and points at the
repository's newest stable release, which is usually the mobile app's. One
value in `desktop/packaging/macos/release.env`, `APPCAST_HOSTING`, picks
one of three stable places. **Conduit uses `release-asset`** (chosen
2026-11-09); `pages` and `branch` stay implemented as alternatives.

| `APPCAST_HOSTING` | Feed URL | Publish | Trade-offs |
| --- | --- | --- | --- |
| **`release-asset` (chosen, the default)** | `https://github.com/cogwheel0/conduit/releases/download/desktop-appcast/appcast.xml` | `gh release upload desktop-appcast appcast.xml --clobber` to a fixed prerelease (made on first use, never "Latest") | Nothing to set up; same permissions as publishing a release. The "desktop-appcast" entry shows in the releases list, and the file is briefly missing while it is replaced (a check then simply fails and retries the next day). |
| `pages` (alternative) | `https://cogwheel0.github.io/conduit/desktop/appcast.xml` | commits `desktop/appcast.xml` to `gh-pages` | The cleanest URL, can carry HTML release notes, and could become the project's site later. Needs GitHub Pages turned on for the repository (it is off today) and a `gh-pages` branch. |
| `branch` (alternative) | `https://raw.githubusercontent.com/cogwheel0/conduit/desktop-appcast/appcast.xml` | commits `appcast.xml` to the `desktop-appcast` branch | Simple, but raw.githubusercontent.com is not meant as a download host (rate limits, up to 5 minutes of caching), and it adds a branch. |

`CONDUIT_APPCAST_URL` overrides the URL for one build (local tests, or a
custom domain in front of any of these). To move the feed after a release
has shipped, keep serving the old URL and ship one update whose
Info.plist names the new one.

## Releasing

1. Make sure the secrets and the variable below are set.
2. Tag and push: `git tag desktop-v1.2.0 && git push origin desktop-v1.2.0`
   (a beta: `desktop-v1.3.0-beta.1`).
3. `release-desktop.yml` (macOS 15, Apple Silicon) then: reads the version
   from the tag; builds with no secrets in reach; regenerates
   `THIRD_PARTY_NOTICES.md`; imports the certificate into a temporary
   keychain; signs; notarizes and staples the app; builds, notarizes and
   staples the DMG; runs `bundle.sh verify --release` and `smoke.sh --launch`;
   adds the DMG to the appcast; publishes the GitHub release (a prerelease
   for betas; never marked "Latest", which stays the mobile app's); then
   publishes the appcast, after the DMG it points at. The run keeps the
   notary reports, the codesign report and the appcast as an artifact, and
   removes the temporary keychain.

Releases run one at a time (each rewrites the appcast). The first release
starts a new appcast.

Pull requests that touch `desktop/`, `apps/daemon/` or the ARBs also run
`desktop.yml`'s **Release bundle (unsigned) + smoke** job: the same
`bundle.sh all` with an ad-hoc signature and a throwaway Sparkle public
key, then `smoke.sh --launch`; the DMG is kept for five days.

### Secrets and variables

| Name | Kind | What it holds | How to make it |
| --- | --- | --- | --- |
| `MACOS_DEVELOPER_ID_P12` | secret | base64 of a `.p12` with the **Developer ID Application** certificate and its private key | Create the certificate in the Apple Developer account (Certificates › +, "Developer ID Application"; only the Account Holder can), install it, export certificate + key from Keychain Access as `.p12`, then `base64 -i cert.p12 \| pbcopy` |
| `MACOS_DEVELOPER_ID_P12_PASSWORD` | secret | the `.p12`'s export password | chosen at export |
| `MACOS_NOTARY_API_KEY` | secret | the App Store Connect API key, the text of `AuthKey_XXXXXXXXXX.p8` | App Store Connect › Users and Access › Integrations › Team Keys, a key with the Developer role; the `.p8` downloads once |
| `MACOS_NOTARY_API_KEY_ID` | secret | that key's ID | shown next to the key |
| `MACOS_NOTARY_API_ISSUER_ID` | secret | the team's issuer ID | shown above the keys |
| `SPARKLE_ED_PRIVATE_KEY` | secret | Sparkle's private EdDSA key | [Keys](#keys) |
| `SPARKLE_PUBLIC_ED_KEY` | variable | the matching public key | [Keys](#keys) |

The workflow checks that all of them are present before it builds. The
`GITHUB_TOKEN` (with `contents: write` for that job only) publishes the
release and the appcast.

## Testing an update locally

Sparkle can be exercised end to end on one Mac with a throwaway key and a
feed on `127.0.0.1`, without touching the real app:

1. Make a throwaway key pair outside the repository (never `generate_keys`,
   which writes to the login Keychain):
   `openssl genpkey -algorithm ed25519 -outform DER -out k.der`, then the
   private key is `tail -c 32 k.der | base64` and the public key
   `openssl pkey -inform DER -in k.der -pubout -outform DER | tail -c 32 | base64`.
2. Build versions N and N+1 (and a beta) with
   `CONDUIT_APPCAST_URL=http://127.0.0.1:<port>/appcast.xml`,
   `SPARKLE_PUBLIC_ED_KEY=<public>`, `--bundle-id <a test id>`, and
   `--test-env` entries for `CONDUIT_FLAVOR=dev`, `CONDUIT_USER_DATA` and
   `CONDUIT_LOGS` pointing at a scratch folder, so the test bundles (and
   anything Sparkle relaunches) keep their data apart from the real app.
3. With the throwaway private key in the environment
   (`export SPARKLE_ED_PRIVATE_KEY=<private>`), add N+1 to a new feed, then
   the beta to that feed, and serve the second folder with both DMGs (it
   starts with only the beta's):

   ```sh
   appcast.sh --dmg <N+1>.dmg --version <N+1> --fresh \
     --download-url-prefix http://127.0.0.1:<port>/ --work /tmp/feed
   appcast.sh --dmg <beta>.dmg --version <beta> --existing /tmp/feed/appcast.xml \
     --download-url-prefix http://127.0.0.1:<port>/ --work /tmp/feed-2
   cp <N+1>.dmg /tmp/feed-2/
   python3 -m http.server --bind 127.0.0.1 <port> --directory /tmp/feed-2
   ```

   `appcast.sh` refuses a feed that drops an earlier item, an unsigned or
   wrong-length enclosure, or a build out of order (a stable build must be
   newer than every stable item, a beta newer than every item;
   `check_appcast.py`); `release_test.sh` checks those safeguards and the
   publishing ones against synthetic feeds.
4. Copy N into a scratch folder, set
   `defaults write <test id> SUAutomaticallyUpdate -bool YES` so Sparkle
   downloads in the background and installs on quit, launch it, and watch
   the app log for `updates: found …` and `downloaded`; quit, and the
   scratch copy is N+1. With `"betaUpdates": true` in the scratch profile's
   `desktop-preferences.json` the beta is offered; without it, it is not.
5. Afterwards unregister the test bundles from Launch Services
   (`lsregister -u <path>`).

## Third-party notices

`THIRD_PARTY_NOTICES.md` ships in the bundle. It is not committed:
`bundle.sh` generates it into each bundle (`Contents/Resources/`), so it
always matches the dependencies built in.

```sh
desktop/packaging/notices/notices.sh           # write desktop/target/notices/THIRD_PARTY_NOTICES.md
desktop/packaging/notices/notices.sh --check   # generate it in a temporary folder; fail if a licence is missing
```

It lists the components bundled directly (the vendored and modified
gpui-pre, Sparkle, whisper.cpp, SQLite, the Dart runtime, mermaid, Chart.js,
Lucide, the KaTeX fonts), every Rust crate in the `conduit-desktop` binary
(cargo-about, `about.toml`, `about.hbs`) and every Dart package in conduitd,
each grouped by licence text. Licence texts that are not in a package on
disk live in `desktop/packaging/notices/texts/`.

## App icon

The macOS icon is the iOS app icon
(`ios/Runner/Assets.xcassets/AppIcon.appiconset/AppIcon~ios-marketing.png`,
the white hub-and-spokes mark on blue) placed on Apple's macOS icon grid:
`icon-master.swift` scales it, unchanged, into an 824 x 824 tile with
continuous corners centred on the 1024 px canvas, with a soft drop shadow,
and writes `packaging/macos/AppIcon-master.png`. `icon.sh` then makes both
icon files from the master (sips and iconutil for the PNGs, Xcode's actool
for the catalog; never ImageMagick):

```sh
xcrun swift desktop/packaging/macos/icon-master.swift \
  ios/Runner/Assets.xcassets/AppIcon.appiconset/AppIcon~ios-marketing.png \
  desktop/packaging/macos/AppIcon-master.png
desktop/packaging/macos/icon.sh desktop/packaging/macos/AppIcon-master.png
```

| File | Info.plist | Shown by |
| --- | --- | --- |
| `Assets.car` (asset-catalog AppIcon) | `CFBundleIconName` | macOS 26 and later. With only an `.icns`, macOS 27 draws the icon shrunk inside a grey squircle at small sizes (checked with `NSWorkspace.icon(forFile:)` at 32 px). |
| `AppIcon.icns` (16 to 512 px at 1x and 2x) | `CFBundleIconFile` | macOS 14 and 15 |

All three files are committed, so builds never render. `bundle.sh` copies
both into `Contents/Resources`, and `verify` checks them (`--release` fails
without them). On macOS 26+ the system adds its own glass edge and lighting
to the tile; the artwork itself is the iOS icon's.

## Troubleshooting

- **"Launchd job spawn failed" / error 162 on launch**: a binary was
  overwritten in place; `bundle.sh` always assembles a new bundle.
- **Keychain prompts with ad-hoc builds**: an item created by an ad-hoc
  binary belongs to that exact build. Test ad-hoc bundles with
  `CONDUIT_FLAVOR=dev` (the dev Keychain item through `/usr/bin/security`) and
  throwaway `CONDUIT_USER_DATA`/`CONDUIT_LOGS`.
- **dyld refuses `libsqlite3.dylib` or Sparkle**: library validation; ad-hoc
  builds need `disable-library-validation` (bundle.sh adds it), Developer ID
  builds need everything signed with the same team.
- **`sqlite3` hook download fails** in `dart build cli` (HTTP 504 leaves a
  `.tmp` and a hash error): retry, or copy a verified `libsqlite3.dylib`
  into the hook's cache.
- **Sparkle says "An error occurred in retrieving update information"**: the
  feed URL is unreachable or not an appcast yet (the first release creates
  it).
