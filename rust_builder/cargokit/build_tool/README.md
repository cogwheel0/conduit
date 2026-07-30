# Vendored Cargokit build tool

This package is copied source from the Cargokit bundle embedded in Flutter Rust
Bridge 2.12.0 at commit
`62b9330ed2f900535e34d8443ff82dc54070579a`. The surrounding Gradle, podspec,
and CMake scripts invoke `bin/build_tool.dart`; it is not application code and
is not published as a Dart package.

For local diagnostics, run `dart pub get` and `dart analyze` in this directory.
When updating the vendored copy, compare it to the same pinned upstream FRB
template, keep dependency pins synchronized with `pubspec.lock`, and validate it
through both Android and iOS release builds.
