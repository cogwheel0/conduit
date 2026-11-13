# Releasing Conduit Desktop (macOS)

How a signed, notarized, self-updating Conduit Desktop release is made, and
the one-time setup it needs. Building and testing the app day to day is in
[BUILDING-DESKTOP.md](BUILDING-DESKTOP.md).

**What ships:** `Conduit-<version>.dmg`, holding `Conduit.app` for **Apple
silicon only** (arm64) on **macOS 14 Sonoma or later**. It is signed with a
Developer ID Application certificate, notarized, and stapled. It updates
itself through **Sparkle 2** from **one stable channel**: a single appcast on
GitHub Releases, fed by `desktop-v*` tags. There are no beta releases; a
`-beta.N` tag is refused.

**Contents**

- [The release at a glance](#the-release-at-a-glance)
- [One-time setup](#one-time-setup)
- [Secrets and variables](#secrets-and-variables)
- [Making a release](#making-a-release)
- [What the workflow checks](#what-the-workflow-checks)
- [Rehearsals](#rehearsals)
- [Platform targets](#platform-targets)
- [Stripping and dSYMs](#stripping-and-dsyms)
- [Sparkle](#sparkle)
- [When something goes wrong](#when-something-goes-wrong)

## The release at a glance

```text
git tag desktop-v1.2.0 && git push origin desktop-v1.2.0
   │
   ▼  release-desktop.yml, job "build" (macOS, Apple silicon, Xcode 26+)
   build (no secrets) ─ strip, keep dSYMs ─ import Developer ID into a temporary keychain
   ─ sign inside out ─ notarize + staple the app ─ DMG ─ sign, notarize + staple it
   ─ verify ─ smoke --launch ─ sign the appcast ─ DRAFT release:
       Conduit-1.2.0.dmg, Conduit-1.2.0-dSYMs.zip, appcast.xml, SHA256SUMS.txt
   │
   ▼  a person checks the draft and publishes it
   release-desktop.yml, job "feed"
   appcast.xml → the fixed release `desktop-appcast` (the URL in every Info.plist)
   │
   ▼  installed copies find 1.2.0 on their next check (daily, or Check for Updates…)
```

Nothing reaches installed copies until the draft is published.

## One-time setup

Do these once, on a Mac you trust. None of the values below goes into the
repository; they go into the repository's Actions secrets and variables
(Settings › Secrets and variables › Actions), or into `gh secret set`, which
reads them from a prompt or from stdin.

### 1. The Developer ID Application certificate

1. In the Apple Developer account (Certificates, Identifiers & Profiles ›
   Certificates › +), create a **Developer ID Application** certificate
   (only the team's Account Holder can). Use the G2 Sub-CA. Download it and
   open it, so it lands in the login keychain with its private key.
2. Find its SHA-1 (the identity is always named by its SHA-1 here, never by
   the name in the certificate):

   ```sh
   security find-identity -v -p codesigning | grep 'Developer ID Application'
   ```

3. Check it locally before anything else (step 5).
4. Export certificate and key: Keychain Access › My Certificates, select the
   Developer ID Application certificate, File › Export Items… › `.p12`,
   with a strong export password. Then store both:

   ```sh
   base64 -i DeveloperID.p12 | gh secret set MACOS_DEVELOPER_ID_P12
   gh secret set MACOS_DEVELOPER_ID_P12_PASSWORD     # prompts for the password
   ```

   Keep the `.p12` in an offline backup (a password manager), not on disk.

### 2. Notarization credentials

`notarytool` takes either of two kinds. The workflow uses the API key when
all three of its secrets are set, the Apple ID otherwise.

**An App Store Connect API key (recommended).** App Store Connect › Users
and Access › Integrations › Team Keys › +, role **Developer**. Note the key
ID and the issuer ID shown above the list; the `.p8` file downloads once.

```sh
gh secret set MACOS_NOTARY_API_KEY < AuthKey_XXXXXXXXXX.p8
gh secret set MACOS_NOTARY_API_KEY_ID          # prompts: the key ID
gh secret set MACOS_NOTARY_API_ISSUER_ID       # prompts: the issuer ID
```

**Or an Apple ID with an app-specific password.** appleid.apple.com › Sign-In
and Security › App-Specific Passwords › +. The team is read from the
Developer ID certificate.

```sh
gh secret set MACOS_NOTARY_APPLE_ID            # prompts: the Apple ID's email
gh secret set MACOS_NOTARY_APP_PASSWORD        # prompts: the app-specific password
```

For local notarization (step 5), store the same credentials as a keychain
profile named `conduit-desktop-notary`. `notarytool` prompts for whatever
is secret, so nothing lands in the shell history:

```sh
# API key:
xcrun notarytool store-credentials conduit-desktop-notary \
  --key AuthKey_XXXXXXXXXX.p8 --key-id XXXXXXXXXX --issuer <issuer UUID>
# or Apple ID (prompts for the app-specific password):
xcrun notarytool store-credentials conduit-desktop-notary \
  --apple-id <email> --team-id <team ID>
```

### 3. The Sparkle EdDSA key

Every update and the appcast itself are signed with one EdDSA (ed25519) key
pair. Installed copies trust only the public key their Info.plist carries,
so **the key is made once and never changes** (see
[Losing or rotating the key](#losing-or-rotating-the-sparkle-key)). Use
Sparkle's own `generate_keys` from the pinned Sparkle release; it creates
the key in the login keychain:

```sh
d="$(bash -c '. desktop/packaging/macos/lib.sh && sparkle_dir')"   # Sparkle 2.10.1, checksum-verified
"$d/bin/generate_keys" --account conduit-desktop                   # creates the key; prints the public key
"$d/bin/generate_keys" --account conduit-desktop -p                # prints the public key again
"$d/bin/generate_keys" --account conduit-desktop -x sparkle-private-key.txt   # exports the private key (base64 seed)
```

Then store both halves and check that they belong together:

```sh
gh variable set SPARKLE_PUBLIC_ED_KEY --body "$("$d/bin/generate_keys" --account conduit-desktop -p)"
gh secret set SPARKLE_ED_PRIVATE_KEY < sparkle-private-key.txt
bash -c '. desktop/packaging/macos/lib.sh && sparkle_public_key' < sparkle-private-key.txt
# must print the same public key
```

Where the private key lives afterwards is your choice; the release only
needs the secret:

- **Keychain:** keep it under the `conduit-desktop` account (a release can
  then also be signed on this Mac), and put `sparkle-private-key.txt` in an
  offline backup.
- **Exported file only:** put `sparkle-private-key.txt` in an offline
  backup, then delete the keychain item "Private key for signing Sparkle
  updates" (account `conduit-desktop`) in Keychain Access. To use it on a
  Mac again: `generate_keys --account conduit-desktop -f sparkle-private-key.txt`.

Either way, do not leave `sparkle-private-key.txt` on disk, and never
commit either half. The `--account` keeps this key apart from any other
Sparkle app's on the same Mac.

### 4. Provisioning profiles (optional: the widget)

macOS lists the desktop widget in its gallery only when provisioning
profiles vouch for the app's and the widget's entitlements (app group).
Without them the release still works and ships the widget unlisted. To add
them: Developer ID provisioning profiles for `app.cogwheel.conduit.desktop`
and `app.cogwheel.conduit.desktop.widget` with the App Groups capability
(BUILDING-DESKTOP.md, "The desktop widget"), then:

```sh
base64 -i Conduit.provisionprofile | gh secret set MACOS_APP_PROVISIONING_PROFILE
base64 -i ConduitWidget.provisionprofile | gh secret set MACOS_WIDGET_PROVISIONING_PROFILE
```

### 5. Check the certificate and the credentials on this Mac

Before the first tag, run the whole release path locally on a test bundle
id. It builds, signs with the Developer ID identity, notarizes and staples
the app and the DMG, and checks Gatekeeper, the signatures and the tickets:

```sh
desktop/packaging/macos/release-local.sh \
  --identity <the SHA-1 from step 1> --keychain-profile conduit-desktop-notary
```

It refuses an identity that is not Developer ID Application, a notary
profile that cannot sign in, and the release bundle id. The Sparkle key is
a throwaway one made for the run (the bundle is not for distribution). It
ends with `spctl` reporting `source=Notarized Developer ID`.

### 6. A dry run on GitHub

Actions › Release Desktop › Run workflow runs the whole build as a
rehearsal: ad-hoc signature, a test bundle id, a throwaway Sparkle key, no
secrets, nothing published. It is the cheapest way to find out whether the
runner image (Xcode 26+), the disk and the time limit hold before a real
tag. `desktop.yml`'s bundle job runs the same rehearsal on every pull
request that touches the desktop app.

## Secrets and variables

| Name | Kind | Holds | Needed |
| --- | --- | --- | --- |
| `MACOS_DEVELOPER_ID_P12` | secret | base64 of the `.p12` with the Developer ID Application certificate and its private key | always |
| `MACOS_DEVELOPER_ID_P12_PASSWORD` | secret | the `.p12`'s export password | always |
| `MACOS_NOTARY_API_KEY` | secret | the App Store Connect API key, the text of `AuthKey_<ID>.p8` | notarization, option A |
| `MACOS_NOTARY_API_KEY_ID` | secret | that key's ID | option A |
| `MACOS_NOTARY_API_ISSUER_ID` | secret | the team's issuer ID | option A |
| `MACOS_NOTARY_APPLE_ID` | secret | the Apple ID (email) that notarizes | notarization, option B |
| `MACOS_NOTARY_APP_PASSWORD` | secret | an app-specific password for it | option B |
| `SPARKLE_ED_PRIVATE_KEY` | secret | Sparkle's private EdDSA key (`generate_keys -x`) | always |
| `SPARKLE_PUBLIC_ED_KEY` | variable | the matching public key (it ends up in every Info.plist) | always |
| `MACOS_APP_PROVISIONING_PROFILE` | secret | base64 of the app's Developer ID provisioning profile | optional (widget listed) |
| `MACOS_WIDGET_PROVISIONING_PROFILE` | secret | base64 of the widget extension's | optional (widget listed) |
| `DESKTOP_MACOS_RUNNER` | variable | another runner image for the macOS jobs (default `macos-26`) | optional |

Either option A or option B is needed for notarization; with both, A is
used. The `GITHUB_TOKEN` creates the draft release (`contents: write`, in
that job only) and, when it is published, updates the feed. The workflow
reads every secret only in the step that needs it, after the build, and
fails within a minute (before building) when one is missing or when the
Sparkle private key does not belong to `SPARKLE_PUBLIC_ED_KEY`.

## Making a release

1. **Version.** `X.Y.Z` (no beta). `CFBundleShortVersionString` is the
   version, `CFBundleVersion` the build number `X*1000000 + Y*10000 + Z*100
   + 99` (BUILDING-DESKTOP.md, "Versions and build numbers"), which is what
   Sparkle compares.
2. **Tag and push** the commit to release (on `main`):

   ```sh
   git tag desktop-v1.2.0 && git push origin desktop-v1.2.0
   ```

3. **Wait for the draft.** `release-desktop.yml` › job *build* takes about
   an hour (a cold GPUI build, whisper, notarization twice). It ends with a
   **draft** release `desktop-v1.2.0` carrying:
   - `Conduit-1.2.0.dmg`, signed, notarized and stapled;
   - `Conduit-1.2.0-dSYMs.zip`, the debug symbols (see below);
   - `appcast.xml`, the signed feed with the new item on top;
   - `SHA256SUMS.txt`.

   The run also keeps the notary reports and the codesign report as an
   artifact for 30 days.
4. **Check the draft.** Download the DMG on a Mac that has never seen a
   development build: it opens without a warning, the app starts, Settings ›
   About shows the version. Write the release notes into the draft.
5. **Publish** it, never as "Latest" (that stays the mobile app's):

   ```sh
   gh release edit desktop-v1.2.0 --draft=false --latest=false
   ```

   (In the web UI: untick "Set as the latest release" before Publish.)
6. **The feed goes live.** Publishing starts job *feed*: it checks that the
   draft's `appcast.xml` matches `SHA256SUMS.txt`, that its newest item is
   this version at this release's DMG (which now downloads), and that it
   keeps every item the live feed has; then it uploads it to the fixed
   prerelease `desktop-appcast` (made on the first release). Installed
   copies pick the update up on their next daily check, or at once with
   Conduit › Check for Updates….

Releases run one at a time. Publish each draft before tagging the next
release: a draft's appcast is made from the live feed at build time, and
the feed job refuses one that would drop a release published since.

## What the workflow checks

Before it signs anything, `bundle.sh verify --release` (and the same for a
rehearsal) checks:

- `LSMinimumSystemVersion` 14.0; every Mach-O file is **arm64 only** with a
  minimum macOS of **14.0 or lower** (Sparkle's are 12.0, conduitd's
  libsqlite3 13.0), and the five binaries built here (the app, the widget
  and its library, the Share extension, the whisper library) target
  exactly 14.0;
- those five are **stripped**, each with a **dSYM of the same UUID**, and
  the app's dSYM has line tables;
- the signature: `codesign --verify --deep --strict`, the hardened runtime,
  one team on every Mach-O file, the entitlements, the widget's and the
  Share extension's sandbox and app group;
- Gatekeeper: `spctl` accepts the app and the DMG, and both carry a
  stapled notarization ticket;
- Info.plist, the privacy prompts and the App Intents strings in 14
  languages, the icon (asset catalog and `.icns`);
- Sparkle: embedded, thinned to arm64, signed in Sparkle's order, with
  `SURequireSignedFeed`.

Then `smoke.sh --launch` starts the signed app on a throwaway profile and
checks the bundled conduitd, and `appcast.sh` checks that:

- the private key belongs to `SPARKLE_PUBLIC_ED_KEY` and to the
  `SUPublicEDKey` of the app inside the DMG;
- the new item is this version and build, with
  `sparkle:minimumSystemVersion` 14.0 and `sparkle:hardwareRequirements`
  arm64, at the release's download URL;
- its EdDSA signature verifies against the DMG, and the feed's own
  signature verifies;
- no item is on a channel;
- the feed keeps every item of the one it started from, and the new item
  is the DMG's length and the newest build (`check_appcast.py`). A new feed
  is started only when none was ever published: a failed lookup stops the
  release.

`release_test.sh` (run by `desktop.yml` on every pull request) checks these
feed safeguards and the publishing ones against synthetic feeds.

## Rehearsals

`bundle.sh --rehearsal` runs the release path on a **test bundle id** with
the release's strictness (Sparkle key, icon, stripping, dSYMs) and any
identity. With a Developer ID identity it notarizes as a release does
(`release-local.sh` is that, in one command). With an Apple Development or
ad-hoc identity it skips notarization, and every step says
`REHEARSAL … NOT notarized; not for distribution`. `--release` itself
refuses test bundle ids, `--test-env` and Apple Development identities.

```sh
CONDUIT_SIGN_IDENTITY=<Apple Development SHA-1> SPARKLE_PUBLIC_ED_KEY=<throwaway> \
  desktop/packaging/macos/bundle.sh all --rehearsal --version 1.0.0 \
  --bundle-id app.cogwheel.conduit.desktop.rehearsal \
  --test-env CONDUIT_FLAVOR=dev --test-env CONDUIT_USER_DATA=/tmp/r/user-data \
  --test-env CONDUIT_LOGS=/tmp/r/logs
```

### An update, end to end, on one Mac

Sparkle can be tested without touching the real app or the real feed:

1. A throwaway key pair, outside the keychain and the repository:
   `openssl genpkey -algorithm ed25519 -outform DER -out k.der`; the private
   key is `tail -c 32 k.der | base64`, the public key
   `openssl pkey -inform DER -in k.der -pubout -outform DER | tail -c 32 | base64`.
2. Build versions N and N+1 as rehearsals (above) with
   `SPARKLE_PUBLIC_ED_KEY=<public>` and
   `CONDUIT_APPCAST_URL=http://127.0.0.1:<port>/appcast.xml`.
3. With the throwaway private key in the environment
   (`export SPARKLE_ED_PRIVATE_KEY=<private>`), add N+1 to a new feed and
   serve that folder (`appcast.sh` copies the DMG next to the feed):

   ```sh
   appcast.sh --dmg <N+1 DMG> --version <N+1> --fresh \
     --download-url-prefix http://127.0.0.1:<port>/ --work /tmp/feed
   python3 -m http.server --bind 127.0.0.1 <port> --directory /tmp/feed
   ```
4. Copy N into a scratch folder and start it. Conduit › Check for Updates…
   shows Sparkle's "A new version of Conduit is available"; Install Update
   downloads it, checks its signature, and "Install and Relaunch" brings up
   N+1 from the same place. The app log says
   `updates: found …`, `downloaded`, `installing`, `relaunching`.
5. Afterwards unregister the test bundles from Launch Services
   (`lsregister -u <path>`, and `pluginkit -r` for their extensions).

A feed signed with another key, or an item whose signature does not match
its DMG, is refused (Sparkle shows an error and the app stays as it was).

To drive these steps from a script instead of by hand, the app's `--probe`
starts the check (`check-for-updates`) and presses Sparkle's buttons
(`press <title>`). The probe belongs to the test harness, which release
builds leave out, so build N and N+1 with `--test-harness` as well: every
step then says "harness build, not for distribution", `verify` checks that
the harness is in, and `--release` and Developer ID identities refuse the
flag. Such a bundle is never published.

## Platform targets

- **Apple silicon only.** `release.env` `ARCH=arm64`; Rust builds
  `aarch64-apple-darwin`, whisper and the Swift parts build for arm64, and
  Sparkle's universal binaries are thinned. The appcast item carries
  `sparkle:hardwareRequirements` arm64, so an Intel Mac is never offered
  an update.
- **macOS 14 Sonoma or later.** `release.env` `MACOS_MIN=14.0` is
  `LSMinimumSystemVersion`, `MACOSX_DEPLOYMENT_TARGET` for Rust (and the
  App Intents and FoundationModels Swift it links), `-target
  arm64-apple-macos14.0` for the widget and the Share extension, and
  `CMAKE_OSX_DEPLOYMENT_TARGET` for whisper. conduitd comes from `dart
  build cli` and its own floor (14.0 with the current Dart SDK; libsqlite3
  13.0), which `verify` holds to 14.0 or lower. The appcast item carries
  `sparkle:minimumSystemVersion` 14.0.
- **Build machine.** Xcode 26 or later (the FoundationModels framework is
  linked weakly, so it needs the macOS 26 SDK even though the app runs
  from 14). Xcode 27 or later (the macOS 27 SDK) for the complete Apple
  On-Device engine: built with Xcode 26, replies on macOS 27 report no
  token usage and macOS 27's model errors read as a generic failure.
  `apple_models.sh sdk-gaps` lists what the active Xcode leaves out; the
  build prints it as cargo warnings, and both workflows put it on the run
  as a warning annotation and in the job summary. The workflows pick the
  runner image's newest Xcode, so they use Xcode 27 once the image has
  it.

## Stripping and dSYMs

`bundle.sh build` compiles the release with line tables
(`CARGO_PROFILE_RELEASE_DEBUG=line-tables-only`, `split-debuginfo =
packed`, so rustc writes `conduit-desktop.dSYM`) and no stripping by rustc.
After assembling, it keeps a dSYM for each binary it built in
`<out>/dSYMs/` and strips the bundled copies:

- with **rust-objcopy** when the toolchain has the `llvm-tools` component
  (the release workflow adds it): `--strip-all` for executables,
  `--discard-all` for libraries, as rustc itself strips;
- otherwise with **Apple's `strip`** (`strip`, `strip -x`).

`llvm-tools` stays out of `rust-toolchain.toml` so that not every checkout
downloads it; `rustup component add llvm-tools` in `desktop/` turns the
first path on locally. conduitd (a Dart AOT executable, which stripping
would break), libsqlite3 and Sparkle are left as they come.

`Conduit-<version>-dSYMs.zip` is attached to every release. To symbolicate
a crash report's frames from the app (load address from the report's
"Binary Images"):

```sh
atos -arch arm64 -o Conduit.dSYM/Contents/Resources/DWARF/Conduit -l <load address> <addresses…>
dwarfdump --uuid Conduit.dSYM     # matches the report's UUID for Conduit
```

## Sparkle

`release.env` pins Sparkle (2.10.1, SHA-256 checked). Every release bundle
sets:

| Key | Value |
| --- | --- |
| `SUFeedURL` | `https://github.com/<repo>/releases/download/desktop-appcast/appcast.xml` |
| `SUPublicEDKey` | `SPARKLE_PUBLIC_ED_KEY` |
| `SUEnableAutomaticChecks` | `true`, daily (`SUScheduledCheckInterval` 86400) |
| `SUVerifyUpdateBeforeExtraction` | `true`: the EdDSA signature is checked before unpacking |
| `SURequireSignedFeed` | `true`: an appcast not signed with the same key is refused |

The feed lives where `release.env`'s `APPCAST_HOSTING` says:
`release-asset`, the fixed prerelease `desktop-appcast` (chosen; `pages` and
`branch` stay implemented as alternatives, described in `release.env`).
`releases/latest/download/appcast.xml` would not do: "latest" is the
repository's newest release, usually the mobile app's.

The feed URL never changes once a version has shipped. To move it, keep
serving the old URL and ship one update whose Info.plist names the new one.
`appcast.sh` and `publish-appcast.sh` are the two halves (sign, upload);
the workflow runs the first in the build job and the second when the draft
is published.

## When something goes wrong

**The build job fails.** Nothing was published. A passing failure (the
network, a notarization queue): re-run the job; a draft it already made
takes the new build's files, and a published release is never changed. A
fix in the code: delete the tag (`git push --delete origin
desktop-vX.Y.Z`, `git tag -d desktop-vX.Y.Z`) and the draft, and tag again.
Notarization failures print `notarytool log` in the job log.

**A published release is bad.** Installed copies that already updated keep
it until the next release. To stop offering it, put the previous feed back:
download `appcast.xml` from the previous `desktop-v*` release and run
`desktop/packaging/macos/publish-appcast.sh appcast.xml --push` (with `gh`
signed in). Then ship a fixed X.Y.Z+1.

**The feed job refuses** ("the live feed has builds this appcast lacks"):
a release was published after this draft was built. Delete this draft and
its tag, and tag again; the new draft starts from the current feed.

### Losing or rotating the Sparkle key

Installed copies accept only updates and feeds signed with the key in their
Info.plist. To rotate deliberately, ship one release still signed with the
old key whose Info.plist carries the new public key; every later release
signs with the new one. If the private key is lost, plan for installed
copies not updating themselves any more (Sparkle's documentation on key
rotation describes the narrow exceptions): publish a release asking people
to download the new version by hand. Keep the private key in two places
(the secret and an offline backup).
