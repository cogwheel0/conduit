# Third-party notices

Conduit Desktop ships `THIRD_PARTY_NOTICES.md` with the app (the Mac's
`Conduit.app/Contents/Resources`, the Windows install folder, the Linux
packages' `/usr/lib/conduit` and `/usr/share/doc/conduit-desktop`; Settings ›
About opens the installed copy, `paths::packaged_notices`): the licences of
everything the
app and its `conduitd` include. It is generated
for each build rather than committed:

```sh
desktop/packaging/notices/notices.sh                 # desktop/target/notices/THIRD_PARTY_NOTICES.md
desktop/packaging/notices/notices.sh --out FILE      # somewhere else
desktop/packaging/notices/notices.sh --check         # generate to a temporary folder only
desktop/packaging/notices/notices.sh --target x86_64-pc-windows-msvc --out FILE
desktop/packaging/notices/notices.sh --target x86_64-unknown-linux-gnu --out FILE
```

`--target` makes the Windows installer's and the Linux packages' notices:
the crates cargo builds into the app for that target, and the components
those packages bundle (no Sparkle, no whisper library). Any target's can be
made on a Mac or Linux; CI makes both on Linux (`Third-party notices
(Windows, Linux)`) and the package jobs ship them: in the Windows install
folder, and beside the Linux app in `/usr/lib/conduit/` as well as in
`/usr/share/doc/conduit-desktop/`, which a minimized system (dpkg's
`path-exclude`, rpm's `nodocs`) drops.

`packaging/macos/bundle.sh build` runs it for every bundle, and CI runs
`--check` (`.github/workflows/desktop.yml`). Each run fails unless the
licence set is complete: every Rust crate built into the app has an
accepted licence (`about.toml`), every Dart package in `conduitd` has a
licence file, and every directly bundled component's licence is found.

- `about.toml`, `about.hbs`: cargo-about's configuration and template for
  the Rust crates.
- `notices.py`: puts the file together, with the components bundled
  directly (vendored gpui-pre, Sparkle, whisper.cpp, SQLite, the Dart
  runtime, mermaid, Chart.js, Lucide, the KaTeX fonts) and the Dart
  packages.
- `texts/`: licence texts that no package manager provides (whisper.cpp,
  SQLite's blessing, Chart.js).

It needs cargo-about 0.9 (`cargo install cargo-about --locked --features
cli --version 0.9.3`), `flutter pub get` at the repository root, and
python3.
