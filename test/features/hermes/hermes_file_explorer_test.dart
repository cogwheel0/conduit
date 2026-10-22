import 'dart:io';
import 'dart:ui' as ui;

import 'package:conduit/features/hermes/providers/hermes_file_browser.dart';
import 'package:conduit/features/hermes/providers/hermes_mobile_navigation.dart';
import 'package:conduit/features/hermes/providers/hermes_mobile_files.dart';
import 'package:conduit/features/hermes/widgets/hermes_mobile_shell.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/hermes/models/hermes_file_entry.dart';
import 'package:conduit_core/features/hermes/models/hermes_model.dart';
import 'package:conduit_core/features/hermes/models/hermes_session.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_file_browser_service.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:dio/dio.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:go_router/go_router.dart';

const _folder = HermesFileEntry(
  name: 'projects',
  path: '/server/.hermes/projects',
  isDirectory: true,
);
const _file = HermesFileEntry(
  name: 'SOUL.md',
  path: '/server/.hermes/SOUL.md',
  isDirectory: false,
  size: 1234,
);

class _Files implements HermesFileBrowserService {
  List<HermesFileEntry> entries = [_folder, _file];
  final browsed = <String?>[];
  final created = <({String directory, String name, String? content})>[];
  bool fail = false;
  bool locked = false;
  int reads = 0;

  @override
  Future<HermesDirectory> browseFiles({
    String? path,
    CancelToken? cancelToken,
  }) async {
    browsed.add(path);
    if (path == '/missing') throw StateError('Missing folder');
    return HermesDirectory(
      path: path ?? '/server/.hermes',
      root: locked ? '/server/.hermes' : null,
      canChangePath: !locked,
      parent: locked && path == null
          ? null
          : path == _folder.path
          ? '/server/.hermes'
          : '/server',
      entries: path == _folder.path ? const [] : entries,
    );
  }

  @override
  Future<void> createFile({
    required String directory,
    required String name,
    required String content,
  }) async {
    if (fail) throw StateError('Conflict');
    created.add((directory: directory, name: name, content: content));
  }

  @override
  Future<void> createDirectory({
    required String directory,
    required String name,
  }) async {
    created.add((directory: directory, name: name, content: null));
  }

  @override
  Future<String> readFileDataUrl(
    String path, {
    CancelToken? cancelToken,
  }) async {
    reads++;
    return 'data:text/plain;base64,U291bCBjb250ZW50';
  }
}

Future<ProviderContainer> _pump(
  WidgetTester tester,
  _Files service, {
  Brightness brightness = Brightness.light,
  double scale = 1,
  bool openFolders = true,
}) async {
  final container = ProviderContainer(
    overrides: [
      hermesMobileLayoutProvider.overrideWithValue(true),
      apiServiceProvider.overrideWithValue(null),
      hermesApiServiceProvider.overrideWithValue(null),
      hermesFileBrowserAccessProvider.overrideWithValue(service),
      hermesFilePinStorageKeyProvider.overrideWithValue('hermes-test-pins'),
      hermesMobileFilesProvider.overrideWith(
        (_) => Stream.value(
          const HermesFileLibrary([
            HermesLibraryFile(
              name: 'report.pdf',
              category: HermesFileCategory.artifacts,
              session: HermesSessionSummary(
                id: 'fixture-report',
                title: 'Research summary',
              ),
              messageId: 'report',
              extractedText: 'Three sources and recommendations.',
            ),
          ]),
        ),
      ),
      hermesSessionsProvider.overrideWith(() => _Sessions()),
      isChatStreamingProvider.overrideWithValue(false),
      selectedModelProvider.overrideWith(_Selected.new),
    ],
  );
  addTearDown(container.dispose);
  container
      .read(hermesMobileNavigationProvider.notifier)
      .select(HermesWorkArea.files);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: RepaintBoundary(
        key: const ValueKey('explorer-render'),
        child: MaterialApp(
          theme: brightness == Brightness.dark
              ? AppTheme.dark(TweakcnThemes.conduit)
              : AppTheme.light(TweakcnThemes.conduit),
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: const HermesMobileShell(child: Text('Chat content')),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  if (openFolders) {
    await tester.tap(find.byKey(const ValueKey('hermes-files-folders')));
    await tester.pumpAndSettle();
  }
  return container;
}

class _Sessions extends HermesSessionsController {
  @override
  Future<List<HermesSessionSummary>> build() async => [];
}

class _Selected extends SelectedModel {
  @override
  Model? build() => hermesSyntheticModel();
}

Future<void> _capture(WidgetTester tester, String name) async {
  await tester.runAsync(() async {
    final boundary =
        tester
                .element(find.byKey(const ValueKey('explorer-render')))
                .findRenderObject()!
            as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final directory = Directory('build/hermes-file-explorer');
    directory.createSync(recursive: true);
    File('${directory.path}/$name.png')
        .writeAsBytesSync(data!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'Files starts with outputs and previews, opening server folders only on request',
    (tester) async {
      final service = _Files();
      final container = await _pump(tester, service, openFolders: false);
      expect(service.browsed, isEmpty);
      expect(find.text('report.pdf'), findsOneWidget);
      expect(find.text('SOUL.md'), findsNothing);
      await tester.tap(find.text('report.pdf'));
      await tester.pumpAndSettle();
      expect(find.text('Three sources and recommendations.'), findsOneWidget);
      expect(service.reads, 0);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('hermes-files-folders')));
      await tester.pumpAndSettle();
      expect(service.browsed, [null]);
      expect(container.read(hermesFileBrowserBackProvider).back(), isTrue);
      await tester.pumpAndSettle();
      expect(find.text('report.pdf'), findsOneWidget);
      expect(find.text('SOUL.md'), findsNothing);
    },
  );

  testWidgets(
    'header Back follows folder history and restores the recent-file search',
    (tester) async {
      final service = _Files();
      await _pump(tester, service, openFolders: false);
      await tester.enterText(find.byType(TextField), 'report');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('hermes-files-folders')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('projects'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('hermes-explorer-back')));
      await tester.pumpAndSettle();
      expect(find.text('SOUL.md'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('hermes-explorer-back')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<EditableText>(find.byType(EditableText)).controller.text,
        'report',
      );
      expect(find.text('report.pdf'), findsOneWidget);
      expect(find.text('SOUL.md'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Browse and Pinned expose selection with the shared underline', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await _pump(tester, _Files());
      BorderSide underline(String scope) =>
          ((tester
                              .widget<DecoratedBox>(
                                find.byKey(
                                  ValueKey('hermes-explorer-$scope-indicator'),
                                ),
                              )
                              .decoration
                          as BoxDecoration)
                      .border
                  as Border)
              .bottom;
      expect(underline('browse').width, 2);
      expect(underline('pinned').width, 1);
      expect(
        tester.getSemantics(
          find.byKey(const ValueKey('hermes-explorer-browse-state')),
        ),
        isSemantics(isSelected: true),
      );
      await tester.tap(find.byKey(const ValueKey('hermes-explorer-pinned')));
      await tester.pumpAndSettle();
      expect(underline('browse').width, 1);
      expect(underline('pinned').width, 2);
      expect(
        tester.getSemantics(
          find.byKey(const ValueKey('hermes-explorer-pinned-state')),
        ),
        isSemantics(isSelected: true),
      );
      expect(
        tester.getSemantics(
          find.byKey(const ValueKey('hermes-explorer-browse-state')),
        ),
        isSemantics(isSelected: false),
      );
      expect(
        tester
            .getSize(find.byKey(const ValueKey('hermes-explorer-pinned')))
            .height,
        greaterThanOrEqualTo(48),
      );
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets(
    'bottom Files returns to recent files and folders reopen at Hermes home',
    (tester) async {
      final container = await _pump(tester, _Files());
      await tester.tap(find.text('projects'));
      await tester.pumpAndSettle();
      expect(find.textContaining('This folder is empty'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('hermes-nav-files')));
      await tester.pumpAndSettle();
      expect(find.text('SOUL.md'), findsNothing);
      expect(container.read(hermesFileBrowserBackProvider).back(), isFalse);
      await tester.tap(find.byKey(const ValueKey('hermes-files-folders')));
      await tester.pumpAndSettle();
      expect(find.text('SOUL.md'), findsOneWidget);
      expect(
        container.read(hermesMobileNavigationProvider).area,
        HermesWorkArea.files,
      );
      await tester.enterText(
        find.byType(TextField),
        'no-match-for-root-search',
      );
      await tester.pumpAndSettle();
      expect(find.text('SOUL.md'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('hermes-nav-files')));
      await tester.pumpAndSettle();
      expect(find.text('report.pdf'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('hermes-files-folders')));
      await tester.pumpAndSettle();
      expect(find.text('SOUL.md'), findsOneWidget);
      expect(
        tester.widget<EditableText>(find.byType(EditableText)).controller.text,
        isEmpty,
      );
    },
  );

  testWidgets(
    'Android Back crosses the GoRouter shell to return to the previous Files folder',
    (tester) async {
      final container = await _pump(tester, _Files());
      final router = GoRouter(
        routes: [
          ShellRoute(
            builder: (context, state, child) => HermesMobileShell(child: child),
            routes: [
              GoRoute(
                path: '/',
                builder: (context, state) => const Text('Chat content'),
              ),
            ],
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            routerConfig: router,
            theme: AppTheme.light(TweakcnThemes.conduit),
            localizationsDelegates: conduitLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('hermes-files-folders')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('projects'));
      await tester.pumpAndSettle();
      expect(find.textContaining('This folder is empty'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('hermes-explorer-create')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New file'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('hermes-explorer-name')),
        findsOneWidget,
      );
      expect(await tester.binding.handlePopRoute(), isTrue);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('hermes-explorer-name')), findsNothing);
      expect(find.textContaining('This folder is empty'), findsOneWidget);
      expect(await tester.binding.handlePopRoute(), isTrue);
      await tester.pumpAndSettle();
      expect(find.text('SOUL.md'), findsOneWidget);
      expect(
        container.read(hermesMobileNavigationProvider).area,
        HermesWorkArea.files,
      );
    },
  );

  testWidgets(
    'opens server folders and Android Back returns to the explorer parent',
    (tester) async {
      final service = _Files();
      final container = await _pump(tester, service);
      expect(find.text('SOUL.md'), findsOneWidget);
      expect(service.browsed, [null]);
      await tester.tap(find.text('projects'));
      await tester.pumpAndSettle();
      expect(service.browsed.last, _folder.path);
      expect(find.textContaining('This folder is empty'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('SOUL.md'), findsOneWidget);
      expect(
        container.read(hermesMobileNavigationProvider).area,
        HermesWorkArea.files,
      );
    },
  );

  testWidgets(
    'long press Ask Hermes opens a draft without reading or sending the file',
    (tester) async {
      final service = _Files();
      final container = await _pump(tester, service);
      await tester.longPress(find.text('SOUL.md'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ask Hermes'));
      await tester.pumpAndSettle();
      expect(
        container.read(hermesMobileNavigationProvider).area,
        HermesWorkArea.chat,
      );
      expect(
        container.read(hermesMobileNavigationProvider).conversation,
        isTrue,
      );
      expect(
        container.read(prefilledInputTextProvider),
        contains('"/server/.hermes/SOUL.md"'),
      );
      expect(container.read(chatMessagesProvider), isEmpty);
      expect(service.reads, 0);
      expect(service.created, isEmpty);
    },
  );

  testWidgets(
    'pins files and folders, restores them, and scopes them to the connection',
    (tester) async {
      final container = await _pump(tester, _Files());
      final folderRow = find.byKey(
        ValueKey('hermes-explorer-entry-${_folder.path}'),
      );
      final folderName = find.descendant(
        of: folderRow,
        matching: find.text('projects'),
      );
      await tester.longPress(folderRow);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pin'));
      await tester.pumpAndSettle();
      expect(
        container.read(hermesFilePinsProvider).requireValue.single.path,
        _folder.path,
      );
      expect(folderName, findsOneWidget);
      expect(find.text('Folder'), findsNothing);
      expect(folderRow, findsOneWidget);
      await tester.enterText(find.byType(TextField), 'projects');
      await tester.pumpAndSettle();
      expect(folderName, findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('hermes-explorer-pinned')));
      await tester.pumpAndSettle();
      expect(folderName, findsOneWidget);
      expect(find.text('SOUL.md'), findsNothing);
      final restored = ProviderContainer(
        overrides: [
          hermesFilePinStorageKeyProvider.overrideWithValue('hermes-test-pins'),
          hermesMobileFilesProvider.overrideWith(
            (_) => Stream.value(
              const HermesFileLibrary([
                HermesLibraryFile(
                  name: 'report.pdf',
                  category: HermesFileCategory.artifacts,
                  session: HermesSessionSummary(
                    id: 'fixture-report',
                    title: 'Research summary',
                  ),
                  messageId: 'report',
                  extractedText: 'Three sources and recommendations.',
                ),
              ]),
            ),
          ),
        ],
      );
      final other = ProviderContainer(
        overrides: [
          hermesFilePinStorageKeyProvider.overrideWithValue(
            'hermes-other-server-pins',
          ),
        ],
      );
      addTearDown(restored.dispose);
      addTearDown(other.dispose);
      expect(
        (await restored.read(hermesFilePinsProvider.future)).single.path,
        _folder.path,
      );
      expect(await other.read(hermesFilePinsProvider.future), isEmpty);
      await tester.longPress(folderRow);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Unpin'));
      await tester.pumpAndSettle();
      expect(container.read(hermesFilePinsProvider).requireValue, isEmpty);
    },
  );

  testWidgets(
    'creates a file in the selected folder and preserves content after failure',
    (tester) async {
      final service = _Files()..fail = true;
      await _pump(tester, service);
      await tester.tap(find.byKey(const ValueKey('hermes-explorer-create')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New file'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('hermes-explorer-name')),
          matching: find.byType(TextField),
        ),
        'notes.md',
      );
      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('hermes-explorer-content')),
          matching: find.byType(TextField),
        ),
        'Keep this draft',
      );
      await tester.tap(find.byKey(const ValueKey('hermes-explorer-save')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Could not create this item'), findsOneWidget);
      expect(find.text('Keep this draft'), findsOneWidget);
      service.fail = false;
      await tester.tap(find.byKey(const ValueKey('hermes-explorer-save')));
      await tester.pumpAndSettle();
      expect(service.created.single, (
        directory: '/server/.hermes',
        name: 'notes.md',
        content: 'Keep this draft',
      ));
      expect(find.byKey(const ValueKey('hermes-explorer-save')), findsNothing);
      expect(service.browsed, hasLength(2));
    },
  );

  testWidgets('creates a folder and rejects names containing traversal', (
    tester,
  ) async {
    final service = _Files();
    await _pump(tester, service);
    await tester.tap(find.byKey(const ValueKey('hermes-explorer-create')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New Folder'));
    await tester.pumpAndSettle();
    final name = find.descendant(
      of: find.byKey(const ValueKey('hermes-explorer-name')),
      matching: find.byType(TextField),
    );
    await tester.enterText(name, '../outside');
    await tester.tap(find.byKey(const ValueKey('hermes-explorer-save')));
    await tester.pumpAndSettle();
    expect(service.created, isEmpty);
    await tester.enterText(name, 'Research');
    await tester.tap(find.byKey(const ValueKey('hermes-explorer-save')));
    await tester.pumpAndSettle();
    expect(service.created.single, (
      directory: '/server/.hermes',
      name: 'Research',
      content: null,
    ));
  });

  testWidgets('opens another server location and surfaces a missing folder', (
    tester,
  ) async {
    final service = _Files();
    await _pump(tester, service);
    expect(find.text('.hermes'), findsOneWidget);
    expect(find.text('/server/.hermes'), findsNothing);
    expect(find.byTooltip('/server/.hermes'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('hermes-explorer-path')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<EditableText>(find.byType(EditableText).last)
          .controller
          .text,
      '/server/.hermes',
    );
    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey('hermes-explorer-location-input')),
        matching: find.byType(TextField),
      ),
      '/missing',
    );
    await tester.tap(find.text('Go to folder').last);
    await tester.pumpAndSettle();
    expect(service.browsed.last, '/missing');
    expect(find.textContaining('Could not open this folder'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('hermes-explorer-home')));
    await tester.pumpAndSettle();
    expect(find.text('SOUL.md'), findsOneWidget);
  });

  testWidgets('oversized files remain browsable without a preview download', (
    tester,
  ) async {
    final service = _Files()
      ..entries = const [
        HermesFileEntry(
          name: 'large.zip',
          path: '/server/.hermes/large.zip',
          isDirectory: false,
          size: 100 * 1024 * 1024,
        ),
      ];
    await _pump(tester, service);
    await tester.tap(find.text('large.zip'));
    await tester.pumpAndSettle();
    expect(service.reads, 0);
    expect(
      find.text(
        'This file cannot be previewed. Use Ask Hermes from its actions menu to ask about it.',
      ),
      findsOneWidget,
    );
  });

  for (final brightness in Brightness.values) {
    testWidgets(
      'explorer and actions render in ${brightness.name} at 200 percent text',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        const renderFont = String.fromEnvironment('CONDUIT_RENDER_FONT');
        if (renderFont.isNotEmpty) {
          await tester.runAsync(() async {
            await (FontLoader('Roboto')..addFont(
                  Future.value(
                    ByteData.sublistView(await File(renderFont).readAsBytes()),
                  ),
                ))
                .load();
            await (FontLoader('MaterialIcons')
                  ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
                .load();
          });
        }
        await _pump(
          tester,
          _Files(),
          brightness: brightness,
          scale: const int.fromEnvironment(
            'CONDUIT_RENDER_SCALE',
            defaultValue: 2,
          ).toDouble(),
        );
        expect(tester.takeException(), isNull);
        if (const bool.fromEnvironment('CONDUIT_CAPTURE_RENDER')) {
          await _capture(
            tester,
            '${brightness.name}-${const int.fromEnvironment('CONDUIT_RENDER_SCALE', defaultValue: 2)}-text',
          );
        }
        await tester.longPress(find.text('SOUL.md'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        if (const bool.fromEnvironment('CONDUIT_CAPTURE_RENDER')) {
          await _capture(
            tester,
            '${brightness.name}-${const int.fromEnvironment('CONDUIT_RENDER_SCALE', defaultValue: 2)}-actions',
          );
        }
      },
    );
  }
}
