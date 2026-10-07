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
    write('lib/generated.g.dart', "import 'package:flutter/material.dart';\n");
    final result = await Process.run('dart', [
      File('tool/platform_ui_lint.dart').absolute.path,
      '--root',
      root.path,
      '--inventory',
    ]);
    expect(result.exitCode, 0, reason: result.stderr.toString());
    final counts = jsonDecode(result.stdout as String);
    expect(counts, {
      'lib/barrel.dart|package|package:material_ui/material_ui.dart': 1,
      'lib/conditional.dart|package|package:flutter/cupertino.dart': 1,
      'lib/direct.dart|package|package:material_ui/material_ui.dart': 1,
      'lib/indirect.dart|package|barrel:barrel.dart': 1,
      'lib/use_seam.dart|symbol|ElevatedButton': 4,
    });
  }, timeout: const Timeout(Duration(minutes: 3)));

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
