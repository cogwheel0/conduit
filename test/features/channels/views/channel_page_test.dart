import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit_core/auth/api_auth_interceptor.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/models/channel_message.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/features/channels/providers/channel_providers.dart';
import 'package:conduit/features/channels/views/channel_page.dart';
import 'package:conduit/features/channels/widgets/thread_panel.dart';
import 'package:conduit/features/chat/widgets/modern_chat_input.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/utils/conversation_context_menu.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final _channelApiOwnerProvider =
    NotifierProvider<_MutableChannelApiOwner, ApiService?>(
      _MutableChannelApiOwner.new,
    );
final _channelAuthEpochProvider =
    NotifierProvider<_MutableChannelAuthEpoch, Object>(
      _MutableChannelAuthEpoch.new,
    );

void main() {
  testWidgets('a posted message is stored at once and gets its sender later', (
    tester,
  ) async {
    final userLoading = Completer<User?>();
    final api = _ChannelApi(
      // The server's answer to a post names only the sender's id.
      sendResponse: Completer<Map<String, dynamic>>()
        ..complete({
          'id': 'message-2',
          'channel_id': 'channel-1',
          'user_id': 'user-1',
          'content': 'hello',
        }),
    );
    final container = ProviderContainer(
      overrides: [
        apiServiceProvider.overrideWithValue(api),
        currentUserProvider.overrideWith((ref) => userLoading.future),
        socketServiceProvider.overrideWithValue(null),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(TweakcnThemes.t3Chat),
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const ChannelPage(channelId: 'channel-1'),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 1));

    final send =
        tester
                .widget<ModernChatInput>(find.byType(ModernChatInput).first)
                .onSendMessage('hello')
            as Future<void>;
    // The post is stored without waiting for the user to load.
    await send;
    await tester.pump(const Duration(milliseconds: 1));
    final stored = container
        .read(channelMessagesProvider('channel-1'))
        .requireValue
        .single;
    check(stored.id).equals('message-2');
    check(stored.user).isNull();

    userLoading.complete(
      const User(
        id: 'user-1',
        username: 'alice',
        email: 'alice@example.test',
        name: 'Alice',
        role: 'user',
      ),
    );
    await tester.pump(const Duration(milliseconds: 1));

    final posted = container
        .read(channelMessagesProvider('channel-1'))
        .requireValue
        .single;
    check(posted.userName).equals('Alice');
  });

  testWidgets(
    'mounted channel reloads details when API and auth owner change',
    (tester) async {
      final firstResponse = Completer<Map<String, dynamic>>();
      final firstSendResponse = Completer<Map<String, dynamic>>();
      final replacementSendResponse = Completer<Map<String, dynamic>>();
      final firstApi = _ChannelApi(
        firstResponse: firstResponse,
        sendResponse: firstSendResponse,
        messages: [_messageJson('Original message')],
      );
      final replacementApi = _ChannelApi(
        channelName: 'Replacement channel',
        sendResponse: replacementSendResponse,
        messages: [_messageJson('Replacement message')],
      );
      final container = ProviderContainer(
        overrides: [
          apiServiceProvider.overrideWith(
            (ref) => ref.watch(_channelApiOwnerProvider),
          ),
          openWebUiAuthSessionEpochProvider.overrideWith(
            (ref) => ref.watch(_channelAuthEpochProvider),
          ),
          currentUserProvider.overrideWith(
            (ref) async => const User(
              id: 'user-1',
              username: 'alice',
              email: 'alice@example.test',
              name: 'Alice',
              role: 'user',
            ),
          ),
          socketServiceProvider.overrideWithValue(null),
        ],
      );
      addTearDown(container.dispose);
      container.read(_channelApiOwnerProvider.notifier).set(firstApi);
      final firstAuthEpoch = container.read(_channelAuthEpochProvider);
      final replacementAuthEpoch = Object();

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.light(TweakcnThemes.t3Chat),
            localizationsDelegates: conduitLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const ChannelPage(channelId: 'channel-1'),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 1));
      check(firstApi.getChannelCalls).equals(1);

      final messageMenu = tester.widget<ConduitContextMenu>(
        find.byType(ConduitContextMenu).first,
      );
      for (final label in ['Reply', 'Thread', 'Edit']) {
        await messageMenu.actions
            .singleWhere((action) => action.label == label)
            .onSelected();
        await tester.pump(const Duration(milliseconds: 1));
      }
      expect(find.text('Replying to Alice'), findsOneWidget);
      expect(find.byType(ThreadPanel), findsOneWidget);
      check(
        tester
            .widgetList<TextField>(find.byType(TextField))
            .any((field) => field.controller?.text == 'Original message'),
      ).isTrue();

      unawaited(
        messageMenu.actions
            .singleWhere((action) => action.label == 'React')
            .onSelected(),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('👍'), findsOneWidget);

      final firstSend =
          tester
                  .widget<ModernChatInput>(find.byType(ModernChatInput).first)
                  .onSendMessage('Old owner message')
              as Future<void>;
      await tester.pump(const Duration(milliseconds: 1));
      check(firstApi.postChannelMessageCalls).equals(1);

      container.read(_channelApiOwnerProvider.notifier).set(replacementApi);
      container
          .read(_channelAuthEpochProvider.notifier)
          .set(replacementAuthEpoch);
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump(const Duration(milliseconds: 1));

      check(replacementApi.getChannelCalls).equals(1);
      check(container.read(activeChannelProvider)?.name)
          .equals('Replacement channel');
      expect(find.text('Replying to Alice'), findsNothing);
      expect(find.byType(ThreadPanel), findsNothing);
      check(
        tester
            .widgetList<TextField>(find.byType(TextField))
            .any((field) => field.controller?.text == 'Original message'),
      ).isFalse();

      // Return to the exact API/auth/channel owner that opened the picker.
      // Only the operation generation distinguishes this A -> B -> A cycle.
      container.read(_channelApiOwnerProvider.notifier).set(firstApi);
      container.read(_channelAuthEpochProvider.notifier).set(firstAuthEpoch);
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump(const Duration(milliseconds: 1));
      firstSendResponse.complete(_messageJson('Old owner response'));
      await firstSend;
      await tester.pump(const Duration(milliseconds: 1));
      expect(find.text('Old owner response'), findsNothing);
      tester
          .widget<GestureDetector>(
            find
                .ancestor(
                  of: find.text('👍'),
                  matching: find.byType(GestureDetector),
                )
                .first,
          )
          .onTap!();
      await tester.pump(const Duration(milliseconds: 300));
      check(firstApi.addMessageReactionCalls).equals(0);
      check(replacementApi.addMessageReactionCalls).equals(0);

      container.read(_channelApiOwnerProvider.notifier).set(replacementApi);
      container
          .read(_channelAuthEpochProvider.notifier)
          .set(replacementAuthEpoch);
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump(const Duration(milliseconds: 1));

      final replacementComposer = tester.widget<ModernChatInput>(
        find.byType(ModernChatInput).first,
      );
      final replacementSend = replacementComposer.onSendMessage(
        'Replacement owner message',
      ) as Future<void>;
      await tester.pump(const Duration(milliseconds: 1));
      check(replacementApi.postChannelMessageCalls).equals(1);

      await (replacementComposer.onSendMessage('Must remain blocked')
          as Future<void>);
      check(replacementApi.postChannelMessageCalls).equals(1);

      replacementSendResponse.complete(
        _messageJson('Replacement owner response'),
      );
      await replacementSend;
      await tester.pump(const Duration(milliseconds: 1));

      firstResponse.complete(_channelJson('Stale channel'));
      await tester.pump(const Duration(milliseconds: 1));
      check(container.read(activeChannelProvider)?.name)
          .equals('Replacement channel');

      container.read(_channelApiOwnerProvider.notifier).set(null);
      container.read(_channelAuthEpochProvider.notifier).rotate();
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump(const Duration(milliseconds: 1));
      check(container.read(activeChannelProvider)).isNull();

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    },
  );

  testWidgets('a thread shows reply reactions and toggles them', (
    tester,
  ) async {
    final api = _ChannelApi(
      messages: [_messageJson('Parent')],
      threadMessages: [
        {
          'id': 'reply-1',
          'channel_id': 'channel-1',
          'parent_id': 'message-1',
          'content': 'A reply',
          'reactions': [
            {
              'name': '🎉',
              'users': [
                {'id': 'user-2'},
              ],
              'count': 1,
            },
          ],
        },
      ],
    );
    final container = ProviderContainer(
      overrides: [
        apiServiceProvider.overrideWithValue(api),
        currentUserProvider.overrideWith(
          (ref) async => const User(
            id: 'user-1',
            username: 'alice',
            email: 'alice@example.test',
            name: 'Alice',
            role: 'user',
          ),
        ),
        socketServiceProvider.overrideWithValue(null),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(TweakcnThemes.t3Chat),
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const ChannelPage(channelId: 'channel-1'),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 1));
    await tester
        .widget<ConduitContextMenu>(find.byType(ConduitContextMenu).first)
        .actions
        .singleWhere((action) => action.label == 'Thread')
        .onSelected();
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 300));

    final chip = find.descendant(
      of: find.byType(ThreadPanel),
      matching: find.widgetWithText(ActionChip, '🎉 1'),
    );
    expect(chip, findsOneWidget);
    tester.widget<ActionChip>(chip).onPressed!();
    await tester.pump(const Duration(milliseconds: 1));
    check(api.reactedMessageIds).deepEquals(['reply-1']);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  // The phone thread sheet can be a native sheet with no Material behind it.
  testWidgets('a thread panel without a Material ancestor shows reactions', (
    tester,
  ) async {
    final api = _ChannelApi(
      threadMessages: [
        {
          'id': 'reply-1',
          'channel_id': 'channel-1',
          'parent_id': 'message-1',
          'content': 'A reply',
          'reactions': [
            {
              'name': '🎉',
              'users': [
                {'id': 'user-2'},
              ],
              'count': 1,
            },
          ],
        },
      ],
    );
    final container = ProviderContainer(
      overrides: [
        apiServiceProvider.overrideWithValue(api),
        socketServiceProvider.overrideWithValue(null),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(TweakcnThemes.t3Chat),
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ThreadPanel(
            channelId: 'channel-1',
            parentMessage: ChannelMessage.fromJson(_messageJson('Parent')),
            onClose: () {},
            onReactionTap: (_, _) {},
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 1));

    check(tester.takeException()).isNull();
    expect(find.widgetWithText(ActionChip, '🎉 1'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('channel route change clears the prior active channel', (
    tester,
  ) async {
    final secondResponse = Completer<Map<String, dynamic>>();
    final api = _RouteChangeChannelApi(secondResponse);
    final container = ProviderContainer(
      overrides: [
        apiServiceProvider.overrideWithValue(api),
        socketServiceProvider.overrideWithValue(null),
      ],
    );
    addTearDown(container.dispose);

    Widget buildPage(String channelId) => UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.light(TweakcnThemes.t3Chat),
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ChannelPage(channelId: channelId),
      ),
    );

    await tester.pumpWidget(buildPage('channel-1'));
    await tester.pump(const Duration(milliseconds: 1));
    check(container.read(activeChannelProvider)?.name).equals('First channel');

    await tester.pumpWidget(buildPage('channel-2'));
    await tester.pump(const Duration(milliseconds: 1));
    check(container.read(activeChannelProvider)).isNull();

    secondResponse.complete({'id': 'channel-2', 'name': 'Second channel'});
    await tester.pump(const Duration(milliseconds: 1));
    check(container.read(activeChannelProvider)?.name).equals('Second channel');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });
  testWidgets('the members button opens the searchable, pageable list with '
      'the opener\'s credentials', (tester) async {
    final api = _MemberChannelApi();
    final container = ProviderContainer(
      overrides: [
        apiServiceProvider.overrideWithValue(api),
        activeServerProvider.overrideWith((ref) => api.serverConfig),
        authTokenProvider3.overrideWithValue('token-a'),
        socketServiceProvider.overrideWithValue(null),
      ],
    );
    addTearDown(container.dispose);
    await container.read(activeServerProvider.future);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(TweakcnThemes.t3Chat),
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const ChannelPage(channelId: 'channel-1'),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 1));

    await tester.tap(find.byIcon(Icons.people_outline));
    await tester.pumpAndSettle();

    // The interactive sheet, not a first-page-only static one: it has search
    // and a way to reach the next page.
    expect(find.byKey(const Key('channel-members-list')), findsOneWidget);
    expect(find.byType(TextField), findsWidgets);
    expect(find.text('Members (65)'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.byKey(const Key('channel-members-load-more')),
      200,
      scrollable: find.descendant(
        of: find.byKey(const Key('channel-members-list')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.tap(find.byKey(const Key('channel-members-load-more')));
    await tester.pumpAndSettle();
    check(api.memberReads.map((read) => read.page)).deepEquals([1, 2]);

    await tester.enterText(find.byType(TextField).last, 'Person 004');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    check(api.memberReads.last.query).equals('Person 004');
    check(api.memberReads.last.page).equals(1);

    // Every read was bound to the credentials captured when the sheet opened.
    check(api.memberReads.map((read) => read.snapshot))
        .every((it) => it.isNotNull());
  });

  testWidgets('the count refresh after removing a member is bound to the '
      'opener\'s credentials', (tester) async {
    final api = _MemberChannelApi();
    final container = ProviderContainer(
      overrides: [
        apiServiceProvider.overrideWithValue(api),
        activeServerProvider.overrideWith((ref) => api.serverConfig),
        authTokenProvider3.overrideWithValue('token-a'),
        currentUserProvider2.overrideWithValue(
          const User(
            id: 'user-1',
            username: 'user-1',
            email: 'user-1@example.test',
            role: 'user',
          ),
        ),
        appSettingsProvider.overrideWith(() => _AdvancedSettings()),
        socketServiceProvider.overrideWithValue(null),
      ],
    );
    addTearDown(container.dispose);
    await container.read(activeServerProvider.future);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(TweakcnThemes.t3Chat),
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const ChannelPage(channelId: 'channel-1'),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 1));
    // The page's own load is an ordinary read.
    check(api.channelReadSnapshots).deepEquals([null]);

    await tester.tap(find.byIcon(Icons.people_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('channel-member-remove-user-3')));
    await tester.pumpAndSettle();

    check(api.removals.map((r) => r.userIds)).deepEquals([
      ['user-3'],
    ]);
    // The refresh that follows is the second channel read, and it carries the
    // snapshot captured when the sheet opened.
    check(api.channelReadSnapshots).length.equals(2);
    check(api.channelReadSnapshots.last).isNotNull();
    check(api.removals.single.snapshot).isNotNull();
  });
}

class _AdvancedSettings extends AppSettingsNotifier {
  @override
  AppSettings build() => const AppSettings(advancedFeaturesEnabled: true);
}

Map<String, dynamic> _channelJson(String name) => {
  'id': 'channel-1',
  'name': name,
};

Map<String, dynamic> _messageJson(String content) => {
  'id': 'message-1',
  'channel_id': 'channel-1',
  'user_id': 'user-1',
  'content': content,
  'user': {'id': 'user-1', 'name': 'Alice', 'email': 'alice@example.test'},
};

class _MutableChannelApiOwner extends Notifier<ApiService?> {
  @override
  ApiService? build() => null;

  void set(ApiService? value) => state = value;
}

class _MutableChannelAuthEpoch extends Notifier<Object> {
  @override
  Object build() => Object();

  void rotate() => state = Object();

  void set(Object value) => state = value;
}

class _ChannelApi extends ApiService {
  _ChannelApi({
    this.firstResponse,
    this.sendResponse,
    this.channelName = 'Initial channel',
    this.messages = const [],
    this.threadMessages = const [],
  }) : super(
         serverConfig: const ServerConfig(
           id: 'test-server',
           name: 'Test Server',
           url: 'https://example.com',
         ),
         workerManager: WorkerManager(),
       );

  final Completer<Map<String, dynamic>>? firstResponse;
  final Completer<Map<String, dynamic>>? sendResponse;
  final String channelName;
  final List<Map<String, dynamic>> messages;
  final List<Map<String, dynamic>> threadMessages;
  final List<String> reactedMessageIds = [];
  int getChannelCalls = 0;
  int postChannelMessageCalls = 0;
  int addMessageReactionCalls = 0;

  @override
  Future<Map<String, dynamic>> getChannel(
    String channelId, {
    ApiAuthSnapshot? authSnapshot,
  }) {
    getChannelCalls += 1;
    return firstResponse?.future ??
        Future<Map<String, dynamic>>.value(_channelJson(channelName));
  }

  @override
  Future<List<Map<String, dynamic>>> getChannelMessages(
    String channelId, {
    int skip = 0,
    int limit = 50,
  }) async => messages;

  @override
  Future<List<Map<String, dynamic>>> getMessageThread(
    String channelId,
    String messageId, {
    int skip = 0,
    int limit = 50,
  }) async => threadMessages;

  @override
  Future<Map<String, dynamic>> postChannelMessage(
    String channelId, {
    required String content,
    String? tempId,
    String? replyToId,
    String? parentId,
    Map<String, dynamic>? data,
    Map<String, dynamic>? meta,
  }) {
    postChannelMessageCalls += 1;
    return sendResponse?.future ??
        Future<Map<String, dynamic>>.value(_messageJson(content));
  }

  @override
  Future<bool> addMessageReaction(
    String channelId,
    String messageId,
    String name,
  ) async {
    addMessageReactionCalls += 1;
    reactedMessageIds.add(messageId);
    return true;
  }

  @override
  Future<(List<Map<String, dynamic>>, bool)> getChannels() async =>
      (const <Map<String, dynamic>>[], true);

  @override
  Future<Map<String, dynamic>> getUserPermissions({
    ApiAuthSnapshot? authSnapshot,
  }) async => const {};

  @override
  Future<Map<String, dynamic>> getUserSettings({
    ApiAuthSnapshot? authSnapshot,
  }) async => const {};
}

class _RouteChangeChannelApi extends _ChannelApi {
  _RouteChangeChannelApi(this.secondResponse);

  final Completer<Map<String, dynamic>> secondResponse;

  @override
  Future<Map<String, dynamic>> getChannel(
    String channelId, {
    ApiAuthSnapshot? authSnapshot,
  }) {
    if (channelId == 'channel-2') return secondResponse.future;
    return Future<Map<String, dynamic>>.value({
      'id': channelId,
      'name': 'First channel',
    });
  }
}

class _MemberChannelApi extends _ChannelApi {
  _MemberChannelApi();

  final List<({int page, String? query, ApiAuthSnapshot? snapshot})>
  memberReads = [];

  final List<ApiAuthSnapshot?> channelReadSnapshots = [];
  final List<({List<String> userIds, ApiAuthSnapshot? snapshot})> removals = [];

  @override
  Future<Map<String, dynamic>> getChannel(
    String channelId, {
    ApiAuthSnapshot? authSnapshot,
  }) async {
    channelReadSnapshots.add(authSnapshot);
    return {
      'id': channelId,
      'name': 'Team',
      'type': 'group',
      'user_id': 'user-1',
      'is_manager': true,
      'user_count': 65,
    };
  }

  @override
  Future<void> removeChannelMembers(
    String channelId, {
    required List<String> userIds,
    ApiAuthSnapshot? authSnapshot,
  }) async => removals.add((userIds: userIds, snapshot: authSnapshot));

  @override
  Future<Map<String, dynamic>> getChannelMembers(
    String channelId, {
    String? query,
    String? orderBy,
    String? direction,
    int page = 1,
    ApiAuthSnapshot? authSnapshot,
  }) async {
    memberReads.add((page: page, query: query, snapshot: authSnapshot));
    if (query != null) {
      return {
        'users': [_memberJson(4)],
        'total': 1,
      };
    }
    final first = (page - 1) * 30 + 1;
    return {
      'users': [
        for (var n = first; n < first + 30 && n <= 65; n++) _memberJson(n),
      ],
      'total': 65,
    };
  }
}

Map<String, dynamic> _memberJson(int n) => {
  'id': 'user-$n',
  'name': 'Person ${n.toString().padLeft(3, '0')}',
  'role': 'user',
};
