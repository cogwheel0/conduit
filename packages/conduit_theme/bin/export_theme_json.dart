// Writes the computed desktop palettes to the JSON file the native desktop
// app embeds (desktop/crates/components/assets/themes/palettes.json).
//
// Run from anywhere inside the repository:
//
//   dart run packages/conduit_theme/bin/export_theme_json.dart
//
// `--check` exits 1 instead of writing when the file is stale. The package
// test `theme_json_test.dart` fails the same way, so CI catches a palette
// edit that forgot to regenerate.

import 'dart:io';

import 'package:conduit_theme/src/theme_json.dart';

void main(List<String> args) {
  final check = args.contains('--check');
  final root = _repoRoot();
  final file = File('${root.path}/$kDesktopThemeJsonPath');
  final json = desktopThemeJson();
  final current = file.existsSync() ? file.readAsStringSync() : null;
  if (check) {
    if (current != json) {
      stderr.writeln(
        '$kDesktopThemeJsonPath is stale; run '
        'dart run packages/conduit_theme/bin/export_theme_json.dart',
      );
      exitCode = 1;
    }
    return;
  }
  if (current == json) {
    stdout.writeln('$kDesktopThemeJsonPath is up to date');
    return;
  }
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(json);
  stdout.writeln('wrote $kDesktopThemeJsonPath');
}

/// The repository root: the nearest ancestor of the working directory, or of
/// this script, that holds `packages/conduit_theme`.
Directory _repoRoot() {
  for (final start in <Directory>[
    Directory.current,
    File.fromUri(Platform.script).parent,
  ]) {
    var dir = start.absolute;
    while (true) {
      if (Directory('${dir.path}/packages/conduit_theme').existsSync()) {
        return dir;
      }
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
  }
  stderr.writeln('run this from inside the conduit repository');
  exit(64);
}
