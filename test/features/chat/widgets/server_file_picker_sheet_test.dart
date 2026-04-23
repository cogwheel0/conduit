import 'dart:async';

import 'package:conduit/core/models/file_info.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:conduit/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit/features/chat/widgets/server_file_picker_sheet.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('loads the first page once on first build', (
    WidgetTester tester,
  ) async {
    final api = _FakeServerFilePickerApiService(
      pageResponses: {
        1: (items: [_fileInfo('server-file-1')], total: 1, isPaginated: true),
      },
    );

    await tester.pumpWidget(_buildHarness(api));
    await tester.pumpAndSettle();

    expect(api.requestedPages, [1]);
    expect(find.text('server-file-1.txt'), findsOneWidget);
  });

  testWidgets('search refresh waits for the refreshed query to resolve', (
    WidgetTester tester,
  ) async {
    final refreshCompleter = Completer<List<FileInfo>>();
    final api = _FakeServerFilePickerApiService(
      pageResponses: {
        1: (items: [_fileInfo('server-file-1')], total: 1, isPaginated: true),
      },
      searchResponses: [
        Future<List<FileInfo>>.value([_fileInfo('search-initial')]),
        refreshCompleter.future,
      ],
    );

    await tester.pumpWidget(_buildHarness(api));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'search');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(find.text('search-initial.txt'), findsOneWidget);
    expect(api.searchQueries, ['search']);

    final refreshIndicator = tester.widget<RefreshIndicator>(
      find.byType(RefreshIndicator),
    );

    var refreshCompleted = false;
    final refreshFuture = refreshIndicator.onRefresh().then((_) {
      refreshCompleted = true;
    });

    await tester.pump();

    expect(api.searchQueries, ['search', 'search']);
    expect(refreshCompleted, isFalse);

    refreshCompleter.complete([_fileInfo('search-refreshed')]);
    await refreshFuture;
    await tester.pumpAndSettle();

    expect(refreshCompleted, isTrue);
    expect(find.text('search-refreshed.txt'), findsOneWidget);
  });
}

Widget _buildHarness(ApiService api) {
  return ProviderScope(
    overrides: [
      isAuthenticatedProvider2.overrideWithValue(true),
      apiServiceProvider.overrideWithValue(api),
    ],
    child: MaterialApp(
      theme: AppTheme.light(TweakcnThemes.t3Chat),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: ServerFilePickerSheet(onSelected: (_) {})),
    ),
  );
}

class _FakeServerFilePickerApiService extends ApiService {
  _FakeServerFilePickerApiService({
    this.pageResponses = const {},
    this.searchResponses = const [],
  }) : super(
         serverConfig: const ServerConfig(
           id: 'test',
           name: 'Test',
           url: 'https://example.com',
         ),
         workerManager: WorkerManager(),
       );

  final Map<int, ({List<FileInfo> items, int? total, bool isPaginated})>
  pageResponses;
  final List<Future<List<FileInfo>>> searchResponses;
  final List<int> requestedPages = <int>[];
  final List<String> searchQueries = <String>[];

  @override
  Future<({List<FileInfo> items, int? total, bool isPaginated})>
  getUserFilesPage({int page = 1}) async {
    requestedPages.add(page);
    return pageResponses[page] ??
        (items: const <FileInfo>[], total: null, isPaginated: true);
  }

  @override
  Future<List<FileInfo>> searchFiles({
    String? query,
    String? contentType,
    int? limit,
    int? offset,
  }) async {
    final trimmedQuery = query?.trim() ?? '';
    searchQueries.add(trimmedQuery);
    final index = searchQueries.length - 1;
    if (index < searchResponses.length) {
      return searchResponses[index];
    }
    return const <FileInfo>[];
  }
}

FileInfo _fileInfo(String id) {
  return FileInfo(
    id: id,
    filename: '$id.txt',
    originalFilename: '$id.txt',
    size: 128,
    mimeType: 'text/plain',
    createdAt: DateTime.utc(2026, 1, 1),
    updatedAt: DateTime.utc(2026, 1, 2),
  );
}
