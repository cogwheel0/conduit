import 'dart:convert';

import 'package:conduit/features/chat/widgets/chat_share_sheet.dart';
import 'package:conduit/features/workspace/models/workspace_capabilities.dart';
import 'package:conduit/features/workspace/providers/workspace_capabilities_provider.dart';
import 'package:conduit/features/workspace/widgets/resource_sharing_sheet.dart';
import 'package:conduit/features/workspace/widgets/workspace_access_grants.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit/shared/widgets/themed_sheets.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/sharing/models/resource_access.dart';
import 'package:conduit_core/features/workspace/models/workspace_common.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _server = ServerConfig(
  id: 'test-server',
  name: 'Test Server',
  url: 'https://server.example',
  isActive: true,
);

const _alice = User(
  id: 'alice',
  username: 'alice',
  email: 'alice@example.com',
  role: 'user',
);
const _bob = User(
  id: 'bob',
  username: 'bob',
  email: 'bob@example.com',
  role: 'user',
);

class _CurrentUser extends Notifier<User?> {
  @override
  User? build() => _alice;

  void switchTo(User user) => state = user;
}

final _currentUser = NotifierProvider<_CurrentUser, User?>(_CurrentUser.new);

Map<String, dynamic> _row(String type, String id, String permission) => {
  'principal_type': type,
  'principal_id': id,
  'permission': permission,
};

/// A server for the three resources' access routes. It keeps the grants it
/// was last given so a read after a save shows what the server really holds.
final class _Server implements HttpClientAdapter {
  _Server();

  final requests = <RequestOptions>[];
  List<Map<String, dynamic>> grants = [_row('user', 'bob', 'read')];
  bool writeAccess = true;

  /// Rows the server keeps of what it receives, to model filtering.
  List<Map<String, dynamic>> Function(List<Map<String, dynamic>> given)? filter;

  Map<String, dynamic> _detail(String id) => {
    'id': id,
    'user_id': 'creator',
    'name': 'Resource',
    'title': 'Resource',
    'write_access': writeAccess,
    'access_grants': grants,
  };

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final path = options.path;
    Object body;
    if (options.method == 'POST') {
      final given = [
        for (final row in (options.data as Map)['access_grants'] as List)
          Map<String, dynamic>.from(row as Map),
      ];
      grants = filter?.call(given) ?? given;
      body = _detail('x');
    } else if (path.contains('/chats/shared/')) {
      body = grants;
    } else {
      body = _detail(path.split('/').last);
    }
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}

  List<String> get posts => [
    for (final r in requests)
      if (r.method == 'POST') r.path,
  ];
  List<String> get reads => [
    for (final r in requests)
      if (r.method == 'GET') r.path,
  ];
}

void main() {
  late _Server server;
  late ApiService api;

  setUp(() {
    server = _Server();
    api = ApiService(
      serverConfig: _server,
      workerManager: WorkerManager(),
      authToken: 'session-a',
    );
    api.dio.httpClientAdapter = server;
  });

  tearDown(() => api.dispose());

  Future<ProviderContainer> pumpOpener(
    WidgetTester tester, {
    required Future<void> Function(BuildContext context, WidgetRef ref) onOpen,
    WorkspaceCapabilities capabilities = WorkspaceCapabilities.all,
    bool advanced = true,
    WorkspacePrincipalDirectory? directory,
  }) async {
    final container = ProviderContainer(
      overrides: [
        if (directory != null)
          workspacePrincipalDirectoryProvider.overrideWithValue(directory),
        apiServiceProvider.overrideWithValue(api),
        isAuthenticatedProvider2.overrideWithValue(true),
        authTokenProvider3.overrideWithValue('token'),
        currentUserProvider2.overrideWith((ref) => ref.watch(_currentUser)),
        activeServerProvider.overrideWith((ref) async => _server),
        workspaceCapabilitiesProvider.overrideWith((ref) async => capabilities),
        appSettingsProvider.overrideWithValue(
          AppSettings(advancedFeaturesEnabled: advanced),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(activeServerProvider.future);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          // The native iOS sheet is presented by a package that uses Flutter's
          // own Material route, which looks for Flutter's localizations.
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => TextButton(
                onPressed: () => onOpen(context, ref),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    return container;
  }

  Future<void> openSheet(WidgetTester tester) async {
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
  }

  Future<void> openNote(
    WidgetTester tester, {
    WorkspaceCapabilities capabilities = WorkspaceCapabilities.all,
  }) async {
    await pumpOpener(
      tester,
      capabilities: capabilities,
      onOpen: (context, ref) => ResourceSharingSheet.show(
        context,
        ref,
        kind: ResourceKind.note,
        resourceId: 'n1',
      ),
    );
    await openSheet(tester);
  }

  Finder bobWrite() => find.byKey(const Key('workspace-access-write-user-bob'));

  testWidgets('opening and closing the sheet sends no write', (tester) async {
    await openNote(tester);

    expect(find.byKey(const Key('workspace-access-list')), findsOneWidget);
    await tester.tap(find.byType(SheetCloseButton));
    await tester.pumpAndSettle();

    expect(server.posts, isEmpty);
    expect(server.reads, ['/api/v1/notes/n1']);
  });

  testWidgets('a writable recipient is saved as separate read and write rows', (
    tester,
  ) async {
    await openNote(tester);

    await tester.tap(bobWrite());
    await tester.pump();
    await tester.tap(find.byKey(const Key('workspace-access-save')));
    await tester.pumpAndSettle();

    expect(server.posts, ['/api/v1/notes/n1/access/update']);
    final body =
        server.requests.firstWhere((r) => r.method == 'POST').data as Map;
    expect(body['access_grants'], [
      _row('user', 'bob', 'read'),
      _row('user', 'bob', 'write'),
    ]);
    // The server's answer was read back before the sheet closed.
    expect(server.reads, ['/api/v1/notes/n1', '/api/v1/notes/n1']);
    expect(find.byKey(const Key('workspace-access-list')), findsNothing);
  });

  testWidgets('a folder recipient can be made writable too', (tester) async {
    await pumpOpener(
      tester,
      onOpen: (context, ref) => ResourceSharingSheet.show(
        context,
        ref,
        kind: ResourceKind.folder,
        resourceId: 'f1',
      ),
    );
    await openSheet(tester);

    await tester.tap(bobWrite());
    await tester.pump();
    await tester.tap(find.byKey(const Key('workspace-access-save')));
    await tester.pumpAndSettle();

    expect(server.posts, ['/api/v1/folders/f1/access/update']);
    final body =
        server.requests.firstWhere((r) => r.method == 'POST').data as Map;
    expect(body['access_grants'], [
      _row('user', 'bob', 'read'),
      _row('user', 'bob', 'write'),
    ]);
  });

  testWidgets('a read-only recipient sees the access but cannot save it', (
    tester,
  ) async {
    server.writeAccess = false;
    await openNote(tester);

    expect(find.byKey(const Key('workspace-access-list')), findsOneWidget);
    expect(find.byKey(const Key('workspace-access-save')), findsNothing);
    expect(server.posts, isEmpty);
  });

  testWidgets('a note without public sharing cannot be made public', (
    tester,
  ) async {
    await openNote(
      tester,
      capabilities: const WorkspaceCapabilities(
        notes: ResourceSharingCapabilities(
          section: WorkspaceSectionCapabilities(share: true),
          allowUserGrants: true,
          allowGroupGrants: true,
        ),
      ),
    );

    final tile = find.byKey(const Key('workspace-access-public'));
    final toggle = tester.widget<Switch>(
      find.descendant(of: tile, matching: find.byType(Switch)),
    );
    expect(toggle.onChanged, isNull);
  });

  testWidgets('the server may keep less than was asked and the sheet says so', (
    tester,
  ) async {
    server.filter = (given) =>
        given.where((r) => r['principal_type'] != 'user').toList();
    await openNote(tester);

    await tester.tap(bobWrite());
    await tester.pump();
    await tester.tap(find.byKey(const Key('workspace-access-save')));
    // Step rather than settle: the message is a snackbar that times out.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(
      find.text('Saved. The server kept only part of the access you chose.'),
      findsOneWidget,
    );
  });

  testWidgets(
    'account A\'s retained form is refused after a switch to B on the same '
    'API, keeps its edits, and neither writes nor reads for B',
    (tester) async {
      final container = await pumpOpener(
        tester,
        onOpen: (context, ref) => ResourceSharingSheet.show(
          context,
          ref,
          kind: ResourceKind.note,
          resourceId: 'n1',
        ),
      );
      await openSheet(tester);
      await tester.tap(bobWrite());
      await tester.pump();
      server.requests.clear();

      final apiBefore = container.read(apiServiceProvider);
      container.read(_currentUser.notifier).switchTo(_bob);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('workspace-access-save')));
      await tester.pumpAndSettle();

      expect(identical(container.read(apiServiceProvider), apiBefore), isTrue);
      expect(server.requests, isEmpty);
      final l10n = AppLocalizations.of(
        tester.element(find.byKey(const Key('workspace-access-save-error'))),
      )!;
      expect(find.text(l10n.resourceSharingSessionChanged), findsOneWidget);
      // The form is still A's, with the edit the user made.
      expect(tester.widget<AdaptiveSwitch>(bobWrite()).value, isTrue);
    },
  );

  group('adding a person with the keyboard up', () {
    const phone = Size(390, 844);
    const statusBar = 47.0;
    const homeIndicator = 34.0;
    const keyboard = 336.0;
    const keyboardTop = 844 - keyboard;
    const exact = 'Conduit Parity Member 033';

    final members = [
      for (var i = 0; i < 40; i++)
        WorkspacePrincipalPreview(
          id: 'u$i',
          type: WorkspacePrincipalType.user,
          name: 'Conduit Parity Member ${'$i'.padLeft(3, '0')}',
          email: 'member$i@example.com',
        ),
    ];
    final directory = WorkspacePrincipalDirectory(
      searchUsers: (query) async => [
        for (final m in members)
          if (m.name.toLowerCase().contains(query.toLowerCase())) m,
      ],
      loadGroups: () async => const [],
    );

    void showKeyboard(WidgetTester tester, {required bool up}) {
      tester.view.padding = FakeViewPadding(
        top: statusBar * 3,
        bottom: up ? 0 : homeIndicator * 3,
      );
      tester.view.viewInsets = FakeViewPadding(bottom: up ? keyboard * 3 : 0);
    }

    Finder inPicker(Finder finder) => find.descendant(
      of: find.byType(WorkspacePrincipalPicker),
      matching: finder,
    );

    // Above the keyboard, below the status bar, and reachable by a tap.
    void expectClear(WidgetTester tester, Finder finder, String what) {
      expect(finder, findsOneWidget, reason: what);
      final rect = tester.getRect(finder);
      expect(rect.bottom, lessThanOrEqualTo(keyboardTop), reason: what);
      expect(rect.top, greaterThanOrEqualTo(statusBar), reason: what);
      expect(finder.hitTestable(), findsOneWidget, reason: what);
    }

    for (final native in [false, true]) {
      testWidgets(
        '${native ? 'native iOS' : 'Material'} sheet: the picker stays between '
        'the status bar and the keyboard and its result can be chosen',
        (tester) async {
          tester.view.devicePixelRatio = 3;
          tester.view.physicalSize = phone * 3;
          tester.view.viewPadding = FakeViewPadding(
            top: statusBar * 3,
            bottom: homeIndicator * 3,
          );
          showKeyboard(tester, up: false);
          addTearDown(tester.view.reset);
          if (native) {
            PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
            PlatformUiCapabilities.debugIOSMajorVersionOverride = 26;
            PlatformUiCapabilities.debugNativeIOS26Override = true;
            addTearDown(PlatformUiCapabilities.resetDebugOverrides);
          }

          await pumpOpener(
            tester,
            directory: directory,
            onOpen: (context, ref) => ResourceSharingSheet.show(
              context,
              ref,
              kind: ResourceKind.note,
              resourceId: 'n1',
            ),
          );
          // The localizations load asynchronously; the native sheet needs them
          // when it is presented.
          await tester.pumpAndSettle();
          await openSheet(tester);
          await tester.tap(find.byKey(const Key('workspace-access-add')));
          await tester.pumpAndSettle();
          expect(find.byType(WorkspacePrincipalPicker), findsOneWidget);

          final search = inPicker(find.byType(EditableText));
          await tester.tap(search);
          showKeyboard(tester, up: true);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 250));

          // Many results: the surface is bounded and the list scrolls.
          await tester.enterText(search, 'Conduit');
          await tester.pump(const Duration(milliseconds: 301));
          await tester.pump();
          final results = inPicker(
            find.byKey(const Key('workspace-principal-results')),
          );
          expectClear(tester, results, 'results list');
          final surface = tester.getRect(
            inPicker(find.byType(ConduitModalSheetSurface)),
          );
          expect(surface.top, greaterThanOrEqualTo(statusBar));
          expect(surface.bottom, lessThanOrEqualTo(keyboardTop));
          expect(
            inPicker(find.byKey(const Key('workspace-principal-user-u39'))),
            findsNothing,
          );
          await tester.drag(results, const Offset(0, -4000));
          await tester.pump();
          expect(
            inPicker(find.byKey(const Key('workspace-principal-user-u39'))),
            findsOneWidget,
          );

          // The member from the device check.
          await tester.enterText(search, exact);
          await tester.pump(const Duration(milliseconds: 301));
          await tester.pump();
          final l10n = AppLocalizations.of(tester.element(search))!;
          expectClear(
            tester,
            inPicker(find.text(l10n.workspacePrincipalTitle)),
            'header',
          );
          expectClear(tester, search, 'search field');
          expectClear(tester, inPicker(find.byType(SheetCloseButton)), 'Close');
          final row = inPicker(
            find.byKey(const Key('workspace-principal-user-u33')),
          );
          expectClear(tester, row, 'matching row');

          await tester.tap(row);
          await tester.pumpAndSettle();

          // The grant sheet is back, with the person added, the keyboard
          // asked to go away, and Save reachable once it has.
          expect(find.byType(WorkspacePrincipalPicker), findsNothing);
          expect(tester.testTextInput.isVisible, isFalse);
          showKeyboard(tester, up: false);
          await tester.pumpAndSettle();
          expect(
            find.byKey(const Key('workspace-access-principal-user-u33')),
            findsOneWidget,
          );
          final save = find.byKey(const Key('workspace-access-save'));
          expect(save.hitTestable(), findsOneWidget);
          expect(
            tester.getRect(save).bottom,
            lessThanOrEqualTo(844 - homeIndicator),
          );
          await tester.tap(save);
          await tester.pumpAndSettle();

          final body =
              server.requests.firstWhere((r) => r.method == 'POST').data as Map;
          expect(body['access_grants'], [
            _row('user', 'bob', 'read'),
            _row('user', 'u33', 'read'),
          ]);
        },
      );
    }
  });

  group('chat visibility', () {
    Map<String, dynamic> anyoneRead() => _row('anyone', '*', 'read');
    Map<String, dynamic> everyoneRead() => _row('user', '*', 'read');

    Future<void> openChat(
      WidgetTester tester, {
      bool shareOpenly = true,
      bool sharePublicly = true,
      WorkspacePrincipalDirectory? directory,
    }) async {
      await pumpOpener(
        tester,
        directory: directory,
        capabilities: WorkspaceCapabilities(
          chats: ResourceSharingCapabilities(
            section: WorkspaceSectionCapabilities(
              share: true,
              sharePublicly: sharePublicly,
            ),
            allowUserGrants: true,
            allowGroupGrants: true,
            shareOpenly: shareOpenly,
          ),
        ),
        onOpen: (context, ref) => ResourceSharingSheet.show(
          context,
          ref,
          kind: ResourceKind.chat,
          resourceId: 'chat-original',
        ),
      );
      await openSheet(tester);
    }

    Finder removeBob() =>
        find.byKey(const Key('workspace-access-remove-user-bob'));

    Finder option(String label) => find.descendant(
      of: find.byKey(const Key('workspace-access-audience')),
      matching: find.text(label),
    );

    ResourceAudience shown(WidgetTester tester) => tester
        .widget<SegmentedButton<ResourceAudience>>(
          find.byType(SegmentedButton<ResourceAudience>),
        )
        .selected
        .single;

    bool enabled(WidgetTester tester, ResourceAudience audience) => tester
        .widget<SegmentedButton<ResourceAudience>>(
          find.byType(SegmentedButton<ResourceAudience>),
        )
        .segments
        .singleWhere((segment) => segment.value == audience)
        .enabled;

    Future<List<Map<String, dynamic>>> save(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('workspace-access-save')));
      await tester.pumpAndSettle();
      final post = server.requests.singleWhere((r) => r.method == 'POST');
      expect(post.path, '/api/v1/chats/shared/chat-original/access/update');
      return [
        for (final row in (post.data as Map)['access_grants'] as List)
          Map<String, dynamic>.from(row as Map),
      ];
    }

    testWidgets(
      'an Open chat is shown as Open even though the account may not author '
      'it, and an unrelated edit leaves the Open grant alone',
      (tester) async {
        server.grants = [_row('user', 'bob', 'read'), anyoneRead()];
        await openChat(tester, shareOpenly: false);

        expect(shown(tester), ResourceAudience.open);
        expect(find.text('Anyone with the link can view it.'), findsOneWidget);
        expect(enabled(tester, ResourceAudience.open), isTrue);

        await tester.tap(removeBob());
        await tester.pump();

        expect(await save(tester), [anyoneRead()]);
      },
    );

    testWidgets('an unrelated edit keeps an anyone grant the audience does not '
        'show', (tester) async {
      server.grants = [
        _row('user', 'bob', 'read'),
        _row('anyone', '*', 'write'),
      ];
      await openChat(tester, shareOpenly: false);
      expect(shown(tester), ResourceAudience.private);

      await tester.tap(removeBob());
      await tester.pump();

      expect(await save(tester), [_row('anyone', '*', 'write')]);
    });

    testWidgets(
      'a chat recipient is read-only: added people get read, and a write grant '
      'the server already holds is kept',
      (tester) async {
        server.grants = [
          _row('user', 'bob', 'read'),
          _row('user', 'bob', 'write'),
          _row('user', 'eve', 'read'),
          _row('anyone', '*', 'write'),
        ];
        await openChat(
          tester,
          directory: WorkspacePrincipalDirectory(
            searchUsers: (_) async => const [
              WorkspacePrincipalPreview(
                id: 'carol',
                type: WorkspacePrincipalType.user,
                name: 'Carol',
              ),
            ],
            loadGroups: () async => const [],
          ),
        );

        Finder writeSwitch(String id) =>
            find.byKey(Key('workspace-access-write-user-$id'));
        expect(removeBob(), findsOneWidget);
        expect(writeSwitch('bob'), findsNothing);
        expect(writeSwitch('eve'), findsNothing);

        await tester.tap(find.byKey(Key('workspace-access-remove-user-eve')));
        await tester.pump();
        await tester.tap(find.byKey(const Key('workspace-access-add')));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(EditableText), 'Car');
        await tester.pump(const Duration(milliseconds: 301));
        await tester.pump();
        await tester.tap(
          find.byKey(const Key('workspace-principal-user-carol')),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('workspace-access-principal-user-carol')),
          findsOneWidget,
        );
        expect(writeSwitch('carol'), findsNothing);

        expect(await save(tester), [
          _row('user', 'bob', 'read'),
          _row('user', 'bob', 'write'),
          _row('user', 'carol', 'read'),
          _row('anyone', '*', 'write'),
        ]);
      },
    );

    testWidgets(
      'choosing a narrower audience replaces the wildcard grants and keeps '
      'the named ones',
      (tester) async {
        server.grants = [
          _row('user', 'bob', 'read'),
          everyoneRead(),
          anyoneRead(),
        ];
        await openChat(tester, shareOpenly: false);
        expect(shown(tester), ResourceAudience.open);

        await tester.tap(option('Private'));
        await tester.pump();
        expect(shown(tester), ResourceAudience.private);

        expect(await save(tester), [_row('user', 'bob', 'read')]);
      },
    );

    testWidgets('Public uses the user wildcard and drops an Open grant', (
      tester,
    ) async {
      server.grants = [anyoneRead()];
      await openChat(tester);

      await tester.tap(option('Public'));
      await tester.pump();

      expect(await save(tester), [everyoneRead()]);
    });

    testWidgets('Open uses the anyone wildcard and keeps the named grants', (
      tester,
    ) async {
      server.grants = [_row('user', 'bob', 'read')];
      await openChat(tester);
      expect(shown(tester), ResourceAudience.private);

      await tester.tap(option('Open'));
      await tester.pump();

      expect(await save(tester), [_row('user', 'bob', 'read'), anyoneRead()]);
    });

    testWidgets('an audience the account may not choose cannot be picked', (
      tester,
    ) async {
      server.grants = [_row('user', 'bob', 'read')];
      await openChat(tester, shareOpenly: false, sharePublicly: false);

      expect(enabled(tester, ResourceAudience.private), isTrue);
      expect(enabled(tester, ResourceAudience.public), isFalse);
      expect(enabled(tester, ResourceAudience.open), isFalse);
      await tester.tap(option('Open'));
      await tester.pump();

      expect(shown(tester), ResourceAudience.private);
      expect(await save(tester), [_row('user', 'bob', 'read')]);
    });

    testWidgets('a folder offers no public choice and a note keeps its own '
        'public switch', (tester) async {
      await pumpOpener(
        tester,
        onOpen: (context, ref) => ResourceSharingSheet.show(
          context,
          ref,
          kind: ResourceKind.folder,
          resourceId: 'f1',
        ),
      );
      await openSheet(tester);

      expect(find.byKey(const Key('workspace-access-list')), findsOneWidget);
      expect(find.byKey(const Key('workspace-access-audience')), findsNothing);
      expect(find.byKey(const Key('workspace-access-public')), findsNothing);
    });

    testWidgets('a note has no Open choice', (tester) async {
      await openNote(tester);

      expect(find.byKey(const Key('workspace-access-audience')), findsNothing);
      expect(find.byKey(const Key('workspace-access-public')), findsOneWidget);
    });
  });

  group('chat audience', () {
    final conversation = Conversation(
      id: 'chat-original',
      title: 'Chat',
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      shareId: 'share-link-9',
    );

    Future<void> openChatShare(
      WidgetTester tester, {
      bool advanced = true,
    }) async {
      await pumpOpener(
        tester,
        advanced: advanced,
        onOpen: (context, ref) => showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          builder: (_) => ChatShareSheet(
            conversation: conversation,
            share: (_) async => throw UnimplementedError(),
          ),
        ),
      );
      await openSheet(tester);
    }

    testWidgets('is hidden while Advanced is off', (tester) async {
      await openChatShare(tester, advanced: false);

      expect(find.byKey(const Key('chat-share-audience')), findsNothing);
    });

    testWidgets(
      'edits access by the chat id while the link keeps its share id',
      (tester) async {
        await openChatShare(tester);

        await tester.tap(find.byKey(const Key('chat-share-audience')));
        await tester.pumpAndSettle();

        expect(server.reads, ['/api/v1/chats/shared/chat-original/access']);
        expect(
          server.requests.any((r) => r.path.contains('share-link-9')),
          isFalse,
        );
        // The existing link is still the one the share flow shows.
        expect(find.byKey(const Key('workspace-access-list')), findsOneWidget);
      },
    );
  });
}
