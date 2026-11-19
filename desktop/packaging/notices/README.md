# Third-party notices

Conduit Desktop ships `THIRD_PARTY_NOTICES.md` inside the app
(`Conduit.app/Contents/Resources`, opened from Settings › About): the
licences of everything the app and its `conduitd` include. It is generated
for each build rather than committed:

```sh
desktop/packaging/notices/notices.sh                 # desktop/target/notices/THIRD_PARTY_NOTICES.md
desktop/packaging/notices/notices.sh --out FILE      # somewhere else
desktop/packaging/notices/notices.sh --check         # generate to a temporary folder only
```

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
