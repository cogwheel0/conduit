import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conduit/features/workspace/widgets/workspace_import_sheet.dart';
import 'package:conduit/l10n/app_localizations.dart';

void main() {
  group('runWorkspaceImport', () {
    test('records per-item failures without aborting the batch', () async {
      final attempted = <int>[];
      final report = await runWorkspaceImport(
        [
          {'name': 'Alpha'},
          {'name': 'Bravo'},
          {'name': 'Charlie'},
        ],
        importItem: (item) async {
          final name = item['name'] as String;
          attempted.add(1);
          if (name == 'Bravo') {
            throw StateError('boom');
          }
        },
        labelOf: (item) => item['name'] as String,
      );

      // Every item was attempted even though the middle one failed.
      expect(attempted, hasLength(3));
      expect(report.total, 3);
      expect(report.successCount, 2);
      expect(report.failureCount, 1);
      expect(report.hasFailures, isTrue);
      expect(report.failures.single.label, 'Bravo');
      expect(report.failures.single.error, contains('boom'));
    });

    test('all-success report has no failures', () async {
      final report = await runWorkspaceImport(
        [
          {'name': 'Only'},
        ],
        importItem: (_) async {},
      );
      expect(report.hasFailures, isFalse);
      expect(report.successCount, 1);
    });
  });

  group('workspaceImportItemsFromJson', () {
    test('accepts a bare list', () {
      final items = workspaceImportItemsFromJson([
        {'id': '1'},
        {'id': '2'},
      ]);
      expect(items, hasLength(2));
    });

    test('unwraps an envelope with an items list', () {
      final items = workspaceImportItemsFromJson({
        'items': [
          {'id': '1'},
        ],
      });
      expect(items, hasLength(1));
    });

    test('treats a single object as a one-item import', () {
      final items = workspaceImportItemsFromJson({'id': 'solo'});
      expect(items, hasLength(1));
      expect(items.single['id'], 'solo');
    });

    test('non-JSON scalars yield an empty list', () {
      expect(workspaceImportItemsFromJson('nope'), isEmpty);
    });
  });

  group('WorkspaceImportSheet', () {
    testWidgets('reports per-item success and failure after running', (
      tester,
    ) async {
      final report = WorkspaceImportReport([
        const WorkspaceImportItemResult(
          index: 0,
          label: 'Alpha',
          succeeded: true,
        ),
        const WorkspaceImportItemResult(
          index: 1,
          label: 'Bravo',
          succeeded: false,
          error: 'permission denied',
        ),
      ]);

      List<Map<String, dynamic>>? receivedItems;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: WorkspaceImportSheet(
                title: 'Import models',
                importer: (items) async {
                  receivedItems = items;
                  return report;
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('workspace-import-json-field')),
        '[{"name":"Alpha"},{"name":"Bravo"}]',
      );
      await tester.ensureVisible(
        find.byKey(const Key('workspace-import-run')),
      );
      await tester.tap(find.byKey(const Key('workspace-import-run')));
      await tester.pumpAndSettle();

      expect(receivedItems, hasLength(2));
      expect(find.byKey(const Key('workspace-import-summary')), findsOneWidget);
      expect(
        find.byKey(const Key('workspace-import-result-0')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('workspace-import-result-1')),
        findsOneWidget,
      );
      // The failed item surfaces its error message.
      expect(find.text('permission denied'), findsOneWidget);
      expect(find.byIcon(Icons.error_outline), findsWidgets);
    });

    testWidgets('invalid JSON shows an inline error and does not run importer', (
      tester,
    ) async {
      var importerCalls = 0;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: WorkspaceImportSheet(
                title: 'Import models',
                importer: (items) async {
                  importerCalls++;
                  return const WorkspaceImportReport([]);
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('workspace-import-json-field')),
        'not json',
      );
      await tester.ensureVisible(
        find.byKey(const Key('workspace-import-run')),
      );
      await tester.tap(find.byKey(const Key('workspace-import-run')));
      await tester.pumpAndSettle();

      expect(importerCalls, 0);
      expect(find.byKey(const Key('workspace-import-error')), findsOneWidget);
      expect(find.byKey(const Key('workspace-import-summary')), findsNothing);
    });
  });
}
