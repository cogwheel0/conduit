import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/core/auth/api_auth_interceptor.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/models/user.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:conduit/features/channels/providers/channel_providers.dart';
import 'package:conduit/features/channels/views/channel_page.dart';
import 'package:conduit/features/channels/widgets/thread_panel.dart';
import 'package:conduit/features/chat/widgets/modern_chat_input.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/utils/conversation_context_menu.dart';
import 'package:flutter/material.dart';
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
            localizationsDelegates: AppLocalizations.localizationsDelegates,
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
      check(
        container.read(activeChannelProvider)?.name,
      ).equals('Replacement channel');
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
      final replacementSend =
          replacementComposer.onSendMessage('Replacement owner message')
              as Future<void>;
      await tester.pump(const Duration(milliseconds: 1));
      check(replacementApi.postChannelMessageCalls).equals(1);

      firstSendResponse.complete(_messageJson('Old owner response'));
      await firstSend;
      await tester.pump(const Duration(milliseconds: 1));
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
      check(
        container.read(activeChannelProvider)?.name,
      ).equals('Replacement channel');

      container.read(_channelApiOwnerProvider.notifier).set(null);
      container.read(_channelAuthEpochProvider.notifier).rotate();
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump(const Duration(milliseconds: 1));
      check(container.read(activeChannelProvider)).isNull();

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    },
  );

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
        localizationsDelegates: AppLocalizations.localizationsDelegates,
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
  int getChannelCalls = 0;
  int postChannelMessageCalls = 0;
  int addMessageReactionCalls = 0;

  @override
  Future<Map<String, dynamic>> getChannel(String channelId) {
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
  }) async => const [];

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
    return true;
  }

  @override
  Future<(List<Map<String, dynamic>>, bool)> getChannels() async =>
      (const <Map<String, dynamic>>[], true);

  @override
  Future<Map<String, dynamic>> getUserPermissions() async => const {};

  @override
  Future<Map<String, dynamic>> getUserSettings({
    ApiAuthSnapshot? authSnapshot,
  }) async => const {};
}

class _RouteChangeChannelApi extends _ChannelApi {
  _RouteChangeChannelApi(this.secondResponse);

  final Completer<Map<String, dynamic>> secondResponse;

  @override
  Future<Map<String, dynamic>> getChannel(String channelId) {
    if (channelId == 'channel-2') return secondResponse.future;
    return Future<Map<String, dynamic>>.value({
      'id': channelId,
      'name': 'First channel',
    });
  }
}
