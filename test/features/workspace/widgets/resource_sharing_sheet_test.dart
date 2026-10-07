import 'dart:async';
import 'dart:convert';

import 'package:conduit/features/chat/widgets/chat_share_sheet.dart';
import 'package:conduit/features/workspace/models/workspace_capabilities.dart';
import 'package:conduit/features/workspace/providers/workspace_capabilities_provider.dart';
import 'package:conduit/features/workspace/widgets/resource_sharing_sheet.dart';
import 'package:conduit/features/workspace/widgets/workspace_access_grants.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit/shared/widgets/themed_sheets.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/sharing/models/resource_access.dart';
import 'package:conduit_core/features/sharing/providers/principal_lookup.dart';
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

  /// Names the users route knows.
  Map<String, String> userNames = {'bob': 'Bob Builder'};

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
    } else if (path.startsWith('/api/v1/users/') && path.endsWith('/info')) {
      final id = path.split('/')[4];
      final name = userNames[id];
      if (name == null) {
        return ResponseBody.fromString(
          jsonEncode({'detail': 'not found'}),
          400,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      }
      body = {
        'id': id,
        'name': name,
        'email': '$id@example.com',
        'role': 'user',
      };
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
  /// Reads of the resource's access, not of people's names.
  List<String> get reads => [
    for (final r in requests)
      if (r.method == 'GET' && !r.path.startsWith('/api/v1/users/')) r.path,
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
    WorkspacePrincipalDirectory? directory,
    bool namesFromServer = false,
  }) async {
    final container = ProviderContainer(
      overrides: [
        if (directory != null)
          workspacePrincipalDirectoryProvider.overrideWithValue(directory),
        // Names come from a fixed lookup unless a test reads them from the
        // server, so the access routes are all the server sees.
        if (!namesFromServer)
          workspacePrincipalLookupProvider.overrideWithValue(
            WorkspacePrincipalLookup(
              fetchUser: (id) async => switch (id) {
                'bob' => const WorkspacePrincipalPreview(
                  id: 'bob',
                  type: WorkspacePrincipalType.user,
                  name: 'Bob',
                ),
                _ => null,
              },
              fetchGroups: () async => const [],
            ),
          ),
        apiServiceProvider.overrideWithValue(api),
        isAuthenticatedProvider2.overrideWithValue(true),
        authTokenProvider3.overrideWithValue('token'),
        currentUserProvider2.overrideWith((ref) => ref.watch(_currentUser)),
        activeServerProvider.overrideWith((ref) async => _server),
        workspaceCapabilitiesProvider.overrideWith((ref) async => capabilities),
        // Advanced stays off: sharing and the chat audience do not need it.
        appSettingsProvider.overrideWithValue(const AppSettings()),
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

  Future<void> makeBobEditor(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('workspace-access-level-user-bob')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('workspace-access-edit-user-bob')));
    await tester.pumpAndSettle();
  }

  Finder bobLevel(String label) => find.descendant(
    of: find.byKey(const Key('workspace-access-level-user-bob')),
    matching: find.text('$label ▾'),
  );

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

    await makeBobEditor(tester);
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

    await makeBobEditor(tester);
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
    expect(
      find.text(
        'Only the owner and people who can edit can change who has access.',
      ),
      findsOneWidget,
    );
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

    await tester.tap(find.byKey(const Key('workspace-access-general')));
    await tester.pumpAndSettle();
    final everyone = tester.widget<PopupMenuItem<int>>(
      find.ancestor(
        of: find.text('Everyone on this server').last,
        matching: find.byType(PopupMenuItem<int>),
      ),
    );
    expect(everyone.enabled, isFalse);
  });

  testWidgets('the server may keep less than was asked: the sheet stays on '
      'its answer and names who was dropped', (tester) async {
    server.filter = (given) =>
        given.where((r) => r['principal_type'] != 'user').toList();
    ResourceAccessSnapshot? saved;
    await pumpOpener(
      tester,
      onOpen: (context, ref) async {
        saved = await ResourceSharingSheet.show(
          context,
          ref,
          kind: ResourceKind.note,
          resourceId: 'n1',
        );
      },
    );
    await openSheet(tester);

    await makeBobEditor(tester);
    await tester.tap(find.byKey(const Key('workspace-access-save')));
    await tester.pumpAndSettle();

    expect(
      find.text("Saved, but Bob couldn't be given access."),
      findsOneWidget,
    );
    expect(find.byKey(const Key('workspace-access-list')), findsOneWidget);
    expect(
      find.byKey(const Key('workspace-access-principal-user-bob')),
      findsNothing,
    );

    // The save happened, so closing the sheet reports it.
    await tester.tap(find.byType(SheetCloseButton));
    await tester.pumpAndSettle();
    expect(saved?.rawGrants, isEmpty);
  });

  testWidgets('people are named by the server, and an unknown one is not '
      'shown by id', (tester) async {
    server.grants = [
      _row('user', 'bob', 'read'),
      _row('user', 'ghost', 'read'),
    ];
    await pumpOpener(
      tester,
      namesFromServer: true,
      onOpen: (context, ref) => ResourceSharingSheet.show(
        context,
        ref,
        kind: ResourceKind.note,
        resourceId: 'n1',
        resourceName: 'Trip plan',
      ),
    );
    await tester.tap(find.text('open'));
    // Step rather than settle: Bob's picture keeps loading in a test.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.text('Trip plan'), findsOneWidget);
    expect(find.text('Bob Builder'), findsOneWidget);
    expect(find.text('bob@example.com'), findsOneWidget);
    expect(find.text('Unknown person'), findsOneWidget);
    expect(find.textContaining('ghost'), findsNothing);
    final lookups = [
      for (final r in server.requests)
        if (r.path.startsWith('/api/v1/users/')) r.path,
    ];
    expect(
      lookups,
      unorderedEquals(['/api/v1/users/bob/info', '/api/v1/users/ghost/info']),
    );
  });

  testWidgets('loading and a failed load keep the header and its close '
      'button', (tester) async {
    final failing = _FailingServer();
    api.dio.httpClientAdapter = failing;
    await pumpOpener(
      tester,
      onOpen: (context, ref) => ResourceSharingSheet.show(
        context,
        ref,
        kind: ResourceKind.folder,
        resourceId: 'f1',
        resourceName: 'Projects',
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Share'), findsOneWidget);
    expect(find.text('Projects'), findsOneWidget);
    expect(find.byType(SheetCloseButton), findsOneWidget);

    failing.fail.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('resource-sharing-error')), findsOneWidget);
    expect(find.byKey(const Key('resource-sharing-retry')), findsOneWidget);
    expect(find.text('Share'), findsOneWidget);
    await tester.tap(find.byType(SheetCloseButton));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('resource-sharing-error')), findsNothing);
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
      await makeBobEditor(tester);
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
      expect(bobLevel(l10n.workspaceAccessCanEdit), findsOneWidget);
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
          await tester.pump();
          final add = inPicker(
            find.byKey(const Key('workspace-principal-add')),
          );
          expectClear(tester, add, 'Add button');
          await tester.tap(add);
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

    Future<void> remove(WidgetTester tester, String id) async {
      await tester.tap(find.byKey(Key('workspace-access-level-user-$id')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('workspace-access-remove-user-$id')));
      await tester.pumpAndSettle();
    }

    const labels = {
      ResourceAudience.private: 'Only people added',
      ResourceAudience.public: 'Everyone on this server',
      ResourceAudience.open: 'Anyone with the link',
    };

    ResourceAudience shown(WidgetTester tester) => labels.entries
        .singleWhere(
          (entry) => find
              .descendant(
                of: find.byKey(const Key('workspace-access-general')),
                matching: find.text(entry.value),
              )
              .evaluate()
              .isNotEmpty,
        )
        .key;

    Finder menuItem(ResourceAudience audience) => find.ancestor(
      of: find.text(labels[audience]!).last,
      matching: find.byType(PopupMenuItem<int>),
    );

    Future<bool> enabled(WidgetTester tester, ResourceAudience audience) async {
      await tester.tap(find.byKey(const Key('workspace-access-general')));
      await tester.pumpAndSettle();
      final item = tester.widget<PopupMenuItem<int>>(menuItem(audience));
      // Close the menu again.
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      return item.enabled;
    }

    Future<void> pick(WidgetTester tester, ResourceAudience audience) async {
      await tester.tap(find.byKey(const Key('workspace-access-general')));
      await tester.pumpAndSettle();
      await tester.tap(menuItem(audience));
      await tester.pumpAndSettle();
    }

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
        expect(await enabled(tester, ResourceAudience.open), isTrue);
        // Open is already set, so no "cannot share by link" notice.
        expect(
          find.text("You don't have permission to share by link."),
          findsNothing,
        );

        await remove(tester, 'bob');

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

      await remove(tester, 'bob');

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

        Future<void> expectNoCanEdit(String id) async {
          await tester.tap(find.byKey(Key('workspace-access-level-user-$id')));
          await tester.pumpAndSettle();
          expect(
            find.byKey(Key('workspace-access-edit-user-$id')),
            findsNothing,
          );
          expect(
            find.byKey(Key('workspace-access-remove-user-$id')),
            findsOneWidget,
          );
          await tester.tapAt(const Offset(5, 5));
          await tester.pumpAndSettle();
        }

        await expectNoCanEdit('bob');
        await expectNoCanEdit('eve');

        await remove(tester, 'eve');
        await tester.tap(find.byKey(const Key('workspace-access-add')));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(EditableText), 'Car');
        await tester.pump(const Duration(milliseconds: 301));
        await tester.pump();
        await tester.tap(
          find.byKey(const Key('workspace-principal-user-carol')),
        );
        await tester.pump();
        await tester.tap(find.byKey(const Key('workspace-principal-add')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('workspace-access-principal-user-carol')),
          findsOneWidget,
        );
        await expectNoCanEdit('carol');

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

        await pick(tester, ResourceAudience.private);
        expect(shown(tester), ResourceAudience.private);

        expect(await save(tester), [_row('user', 'bob', 'read')]);
      },
    );

    testWidgets('Public uses the user wildcard and drops an Open grant', (
      tester,
    ) async {
      server.grants = [anyoneRead()];
      await openChat(tester);

      await pick(tester, ResourceAudience.public);

      expect(await save(tester), [everyoneRead()]);
    });

    testWidgets('Open uses the anyone wildcard and keeps the named grants', (
      tester,
    ) async {
      server.grants = [_row('user', 'bob', 'read')];
      await openChat(tester);
      expect(shown(tester), ResourceAudience.private);

      await pick(tester, ResourceAudience.open);

      expect(await save(tester), [_row('user', 'bob', 'read'), anyoneRead()]);
    });

    testWidgets('an audience the account may not choose cannot be picked', (
      tester,
    ) async {
      server.grants = [_row('user', 'bob', 'read')];
      await openChat(tester, shareOpenly: false, sharePublicly: false);

      expect(await enabled(tester, ResourceAudience.private), isTrue);
      expect(await enabled(tester, ResourceAudience.public), isFalse);
      expect(await enabled(tester, ResourceAudience.open), isFalse);
      // Each choice it may not make says why.
      expect(
        find.text('You do not have permission to share this publicly.'),
        findsOneWidget,
      );
      expect(
        find.text("You don't have permission to share by link."),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('workspace-access-general')));
      await tester.pumpAndSettle();
      await tester.tap(menuItem(ResourceAudience.open), warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(shown(tester), ResourceAudience.private);
      // Nothing changed, so there is nothing to save.
      expect(
        tester
            .widget<ConduitButton>(
              find.byKey(const Key('workspace-access-save')),
            )
            .onPressed,
        isNull,
      );
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
      expect(find.byKey(const Key('workspace-access-general')), findsNothing);
    });

    testWidgets('a note has no Open choice', (tester) async {
      await openNote(tester);

      await tester.tap(find.byKey(const Key('workspace-access-general')));
      await tester.pumpAndSettle();
      expect(find.text('Everyone on this server'), findsOneWidget);
      expect(find.text('Anyone with the link'), findsNothing);
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

    Future<void> openChatShare(WidgetTester tester) async {
      await pumpOpener(
        tester,
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

    testWidgets(
      'edits access by the chat id while the link keeps its share id, with '
      'Advanced off',
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

/// Answers every request with a server error once [fail] completes, so the
/// loading state can be seen before it.
final class _FailingServer implements HttpClientAdapter {
  final fail = Completer<void>();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    await fail.future;
    return ResponseBody.fromString(
      jsonEncode({'detail': 'boom'}),
      500,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
