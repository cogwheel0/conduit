import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conduit/features/workspace/widgets/workspace_tool_url_import_sheet.dart';
import 'package:conduit/l10n/app_localizations.dart';

Future<List<String>> _pumpAndRun(
  WidgetTester tester, {
  required String url,
  Map<String, dynamic> Function()? result,
}) async {
  final calls = <String>[];
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: WorkspaceToolUrlImportSheet(
            loader: (value) async {
              calls.add(value);
              return result?.call() ?? const <String, dynamic>{};
            },
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.enterText(
    find.byKey(const Key('workspace-tool-url-field')),
    url,
  );
  await tester.tap(find.byKey(const Key('workspace-tool-url-run')));
  await tester.pumpAndSettle();
  return calls;
}

void main() {
  testWidgets('does not forward a link-local metadata URL to the loader', (
    tester,
  ) async {
    final calls = await _pumpAndRun(
      tester,
      url: 'http://169.254.169.254/latest/meta-data/',
    );

    expect(calls, isEmpty);
    expect(find.byKey(const Key('workspace-tool-url-error')), findsOneWidget);
  });

  testWidgets('does not forward an internal https host to the loader', (
    tester,
  ) async {
    final calls = await _pumpAndRun(
      tester,
      url: 'https://internal.corp/tool.py',
    );

    expect(calls, isEmpty);
    expect(find.byKey(const Key('workspace-tool-url-error')), findsOneWidget);
  });

  testWidgets('forwards a normalized GitHub URL to the loader', (tester) async {
    final calls = await _pumpAndRun(
      tester,
      url: 'https://github.com/acme/tools/blob/main/search/tool.py',
      result: () => {'name': 'Search', 'content': '"""\n"""\n'},
    );

    expect(calls, hasLength(1));
    expect(
      calls.single,
      'https://raw.githubusercontent.com/acme/tools/refs/heads/main/search/tool.py',
    );
  });

  group('normalizeImportedTool', () {
    test('derives id from the original name, not the front-matter title', () {
      final tool = normalizeImportedTool(const {
        'name': 'main',
        'content': '"""\ntitle: Web Search\n"""\n',
      });
      // The front-matter title becomes the display name, but the id stays tied
      // to the original name so the import does not silently retarget.
      expect(tool['id'], 'main');
      expect(tool['name'], 'Web Search');
    });

    test('falls back to nameToId(title) when the name is empty', () {
      final tool = normalizeImportedTool(const {
        'name': '',
        'content': '"""\ntitle: Web Search\n"""\n',
      });
      expect(tool['id'], 'web_search');
    });

    test('keeps an explicit id untouched', () {
      final tool = normalizeImportedTool(const {
        'id': 'custom_id',
        'name': 'main',
        'content': '"""\ntitle: Web Search\n"""\n',
      });
      expect(tool['id'], 'custom_id');
    });

    test(
      'falls back to the title id when a punctuation-only name slugifies to ""',
      () {
        final tool = normalizeImportedTool(const {
          'name': '!!!',
          'content': '"""\ntitle: Web Search\n"""\n',
        });
        // '!!!' is non-empty but nameToId('!!!') == '', so the id must fall back
        // to the front-matter title rather than end up empty/invalid.
        expect(tool['id'], 'web_search');
      },
    );

    test('falls back to a safe default when no name or title yields an id', () {
      final tool = normalizeImportedTool(const {
        'name': '!!!',
        'content': '"""\n"""\n',
      });
      expect(tool['id'], 'tool');
    });
  });
}
