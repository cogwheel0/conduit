# Releasing Conduit Desktop

How a Conduit Desktop release is made for macOS, Windows and Linux, and the
one-time setup it needs. Building and testing the app day to day is in
[BUILDING-DESKTOP.md](BUILDING-DESKTOP.md).

**What ships:** one `desktop-v*` tag releases every OS together, in one
GitHub release. There are no beta releases; a `-beta.N` tag is refused.

- **macOS:** `Conduit-<version>.dmg`, holding `Conduit.app` for **Apple
  silicon only** (arm64) on **macOS 14 Sonoma or later**. It is signed with
  a Developer ID Application certificate, notarized, and stapled. It updates
  itself through **Sparkle 2** from **one stable channel**: a single appcast
  on GitHub Releases.
- **Windows:** `Conduit-<version>-windows-x64-setup.exe`, a per-user
  installer for x64 Windows 10 or later, **unsigned** for now (the release
  notes say how to get past SmartScreen). It updates itself through
  WinSparkle from its own signed feed.
- **Linux:** `conduit-desktop_<version>-1_amd64.deb` and
  `conduit-desktop-<version>-1.x86_64.rpm` (x86_64). The app says when a
  newer version is out, from its own signed feed; the package manager
  installs it.

All or nothing: a draft is complete only once every OS's files and feeds
are on it and verify, and no feed goes live for a release that lacks any of
them ([The publish gate](#the-publish-gate)). GitHub lets no workflow stop
a person publishing a draft, so the check made at publication runs after
the release is public: a release it refuses is put back to a draft.

**Contents**

- [The release at a glance](#the-release-at-a-glance)
- [One-time setup](#one-time-setup)
- [Secrets and variables](#secrets-and-variables)
- [Making a release](#making-a-release)
- [The publish gate](#the-publish-gate)
- [The release notes](#the-release-notes)
- [What the workflow checks](#what-the-workflow-checks)
- [Rehearsals](#rehearsals)
- [Platform targets](#platform-targets)
- [Stripping and dSYMs](#stripping-and-dsyms)
- [Sparkle](#sparkle)
- [Windows and Linux updates](#windows-and-linux-updates)
- [When something goes wrong](#when-something-goes-wrong)

## The release at a glance

```text
git tag desktop-v1.2.0 && git push origin desktop-v1.2.0
   │
   ▼  release-desktop.yml
   "winlinux-config": the Windows and Linux keys and rotation variables (every build waits for it)
   "draft": the tag's DRAFT release, its notes saying it is still being built
   │
   ├─ "build" (macOS, Apple silicon, Xcode 26+)
   │    build (no secrets) ─ strip, keep dSYMs ─ import Developer ID into a temporary keychain
   │    ─ sign inside out ─ notarize + staple the app ─ DMG ─ sign, notarize + staple it
   │    ─ verify ─ smoke --launch ─ sign the appcast ─ the Mac's files onto the draft
   ├─ "notices" ─ "build-windows" (installer) + "build-linux" (.deb, .rpm), no secrets
   │    ─ "winlinux-feeds": each OS's feed signed with its own key
   │    ─ "smoke-windows" + "smoke-linux": installed on fresh runners
   │
   ▼  "release": the Windows and Linux files onto the draft (step 3 of "Making a release" lists them)
   │  then the publish gate on everything the draft carries, then the release notes
   │
   ▼  a person checks the draft and publishes it
   release-desktop.yml, job "feed"
   the publish gate again (a release it refuses goes back to a draft) ─ each feed against the live one
   ─ appcast.xml, appcast-windows.xml, appcast-linux.xml → the fixed release `desktop-appcast`
   │
   ▼  installed copies find 1.2.0 on their next check (daily, or Check for Updates…)
```

Nothing reaches installed copies until the draft is published, and no feed
changes unless the gate passes.

## One-time setup

Do these once, on a Mac you trust. None of the values below goes into the
repository; they go into the repository's Actions secrets and variables
(Settings › Secrets and variables › Actions), or into `gh secret set`, which
reads them from a prompt or from stdin.

### 1. The Developer ID Application certificate

1. On the Mac you trust, make the certificate signing request: Keychain
   Access › Certificate Assistant › Request a Certificate From a Certificate
   Authority…, "Saved to disk". This makes the private key, in this Mac's
   login keychain.
2. In the Apple Developer account (Certificates, Identifiers & Profiles ›
   Certificates › +), create a **Developer ID Application** certificate
   (only the team's Account Holder can) with that request. Use the G2
   Sub-CA. Download it and open it on the same Mac, so it pairs with its
   private key in the login keychain (on another Mac it would be a
   certificate without a key, and no signing identity).
3. Find its SHA-1 (the identity is always named by its SHA-1 here, never by
   the name in the certificate):

   ```sh
   security find-identity -v -p codesigning | grep 'Developer ID Application'
   ```

4. Check it locally before you store it: make the notarization profile
   first (step 2, `conduit-desktop-notary`, which the check signs in with),
   then run "Check the certificate and the credentials on this Mac", below.
5. Export certificate and key: Keychain Access › My Certificates, select the
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
so **the key stays the same from one release to the next**; changing it
takes a bridge release (see
[Rotating the Sparkle key](#rotating-the-sparkle-key)). Use
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

### 6. The Windows and Linux update keys

Each OS has its own EdDSA key pair, made like the Sparkle key: the commands
and the names are in [Windows and Linux updates](#windows-and-linux-updates).
A tag fails within a minute while any of `WINDOWS_ED_PRIVATE_KEY`,
`LINUX_ED_PRIVATE_KEY`, `WINDOWS_PUBLIC_ED_KEY` and `LINUX_PUBLIC_ED_KEY` is
missing, before anything builds, the Mac's build included.

### 7. A dry run on GitHub

Actions › Release Desktop › Run workflow runs the whole release as a
rehearsal, every OS: the Mac's build with an ad-hoc signature on a test
bundle id, the Windows installer and the Linux packages, throwaway update
keys and feeds for version 0.0.0 that the install smokes read on 127.0.0.1,
and the publish gate on all of it, which must pass and must refuse each file
in turn when that file is missing. No secret is read, and no release or tag
is made or changed. It is the cheapest way to find out whether the runner
images (Xcode 26+, Windows Server 2025, Ubuntu 22.04), the disk and the time
limits hold before a real tag. `desktop.yml`'s bundle job runs the Mac's
rehearsal on every push to `main` that touches the desktop app, and on a
pull request into `main` that changes the packaging (see
[BUILDING-DESKTOP.md](BUILDING-DESKTOP.md) for which); a stacked pull
request skips it unless it has the `full-ci` label. Its Windows and Linux
package and install-smoke jobs run on the same paths, whatever the base.

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
| `SPARKLE_NEXT_PUBLIC_ED_KEY` | variable | the new public key a key rotation's bridge release carries | key rotation only, with `SPARKLE_KEY_ROTATION_TAG` |
| `SPARKLE_KEY_ROTATION_TAG` | variable | the bridge release's tag (`desktop-vX.Y.Z`) | key rotation only, with `SPARKLE_NEXT_PUBLIC_ED_KEY` |
| `MACOS_APP_PROVISIONING_PROFILE` | secret | base64 of the app's Developer ID provisioning profile | optional (widget listed) |
| `MACOS_WIDGET_PROVISIONING_PROFILE` | secret | base64 of the widget extension's | optional (widget listed) |
| `DESKTOP_MACOS_RUNNER` | variable | another runner image for the macOS jobs (default `macos-26`) | optional |
| `WINDOWS_ED_PRIVATE_KEY` | secret | the Windows feed's private EdDSA key ([Windows and Linux updates](#windows-and-linux-updates)) | Windows releases |
| `WINDOWS_PUBLIC_ED_KEY` | variable | its public key, built into every Windows app | Windows releases |
| `LINUX_ED_PRIVATE_KEY` | secret | the Linux feed's private EdDSA key | Linux releases |
| `LINUX_PUBLIC_ED_KEY` | variable | its public key, built into every Linux app | Linux releases |
| `WINDOWS_NEXT_PUBLIC_ED_KEY`, `WINDOWS_KEY_ROTATION_TAG` | variables | a Windows key rotation's next public key and bridge tag | a Windows key rotation only, together |
| `LINUX_NEXT_PUBLIC_ED_KEY`, `LINUX_KEY_ROTATION_TAG` | variables | a Linux key rotation's next public key and bridge tag | a Linux key rotation only, together |
| `WINDOWS_RETIRED_PUBLIC_ED_KEY` | variable | the Windows public key before a key swap, which the published Windows feed is still signed with | the one release after a Windows key swap |
| `LINUX_RETIRED_PUBLIC_ED_KEY` | variable | the same for Linux | the one release after a Linux key swap |

Either option A or option B is needed for notarization; with both, A is
used. The `GITHUB_TOKEN` creates the draft release and adds the files to it
(`contents: write`, in those jobs only) and, when it is published, updates
the feeds. The builds themselves (cargo, dart, cmake) get no secret. Two
steps read secrets before them, so the run fails within a minute instead
of after the builds: the Mac's configuration check, which sees whether each
secret is set and reads `SPARKLE_ED_PRIVATE_KEY` to check that it belongs
to `SPARKLE_PUBLIC_ED_KEY` (and the rotation variables, see
[Rotating the Sparkle key](#rotating-the-sparkle-key)); and job
`winlinux-config`, which does the same for `WINDOWS_ED_PRIVATE_KEY` and
`LINUX_ED_PRIVATE_KEY` (see [Rotating the Windows or Linux
key](#rotating-the-windows-or-linux-key)). Every other secret is read after
the builds, only in the step that needs it: the two Windows and Linux
private keys again in job `winlinux-feeds`, which signs the feeds.

## Making a release

1. **Version.** `X.Y.Z` (no beta). `CFBundleShortVersionString` is the
   version, `CFBundleVersion` the build number `X*1000000 + Y*10000 + Z*100
   + 99` (BUILDING-DESKTOP.md, "Versions and build numbers"), which is what
   Sparkle compares.
2. **Tag and push** the commit to release (on `main`):

   ```sh
   git tag desktop-v1.2.0 && git push origin desktop-v1.2.0
   ```

3. **Wait for the draft to complete.** The run makes the **draft** release
   `desktop-v1.2.0` at once, its notes saying it is still being built. Job
   *build* (macOS) takes about an hour (a cold GPUI build, whisper,
   notarization twice) and puts the Mac's files on the draft; the Windows
   and Linux builds and their install smokes run alongside. Job
   *release* ends the run: it adds the Windows and Linux files, runs [the
   publish gate](#the-publish-gate) on everything the draft carries, and
   only then replaces the notes with the release notes
   (`desktop/packaging/release-notes.md`, [below](#the-release-notes)). The
   draft then carries:
   - `Conduit-1.2.0.dmg`, signed, notarized and stapled;
   - `Conduit-1.2.0-dSYMs.zip`, the debug symbols (see below);
   - `appcast.xml`, the signed Mac feed with the new item on top;
   - `SHA256SUMS.txt`, the Mac files' checksums;
   - `Conduit-1.2.0-windows-x64-setup.exe`, the unsigned Windows installer;
   - `conduit-desktop_1.2.0-1_amd64.deb` and
     `conduit-desktop-1.2.0-1.x86_64.rpm`;
   - `appcast-windows.xml` and `appcast-linux.xml`, each OS's signed feed
     with the new item on top;
   - `THIRD_PARTY_NOTICES-windows.md` and `THIRD_PARTY_NOTICES-linux.md`,
     the licences of what the Windows and Linux builds include;
   - `SHA256SUMS-windows.txt` and `SHA256SUMS-linux.txt`.

   The run also keeps the notary reports and the codesign report as an
   artifact for 30 days. A draft whose notes still say it is being built is
   not complete: the run is still going, or a job failed (the run says
   which; see [When something goes wrong](#when-something-goes-wrong)).
4. **Check the draft.** Download the DMG on a Mac that has never seen a
   development build: it opens without a warning, the app starts, Settings ›
   About shows the version. On a clean Windows VM, the installer passes
   SmartScreen with More info › Run anyway, the app starts and About shows
   the version; on Ubuntu and Fedora VMs, the .deb and the .rpm install
   with the package manager and the app starts. (The install smokes did
   this on fresh runners; a VM is a real desktop.) Add anything worth saying
   to the release notes.
5. **Publish** it, only once it has its release notes (the gate passed on
   the draft), and never as "Latest" (that stays the mobile app's):

   ```sh
   gh release edit desktop-v1.2.0 --draft=false --latest=false
   ```

   (In the web UI: untick "Set as the latest release" before Publish.)
6. **The feeds go live.** Publishing starts job *feed*, once the release
   is public. It runs the publish gate again on the release's files; a
   release it refuses goes back to a draft and no feed changes. Then it
   checks that the draft's `appcast.xml` matches `SHA256SUMS.txt`, that its
   newest item is
   this version at this release's DMG, and that it keeps every item the
   live feed has; it downloads that DMG from its public URL and checks it
   against `SHA256SUMS.txt` and against the item's signed enclosure (its
   length, and its EdDSA signature with `SPARKLE_PUBLIC_ED_KEY`), so a DMG
   swapped on the draft never goes live. It checks the Windows and Linux
   feeds the same way: each keeps every item its live feed has (none on
   that OS's first release), and the installer, the .deb and the .rpm
   download from their public URLs as the files the gate checked. Only
   then does anything go live. `publish-appcast.sh` checks
   the feed's own signature with `SPARKLE_PUBLIC_ED_KEY` (installed copies
   refuse a feed their key did not sign), so an appcast swapped on the
   draft, its checksum with it, never goes live either, and puts the feed
   on the fixed prerelease `desktop-appcast`. The first time, that release
   is made as a **draft**, `appcast.xml` is uploaded to it and read back,
   and only then is it published: a run that fails on the way leaves a
   draft no installed copy reads, and the next run takes it over (re-run
   the feed job). Later publications upload the new feed under a name of
   their run's own (`appcast.next-….xml`) and swap that file in by two
   renames, the last one kept as `appcast.previous.xml`. Then
   `publish-appcast.sh --os windows` and `--os linux` do the same for
   `appcast-windows.xml` and `appcast-linux.xml` beside it, each checked
   with its own OS's public key (`appcast-windows.previous.xml` and so on).
   Installed copies pick the update up on their next daily check, or at
   once with Check for Updates….

Publish each draft, and wait for its feed job to pass, before tagging the
next release: a draft's feeds are made from the live ones at build time,
and the feed job refuses one that would drop a release published since.
Feed publications run one at a time, in order, in their own queue
(`queue: max`): no other run (a mobile release, a dry run) can cancel
one, and a newer publication never replaces one still waiting.

Leave immutable releases off for the repository (Settings › General ›
Releases). The update feed lives in one published release,
`desktop-appcast` (a draft only until its first `appcast.xml` is checked),
whose `appcast.xml` is replaced at every publication; immutable releases
would refuse that change, so the first update after turning them on could
not be published. A re-run of the build job replaces
a draft's files only after looking the draft up again right before each
one, and refuses once it is published; a release published in the moment
between that look and the upload is the one case this does not close.

## The publish gate

One tag releases every OS, and no OS's feed goes live without the others.
`desktop/packaging/release_gate.sh check` decides it, on the release's
files as GitHub serves them, and lists every problem it finds:

- every file in [Making a release](#making-a-release), step 3, is there
  (`release_gate.sh assets --os mac|windows|linux --version X.Y.Z` prints
  the exact names);
- each checksum file lists exactly its OS's other files, and each matches
  (one that cannot be read refuses the release);
- each feed is signed with the key installed copies of that OS have
  (`SPARKLE_PUBLIC_ED_KEY`, `WINDOWS_PUBLIC_ED_KEY`,
  `LINUX_PUBLIC_ED_KEY`), and its newest item is this version: the Mac's
  at this release's DMG, with its length and EdDSA signature, the Windows
  one at this release's installer, likewise; the Windows and Linux items
  name this release's page;
- each OS's notices were made for it.

It runs twice:

- **Before publication.** At the end of the tag's run, job *release* runs
  it on the draft once every file is on it, and only then writes the
  release notes. A draft whose notes still say it is being built is
  incomplete, and the run says why. This is the check to rely on: publish
  only a draft that has its notes.
- **After publication.** GitHub lets no workflow stop a person publishing a
  draft, so job *feed* starts once the release is already public, and runs
  the gate again before any feed changes. A release it refuses is **put back
  to a draft** and no feed changes, so installed copies are offered
  nothing. Until then, and if putting it back fails (the job says so; do it
  by hand), its files are public. A gate that could not run (a lookup or a
  download failed) changes nothing, the release stays public, and the job
  says so: re-run it.

The dry run (workflow_dispatch) runs it on the dry run's files, which must
pass, then takes each file away in turn and checks that the gate refuses
the release and names that file. `release_gate_test.sh`, which
`desktop.yml` runs, checks each refusal against synthetic releases.

## The release notes

Job *release* writes them from `desktop/packaging/release-notes.md`, with
the version in place of `@VERSION@`: what each OS's download is and how to
install it, and the release's assets. While the Windows installer is
unsigned they carry the SmartScreen note from
[BUILDING-DESKTOP.md](BUILDING-DESKTOP.md) ("Unsigned installers"): check
the download against `SHA256SUMS-windows.txt`, then choose **More info**,
then **Run anyway**. Edit the template for what every release says, and the
draft for what one release says.

## What the workflow checks

After the app and the DMG are signed, notarized and stapled,
`bundle.sh verify --release` (and the same for a rehearsal) checks that the
bundle is a release build (the release bundle id, no test environment,
this version; `bundle.sh sign --release` refuses another as well), and:

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
  `SUPublicEDKey` of the app inside the DMG (a bridge release's app
  carries `SPARKLE_NEXT_PUBLIC_ED_KEY` instead, and no other key);
- the new item is this version and build, with
  `sparkle:minimumSystemVersion` 14.0 and `sparkle:hardwareRequirements`
  arm64, at the release's download URL;
- its EdDSA signature verifies against the DMG, and the feed's own
  signature verifies, both with Sparkle's `sign_update` and with the check
  the feed job makes before it publishes (`lib.sh` `verify_feed`, which
  needs only the public key);
- no item is on a channel;
- the feed keeps every item of the one it started from, and the new item
  is the DMG's length and the newest build (`check_appcast.py`). A new feed
  is started only when none was ever published: a failed lookup stops the
  release.

`release_test.sh` (run by `desktop.yml`'s workspace job) checks these
feed safeguards and the publishing ones against synthetic feeds and keys.
On macOS it also checks `verify_feed` against feeds the pinned Sparkle's
`sign_update` signs, and runs `appcast.sh` through its `generate_appcast`
for a release, a bridge release and the release after it.

For Windows and Linux, `build.ps1` and `package.sh` check the install
folder (complete, no test harness, the notices made for that OS), the
install smokes install each package on a fresh runner and run the app's
`--smoke` pass, `winlinux-appcast.sh` checks each OS's new feed as
[Windows and Linux updates](#windows-and-linux-updates) says, and the
publish gate checks the lot.

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

1. A throwaway key pair, outside the keychain and the repository, with an
   openssl that does Ed25519 (macOS's own does not):
   `openssl="$(bash -c '. desktop/packaging/macos/lib.sh; ed25519_openssl')"`, then
   `"$openssl" genpkey -algorithm ed25519 -outform DER -out k.der`; the
   private key is `tail -c 32 k.der | base64`, the public key
   `"$openssl" pkey -inform DER -in k.der -pubout -outform DER | tail -c 32 | base64`.
2. Build versions N and N+1 as rehearsals (above) with
   `SPARKLE_PUBLIC_ED_KEY=<public>` and
   `CONDUIT_APPCAST_URL=http://127.0.0.1:<port>/appcast.xml`.
3. With the throwaway private key in the environment
   (`export SPARKLE_ED_PRIVATE_KEY=<private>`), add N+1 to a new feed and
   serve that folder (`appcast.sh` copies the DMG next to the feed):

   ```sh
   desktop/packaging/macos/appcast.sh --dmg <N+1 DMG> --version <N+1> --fresh \
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
(`press <title>`). A `press` line runs once, when the probe reads it: the
driver waits until `<file>.panels.json` lists a button with that title
before it appends the line (a press for a button not shown yet is lost). The probe belongs to the test harness, which release
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
  as a warning annotation and in the job summary. The workflows keep the
  runner's active Xcode when it is 26 or later (they switch only from an
  older one, to the newest installed): for the complete macOS 27 support,
  use a runner image whose active Xcode is 27 (`DESKTOP_MACOS_RUNNER`), or
  select it on the runner.

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
| `SUPublicEDKey` | `SPARKLE_PUBLIC_ED_KEY` (a bridge release: `SPARKLE_NEXT_PUBLIC_ED_KEY`) |
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

## Windows and Linux updates

The Windows installer updates itself through WinSparkle, and the Linux app
says when a newer version exists and links to its release (it installs
nothing). Each has its **own EdDSA key** and its **own feed** beside the
Mac's, so a key or a feed of one OS never touches another's. The release
workflow builds each OS's packages with its public key built in, adds the
version to its feed in job *winlinux-feeds*, and publishes the feed with
the Mac's when the draft is published.

**The feeds**, on the same fixed release as the Mac's `appcast.xml`
(`release.env`'s hosting; `desktop/packaging/winlinux_feed.py url windows`
prints the URL), never moved once a version has shipped:

| File | Read by | Each item |
| --- | --- | --- |
| `appcast-windows.xml` | WinSparkle | the version, its build number as `sparkle:version` (as the Mac's), and the installer `Conduit-X.Y.Z-windows-x64-setup.exe` as the enclosure: its length, its EdDSA signature, `sparkle:os` windows-x64 and the arguments WinSparkle runs it with (`/SILENT /SP- /SUPPRESSMSGBOXES /NORESTART /RELAUNCH=1`) |
| `appcast-linux.xml` | the Linux notice | the version, its build number, and the release's page (`<link>`); nothing to download |

Both are Sparkle appcasts signed as the Mac's is: the bytes before the
last `<!-- sparkle-signatures:` block carry an EdDSA signature, which
`lib.sh verify_feed` checks. The Linux app refuses a feed without a valid
signature by its key; WinSparkle reads the feed without checking it, but
checks the installer's signature before running it, so whoever controls
the feed can hold an update back but can't push unsigned code.

**The keys** were made with Sparkle's `generate_keys` in the maintainer's
login keychain (service `https://sparkle-project.org`), under the accounts
`conduit-desktop-windows` and `conduit-desktop-linux`. The repository
needs these (also in [Secrets and variables](#secrets-and-variables)),
which the Windows and Linux release jobs read:

| Name | Kind | Holds |
| --- | --- | --- |
| `WINDOWS_ED_PRIVATE_KEY` | secret | Windows' private EdDSA key (`generate_keys --account conduit-desktop-windows -x`) |
| `WINDOWS_PUBLIC_ED_KEY` | variable | its public key, built into every Windows app (`build.ps1 -UpdatePublicKey`) |
| `LINUX_ED_PRIVATE_KEY` | secret | Linux's private EdDSA key (`--account conduit-desktop-linux -x`) |
| `LINUX_PUBLIC_ED_KEY` | variable | its public key, built into every Linux app (`package.sh --update-public-key`) |
| `WINDOWS_NEXT_PUBLIC_ED_KEY`, `WINDOWS_KEY_ROTATION_TAG` | variables | a Windows key rotation only, together |
| `LINUX_NEXT_PUBLIC_ED_KEY`, `LINUX_KEY_ROTATION_TAG` | variables | a Linux key rotation only, together |
| `WINDOWS_RETIRED_PUBLIC_ED_KEY`, `LINUX_RETIRED_PUBLIC_ED_KEY` | variables | the one release after that OS's key swap only |

Until all four of the first are set, a tag stops within a minute, before
anything builds. To set them (on the Mac whose login keychain holds the
keys):

```sh
d="$(bash -c '. desktop/packaging/macos/lib.sh && sparkle_dir')"
for os in windows linux; do
  OS="$(printf '%s' "$os" | tr a-z A-Z)"
  gh variable set "${OS}_PUBLIC_ED_KEY" --body "$("$d/bin/generate_keys" --account "conduit-desktop-$os" -p)"
  "$d/bin/generate_keys" --account "conduit-desktop-$os" -x "$os-private-key.txt"
  gh secret set "${OS}_ED_PRIVATE_KEY" < "$os-private-key.txt"
  # must print the same public key as the variable
  bash -c '. desktop/packaging/macos/lib.sh && sparkle_public_key' < "$os-private-key.txt"
  gh variable get "${OS}_PUBLIC_ED_KEY"
done
```

Put each `*-private-key.txt` in the offline backup with the Sparkle key,
and don't leave them on disk. Then run the dry run ([7. A dry run on
GitHub](#7-a-dry-run-on-github)) before the first tag.

**Adding a release to a feed** (what the release jobs run; nothing is
uploaded):

```sh
WINDOWS_ED_PRIVATE_KEY=… WINDOWS_PUBLIC_ED_KEY=… \
  desktop/packaging/winlinux-appcast.sh --os windows --version 1.2.0 \
  --installer Conduit-1.2.0-windows-x64-setup.exe
LINUX_ED_PRIVATE_KEY=… LINUX_PUBLIC_ED_KEY=… \
  desktop/packaging/winlinux-appcast.sh --os linux --version 1.2.0
```

It fetches the current feed (`--existing FILE` instead; `--fresh` or
`--allow-new` for an OS's first release), adds the version's item on top,
signs the installer and the feed with the private key (it reaches openssl
on stdin, never argv), and writes `desktop/target/feeds/<os>-<version>/`.
It adds to a feed only when that feed is signed with the key that signs
this release (or the one `--feed-public-key` names: see the rotation
below) and has its items only under its `<channel>`, where the apps read
them, so a feed someone else changed is never signed again. It stops
unless the private key belongs to `<OS>_PUBLIC_ED_KEY`, the version is a
stable one, the new item is the newest build, every earlier item is kept
exactly as it was, and `lib.sh`'s `verify_enclosure` (Windows) and
`verify_feed` accept the result with the public key alone. `desktop/packaging/winlinux_feed_test.sh` checks these
safeguards against keys it makes. CI's **Update feeds (rehearsal)** runs it,
then makes a throwaway key per OS: the rehearsal packages are built with
its public half and a feed on 127.0.0.1, and the install smokes serve a
feed it signed, which WinSparkle and the Linux notice read.

**In the release workflow**, job *winlinux-feeds* runs it for each OS with
the secrets, after the builds:

- **That OS's first release** (the feed release has neither
  `appcast-<os>.xml` nor `appcast-<os>.previous.xml`): `--allow-new`, so a
  new feed starts only when its URL answers 404; any other answer stops.
  A feed release with `appcast-<os>.previous.xml` but no `appcast-<os>.xml`
  is a publication that stopped half way, never a first release (see [A
  stale or missing appcast](#a-stale-or-missing-appcast)).
- **Later releases**: the published feed is fetched and added to
  (`--existing`), once it verifies with `<OS>_PUBLIC_ED_KEY`, or with
  `<OS>_RETIRED_PUBLIC_ED_KEY` on the first release after a key swap
  (`--feed-public-key`; see below).
- **A bridge release** (`<OS>_KEY_ROTATION_TAG` names the tag): the app is
  built with `<OS>_NEXT_PUBLIC_ED_KEY` and the item added with
  `--next-public-key`.

Job *winlinux-config* makes the same checks of the keys and the published
feeds before anything builds, so a missing or left-over variable stops the
run in a minute. When the draft is published, job *feed* checks each feed
against the live one again (it must keep every live item), checks that the
installer, the .deb and the .rpm download from the release as the files
the gate checked, and publishes each with `publish-appcast.sh --os`.

### Rotating the Windows or Linux key

As for the Mac ([Rotating the Sparkle key](#rotating-the-sparkle-key)),
through one **bridge release** per OS: signed with the current key (its
installer and the feed), its app built with the new public key. Copies that
install it trust only the new key; every later release is signed with it.

1. Make the new key pair under its own account
   (`generate_keys --account conduit-desktop-windows-next`, then `-x` for
   the backup).
2. Set `<OS>_NEXT_PUBLIC_ED_KEY` to its public key and
   `<OS>_KEY_ROTATION_TAG` to the bridge release's tag. That release's app
   is built with the next key (`build.ps1 -UpdatePublicKey`,
   `package.sh --update-public-key`), and its item is added with
   `winlinux-appcast.sh --next-public-key <next key>`, which signs with the
   current key and needs `<OS>_PUBLIC_ED_KEY` to be it. Job
   *winlinux-config* stops the run when only one of the two is set, when
   the tag is not the one being built, or when the next key is not a key or
   is the current one, as for the Mac.
3. Tag the bridge release, publish it, and wait for its feed job to pass
   (it checks the feed with `<OS>_PUBLIC_ED_KEY`, still the old key). Then
   keep the old public key for one more release, swap the keys and delete
   both rotation variables (Windows shown; Linux alike):

   ```sh
   gh variable set WINDOWS_RETIRED_PUBLIC_ED_KEY --body "$(gh variable get WINDOWS_PUBLIC_ED_KEY)"
   gh secret set WINDOWS_ED_PRIVATE_KEY < windows-next-private-key.txt
   gh variable set WINDOWS_PUBLIC_ED_KEY --body "$("$d/bin/generate_keys" --account conduit-desktop-windows-next -p)"
   gh variable delete WINDOWS_NEXT_PUBLIC_ED_KEY
   gh variable delete WINDOWS_KEY_ROTATION_TAG
   ```

4. The next release is signed with the new key, but the published feed it
   adds to is still signed with the old one: job *winlinux-feeds* checks it
   with `<OS>_RETIRED_PUBLIC_ED_KEY` (`winlinux-appcast.sh
   --feed-public-key`). Once that release's feed job has passed, delete
   `<OS>_RETIRED_PUBLIC_ED_KEY`. Left set, it stops the next release: the
   published feed is signed with the new key by then, and a retired key is
   never trusted longer than that one release.

What installed copies see: there is no safe mode like Sparkle's on the Mac.
WinSparkle offers the newest item only, so a Windows copy older than the
bridge that checks after the next release refuses that release's signature
and can't reach the bridge; it needs the installer from the release page.
A Linux copy older than the bridge can't check feeds signed with the new
key and stops showing the notice. Leave the bridge as the newest release
for a while (a few weeks) so most copies cross it. A **lost** Windows or
Linux key strands every copy that trusts it the same way, which is why the
backup matters.

## When something goes wrong

**A job of the tag's run fails.** Nothing was published, and the draft's
notes still say it is being built. *winlinux-config* failing names the
missing or wrong variable: set it, then re-run the run. A passing failure
(the network, a notarization queue, a runner): re-run the failed jobs
(GitHub runs the jobs after them again too); the draft takes the new
builds' files, and a published release is never changed. A fix in the
code: delete the tag (`git push --delete origin desktop-vX.Y.Z`, `git tag
-d desktop-vX.Y.Z`) and the draft, and tag again. Notarization failures
print `notarytool log` in the job log; an install smoke that fails keeps
its logs as an artifact.

**A published release is bad.** Installed copies that already updated keep
it until the next release. To stop offering it, put the previous feeds back:
download `appcast.xml`, `appcast-windows.xml` and `appcast-linux.xml` from
the previous `desktop-v*` release and, with `gh` signed in, run:

```sh
SPARKLE_PUBLIC_ED_KEY="$(gh variable get SPARKLE_PUBLIC_ED_KEY)" \
  desktop/packaging/macos/publish-appcast.sh appcast.xml --push
WINDOWS_PUBLIC_ED_KEY="$(gh variable get WINDOWS_PUBLIC_ED_KEY)" \
  desktop/packaging/macos/publish-appcast.sh appcast-windows.xml --push --os windows
LINUX_PUBLIC_ED_KEY="$(gh variable get LINUX_PUBLIC_ED_KEY)" \
  desktop/packaging/macos/publish-appcast.sh appcast-linux.xml --push --os linux
```

Each refuses a feed the current key did not sign (one from before a key
rotation), as installed copies would. Then ship a fixed X.Y.Z+1.

### The publish gate refuses a release

**At the end of the tag's run** (job *release*): the draft stays a draft,
its notes saying it is being built, and the job lists what is missing or
wrong. A file a job failed to put on the draft: re-run that job (and the
ones after it). A file that doesn't verify (a feed signed with another key,
a checksum that doesn't match): find out why before anything else; a file
changed on the draft by hand is the likeliest. Re-run the failed jobs once
it is fixed; job *release* writes the notes when the gate passes.

**When the draft was published** (job *feed*): the release goes back to a
draft and no feed changes, so installed copies are offered nothing, and the
job lists why. Complete the draft as above, wait for job *release* to pass,
and publish it again. If the job could not put it back to a draft, it says
so: run `gh release edit desktop-vX.Y.Z --draft=true`. A gate that could not
run (a lookup or a download failed) changed nothing: re-run the feed job.

### A stale or missing appcast

**The feed job refuses** ("the live feed has builds this appcast lacks"):
a release was published after this draft was built. The feed check runs
after publication, so this release is already public and there is no draft
to delete. Leave the live feed as it is (it is correct: it is the newer
release's). Do not tag this version again: its build number is below the
newest one in the feed, and `appcast.sh` would refuse it the same way. If
the change still needs to ship, release a version above the newest build
in the feed. To avoid this, wait for each release's feed job to pass before
tagging the next one.

**The feed job fails part way through publishing** (say `appcast.xml` went
live, then the Windows upload failed): GitHub has no way to swap the three
files at once, so for now Mac copies are offered the release and Windows or
Linux copies are not. Re-run the feed job. Its checks pass again, a feed
that is already live, byte for byte, is left as it is (its last copy stays
`*.previous.xml`), and the rest go live. A live feed it cannot read back
stops the run with nothing changed; re-run it again. If it stopped between
a feed's two renames, put that feed back first, as below.

**The first publication fails** (the feed release is still a draft):
nothing is live and no installed copy reads a draft. Re-run the feed job;
it takes the draft over, uploads `appcast.xml` again, checks it and
publishes the release.

**The feed job says the feed host exists but `appcast.xml` answers 404**:
a later publication stopped between its two renames, and installed copies
cannot read the feed. On the `desktop-appcast` release, rename
`appcast.previous.xml` back to `appcast.xml` (and delete a leftover
`appcast.next-….xml`), then re-run the feed job. Neither the feed job nor
`publish-appcast.sh` ever starts an empty feed over a published host.

**The same for Windows or Linux** ("the feed release has
appcast-windows.previous.xml but no appcast-windows.xml"): rename it back
to `appcast-windows.xml` (or the Linux one to `appcast-linux.xml`), delete a
leftover `appcast-windows.next-….xml`, and re-run the job that stopped. The
release workflow never takes such a feed release for that OS's first
release. A Windows or Linux feed the feed job refuses as stale is handled as
the Mac's above.

### Rotating the Sparkle key

Installed copies accept only updates and feeds signed with the key their
Info.plist carries. A rotation moves them to a new key pair through one
**bridge release**: signed like any other with the current key (its DMG
and the feed), but its app carries the new public key. Copies that install
it trust only the new key from then on, and every later release is signed
with the new key. A rotation needs the current private key; for a lost
one, see below.

The pipeline refuses an app whose `SUPublicEDKey` is not the public half
of `SPARKLE_ED_PRIVATE_KEY`, except in the one release that two variables
name together: `SPARKLE_NEXT_PUBLIC_ED_KEY`, the new public key, and
`SPARKLE_KEY_ROTATION_TAG`, that release's tag. The configuration check
stops the run when only one is set, when the tag is not the one being
built (so variables left behind stop the next release), or when the next
key is not a key or is the current one. `appcast.sh` then signs the
bridge's DMG itself (`generate_appcast` signs an update only with the key
its app carries), signs the feed again, and checks that the app carries
exactly the next key.

1. **Make the new key pair** on the Mac you trust, under its own account,
   so the current key stays as it is:

   ```sh
   d="$(bash -c '. desktop/packaging/macos/lib.sh && sparkle_dir')"
   "$d/bin/generate_keys" --account conduit-desktop-next      # creates the key; prints the public key
   "$d/bin/generate_keys" --account conduit-desktop-next -x sparkle-next-private-key.txt
   ```

   Put `sparkle-next-private-key.txt` in the offline backup.
2. **Name the bridge release**, the next version `X.Y.Z`, with both
   variables. Leave `SPARKLE_ED_PRIVATE_KEY` and `SPARKLE_PUBLIC_ED_KEY` as
   they are:

   ```sh
   gh variable set SPARKLE_NEXT_PUBLIC_ED_KEY --body "$("$d/bin/generate_keys" --account conduit-desktop-next -p)"
   gh variable set SPARKLE_KEY_ROTATION_TAG --body desktop-vX.Y.Z
   ```

3. **Tag and push** `desktop-vX.Y.Z` as for any release. The run's
   annotations say it is the bridge release.
4. **Check the draft** as for any release, and that its app carries the
   new key:

   ```sh
   gh release download desktop-vX.Y.Z -p Conduit-X.Y.Z.dmg -D bridge
   mkdir bridge/mnt
   hdiutil attach -nobrowse -readonly -mountpoint bridge/mnt bridge/Conduit-X.Y.Z.dmg
   plutil -extract SUPublicEDKey raw -o - bridge/mnt/Conduit.app/Contents/Info.plist   # the new public key
   hdiutil detach bridge/mnt
   ```

5. **Publish it** and wait for its feed job to pass. That job checks the
   feed and the DMG with `SPARKLE_PUBLIC_ED_KEY`, so the variable must
   still be the old key: re-run a failed feed job before step 6.
6. **Swap the keys**, then delete the rotation variables:

   ```sh
   gh secret set SPARKLE_ED_PRIVATE_KEY < sparkle-next-private-key.txt
   gh variable set SPARKLE_PUBLIC_ED_KEY --body "$("$d/bin/generate_keys" --account conduit-desktop-next -p)"
   bash -c '. desktop/packaging/macos/lib.sh && sparkle_public_key' < sparkle-next-private-key.txt
   # must print the same public key
   gh variable delete SPARKLE_NEXT_PUBLIC_ED_KEY
   gh variable delete SPARKLE_KEY_ROTATION_TAG
   ```

   In Keychain Access, delete the item "Private key for signing Sparkle
   updates" of the account `conduit-desktop` (the old key; mark its backup
   as retired). To keep signing on this Mac, move the new key to that
   account with `"$d/bin/generate_keys" --account conduit-desktop -f
   sparkle-next-private-key.txt`, then delete the item of
   `conduit-desktop-next`. Do not leave `sparkle-next-private-key.txt` on
   disk.
7. **Release the next version** as usual. It is signed with the new key,
   and its feed keeps the bridge's item.

What installed copies see:

- A copy older than the bridge reads the bridge's feed with the old key,
  installs it, and from then on trusts only the new key.
- Until step 7, the live feed is the bridge's, signed with the old key. A
  copy already on the bridge cannot read it: Check for Updates… there says
  the feed is improperly signed. There is nothing newer for it meanwhile.
  Copies check daily; give the bridge a couple of weeks to reach most of
  them before step 7.
- A copy that missed the bridge cannot read the feeds signed with the new
  key. Sparkle 2.10.1 lets it through after 20 days of such failures
  (`SUSignedFeedFailureExpirationInterval`): it then reads the feed in a
  restricted mode and installs the newest update if the DMG is signed
  with Developer ID by the installed app's team. Keep the same Developer
  ID team across a rotation; with another team, those copies need a
  download by hand.

### Losing the Sparkle key

No bridge release can be made without the current private key. Make a
new key pair and store both halves as in the one-time setup
([3. The Sparkle EdDSA key](#3-the-sparkle-eddsa-key)), with no rotation
variables, and release. Installed copies refuse its feed until Sparkle's
20-day fallback (above) lets them install it through its Developer ID
signature, from the same team only. Ask people to download the new
version by hand meanwhile. Keep the key in two places (the secret and an
offline backup) so this never happens.
