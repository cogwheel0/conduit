import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/platform_ui_lint.dart';

void main() {
  test('resolved controls, conditional imports and feature barrels cannot bypass the seam', () async {
    final root = Directory.systemTemp.createTempSync('platform-ui-lint-');
    addTearDown(() => root.deleteSync(recursive: true));
    void write(String path, String source) {
      File('${root.path}/$path')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(source);
    }

    write('pubspec.yaml', 'name: conduit\nenvironment:\n  sdk: ^3.13.0\n');
    write(
      '.dart_tool/package_config.json',
      jsonEncode({
        'configVersion': 2,
        'packages': [
          {
            'name': 'conduit',
            'rootUri': '../',
            'packageUri': 'lib/',
            'languageVersion': '3.13',
          },
          {
            'name': 'material_ui',
            'rootUri': '../material/',
            'packageUri': 'lib/',
            'languageVersion': '3.13',
          },
        ],
      }),
    );
    write(
      'material/lib/material_ui.dart',
      'class ElevatedButton {}\nclass Theme {}\n',
    );
    write(
      'lib/shared/widgets/platform_ui/vocabulary.dart',
      "export 'package:material_ui/material_ui.dart' show Theme, ElevatedButton;\n",
    );
    write(
      'lib/use_seam.dart',
      "import 'shared/widgets/platform_ui/vocabulary.dart' as ui;\n"
          'ui.Theme? theme;\nui.ElevatedButton? button;\n'
          'typedef ButtonAlias = ui.ElevatedButton;\n'
          'ButtonAlias? alias;\nfinal constructed = ui.ElevatedButton();\n',
    );
    write(
      'lib/direct.dart',
      "import 'package:material_ui/material_ui.dart' as m show Theme;\n"
          "// import 'package:cupertino_ui/cupertino_ui.dart';\n",
    );
    write(
      'lib/barrel.dart',
      "export 'package:material_ui/material_ui.dart' hide ElevatedButton;\n",
    );
    write('lib/indirect.dart', "export 'barrel.dart';\n");
    write(
      'lib/conditional.dart',
      "import 'shared/widgets/platform_ui/vocabulary.dart'\n"
          "  if (dart.library.io) 'package:flutter/cupertino.dart';\n",
    );
    write('lib/generated.g.dart', "part of 'owner.dart';\n");
    write(
      'lib/authored.g.dart',
      "import 'package:material_ui/material_ui.dart';\n",
    );
    final result = await Process.run('dart', [
      File('tool/platform_ui_lint.dart').absolute.path,
      '--root',
      root.path,
      '--inventory',
    ]);
    expect(result.exitCode, 0, reason: result.stderr.toString());
    final counts = jsonDecode(result.stdout as String);
    expect(counts, {
      'lib/authored.g.dart|package|package:material_ui/material_ui.dart': 1,
      'lib/barrel.dart|package|package:material_ui/material_ui.dart': 1,
      'lib/conditional.dart|package|package:flutter/cupertino.dart': 1,
      'lib/direct.dart|package|package:material_ui/material_ui.dart': 1,
      'lib/indirect.dart|package|barrel:barrel.dart': 1,
      'lib/use_seam.dart|symbol|ElevatedButton': 4,
    });
  }, timeout: const Timeout(Duration(minutes: 3)));

  test(
    'CLI enforces the committed baseline and reports malformed candidates',
    () async {
      final root = Directory.systemTemp.createTempSync('platform-ui-baseline-');
      addTearDown(() => root.deleteSync(recursive: true));
      void write(String path, String source) {
        File('${root.path}/$path')
          ..parent.createSync(recursive: true)
          ..writeAsStringSync(source);
      }

      Future<String> git(List<String> args) async {
        final result = await Process.run(
          'git',
          args,
          workingDirectory: root.path,
        );
        expect(result.exitCode, 0, reason: result.stderr.toString());
        return (result.stdout as String).trim();
      }

      Future<String> commit() async {
        await git(['add', '.']);
        await git([
          '-c',
          'user.name=Lint test',
          '-c',
          'user.email=lint@example.invalid',
          '-c',
          'commit.gpgsign=false',
          'commit',
          '-m',
          'Record fixture baseline',
        ]);
        return git(['rev-parse', 'HEAD']);
      }

      void candidate(int count) {
        write(
          'lib/a.dart',
          [
            for (var i = 0; i < count; i++)
              "import 'package:material_ui/material_ui.dart' as m$i;",
          ].join('\n'),
        );
        write('tool/platform_ui_allowlist.yaml', '''
version: 1
exceptions:
  - path: lib/a.dart
    package: "package:material_ui/material_ui.dart"
    count: $count
    owner: settings
    reason: Existing control migration
    removal: platform-ui-migration
''');
      }

      Future<ProcessResult> lint(String base) => Process.run('dart', [
        File('tool/platform_ui_lint.dart').absolute.path,
        '--root',
        root.path,
        '--base-ref',
        base,
      ]);

      write('pubspec.yaml', 'name: conduit\nenvironment:\n  sdk: ^3.13.0\n');
      write(
        '.dart_tool/package_config.json',
        jsonEncode({
          'configVersion': 2,
          'packages': [
            {
              'name': 'conduit',
              'rootUri': '../',
              'packageUri': 'lib/',
              'languageVersion': '3.13',
            },
            {
              'name': 'material_ui',
              'rootUri': '../material/',
              'packageUri': 'lib/',
              'languageVersion': '3.13',
            },
          ],
        }),
      );
      write('material/lib/material_ui.dart', 'class Theme {}\n');
      write('lib/a.dart', '');
      await git(['init', '--quiet']);
      final withoutAllowlist = await commit();
      candidate(1);
      final baseline = await commit();
      final introduction = await lint(withoutAllowlist);
      expect(introduction.exitCode, 0, reason: introduction.stderr.toString());

      candidate(2);
      final growth = await lint(baseline);
      expect(growth.exitCode, 1);
      expect(growth.stderr, contains('Expanded exception:'));
      final largerBaseline = await commit();
      candidate(1);
      final shrinking = await lint(largerBaseline);
      expect(shrinking.exitCode, 0, reason: shrinking.stderr.toString());
      final invalidBase = await lint('missing-platform-ui-base');
      expect(invalidBase.exitCode, 1);
      expect(invalidBase.stderr, contains('Invalid baseline ref:'));

      final allowlist = File('${root.path}/tool/platform_ui_allowlist.yaml');
      allowlist.writeAsStringSync(
        allowlist.readAsStringSync().replaceFirst('count: 1', 'count: "1"'),
      );
      final malformed = await lint(baseline);
      expect(malformed.exitCode, 1);
      expect(malformed.stderr, contains('Invalid exception:'));
      expect(malformed.stderr, isNot(contains('Unhandled exception')));
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test('exceptions must match exact live counts and carry ownership', () {
    const source = '''
version: 1
exceptions:
  - path: lib/a.dart
    symbol: Slider
    count: 2
    owner: settings
    reason: Existing slider awaiting migration
    removal: platform-ui-migration
''';
    expect(checkAllowlist({'lib/a.dart|symbol|Slider': 2}, source), isEmpty);
    expect(
      checkAllowlistGrowth(
        source,
        source.replaceAll('count: 2', 'count: 3'),
      ).single,
      startsWith('Expanded exception:'),
    );
    expect(
      checkAllowlistGrowth(source, source.replaceAll('count: 2', 'count: 1')),
      isEmpty,
    );
    expect(
      checkAllowlist({'lib/a.dart|symbol|Slider': 3}, source).single,
      startsWith('Expanded violation:'),
    );
    expect(checkAllowlist({}, source).single, startsWith('Stale exception:'));
    expect(
      checkAllowlist({
        'lib/b.dart|symbol|Switch': 1,
      }, 'version: 1\nexceptions: []\n').single,
      startsWith('New violation:'),
    );
    expect(
      checkAllowlist({}, source.replaceAll('lib/a.dart', 'lib/*.dart')).single,
      startsWith('Invalid exception:'),
    );
    for (final field in ['owner', 'removal']) {
      final value = field == 'owner' ? 'settings' : 'platform-ui-migration';
      for (final invalid in ['', 'Settings', 'settings/UI']) {
        expect(
          checkAllowlist(
            {},
            source.replaceAll('$field: $value', '$field: $invalid'),
          ).single,
          startsWith('Invalid exception:'),
        );
      }
    }
    expect(
      checkAllowlist({
        'lib/a.dart|symbol|Slider': 2,
      }, '$source${source.substring(source.indexOf('  - path:'))}').single,
      startsWith('Duplicate exception:'),
    );
  });
}
