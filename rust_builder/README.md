# Rust builder

## Local Cargokit compatibility changes

The vendored Cargokit build tool is kept close to upstream, with three local
toolchain-discovery changes needed by the pinned Rust build on Homebrew hosts:

- `Rustup.toolchainEnvironment` prepends the selected toolchain's compiler
  directory so Cargo can resolve `rustc` when rustup proxy binaries are absent.
- Exact-version toolchains such as `1.95.0` are treated as official toolchains
  alongside stable, beta, and nightly; user-linked custom toolchains remain
  excluded.
- `util.dart` resolves missing tools through Homebrew paths and includes a
  Homebrew-specific installation hint.

This Flutter plugin is the platform build glue for the in-process ChatGPT Rust
runtime. Its Android Gradle, Apple podspec, and desktop CMake entry points invoke
the vendored Cargokit build tool in `cargokit/`.

The files were copied from the Flutter Rust Bridge 2.12.0 integration template
at commit `62b9330ed2f900535e34d8443ff82dc54070579a`. They are checked in so clean
mobile builds do not depend on a globally installed integration tool.

When updating Flutter Rust Bridge, compare this directory with the matching
upstream template, preserve Conduit's package and crate names, then run the
vendored build-tool analyzer, regenerate FRB bindings, and build Android and iOS
release artifacts before committing the synchronized files.
