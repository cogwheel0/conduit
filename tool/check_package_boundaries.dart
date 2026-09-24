// Enforces the workspace's import rules.
//
//   dart run tool/check_package_boundaries.dart
//
// Two rules, both of which exist to stop the mobile and desktop front-ends
// from re-implementing the same logic:
//
//   1. Packages shared with the renderer must stay web-safe, so they can
//      cross `dart compile js`. CI also compiles them for real; this check
//      just fails faster and points at the offending line.
//   2. apps/desktop_ui may depend only on the shared packages, Jaspr and
//      package:web. If it can reach dio, drift or conduit_core, then "logic
//      lives in the core" stops being enforceable by review alone.
import 'dart:convert';
import 'dart:io';

/// Directories of `lib/` that no longer import Flutter and must stay that
/// way.
///
/// Extraction into `packages/conduit_core` proceeds a piece at a time. Each
/// time a directory comes off Flutter it is added here, so the next change
/// cannot silently put the dependency back — which is exactly how an
/// extraction stalls.
const List<String> _flutterFreeDirectories = <String>[
  'lib/core/database',
  'lib/core/models',
  'lib/core/sync',
];

/// Individual libraries that are Flutter-free ahead of their directory.
///
/// `lib/core/providers` still holds `app_startup_providers.dart`, which binds
/// the Flutter host implementations and is meant to. That is no reason to
/// leave the rest of the directory unlocked.
const List<String> _flutterFreeFiles = <String>[
  'lib/core/providers/app_providers.dart',
  'lib/core/providers/host_ports.dart',
];

/// Imports that make a directory non-portable to the daemon.
const List<String> _flutterImports = <String>[
  'package:flutter/',
  'package:flutter_riverpod/',
  'package:drift_flutter/',
  'package:path_provider/',
  'package:shared_preferences/',
  'package:hive_ce_flutter/',
  'package:flutter_secure_storage/',
];

/// Packages the desktop renderer imports, which therefore cannot touch
/// `dart:io`, Flutter, or anything that reaches them.
const List<String> _webSafePackages = <String>[
  'packages/conduit_protocol/lib',
  'packages/conduit_theme/lib',
  'packages/conduit_markdown/lib',
];

/// Imports that are never allowed in a web-safe package.
const List<String> _webSafeForbidden = <String>[
  'dart:io',
  'dart:ffi',
  'dart:mirrors',
  'package:flutter/',
  'package:flutter_test/',
  'package:dio/',
  'package:drift/',
  'package:conduit_core/',
];

/// Packages the desktop UI may never depend on, even deliberately.
///
/// The allow-list below is derived from the renderer's own pubspec, so it
/// moves when someone adds a dependency. These do not: each is either
/// business logic (which belongs in the daemon and travels over RPC) or a
/// native capability the renderer must not have, and adding one to the
/// pubspec is the mistake this is meant to catch.
const List<String> _desktopUiNeverDeclarable = <String>[
  'dio',
  'drift',
  'conduit_core',
  'conduitd',
  'conduit',
  'flutter',
];

/// `dart:` libraries the renderer cannot use, because it compiles to JS.
const List<String> _desktopUiForbiddenDartLibraries = <String>[
  'dart:io',
  'dart:ffi',
  'dart:mirrors',
  'dart:isolate',
  'dart:cli',
];

final RegExp _importRegex = RegExp(
  '''^\\s*(?:import|export)\\s+['"]([^'"]+)['"]''',
  multiLine: true,
);

void main() {
  final violations = <String>[];

  violations.addAll(_scanForTransitiveFlutter('packages/conduit_core/lib'));

  for (final path in _webSafePackages) {
    violations.addAll(
      _scan(
        Directory(path),
        _webSafeForbidden,
        'must stay compilable with `dart compile js`',
      ),
    );
  }

  // `lib/platform` is deliberately absent: it exists precisely to hold the
  // Flutter implementations of the core's ports.
  for (final path in _flutterFreeDirectories) {
    violations.addAll(
      _scan(
        Directory(path),
        _flutterImports,
        'was taken off Flutter and must stay portable '
        'to the conduitd sidecar; put the platform-specific part behind a '
        'port in packages/conduit_core/lib/ports and implement it in '
        'lib/platform',
      ),
    );
  }

  for (final path in _flutterFreeFiles) {
    violations.addAll(
      _scanFile(
        File(path),
        _flutterImports,
        'was taken off Flutter and must stay portable '
        'to the conduitd sidecar; put the platform-specific part behind a '
        'port in packages/conduit_core/lib/ports and implement it in '
        'lib/platform',
      ),
    );
  }

  violations.addAll(_scanDesktopUi());

  if (violations.isEmpty) {
    stdout.writeln('Package boundaries OK.');
    return;
  }
  stderr.writeln('Package boundary violations:');
  for (final violation in violations) {
    stderr.writeln(' - $violation');
  }
  exitCode = 1;
}

List<String> _scan(Directory dir, List<String> forbidden, String because) {
  // A package that does not exist yet is not a violation.
  if (!dir.existsSync()) return const <String>[];
  return _scanFiles(dir.listSync(recursive: true), forbidden, because);
}

/// Scans one file rather than a tree.
///
/// Some libraries are taken off Flutter well before the directory around them
/// is, and the lock is only worth having if it can name them individually.
/// A `part` needs no entry of its own: it has no import directives, and the
/// library root that owns it is what gets scanned.
List<String> _scanFile(File file, List<String> forbidden, String because) {
  if (!file.existsSync()) return const <String>[];
  return _scanFiles(<FileSystemEntity>[file], forbidden, because);
}

List<String> _scanFiles(
  List<FileSystemEntity> entities,
  List<String> forbidden,
  String because,
) {
  final violations = <String>[];
  for (final entity in entities) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    // Generated output is regenerated from checked-in sources, so a problem
    // there is really a problem in the generator's configuration.
    if (entity.path.contains('/l10n/strings')) continue;

    final content = entity.readAsStringSync();
    for (final match in _importRegex.allMatches(content)) {
      final uri = match.group(1)!;
      for (final banned in forbidden) {
        if (uri == banned || uri.startsWith(banned)) {
          final line =
              '\n'.allMatches(content.substring(0, match.start)).length + 1;
          violations.add('${entity.path}:$line imports "$uri" — $because');
        }
      }
    }
  }
  return violations;
}

/// Reports any file under [dir] that imports a package which itself depends
/// on the Flutter SDK.
///
/// The named lists above only catch packages someone thought to write down,
/// which is not good enough for this package's central promise. During the
/// extraction two files reached Flutter through
/// `cached_network_image_ce` and `pdfrx`, passed every other check, and would
/// have voided the guarantee silently. This asks each imported package's own
/// pubspec instead, so a dependency added later cannot smuggle Flutter in
/// under a name nobody listed.
List<String> _scanForTransitiveFlutter(String dir) {
  final configFile = File('.dart_tool/package_config.json');
  if (!configFile.existsSync()) return const <String>[];
  final config =
      jsonDecode(configFile.readAsStringSync()) as Map<String, dynamic>;

  final flutterBacked = <String>{};
  for (final entry in config['packages'] as List<dynamic>) {
    final package = entry as Map<String, dynamic>;
    final name = package['name'] as String;
    final root = package['rootUri'] as String;
    final resolved = root.startsWith('file://')
        ? Uri.parse(root).toFilePath()
        : File('.dart_tool/$root').absolute.path;
    final pubspec = File('$resolved/pubspec.yaml');
    if (!pubspec.existsSync()) continue;
    if (name == 'flutter' ||
        _flutterSdkDependency.hasMatch(pubspec.readAsStringSync())) {
      flutterBacked.add(name);
    }
  }

  final target = Directory(dir);
  if (!target.existsSync()) return const <String>[];
  final violations = <String>[];
  for (final entity in target.listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    final content = entity.readAsStringSync();
    for (final match in _packageImportRegex.allMatches(content)) {
      final package = match.group(1)!;
      if (!flutterBacked.contains(package)) continue;
      final line =
          '\n'.allMatches(content.substring(0, match.start)).length + 1;
      violations.add(
        '${entity.path}:$line imports "package:$package", which depends on '
        'the Flutter SDK - conduit_core must run inside the conduitd '
        'sidecar, so the platform-specific part belongs behind a port',
      );
    }
  }
  return violations;
}

final RegExp _flutterSdkDependency = RegExp(
  r'^\s+flutter:\s*\n\s+sdk:\s*flutter',
  multiLine: true,
);

final RegExp _packageImportRegex = RegExp(
  r'''^\s*import\s+['"]package:([a-z_0-9]+)/''',
  multiLine: true,
);

/// Holds the desktop UI to what its pubspec actually declares.
///
/// This was a deny-list of nine entries behind an error message that said
/// "may depend only on ...", which is a stronger claim than a deny-list can
/// make: `package:http` or `package:hive_ce` would have passed it silently,
/// and those are exactly how logic creeps back into a renderer that is
/// supposed to hold none. Deriving the permitted set from the pubspec makes
/// adding a dependency a deliberate, reviewable edit -- and
/// [_desktopUiNeverDeclarable] means even that edit cannot let the big ones
/// through.
List<String> _scanDesktopUi() {
  const root = 'apps/desktop_ui';
  final pubspec = File('$root/pubspec.yaml');
  if (!pubspec.existsSync()) return const <String>[];

  final declared = _declaredDependencies(pubspec.readAsStringSync());
  final violations = <String>[
    for (final banned in _desktopUiNeverDeclarable)
      if (declared.contains(banned))
        '$root/pubspec.yaml declares "$banned" - the renderer holds no '
            'business logic and has no native capabilities; this belongs in '
            'the daemon, behind RPC',
  ];

  final target = Directory('$root/lib');
  if (!target.existsSync()) return violations;
  for (final entity in target.listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    if (entity.path.contains('/l10n/strings')) continue;
    final content = entity.readAsStringSync();
    for (final match in _importRegex.allMatches(content)) {
      final uri = match.group(1)!;
      final line =
          '\n'.allMatches(content.substring(0, match.start)).length + 1;
      if (uri.startsWith('dart:')) {
        if (_desktopUiForbiddenDartLibraries.contains(uri)) {
          violations.add(
            '${entity.path}:$line imports "$uri", which the renderer cannot '
            'have: it compiles to JS',
          );
        }
        continue;
      }
      if (!uri.startsWith('package:')) continue;
      final package = uri.substring('package:'.length).split('/').first;
      if (package == 'conduit_desktop_ui' || declared.contains(package)) {
        continue;
      }
      violations.add(
        '${entity.path}:$line imports "package:$package", which '
        '$root/pubspec.yaml does not declare - the renderer may use only '
        'what it depends on directly',
      );
    }
  }
  return violations;
}

/// Package names under `dependencies:` and `dev_dependencies:`.
///
/// Deliberately a line scan rather than a YAML parse: this tool has no
/// dependencies of its own, and the shape it needs -- a two-space key under
/// a known top-level section -- is not one pubspec syntax varies on.
Set<String> _declaredDependencies(String pubspec) {
  final declared = <String>{};
  var inDependencies = false;
  for (final line in pubspec.split('\n')) {
    if (line.startsWith('dependencies:') ||
        line.startsWith('dev_dependencies:')) {
      inDependencies = true;
      continue;
    }
    if (line.isNotEmpty && !line.startsWith(' ') && !line.startsWith('#')) {
      inDependencies = false;
      continue;
    }
    if (!inDependencies) continue;
    final match = _dependencyName.firstMatch(line);
    if (match != null) declared.add(match.group(1)!);
  }
  return declared;
}

final RegExp _dependencyName = RegExp(r'^  ([a-z_0-9]+):');
