import 'package:checks/checks.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../tool/check_changed.dart';

final Workspace _workspace = Workspace.fromPubspecs({
  appMember: '''
name: conduit
workspace:
  - packages/conduit_core
  - packages/conduit_markdown
  - packages/conduit_theme
dependencies:
  flutter:
    sdk: flutter
  conduit_core:
dev_dependencies:
  conduit_theme:
''',
  'packages/conduit_core': '''
name: conduit_core
dependencies:
  # Parsers shared with the renderer.
  conduit_markdown:
  dio: ^5.9.0
''',
  'packages/conduit_markdown': 'name: conduit_markdown\ndependencies:\n',
  'packages/conduit_theme': 'name: conduit_theme\n',
});

Plan _plan(List<String> changed, {Set<String> missing = const {}}) =>
    planChecks(
      changed,
      workspace: _workspace,
      exists: (path) => !missing.contains(path),
      base: 'abc123',
    );

List<String> _names(Plan plan) => [for (final step in plan.steps) step.name];

void main() {
  test('a package change analyzes it and everything that depends on it', () {
    // This package keeps lib/src/ but puts its tests straight under test/.
    final plan = _plan(
      ['packages/conduit_markdown/lib/src/blocks.dart'],
      missing: {'packages/conduit_markdown/test/src/blocks_test.dart'},
    );

    check(_names(plan)).deepEquals([
      'Package boundaries',
      'Analyze conduit_core',
      'Analyze conduit_markdown',
      'Analyze app',
      'Test conduit_markdown (1 file)',
    ]);
    final test = plan.steps.last;
    check(test.directory).equals('packages/conduit_markdown');
    check(test.command).deepEquals(['dart', 'test', 'test/blocks_test.dart']);
    check(plan.leftToCi).deepEquals([
      'the full Dart test suites',
      'Web-safe packages (conduit_markdown compiled to JS and run)',
      'Android native tests and the foss build',
    ]);
  });

  test('a package only tests import still reaches its importer', () {
    final plan = _plan(['packages/conduit_theme/pubspec.yaml']);

    check(_names(plan)).deepEquals([
      'Package boundaries',
      'Analyze conduit_theme',
      'Analyze app',
    ]);

    // One lockfile resolves the whole workspace.
    check(_names(_plan(['pubspec.lock']))).deepEquals([
      'Analyze conduit_core',
      'Analyze conduit_markdown',
      'Analyze conduit_theme',
      'Analyze app',
    ]);
  });

  test('an app change runs the seam and the tests beside what changed', () {
    final plan = _plan(
      [
        'lib/features/chat/chat_page.dart',
        'lib/features/chat/deleted.dart',
        'test/features/notes/notes_test.dart',
        'test/support/fake_time.dart',
        'tool/run_test_shards.dart',
      ],
      missing: {'test/features/chat/deleted_test.dart'},
    );

    check(_names(plan)).deepEquals([
      'Platform UI seam',
      'Package boundaries',
      'Analyze app',
      'Test app (3 files)',
    ]);
    check(plan.steps.first.command).deepEquals([
      'dart',
      'tool/platform_ui_lint.dart',
      '--base-ref',
      'abc123',
    ]);
    check(plan.steps.last.command).deepEquals([
      'flutter',
      'test',
      'test/features/chat/chat_page_test.dart',
      'test/features/notes/notes_test.dart',
      'test/tool/run_test_shards_test.dart',
    ]);
    check(plan.leftToCi).contains('the full Dart test suites');
  });

  test('a translation change runs the ARB checks and the analyzer', () {
    check(_names(_plan(['lib/l10n/app_de.arb'])))
        .deepEquals(['ARB descriptions', 'ARB locales', 'Analyze app']);
  });

  test('changes outside Dart run only their own checks', () {
    final relay = _plan(['relay/src/main.rs']);
    check(_names(relay)).deepEquals(['Relay format', 'Relay lint']);
    check(relay.steps.every((step) => step.optional)).isTrue();
    check(relay.steps.first.directory).equals('relay');
    check(relay.leftToCi).deepEquals(['Push relay tests (cargo test)']);

    final docs = _plan(['README.md', 'docs/BUILDING.md']);
    check(docs.steps).isEmpty();
    check(docs.leftToCi).isEmpty();

    final plugins = _plan(['server-plugins/hermes/sync.py']);
    check(plugins.steps).isEmpty();
    check(plugins.leftToCi)
        .deepEquals(['Push server plugins (pytest and the --check scripts)']);

    // Nothing maps a fixture to the tests that read it.
    final fixture = _plan(['packages/conduit_core/test/fixtures/chat.json']);
    check(fixture.steps).isEmpty();
    check(fixture.leftToCi).deepEquals(['the full Dart test suites']);
  });

  test('host-agnostic Swift is checked against the package boundaries', () {
    check(_names(_plan(['ios/Runner/Bridges/VoiceBridge.swift'])))
        .deepEquals(['Package boundaries']);
  });
}
