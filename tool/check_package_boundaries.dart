// Enforces the workspace import rules in docs/desktop/PLAN.md section 2.2.
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
import 'dart:io';

/// Directories of `lib/` that no longer import Flutter and must stay that
/// way (M1).
///
/// Extraction into `packages/conduit_core` proceeds one work package at a
/// time. Each time a directory comes off Flutter it is added here, so the
/// next WP cannot silently put the dependency back — which is exactly how an
/// extraction stalls.
const List<String> _flutterFreeDirectories = <String>[
  'lib/core/database', // WP-1.1, WP-1.8
  'lib/core/models', // WP-1.8
  'lib/core/sync', // WP-1.1, WP-1.4, WP-1.8
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
  // Added by WP-1.13.
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

/// Imports that are never allowed in the desktop UI.
///
/// Anything here is either business logic (which belongs in the daemon and
/// travels over RPC) or a native capability the renderer must not have.
const List<String> _desktopUiForbidden = <String>[
  'dart:io',
  'dart:ffi',
  'dart:mirrors',
  'package:flutter/',
  'package:dio/',
  'package:drift/',
  'package:conduit_core/',
  'package:conduitd/',
  'package:conduit/',
];

final RegExp _importRegex = RegExp(
  '''^\\s*(?:import|export)\\s+['"]([^'"]+)['"]''',
  multiLine: true,
);

void main() {
  final violations = <String>[];

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
        'was taken off Flutter by an M1 work package and must stay portable '
        'to the conduitd sidecar; put the platform-specific part behind a '
        'port in packages/conduit_core/lib/ports and implement it in '
        'lib/platform',
      ),
    );
  }

  violations.addAll(
    _scan(
      Directory('apps/desktop_ui/lib'),
      _desktopUiForbidden,
      'may depend only on conduit_protocol, conduit_markdown, conduit_theme, '
      'Jaspr and package:web (PLAN.md section 2.2)',
    ),
  );

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
  // A package that does not exist yet is not a violation; several are
  // scheduled for later milestones.
  if (!dir.existsSync()) return const <String>[];

  final violations = <String>[];
  for (final entity in dir.listSync(recursive: true)) {
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
