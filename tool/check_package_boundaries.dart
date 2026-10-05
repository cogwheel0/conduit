// Enforces the workspace's import rules.
//
//   dart run tool/check_package_boundaries.dart
//
// The first two rules exist to stop the mobile and desktop front-ends from
// re-implementing the same logic:
//
//   1. Packages shared with the renderer must stay web-safe, so they can
//      cross `dart compile js`. CI also compiles them for real; this check
//      just fails faster and points at the offending line.
//   2. apps/desktop_ui may depend only on the shared packages, Jaspr and
//      package:web. If it can reach dio, drift or conduit_core, then "logic
//      lives in the core" stops being enforceable by review alone.
//
// The third keeps the iOS feature bridges portable between hosts:
//
//   3. Swift in ios/Runner is either host-agnostic, and depends on the host
//      only through `ConduitBridgeHost`, or marked as Flutter-host-only.
//      Host-agnostic files are shared unchanged with other hosts, so
//      they may not name the Flutter app delegate, engine, view controller,
//      scene delegate or plugin registrar.
import 'dart:convert';
import 'dart:io';

/// Directories of `lib/` that no longer import Flutter and must stay that
/// way.
///
/// Extraction into `packages/conduit_core` proceeds a piece at a time. Each
/// time a directory comes off Flutter it is added here, so the next change
/// cannot silently put the dependency back — which is exactly how an
/// extraction stalls.
///
/// Every directory listed here now holds nothing but three-line `export`
/// shims forwarding to the core, so what these entries really protect is the
/// old import paths against gaining a Flutter dependency again. The
/// authoritative guarantee lives in [_scanForTransitiveFlutter], which reads
/// each imported package's own pubspec and covers the whole of
/// `packages/conduit_core/lib` whether or not a path is named here.
///
/// [_checkListedPathsExist] fails the run when an entry stops existing. That
/// is load-bearing: the first version of this list named eight directories
/// that had already been deleted, and because a missing directory simply
/// scanned clean, the locks went vacuous without anyone noticing.
const List<String> _flutterFreeDirectories = <String>[
  'lib/features/channels/providers',
  'lib/features/notes/providers',
  'lib/features/prompts/providers',
  'lib/features/terminal/models',
  'lib/features/terminal/providers',
  'lib/features/terminal/services',
  'lib/features/workspace/models',
];

/// Individual libraries that are Flutter-free ahead of their directory.
///
/// Empty on purpose, and not a mistake to "tidy away": the mechanism stays
/// because a library is often taken off Flutter well before the directory
/// around it is. It was used by `lib/core/providers/app_providers.dart` and
/// `lib/core/providers/host_ports.dart` until both moved into
/// `packages/conduit_core`; the next file in that position should be added
/// back here rather than left to review.
const List<String> _flutterFreeFiles = <String>[];

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

/// Swift under ios/Runner that depends on its host only through
/// `ConduitBridgeHost`, and is reusable unchanged by other hosts.
const List<String> _iosHostAgnosticSwift = <String>[
  'ios/Runner/AppIntentBridge.swift',
  'ios/Runner/AppIntentInvocationStore.swift',
  'ios/Runner/BackgroundStreamingHandler.swift',
  'ios/Runner/ConduitAppIntents.swift',
  'ios/Runner/ConduitBridgeHost.swift',
  'ios/Runner/ConduitCarPlayBridge.swift',
  'ios/Runner/ConduitCarPlaySceneDelegate.swift',
  'ios/Runner/ConduitPlatformApis.g.swift',
  'ios/Runner/CookieBridge.swift',
  'ios/Runner/NativeDropdownBridge.swift',
  'ios/Runner/NativeImageViewerBridge.swift',
  'ios/Runner/NativeIosTtsBridge.swift',
  'ios/Runner/NativeSheetBridge.swift',
  'ios/Runner/NativeSheetUIFoundation.swift',
  'ios/Runner/NativeSttBridge.swift',
  'ios/Runner/NativeSymbolImageBridge.swift',
  'ios/Runner/PccBridge.swift',
  'ios/Runner/PlatformEnvironmentBridge.swift',
  'ios/Runner/ShareImportBridge.swift',
  'ios/Runner/VoiceAudioRouteBridge.swift',
];

/// Swift under ios/Runner that belongs to the Flutter host. Each file says so
/// in its header, so nobody copies it into another host by mistake.
const List<String> _iosFlutterHostSwift = <String>[
  'ios/Runner/AppDelegate.swift',
  'ios/Runner/ConduitSceneDelegate.swift',
  'ios/Runner/DisplayBoostBridge.swift',
  'ios/Runner/FlutterConduitBridgeHost.swift',
  'ios/Runner/NativeKeyboardAttachmentBridge.swift',
  'ios/Runner/NativePasteBridge.swift',
];

const String _iosFlutterHostMarker = '// FLUTTER HOST ONLY.';

/// Host types a host-agnostic bridge must reach through `ConduitBridgeHost`
/// instead of naming them.
final List<RegExp> _iosHostTypes = <RegExp>[
  RegExp(r'\bAppDelegate\b'),
  RegExp(r'\bFlutterAppDelegate\b'),
  RegExp(r'\bFlutterEngine'),
  RegExp(r'\bFlutterImplicitEngine'),
  RegExp(r'\bFlutterViewController\b'),
  RegExp(r'\bFlutterSceneDelegate\b'),
  RegExp(r'\bFlutterPluginRegist'),
  RegExp(r'\bGeneratedPluginRegistrant\b'),
  RegExp(r'UIApplication\.shared\.delegate\b'),
  RegExp(r'\bconnectedScenes\b'),
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
  violations.addAll(
    _checkListedPathsExist(_flutterFreeDirectories, 'Flutter-free directory'),
  );
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

  violations.addAll(
    _checkListedPathsExist(_flutterFreeFiles, 'Flutter-free file'),
  );
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
  violations.addAll(_scanIosBridges());

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

/// Reports every listed path that no longer exists.
///
/// A lock on a path that is gone protects nothing, and silently scanning a
/// missing directory clean is how eight of these went vacuous during the core
/// extraction. This mirrors what [_scanIosBridges] already does for its Swift
/// lists, including the "listed but does not exist" wording, so a file that
/// moves is reported rather than quietly dropped from the rule.
///
/// Only the Flutter-free lists are checked. `_webSafePackages` and
/// `_desktopUiNeverDeclarable` also name things that do not exist yet, but
/// those are rules for the packages the daemon and renderer will add, so a
/// missing path there is intent rather than rot.
List<String> _checkListedPathsExist(List<String> paths, String kind) {
  return <String>[
    for (final path in paths)
      if (!FileSystemEntity.isFileSync(path) && !Directory(path).existsSync())
        '$path is listed as a $kind but does not exist - remove it, or point '
            'it at wherever that code lives now',
  ];
}

List<String> _scan(Directory dir, List<String> forbidden, String because) {
  // A web-safe package the desktop renderer has not added yet is not a
  // violation. The Flutter-free lists get their missing paths reported by
  // [_checkListedPathsExist] before they reach here.
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

/// Returns Swift [source] with comments blanked out.
///
/// Line comments and (nested) block comments become spaces, and newlines stay,
/// so line numbers still match the file. String literals are kept as code: a
/// `//` inside `"https://..."` is not a comment, and code after it still gets
/// scanned.
String stripSwiftComments(String source) {
  final out = StringBuffer();
  final length = source.length;
  var blockDepth = 0;
  var i = 0;
  while (i < length) {
    final char = source[i];
    final next = i + 1 < length ? source[i + 1] : '';
    if (blockDepth > 0) {
      if (char == '/' && next == '*') {
        blockDepth++;
        out.write('  ');
        i += 2;
      } else if (char == '*' && next == '/') {
        blockDepth--;
        out.write('  ');
        i += 2;
      } else {
        out.write(char == '\n' ? '\n' : ' ');
        i++;
      }
    } else if (char == '/' && next == '/') {
      while (i < length && source[i] != '\n') {
        out.write(' ');
        i++;
      }
    } else if (char == '/' && next == '*') {
      blockDepth = 1;
      out.write('  ');
      i += 2;
    } else if (char == '"') {
      final multiline = source.startsWith('"""', i);
      final quote = multiline ? '"""' : '"';
      out.write(quote);
      i += quote.length;
      while (i < length && !source.startsWith(quote, i)) {
        if (!multiline && source[i] == '\n') break;
        if (source[i] == '\\' && i + 1 < length) {
          out.write(source[i]);
          i++;
        }
        out.write(source[i]);
        i++;
      }
      if (i < length && source.startsWith(quote, i)) {
        out.write(quote);
        i += quote.length;
      }
    } else {
      out.write(char);
      i++;
    }
  }
  return out.toString();
}

/// Holds every Swift file in ios/Runner to one side of the host seam.
///
/// A new file has to be listed before this passes, which makes "does another
/// host reuse this?" a question somebody answers on purpose.
List<String> _scanIosBridges() {
  final runner = Directory('ios/Runner');
  if (!runner.existsSync()) return const <String>[];
  final violations = <String>[];
  final listed = <String>{..._iosHostAgnosticSwift, ..._iosFlutterHostSwift};
  for (final entity in runner.listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.swift')) continue;
    if (!listed.contains(entity.path)) {
      violations.add(
        '${entity.path} is not classified - add it to _iosHostAgnosticSwift '
        'or _iosFlutterHostSwift in tool/check_package_boundaries.dart',
      );
    }
  }

  for (final path in _iosHostAgnosticSwift) {
    final file = File(path);
    if (!file.existsSync()) {
      violations.add('$path is listed as host-agnostic but does not exist');
      continue;
    }
    final lines = stripSwiftComments(file.readAsStringSync()).split('\n');
    for (var i = 0; i < lines.length; i++) {
      final code = lines[i];
      for (final hostType in _iosHostTypes) {
        final match = hostType.firstMatch(code);
        if (match == null) continue;
        violations.add(
          '$path:${i + 1} names "${match.group(0)}" - host-agnostic bridges '
          'reach the host through ConduitBridgeHost so other hosts '
          'can reuse them unchanged',
        );
      }
    }
  }

  for (final path in _iosFlutterHostSwift) {
    final file = File(path);
    if (!file.existsSync()) {
      violations.add('$path is listed as Flutter-host-only but does not exist');
      continue;
    }
    if (!file.readAsStringSync().contains(_iosFlutterHostMarker)) {
      violations.add(
        '$path is Flutter-host-only but lacks the "$_iosFlutterHostMarker" '
        'header',
      );
    }
  }
  return violations;
}
