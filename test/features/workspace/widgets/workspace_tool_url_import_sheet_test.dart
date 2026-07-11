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
}
