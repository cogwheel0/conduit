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
├── Frameworks/
│   ├── Sparkle.framework       Sparkle 2, thinned to arm64 (release bundles)
│   └── libconduit_widget.dylib the widget's WidgetCenter calls (Swift)
├── PlugIns/
│   ├── ConduitWidget.appex     the desktop widget (WidgetKit, Swift)
│   └── ConduitShare.appex      the Share extension (packaging/macos/share), sandboxed
└── Resources/
    ├── <lang>.lproj/ServicesMenu.strings   the Services items' titles, 14 languages
    ├── AppIcon.icns            packaging/macos/AppIcon.icns (macOS 14/15)
    ├── Assets.car              packaging/macos/Assets.car (the icon on macOS 26+)
    ├── THIRD_PARTY_NOTICES.md  made by packaging/notices/notices.sh at bundle time
    ├── Metadata.appintents/    the App Intents' metadata (packaging/macos/intents.sh)
    ├── <locale>.lproj/         their strings: Localizable.strings, AppShortcuts.strings
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
| Xcode | with the Metal toolchain (`xcrun metal --version`; else `xcodebuild -downloadComponent MetalToolchain`); its `swiftc` and macOS SDK build the widget |
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
4. `Frameworks/libconduit_widget.dylib`, then `PlugIns/ConduitWidget.appex`
   with `widget/ConduitWidget.entitlements`
5. `PlugIns/ConduitShare.appex` with `Share.entitlements` (filled in for the bundle id)
6. `Conduit.app` with `Conduit.entitlements`

Entitlements (`desktop/packaging/macos/`):

| File | Keys | Why |
| --- | --- | --- |
| `Conduit.entitlements` | `network.client`, `network.server` | the app is a loopback client and server of conduitd and a client of your servers (enforced only under the App Sandbox, which Conduit does not use) |
| `conduitd.entitlements` | `cs.allow-unsigned-executable-memory` | the Dart VM maps executable memory at run time; `allow-jit` alone is not enough |
| `widget/ConduitWidget.entitlements` | `app-sandbox` | app extensions run in the App Sandbox |
| both of the app's and the widget's, added when signing | `application-groups`: `WIDGET_APP_GROUP` | the widget reads the app's snapshot from the group's container ([The desktop widget](#the-desktop-widget)) |
| both, with provisioning profiles only | `com.apple.application-identifier`, `com.apple.developer.team-identifier` | what each profile vouches for |
| `share/Share.entitlements` | `app-sandbox`, `temporary-exception.files.home-relative-path.read-write` for `~/Library/Caches/<bundle id>.share-inbox/` | every app extension is sandboxed; the inbox is the one folder it hands shares through (see below) |

Ad-hoc builds add `cs.disable-library-validation` to both, because without a
team ID dyld refuses the bundle's own libraries (libsqlite3, the whisper
library, Sparkle). Developer ID builds keep library validation. Nothing asks
for the microphone yet: there is no `audio-input` entitlement and no
`NSMicrophoneUsageDescription` until dictation lands.

## The Share menu and the Services menu

**Share extension** (`packaging/macos/share/`): "Conduit" in every app's
Share menu takes text, web links and up to ten files, images or movies, and
shows a small sheet with an optional message, Cancel and Open in Conduit.
`share/build.sh` compiles it with `swiftc` (no Xcode project) and fills its
Info.plist; `bundle.sh` embeds and signs it before the app.

The hand-off works with ad-hoc and Developer ID signatures alike. The
sandboxed extension copies what it was given into
`~/Library/Caches/<bundle id>.share-inbox/<uuid>/` (a `manifest.json` and
`files/<n>/<name>`; written as `<uuid>.part`, then renamed), and opens
`conduit://share/<uuid>` **with its own containing app** (never whichever
app owns `conduit://`). The app reads the share once
(`shell/share_inbox.rs`), opens a new chat with the message and text in the
composer and the files attached, nothing sent, and clears taken shares
after ten minutes and abandoned ones after a day. Why not an App Group: since
macOS 15 a group container needs a team ID prefix or a provisioning profile,
or the system asks the user before the app may read it, and an ad-hoc build
has no team ID. A home-relative temporary exception needs neither (the Mac
App Store would refuse it; Conduit is not sold there).

Limits of an ad-hoc build: Gatekeeper refuses it on other Macs, and
PlugInKit only offers the extension once the app is registered with
LaunchServices (a first launch, or `lsregister`) and the extension is turned
on (System Settings › General › Login Items & Extensions › Sharing, or
`pluginkit -e use -i <bundle id>.share`).

**Services** (`NSServices` in `Info.plist`, `shell/services.rs`): "Ask
Conduit" opens Quick Ask with the selected text quoted (a new chat when Quick
Ask is off or not set up), and "New Conduit Chat With Selection" opens a new
chat with it. Their titles are translated by `ServicesMenu.strings`, which
`share/build.sh` writes from the ARB catalogs (`native_strings.py table`).
Dev bundles (`crates/app/run.sh`) leave `NSServices` out, so worktree builds
never appear in the Services menu.

**Tests:**

- `share/test.sh`: the inbox's tests (`share/tests/InboxTests.swift`, which
  checks the manifest against `share/tests/manifest-v1.json`, as the app's
  `share_inbox` tests do) and a type-check of the extension and its preview.
- `share/preview.sh DIR`: the sheet's content in light and dark, drawn off
  screen by the extension's own view controller over synthetic items
  (built with `-D SHARE_PREVIEW`, which the extension never is).
- `crates/app/run.sh --shots DIR --e2e share`: the app's side, against the
  local Open WebUI: a share staged as the extension stages it, its link, the
  new chat, the upload and the send; the Services provider called as macOS
  calls it.
- `share/e2e-system.sh APP --shots DIR`: a bundle built with a **test**
  bundle id (`bundle.sh --bundle-id … --test-env CONDUIT_FLAVOR=dev …`; the
  release id is refused) registered with LaunchServices and PlugInKit; the
  real sheet opened from another app (`share/tests/ShareDriver.swift`) and
  the copy the sandboxed extension stages; that share finished as Open in
  Conduit finishes it and its link delivered to the test app;
  `NSPerformService("Ask Conduit")` once only the test bundle provides it;
  then everything unregistered. It never opens another app's extension.
- By hand: the real sheet's Open in Conduit and Cancel, and its look in
  place. Since macOS 13 the sheet is a remote view in windows ShareKit lays
  over the host; it takes no synthetic keys from the host and cannot be
  captured without Screen Recording permission.

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
| `MACOS_APP_PROVISIONING_PROFILE` | secret, optional | base64 of the app's Developer ID provisioning profile | [The desktop widget](#the-desktop-widget) |
| `MACOS_WIDGET_PROVISIONING_PROFILE` | secret, optional | base64 of the widget extension's | the same |

The workflow checks that all but the two profiles are present before it
builds; without the profiles it warns, and the release's widget is not
listed by macOS. The
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

## The desktop widget

`PlugIns/ConduitWidget.appex` is a WidgetKit extension (small, medium and
large; desktop and Notification Center): Ask Conduit (Quick Ask), New
Chat, Voice Call, and the newest chats, each a `conduit://` link the app
opens (`quick-ask`, `new`, `call`, `chat/<id>`). Its sources are Swift in
`desktop/packaging/macos/widget/`, built by `widget/build.sh` with `swiftc`
(no Xcode project); `bundle.sh build` runs it.

**Data.** The widget never talks to conduitd. The app writes
`widget-snapshot.json` (ids, titles and times of the six newest chats,
whether anyone is signed in, the app's language; never message text; no
chats when signed out; owner-only) into the app group's container
`~/Library/Group Containers/<WIDGET_APP_GROUP>/`, and asks WidgetKit to
reload through `libconduit_widget.dylib` (`WidgetCenter` is Swift-only,
and it honours only the app that contains the widget). The group is
`WIDGET_APP_GROUP` in `release.env`, `@TEAM_ID@` replaced by the signing
team (`TEAM_ID`, or the identity's certificate); `bundle.sh sign` writes it
into both Info.plists (`ConduitAppGroup`) and both entitlements.

**What it needs from Apple.** Checked on macOS 27.0.1 with throwaway test
bundles (never the release id):

| Signature | The app's group container | macOS lists the widget |
| --- | --- | --- |
| ad-hoc (`-`), any group id | refused (EPERM, no prompt) | no: chronod logs "Ignoring restricted or unknown extension" and drops its descriptors |
| Apple Development certificate, team-prefixed group, no profile | works | no, the same (also from `~/Applications`, and with `com.apple.application-identifier` claimed) |
| Developer ID + Developer ID provisioning profiles | expected to work | expected (not testable here) |

`pluginkit -m` shows every variant registered; `WidgetCenter` answers the
app in all of them. So a release needs, besides the Developer ID
certificate:

1. In the Apple Developer account (Certificates, IDs & Profiles): App IDs
   `app.cogwheel.conduit.desktop` and `app.cogwheel.conduit.desktop.widget`,
   both with the **App Groups** capability, and the group
   (`<TEAMID>.app.cogwheel.conduit.desktop`, or a registered `group.…` id
   set in `WIDGET_APP_GROUP`).
2. Two **Developer ID** provisioning profiles, one per App ID, from the
   Developer ID certificate.
3. Locally: `CONDUIT_APP_PROFILE=… CONDUIT_WIDGET_PROFILE=… bundle.sh`; in
   CI: the two optional secrets above (base64 of each profile). `bundle.sh`
   embeds them as `embedded.provisionprofile`, checks each one is for
   `<TEAMID>.<bundle id>`, and adds the application and team identifiers to
   the entitlements.

For development, Xcode's own way (an Apple Development certificate and a
Mac Development profile naming this Mac) is expected to work as well.

**Trying it.** `CONDUIT_DEV_WIDGET=1 crates/app/run.sh` embeds the widget
in the dev bundle (ad-hoc, group `app.cogwheel.conduit.desktop.dev`): the
app loads the library and asks for reloads, but macOS won't list the
widget. `CONDUIT_WIDGET_SNAPSHOT=<file>` sends the snapshot to a file
instead (the `--e2e widget` pass does). `widget/render.sh OUT_DIR` draws
the widget's views to PNGs (light and dark, each family and state) from
`widget/Fixtures/snapshot.json`, which the app's writer test keeps equal to
what the app writes. The widget's words come from the ARBs
(`desktopWidget*`, "Yesterday" and the weekdays): `widget/build.sh` and
`render.sh` generate `WidgetStrings.swift` with `native_strings.py widget`
before compiling.

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

## Shortcuts and App Intents

Conduit's actions in Shortcuts, Spotlight and Siri (Ask Conduit, New Chat,
Open Chat, Start Voice Call, Show Quick Ask, and their App Shortcuts) are
App Intents written in Swift, in `desktop/crates/app/intents/`. They are
built without Xcode:

1. `crates/app/build.rs` runs `packaging/macos/intents.sh compile`: `swiftc`
   (Swift 6, `-parse-as-library`, the deployment target) makes one object
   and the compiler's constant values, and `libtool` a static library that
   the Rust binary links whole. AppKit registers the process with the App
   Intents runtime at launch; nothing in Rust names the intents.
2. `bundle.sh` (and `crates/app/run.sh` for the dev bundle) runs
   `intents.sh bundle`, which recompiles for the constant values and runs
   Apple's `appintentsmetadataprocessor` as Xcode's "Extract App Intents
   Metadata" step does, into `Resources/Metadata.appintents`. Then
   `native_strings.py intents` writes each locale's `Localizable.strings` and
   `AppShortcuts.strings` from `lib/l10n/desktop` (`desktopIntent*` keys).
   A string the intents show with no ARB key fails the bundle, and
   `cargo test` (`intents::tests`) checks the same before any bundle.
3. `verify` and `smoke.sh` run `intents.sh verify` (five actions, the chat
   entity and its query, five App Shortcuts, every locale's strings), and
   `smoke.sh --launch` checks that every type the metadata names is in the
   binary (`SMOKE intents <n> types resolve`).

Each intent's `perform()` hands the app one JSON request over a C function
(`conduit_intents_request`, `src/intents.rs`) and gets one reply. The app
does the work through conduitd: Ask Conduit is `intents.ask` (a new chat,
then the answer, up to two minutes), Open Chat's list is `intents.chats`,
and New Chat and Open Chat take the `conduit://` links' path. The intents
are in the app rather than in an App Intents extension: an extension must
be sandboxed, could only reach conduitd through an app group (which needs
a team ID), and could do nothing while the app is not running, since
conduitd is the app's child.

`--e2e intents` runs the Swift intents' own `perform()` and query in the
app's process against the local Open WebUI; Shortcuts itself can't be
driven from a test (`shortcuts run` only runs shortcuts in the user's
library).

### Signing and App Intents

| Signature | Shortcuts and Spotlight list the actions | The actions run |
| --- | --- | --- |
| Ad-hoc (`-`, local builds) | yes, once Launch Services has launched the bundle (before that, linkd logs "not trusted for binding") | no: linkd refuses the app's runtime registration ("requiresValidatedBundle", "Unable to get teamId") |
| Apple Development (a free or paid team) | yes | expected yes: the signature has a team ID |
| Developer ID (releases) | yes | yes, as for any notarized app |

No entitlement is needed for App Intents. To see what linkd did with a
bundle: `/usr/bin/log show --last 10m --predicate 'process == "linkd" AND
eventMessage CONTAINS "<bundle id>"'`. Test bundles are registered with
Launch Services when they are launched; take them out afterwards with
`lsregister -u <path to the .app>` (`LSREGISTER` in `lib.sh`).

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
