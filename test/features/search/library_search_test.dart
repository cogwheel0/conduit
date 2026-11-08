import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:conduit/features/search/providers/library_search_providers.dart';
import 'package:conduit/features/search/views/library_search_page.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/chat_database_repository.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/database/mappers/chat_blob_mapper.dart';
import 'package:conduit_core/models/folder.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/connectivity_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class SearchAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  FutureOr<Object?> Function(RequestOptions)? respond;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? body,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final data =
        await (respond?.call(options) ??
            switch (options.path) {
              '/api/v1/chats/search' => [chat('body-match', 'Color study')],
              '/api/v1/chats/body-match/search/snippet' =>
                'A cobalt kite crosses the sky.',
              '/api/v1/notes/search' => {
                'items': [
                  {
                    'id': 'note-1',
                    'title': 'Sketchbook',
                    'created_at': 1,
                    'updated_at': 1,
                    'data': {
                      'content': {'md': 'Mix cobalt with white.'},
                    },
                  },
                ],
                'total': 1,
              },
              _ => [],
            });
    if (data is ResponseBody) return data;
    return ResponseBody.fromString(
      jsonEncode(data),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  static Map<String, Object> chat(String id, String title) => {
    'id': id,
    'title': title,
    'created_at': 1,
    'updated_at': 2,
  };

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase local;
  late SearchAdapter adapter;
  late ApiService api;
  late ProviderContainer container;

  setUp(() {
    local = AppDatabase(NativeDatabase.memory());
    adapter = SearchAdapter();
    api = ApiService(
      serverConfig: const ServerConfig(
        id: 'fixture',
        name: 'Fixture',
        url: 'https://example.test',
      ),
      workerManager: WorkerManager(),
      authToken: 'synthetic-session',
    );
    api.dio.httpClientAdapter = adapter;
    container = ProviderContainer(
      overrides: [
        reviewerModeProvider.overrideWithValue(true),
        openWebUiAuthSessionEpochProvider.overrideWithValue(Object()),
        apiServiceProvider.overrideWithValue(api),
        isOnlineProvider.overrideWithValue(true),
        appDatabaseProvider.overrideWithValue(null),
        directLocalDatabaseProvider.overrideWithValue(local),
        openWebUiAccountAvailableProvider.overrideWithValue(true),
        foldersAvailableProvider.overrideWithValue(true),
        foldersProvider.overrideWith(() => _Folders()),
      ],
    );
  });
  tearDown(() async {
    container.dispose();
    api.dispose();
    await local.close();
  });

  Future<LibrarySearchBatch> load(LibrarySearchRequest request) {
    final provider = librarySearchPageProvider(request);
    container.listen(provider, (_, _) {});
    return container.read(provider.future);
  }

  test(
    'remote search uses supported full-text query and page, not offset',
    () async {
      final page = await load((
        source: LibrarySearchSource.chats,
        query: 'cobalt',
        page: 2,
      ));
      expect(adapter.requests.single.queryParameters, {
        'text': 'cobalt',
        'page': 2,
      });
      expect(page.items.single.title, 'Color study');
      expect(page.items.single.title.toLowerCase(), isNot(contains('cobalt')));
      expect(
        chatStorageKindOf(page.items.single.conversation!),
        ChatStorageKind.openWebUi,
      );
      expect(page.hasMore, isFalse);
      expect(
        adapter.requests.any((r) => r.path.contains('messages/search')),
        isFalse,
      );
    },
  );

  test(
    'on-device full-text search finds a message outside the loaded list',
    () async {
      await local.chatsDao.upsertLocalOnlyChat(
        rows: ChatBlobMapper.blobToRows(
          chatId: 'local-body',
          title: 'Palette notes',
          createdAt: 1,
          updatedAt: 2,
          blob: {
            'title': 'Palette notes',
            'history': {
              'currentId': 'message',
              'messages': {
                'message': {
                  'id': 'message',
                  'parentId': null,
                  'childrenIds': <String>[],
                  'role': 'user',
                  'content': 'Use cobalt for the evening sky.',
                  'timestamp': 2,
                },
              },
            },
          },
        ),
      );
      final page = await container.read(
        librarySearchPageProvider((
          source: LibrarySearchSource.localChats,
          query: 'cobalt',
          page: 1,
        )).future,
      );
      expect(page.items.single.title, 'Palette notes');
      expect(page.items.single.excerpt, contains('cobalt'));
      expect(
        chatStorageKindOf(page.items.single.conversation!),
        ChatStorageKind.directLocal,
      );
      expect(adapter.requests, isEmpty);
    },
  );

  test(
    'remote search errors are visible, never mislabeled as no results',
    () async {
      adapter.respond = (request) => throw DioException(
        requestOptions: request,
        type: DioExceptionType.connectionError,
      );
      await expectLater(
        load((source: LibrarySearchSource.chats, query: 'cobalt', page: 1)),
        throwsA(
          isA<DioException>().having(
            (error) => error.type,
            'type',
            DioExceptionType.connectionError,
          ),
        ),
      );
    },
  );

  test('snippet endpoint is optional on older servers', () async {
    adapter.respond = (request) => ResponseBody.fromString(
      '{}',
      404,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
    expect(
      await api.getChatSearchSnippet(chatId: 'body-match', query: 'cobalt'),
      isNull,
    );
  });

  test('dropping a query cancels its transport', () async {
    final pending = Completer<Object?>();
    adapter.respond = (_) => pending.future;
    final provider = librarySearchPageProvider((
      source: LibrarySearchSource.chats,
      query: 'cobalt',
      page: 1,
    ));
    final subscription = container.listen(provider, (_, _) {});
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(adapter.requests, hasLength(1));
    subscription.close();
    await container.pump();
    expect(adapter.requests.single.cancelToken!.isCancelled, isTrue);
    pending.complete([]);
  });

  Future<void> pumpSearch(
    WidgetTester tester, {
    Size size = const Size(390, 844),
    bool dark = false,
    double textScale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: dark
              ? AppTheme.dark(TweakcnThemes.conduit)
              : AppTheme.light(TweakcnThemes.conduit),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: const LibrarySearchPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('full-page search shows body excerpts and switches scopes', (
    tester,
  ) async {
    await pumpSearch(tester);
    expect(find.text('Search your library'), findsNWidgets(2));
    await tester.enterText(find.byType(TextField), 'cobalt');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.text('Color study'), findsOneWidget);
    expect(
      find.textContaining('A cobalt kite', findRichText: true),
      findsOneWidget,
    );
    expect(find.text('Cobalt studies'), findsOneWidget);
    expect(find.text('Sketchbook'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('search-filter-folders')));
    await tester.pumpAndSettle();
    expect(find.text('Color study'), findsNothing);
    expect(find.text('Cobalt studies'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('search-filter-notes')));
    await tester.pumpAndSettle();
    expect(find.text('Sketchbook'), findsOneWidget);
    expect(
      find.textContaining('Mix cobalt', findRichText: true),
      findsOneWidget,
    );
    await tester.tap(find.byIcon(Icons.clear));
    await tester.pumpAndSettle();
    expect(find.text('Sketchbook'), findsNothing);
    expect(find.text('Search your library'), findsNWidgets(2));
  });

  testWidgets('replaced query cannot reveal a late response', (tester) async {
    final old = Completer<Object?>();
    adapter.respond = (request) {
      if (request.path == '/api/v1/chats/search') {
        return request.queryParameters['text'] == 'old'
            ? old.future
            : [SearchAdapter.chat('new', 'Fresh result')];
      }
      return [];
    };
    await pumpSearch(tester);
    await tester.enterText(find.byType(TextField), 'old');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.enterText(find.byType(TextField), 'new');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    old.complete([SearchAdapter.chat('old', 'Stale result')]);
    await tester.pumpAndSettle();
    expect(find.text('Fresh result'), findsOneWidget);
    expect(find.text('Stale result'), findsNothing);
  });

  testWidgets('pagination retains results, retries, and deduplicates pages', (
    tester,
  ) async {
    var secondPageAttempts = 0;
    adapter.respond = (request) {
      if (request.path != '/api/v1/chats/search') return [];
      if (request.queryParameters['page'] == 1) {
        return List.generate(60, (i) => SearchAdapter.chat('$i', 'Swatch $i'));
      }
      if (++secondPageAttempts == 1) {
        throw DioException(
          requestOptions: request,
          type: DioExceptionType.connectionError,
        );
      }
      return [
        SearchAdapter.chat('59', 'Swatch 59'),
        SearchAdapter.chat('60', 'Final swatch'),
      ];
    };
    await pumpSearch(tester);
    await tester.tap(find.byKey(const ValueKey('search-filter-chats')));
    await tester.enterText(find.byType(TextField), 'swatch');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    final more = find.byKey(const ValueKey('search-more-chats'));
    final scrollable = find
        .descendant(
          of: find.byType(CustomScrollView),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      more,
      500,
      maxScrolls: 20,
      scrollable: scrollable,
    );
    await tester.tap(more);
    await tester.pumpAndSettle();
    expect(find.text('Swatch 59'), findsOneWidget);
    await tester.tap(find.textContaining('Retry'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Final swatch'),
      200,
      scrollable: scrollable,
    );
    expect(find.text('Swatch 59'), findsOneWidget);
    expect(find.text('Final swatch'), findsOneWidget);
    expect(more, findsNothing);
    expect(secondPageAttempts, 2);
  });

  testWidgets(
    'selecting a folder returns its identity; close returns no result',
    (tester) async {
      Object? selection;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.light(TweakcnThemes.conduit),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Builder(
              builder: (context) => TextButton(
                child: const Text('Open search'),
                onPressed: () async => selection = await Navigator.of(context)
                    .push<Object>(
                      MaterialPageRoute(
                        builder: (_) => const LibrarySearchPage(),
                      ),
                    ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open search'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'cobalt');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cobalt studies'));
      await tester.pumpAndSettle();
      expect(
        selection,
        isA<({LibrarySearchSource source, LibrarySearchResult result})>(),
      );
      final result =
          selection
              as ({LibrarySearchSource source, LibrarySearchResult result});
      expect(result.source, LibrarySearchSource.folders);
      expect(result.result.id, 'folder-1');
      await tester.tap(find.text('Open search'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('library-search-close')));
      await tester.pumpAndSettle();
      expect(selection, isNull);
    },
  );

  testWidgets(
    'account transition clears results even with the same API object',
    (tester) async {
      await pumpSearch(tester);
      await tester.enterText(find.byType(TextField), 'cobalt');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(find.text('Color study'), findsOneWidget);
      adapter.respond = (_) => [];
      container.updateOverrides([
        reviewerModeProvider.overrideWithValue(true),
        openWebUiAuthSessionEpochProvider.overrideWithValue(Object()),
        apiServiceProvider.overrideWithValue(api),
        isOnlineProvider.overrideWithValue(true),
        appDatabaseProvider.overrideWithValue(null),
        directLocalDatabaseProvider.overrideWithValue(local),
        openWebUiAccountAvailableProvider.overrideWithValue(true),
        foldersAvailableProvider.overrideWithValue(true),
        foldersProvider.overrideWith(() => _Folders()),
      ]);
      await tester.pumpAndSettle();
      expect(find.text('Color study'), findsNothing);
    },
  );

  testWidgets('iPad layout, dark mode and large text remain usable', (
    tester,
  ) async {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => PlatformUiCapabilities.debugPlatformOverride = null);
    await pumpSearch(
      tester,
      size: const Size(1024, 768),
      dark: true,
      textScale: 2,
    );
    await tester.enterText(find.byType(EditableText), 'cobalt');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    final chipLabel = find.descendant(
      of: find.byKey(const ValueKey('search-filter-all')),
      matching: find.byType(Text),
    );
    final context = tester.element(chipLabel);
    final foreground = DefaultTextStyle.of(context).style.color!
        .computeLuminance();
    final background = context.conduitTheme.surfaceContainer.computeLuminance();
    expect(
      (foreground + 0.05) / (background + 0.05),
      greaterThanOrEqualTo(4.5),
    );
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(EditableText)).width, lessThan(760));
    expect(
      find.byKey(const ValueKey('library-search-close')).hitTestable(),
      findsOneWidget,
    );
  });
}

class _Folders extends Folders {
  @override
  Future<List<Folder>> build() async => [
    const Folder(id: 'folder-1', name: 'Cobalt studies'),
  ];
}
