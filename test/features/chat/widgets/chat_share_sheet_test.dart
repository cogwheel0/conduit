import 'package:checks/checks.dart';
import 'package:conduit_core/database/chat_database_repository.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit/core/services/native_sheet_bridge.dart';
import 'package:conduit/features/chat/widgets/chat_share_sheet.dart';
import 'package:conduit_core/features/hermes/services/hermes_session_provenance.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/platform/conduit_platform_apis.g.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:share_plus/share_plus.dart';

class _RecordingShareApiService extends ApiService {
  _RecordingShareApiService()
    : super(
        serverConfig: const ServerConfig(
          id: 'test',
          name: 'Test',
          url: 'https://example.com',
        ),
        workerManager: WorkerManager(),
      );

  int shareCalls = 0;
  int deleteCalls = 0;
  final sharedConversationIds = <String>[];
  final deletedConversationIds = <String>[];

  @override
  Future<String?> shareConversation(String id) async {
    shareCalls += 1;
    sharedConversationIds.add(id);
    return 'share-$shareCalls';
  }

  @override
  Future<void> deleteSharedConversation(String id) async {
    deleteCalls += 1;
    deletedConversationIds.add(id);
  }
}

class _TestConversations extends Conversations {
  @override
  Future<List<Conversation>> build() async => const <Conversation>[];

  @override
  Future<void> refresh({
    bool includeFolders = false,
    bool forceFresh = false,
  }) async {}
}

class _RecordingShareAction {
  int shareCalls = 0;
  String? lastText;

  Future<ShareResult> share(ShareParams params) async {
    shareCalls += 1;
    lastText = params.text;
    return const ShareResult('success', ShareResultStatus.success);
  }
}

const _testUser = User(
  id: 'user-1',
  username: 'user',
  email: 'user@example.com',
  role: 'user',
);

const _testServer = ServerConfig(
  id: 'test',
  name: 'Test',
  url: 'https://example.com',
);

final _presentResultSheetChannel = BasicMessageChannel<Object?>(
  'dev.flutter.pigeon.conduit.NativeSheetHostApi.presentResultSheet',
  NativeSheetHostApi.pigeonChannelCodec,
);

/// Overrides for a signed-in session, so the chat's audience can be opened.
List<Override> _signedInOverrides(ApiService api) => [
  isAuthenticatedProvider2.overrideWithValue(true),
  apiServiceProvider.overrideWithValue(api),
  currentUserProvider2.overrideWithValue(_testUser),
  activeServerProvider.overrideWith((ref) async => _testServer),
  conversationsProvider.overrideWith(_TestConversations.new),
];

Conversation _chat({String? shareId}) => Conversation(
  id: 'chat-1',
  title: 'Shared chat',
  createdAt: DateTime.utc(2026, 4, 26),
  updatedAt: DateTime.utc(2026, 4, 26),
  shareId: shareId,
);

Future<void> _pumpSignedInSheet(
  WidgetTester tester, {
  required ApiService api,
  required Conversation conversation,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: _signedInOverrides(api),
      child: MaterialApp(
        theme: AppTheme.light(TweakcnThemes.t3Chat),
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: ChatShareSheet(conversation: conversation)),
      ),
    ),
  );
  await tester.pump();
}

/// Lets a transient toast run out so no timer outlives the test.
Future<void> _settleToasts(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 5));
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (
          MethodCall methodCall,
        ) async {
          if (methodCall.method == 'Clipboard.setData') {
            return null;
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets('copying an existing share re-snapshots every time', (
    tester,
  ) async {
    final api = _RecordingShareApiService();
    final conversation = Conversation(
      id: 'chat-1',
      title: 'Shared chat',
      createdAt: DateTime.utc(2026, 4, 26),
      updatedAt: DateTime.utc(2026, 4, 26),
      shareId: 'existing-share',
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          isAuthenticatedProvider2.overrideWithValue(true),
          apiServiceProvider.overrideWithValue(api),
          conversationsProvider.overrideWith(_TestConversations.new),
        ],
        child: MaterialApp(
          theme: AppTheme.light(TweakcnThemes.t3Chat),
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: ChatShareSheet(conversation: conversation)),
        ),
      ),
    );

    await tester.tap(find.text('Update and copy link'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('Update and copy link'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    check(api.shareCalls).equals(2);
  });

  testWidgets('platform share uses the latest re-snapshotted URL', (
    tester,
  ) async {
    final api = _RecordingShareApiService();
    final shareAction = _RecordingShareAction();
    final conversation = Conversation(
      id: 'chat-1',
      title: 'Shared chat',
      createdAt: DateTime.utc(2026, 4, 26),
      updatedAt: DateTime.utc(2026, 4, 26),
      shareId: 'existing-share',
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          isAuthenticatedProvider2.overrideWithValue(true),
          apiServiceProvider.overrideWithValue(api),
          conversationsProvider.overrideWith(_TestConversations.new),
        ],
        child: MaterialApp(
          theme: AppTheme.light(TweakcnThemes.t3Chat),
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: ChatShareSheet(
              conversation: conversation,
              share: shareAction.share,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Share...'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    check(api.shareCalls).equals(1);
    check(shareAction.shareCalls).equals(1);
    check(shareAction.lastText).equals('https://example.com/s/share-1');
  });

  testWidgets('sharing a scoped collision never mutates native Hermes', (
    tester,
  ) async {
    final api = _RecordingShareApiService();
    const rawId = 'local:hermes_share-collision';
    final selected = withChatStorageProvenance(
      Conversation(
        id: rawId,
        title: 'Server row',
        createdAt: DateTime.utc(2026, 4, 26),
        updatedAt: DateTime.utc(2026, 4, 26),
        shareId: 'existing-share',
      ),
      ChatStorageKind.openWebUi,
    );
    final native = markNativeHermesConversation(
      Conversation(
        id: rawId,
        title: 'Native Hermes',
        createdAt: DateTime.utc(2026, 4, 26),
        updatedAt: DateTime.utc(2026, 4, 26),
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          isAuthenticatedProvider2.overrideWithValue(true),
          apiServiceProvider.overrideWithValue(api),
          conversationsProvider.overrideWith(_TestConversations.new),
        ],
        child: MaterialApp(
          theme: AppTheme.light(TweakcnThemes.t3Chat),
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: ChatShareSheet(conversation: selected)),
        ),
      ),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ChatShareSheet)),
    );
    container.read(activeConversationProvider.notifier).set(native);

    await tester.tap(find.text('Update and copy link'));
    await tester.pump(const Duration(milliseconds: 100));

    check(api.sharedConversationIds).deepEquals(<String>[rawId]);
    check(identical(container.read(activeConversationProvider), native))
        .isTrue();
    check(
      isNativeHermesConversation(container.read(activeConversationProvider)),
    ).isTrue();
  });

  testWidgets('deleting a scoped share never mutates native Hermes', (
    tester,
  ) async {
    final api = _RecordingShareApiService();
    const rawId = 'local:hermes_delete-share-collision';
    final selected = withChatStorageProvenance(
      Conversation(
        id: rawId,
        title: 'Server row',
        createdAt: DateTime.utc(2026, 4, 26),
        updatedAt: DateTime.utc(2026, 4, 26),
        shareId: 'existing-share',
      ),
      ChatStorageKind.openWebUi,
    );
    final native = markNativeHermesConversation(
      Conversation(
        id: rawId,
        title: 'Native Hermes',
        createdAt: DateTime.utc(2026, 4, 26),
        updatedAt: DateTime.utc(2026, 4, 26),
        shareId: 'native-share',
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          isAuthenticatedProvider2.overrideWithValue(true),
          apiServiceProvider.overrideWithValue(api),
          conversationsProvider.overrideWith(_TestConversations.new),
        ],
        child: MaterialApp(
          theme: AppTheme.light(TweakcnThemes.t3Chat),
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: ChatShareSheet(conversation: selected)),
        ),
      ),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ChatShareSheet)),
    );
    container.read(activeConversationProvider.notifier).set(native);

    final deleteRow = find.byKey(const Key('chat-share-delete'));
    expect(
      find.descendant(
        of: deleteRow,
        matching: find.text('Delete this link and create a new shared link.'),
      ),
      findsOneWidget,
    );
    await tester.tap(deleteRow);
    await tester.pump(const Duration(milliseconds: 100));

    check(api.deletedConversationIds).deepEquals(<String>[rawId]);
    check(identical(container.read(activeConversationProvider), native))
        .isTrue();
    check(container.read(activeConversationProvider)?.shareId)
        .equals('native-share');
    check(
      isNativeHermesConversation(container.read(activeConversationProvider)),
    ).isTrue();
  });

  testWidgets(
    'an existing link lists Copy and Share, then Who has access, then Delete '
    'last',
    (tester) async {
      await _pumpSignedInSheet(
        tester,
        api: _RecordingShareApiService(),
        conversation: _chat(shareId: 'existing-share'),
      );

      final copy = find.byKey(const Key('chat-share-copy'));
      final share = find.byKey(const Key('chat-share-system'));
      final audience = find.byKey(const Key('chat-share-audience'));
      final delete = find.byKey(const Key('chat-share-delete'));
      for (final row in [copy, share, audience, delete]) {
        expect(row, findsOneWidget);
      }
      expect(
        find.descendant(
          of: audience,
          matching: find.text(l10n.chatShareAudience),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: audience,
          matching: find.text(l10n.chatShareAudienceDescription),
        ),
        findsOneWidget,
      );
      check(l10n.chatShareAudience).equals('Who has access');
      check(l10n.chatShareAudienceDescription)
          .equals('Choose who can open this chat');

      final tops = [
        for (final row in [copy, share, audience, delete])
          tester.getTopLeft(row).dy,
      ];
      check(tops[0]).isLessThan(tops[1]);
      check(tops[1]).isLessThan(tops[2]);
      check(tops[2]).isLessThan(tops[3]);

      final audienceSemantics = tester.getSemantics(audience);
      check(audienceSemantics.flagsCollection.isButton).isTrue();
      check(audienceSemantics.label).contains(l10n.chatShareAudience);
    },
  );

  testWidgets(
    'on iOS, Who has access appears as soon as a link is created',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      PlatformUiCapabilities.debugIOSMajorVersionOverride = 18;
      try {
        final api = _RecordingShareApiService();
        await _pumpSignedInSheet(
          tester,
          api: api,
          conversation: _chat(),
        );

        expect(find.byKey(const Key('chat-share-audience')), findsNothing);
        expect(find.byKey(const Key('chat-share-delete')), findsNothing);

        await tester.tap(find.text(l10n.copyLink));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        check(api.shareCalls).equals(1);
        expect(find.byKey(const Key('chat-share-audience')), findsOneWidget);
        expect(find.text(l10n.chatShareAudience), findsOneWidget);
        expect(find.byKey(const Key('chat-share-delete')), findsOneWidget);
        expect(find.text(l10n.updateAndCopyLink), findsOneWidget);
        check(
          tester.getTopLeft(find.byKey(const Key('chat-share-audience'))).dy,
        ).isLessThan(
          tester.getTopLeft(find.byKey(const Key('chat-share-delete'))).dy,
        );

        await _settleToasts(tester);
      } finally {
        debugDefaultTargetPlatformOverride = null;
        PlatformUiCapabilities.debugIOSMajorVersionOverride = null;
      }
    },
  );

  testWidgets(
    'the native iOS sheet comes back with Who has access after creating a '
    'link, Delete last',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      PlatformUiCapabilities.debugIOSMajorVersionOverride = 18;
      NativeSheetBridge.instance.debugIsIOSOverride = true;
      final requests = <PlatformNativeSheetResultRequest>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockDecodedMessageHandler<Object?>(
        _presentResultSheetChannel,
        (message) async {
          requests.add(
            (message! as List<Object?>).single!
                as PlatformNativeSheetResultRequest,
          );
          // Copy the link from the first sheet, then close the second one.
          return <Object?>[
            if (requests.length == 1)
              PlatformNativeSheetActionResult(
                actionId: 'copy-link',
                values: const <String, Object?>{},
              )
            else
              null,
          ];
        },
      );
      try {
        final api = _RecordingShareApiService();
        await tester.pumpWidget(
          ProviderScope(
            overrides: _signedInOverrides(api),
            child: MaterialApp(
              theme: AppTheme.light(TweakcnThemes.t3Chat),
              localizationsDelegates: conduitLocalizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () => showChatShareSheet(
                      context: context,
                      conversation: _chat(),
                    ),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        await tester.tap(find.text('open'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 100));

        check(api.shareCalls).equals(1);
        check(requests).length.equals(2);

        List<List<String>> sectionIds(PlatformNativeSheetResultRequest r) => [
          for (final section in r.root.sections)
            [for (final item in section.items) item.id],
        ];

        check(sectionIds(requests.first)).deepEquals([
          ['copy-link', 'share-link'],
        ]);
        check(sectionIds(requests.last)).deepEquals([
          ['copy-link', 'share-link'],
          ['audience'],
          ['delete-link'],
        ]);
        final audience = requests.last.root.sections[1].items.single;
        check(audience.title).equals(l10n.chatShareAudience);
        check(audience.subtitle).equals(l10n.chatShareAudienceDescription);
        check(requests.last.root.sections.last.items.single.destructive)
            .isTrue();
        // The returning sheet confirms the copy, since a toast would sit
        // behind it.
        check(requests.last.root.subtitle).equals(l10n.sharedChatCopied);
        check(requests.last.root.sections.first.items.first.title)
            .equals(l10n.updateAndCopyLink);
      } finally {
        messenger.setMockDecodedMessageHandler<Object?>(
          _presentResultSheetChannel,
          null,
        );
        NativeSheetBridge.instance.debugIsIOSOverride = null;
        debugDefaultTargetPlatformOverride = null;
        PlatformUiCapabilities.debugIOSMajorVersionOverride = null;
      }
    },
  );
}
