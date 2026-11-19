import 'package:checks/checks.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../tool/check_changed.dart';

final Workspace _workspace = Workspace.fromPubspecs({
  appMember: '''
name: conduit
workspace:
  - packages/conduit_core
  - packages/conduit_markdown
  - packages/conduit_protocol
  - packages/conduit_theme
  - apps/daemon
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
  'packages/conduit_protocol': 'name: conduit_protocol\n',
  'packages/conduit_theme': 'name: conduit_theme\n',
  'apps/daemon': '''
name: conduitd
dependencies:
  conduit_core:
  conduit_protocol:
''',
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
      'Analyze daemon',
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
      'Desktop daemon (macOS build and smoke test)',
      // conduitd is built from conduit_markdown, and the bundle carries it.
      'Desktop workflow (cargo tests, builds and the generated Rust)',
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
    final lock = _plan(['pubspec.lock']);
    check(_names(lock)).deepEquals([
      'Analyze daemon',
      'Analyze conduit_core',
      'Analyze conduit_markdown',
      'Analyze conduit_protocol',
      'Analyze conduit_theme',
      'Analyze app',
    ]);
    // It can also change the Android plugin set.
    check(lock.leftToCi).contains('Android native tests and the foss build');
  });

  test('a package tested only by goldens runs its whole suite', () {
    final plan = _plan([
      'packages/conduit_protocol/goldens/chatDto.json',
      'packages/conduit_protocol/lib/src/chats.dart',
    ]);

    check(_names(plan)).deepEquals([
      'Package boundaries',
      'Analyze daemon',
      'Analyze conduit_protocol',
      'Test conduit_protocol (whole suite)',
      'Protocol Rust types',
    ]);
    check(plan.steps[3].command).deepEquals(['dart', 'test']);
    // The generator formats with rustfmt: a checkout without Rust skips it.
    check(plan.steps[4].optional).isTrue();
    check(plan.steps[4].needs).equals('rustfmt');
    // Probed where the generator runs it, under the pinned toolchain.
    check(plan.steps[4].needsIn).equals('desktop');
    check(
      plan.leftToCi,
    ).contains('Desktop workflow (cargo tests, builds and the generated Rust)');
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
    final plan = _plan(['lib/l10n/app_de.arb']);
    check(_names(plan))
        .deepEquals(['ARB descriptions', 'ARB locales', 'Analyze app']);
    // The desktop app builds its strings from the same files.
    check(
      plan.leftToCi,
    ).contains('Desktop workflow (cargo tests, builds and the generated Rust)');
  });

  test('changes outside Dart run only their own checks', () {
    final relay = _plan(['relay/src/main.rs']);
    check(_names(relay)).deepEquals(['Relay format', 'Relay lint']);
    check(relay.steps.every((step) => step.optional)).isTrue();
    check(relay.steps.first.directory).equals('relay');
    check(relay.leftToCi).deepEquals(['Push relay tests (cargo test)']);

    final desktop = _plan(['desktop/crates/protocol/src/generated.rs']);
    check(_names(desktop))
        .deepEquals(['Protocol Rust types', 'Desktop format', 'Desktop build']);
    check(desktop.steps.every((step) => step.optional)).isTrue();
    check(desktop.leftToCi).deepEquals([
      'Desktop workflow (cargo tests, builds and the generated Rust)',
    ]);

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

    // The core's code is built into conduitd, which the bundle carries.
    check(
      _plan(['packages/conduit_core/lib/src/x.dart']).leftToCi,
    ).contains('Desktop workflow (cargo tests, builds and the generated Rust)');
  });

  test('host-agnostic Swift is checked against the package boundaries', () {
    check(_names(_plan(['ios/Runner/Bridges/VoiceBridge.swift'])))
        .deepEquals(['Package boundaries']);
  });
}
