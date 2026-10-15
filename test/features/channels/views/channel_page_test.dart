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
import 'package:conduit_core/services/socket_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/features/channels/providers/channel_app_replies.dart';
import 'package:conduit_core/features/channels/providers/channel_providers.dart';
import 'package:conduit/shared/widgets/adaptive_toolbar_components.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit/features/channels/views/channel_page.dart';
import 'package:conduit/features/channels/widgets/channel_app_content.dart';
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

  // Open WebUI 0.12.1 apps post with no user_id and name the app in `user`.
  testWidgets('back-to-back replies from two apps each name their app', (
    tester,
  ) async {
    Map<String, dynamic> appReply(String id, String appId, String name) => {
      'id': id,
      'channel_id': 'channel-1',
      'user_id': null,
      'app_id': appId,
      'content': 'Reply from $name',
      'user': {'id': appId, 'name': name, 'role': 'app'},
    };
    final api = _ChannelApi(
      messages: [
        appReply('message-3', 'app-2', 'Search App'),
        appReply('message-2', 'app-1', 'Helper App'),
      ],
    );
    final container = ProviderContainer(
      overrides: [
        apiServiceProvider.overrideWithValue(api),
        currentUserProvider.overrideWith((ref) async => null),
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

    expect(find.text('Helper App'), findsOneWidget);
    expect(find.text('Search App'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  // Open WebUI 0.12.1 app cards and buttons (AppEmbed.svelte,
  // AppChannelReply.svelte).
  testWidgets('an app card shows its embed and buttons, and a button press '
      'shows the private reply', (tester) async {
    final api = _ChannelApi(
      messages: [_appCardMessageJson()],
      interactionResponse: {
        'type': 'message',
        'visibility': 'private',
        'title': 'Redeploy queued',
        'content': 'Only you can see this',
        'embeds': <Object>[],
        'actions': <Object>[],
      },
    );
    final container = _appRigContainer(api);
    addTearDown(container.dispose);
    await _pumpChannelPage(tester, container);

    // A card-only message is not an empty bubble.
    expect(find.text('Deploy Bot'), findsOneWidget);
    expect(find.text('App'), findsOneWidget);
    expect(find.text('Build 42'), findsOneWidget);
    expect(find.textContaining('All green', findRichText: true), findsWidgets);
    expect(find.text('Branch'), findsOneWidget);
    expect(find.text('took 3m'), findsOneWidget);
    expect(find.text('Redeploy'), findsOneWidget);
    expect(find.text('Open logs'), findsOneWidget);

    await tester.tap(find.text('Redeploy'));
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 1));

    check(api.interactions).deepEquals(['app-1|message-1|redeploy']);
    expect(find.text('Redeploy queued'), findsOneWidget);
    expect(
      find.textContaining('Only you can see this', findRichText: true),
      findsWidgets,
    );
    expect(find.text('Only visible to you'), findsOneWidget);

    await tester.tap(find.text('Dismiss'));
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.text('Only visible to you'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('a thread shows app cards and keeps their private replies', (
    tester,
  ) async {
    final api = _ChannelApi(
      threadMessages: [
        {
          ..._appCardMessageJson(),
          'id': 'reply-1',
          'parent_id': 'message-1',
        },
      ],
      interactionResponse: {'type': 'error', 'visibility': 'private'},
    );
    final container = _appRigContainer(api);
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

    expect(find.text('Build 42'), findsOneWidget);
    await tester.tap(find.text('Redeploy'));
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 1));

    check(api.interactions).deepEquals(['app-1|reply-1|redeploy']);
    // An error without text gets the web client's fallback.
    expect(
      find.text('The app could not complete this operation.'),
      findsOneWidget,
    );
    expect(find.text('Only visible to you'), findsOneWidget);
    // The reply belongs to this thread, not to the channel.
    check(
      container.read(channelAppRepliesProvider('channel-1', 'message-1')).keys,
    ).deepEquals(['reply-1:app-1']);
    check(container.read(channelAppRepliesProvider('channel-1', null)))
        .isEmpty();

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  // The list reuses its rows by position, so a card's button state must
  // follow its message when a newer one arrives above it.
  testWidgets('a failed press stays with its message when a new one arrives', (
    tester,
  ) async {
    final api = _ChannelApi(
      messages: [_appCardMessageJson()],
      interactionError: StateError('app unreachable'),
    );
    final container = _appRigContainer(api);
    addTearDown(container.dispose);
    await _pumpChannelPage(tester, container);
    const failed = 'Something went wrong. Please try again.';

    await tester.tap(find.text('Redeploy'));
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.text(failed), findsOneWidget);

    container
        .read(channelMessagesProvider('channel-1').notifier)
        .prependMessage(
          ChannelMessage.fromJson({
            ..._appCardMessageJson(),
            'id': 'message-2',
          }),
        );
    await tester.pump(const Duration(milliseconds: 1));

    final cards = find.ancestor(
      of: find.text(failed),
      matching: find.byType(ChannelAppMessageCards),
    );
    expect(cards, findsOneWidget);
    check(tester.widget<ChannelAppMessageCards>(cards).message.id)
        .equals('message-1');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('a channel reply to a button press is not shown in place', (
    tester,
  ) async {
    final api = _ChannelApi(
      messages: [_appCardMessageJson()],
      interactionResponse: {'type': 'message', 'visibility': 'channel'},
    );
    final container = _appRigContainer(api);
    addTearDown(container.dispose);
    await _pumpChannelPage(tester, container);

    await tester.tap(find.text('Redeploy'));
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 1));

    check(api.interactions).length.equals(1);
    // It arrives as a channel message over the socket instead.
    expect(find.text('Only visible to you'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  // routers/channels.py sends a failed app mention's error to the asker
  // alone as events:app.
  testWidgets('an events:app error shows under the message that asked', (
    tester,
  ) async {
    final socket = _AppSocket();
    final api = _ChannelApi(
      messages: [
        _messageJson('<@A:app-1|Deploy Bot> deploy'),
      ],
    );
    final container = _appRigContainer(api, socket: socket);
    addTearDown(container.dispose);
    await _pumpChannelPage(tester, container);
    await tester.pump(const Duration(milliseconds: 1));

    Map<String, dynamic> appEvent({String channelId = 'channel-1'}) => {
      'app_id': 'app-1',
      'app_name': 'Deploy Bot',
      'channel_id': channelId,
      'message_id': 'message-1',
      'parent_id': null,
      'reply': {'type': 'error', 'content': 'App error: App is inactive'},
    };
    socket.deliverApp(appEvent(channelId: 'channel-2'));
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.text('Only visible to you'), findsNothing);

    socket.deliverApp(appEvent());
    await tester.pump(const Duration(milliseconds: 1));

    expect(find.text('Only visible to you'), findsOneWidget);
    expect(find.text('Deploy Bot'), findsOneWidget);
    expect(
      find.textContaining('App is inactive', findRichText: true),
      findsWidgets,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('a reply to a card-only app message previews the card text', (
    tester,
  ) async {
    final api = _ChannelApi(
      messages: [
        {
          ..._messageJson('Thanks'),
          'id': 'message-2',
          'reply_to_id': 'message-1',
          // The slim reply preview keeps only the cards.
          'reply_to_message': {
            ..._appCardMessageJson(),
            'data': {
              'app': {
                'embeds': [
                  {'title': 'Build 42'},
                ],
              },
            },
          },
        },
      ],
    );
    final container = _appRigContainer(api);
    addTearDown(container.dispose);
    await _pumpChannelPage(tester, container);

    expect(find.text('Build 42'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('an app message is not editable while the user loads', (
    tester,
  ) async {
    final api = _ChannelApi(messages: [_appCardMessageJson()]);
    final userLoading = Completer<User?>();
    final container = _appRigContainer(api, user: userLoading.future);
    addTearDown(container.dispose);
    await _pumpChannelPage(tester, container);

    final labels = tester
        .widget<ConduitContextMenu>(find.byType(ConduitContextMenu).first)
        .actions
        .map((action) => action.label);
    check(labels).contains('Reply');
    check(labels).not((it) => it.contains('Edit'));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  // Open WebUI 0.12.1 ChannelMenu.svelte: All messages / Mentions only.
  testWidgets('the channel menu sets notifications to mentions only', (
    tester,
  ) async {
    final api = _ChannelApi(
      channels: [
        {'id': 'channel-1', 'name': 'Initial channel'},
      ],
    );
    final container = _appRigContainer(api);
    addTearDown(container.dispose);
    await container.read(channelsListProvider.future);
    await _pumpChannelPage(tester, container);

    ConduitAdaptiveToolbarOverflowButton<String> menu() => tester
        .widget<ConduitAdaptiveToolbarOverflowButton<String>>(
          find.byType(ConduitAdaptiveToolbarOverflowButton<String>),
        );
    Map<String, bool> checked() => {
      for (final item
          in menu().items.whereType<AdaptivePopupMenuItem<String>>())
        if (item.value!.startsWith('notify-')) item.value!: item.checked,
    };
    check(checked()).deepEquals({
      'notify-all': true,
      'notify-mentions': false,
    });

    menu().onSelected('notify-mentions');
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 1));

    check(api.muteRequests).deepEquals(['channel-1=true']);
    check(
      container.read(channelsListProvider).requireValue.single.isChannelMuted,
    ).isTrue();
    check(checked()).deepEquals({
      'notify-all': false,
      'notify-mentions': true,
    });

    // Choosing the current setting sends nothing.
    menu().onSelected('notify-mentions');
    await tester.pump(const Duration(milliseconds: 1));
    check(api.muteRequests).length.equals(1);

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
        // Advanced stays off: removing a member does not depend on it.
        appSettingsProvider.overrideWith(_Settings.new),
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

    // The members button names itself for VoiceOver and TalkBack.
    final semantics = tester.ensureSemantics();
    expect(find.bySemanticsLabel(RegExp(r'^Members \(\d+\)$')), findsWidgets);
    semantics.dispose();

    await tester.tap(find.byIcon(Icons.people_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('channel-member-remove-user-3')));
    await tester.pumpAndSettle();
    // Removing asks first.
    await tester.tap(find.text('Remove'));
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

class _Settings extends AppSettingsNotifier {
  @override
  AppSettings build() => const AppSettings();
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

Map<String, dynamic> _appCardMessageJson() => {
  'id': 'message-1',
  'channel_id': 'channel-1',
  'user_id': null,
  'app_id': 'app-1',
  'content': '',
  'user': {'id': 'app-1', 'name': 'Deploy Bot', 'role': 'app'},
  'data': {
    'app': {
      'embeds': [
        {
          'title': 'Build 42',
          'description': 'All green',
          'footer': {'text': 'took 3m'},
          'fields': [
            {'name': 'Branch', 'value': 'main', 'inline': true},
          ],
        },
      ],
      'actions': [
        {'action_id': 'redeploy', 'label': 'Redeploy', 'context': {}},
        {'label': 'Open logs', 'url': 'https://ci.example/42/logs'},
      ],
    },
  },
};

ProviderContainer _appRigContainer(
  _ChannelApi api, {
  SocketService? socket,
  Future<User?>? user,
}) => ProviderContainer(
  overrides: [
    apiServiceProvider.overrideWithValue(api),
    currentUserProvider.overrideWith(
      (ref) =>
          user ??
          Future<User?>.value(
            const User(
              id: 'user-1',
              username: 'alice',
              email: 'alice@example.test',
              name: 'Alice',
              role: 'user',
            ),
          ),
    ),
    socketServiceProvider.overrideWithValue(socket),
    userPermissionsProvider.overrideWith(
      (ref) async => const <String, dynamic>{},
    ),
  ],
);

Future<void> _pumpChannelPage(
  WidgetTester tester,
  ProviderContainer container,
) async {
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
}

/// A socket that delivers `events:app` to the page and takes the channel
/// subscription without delivering anything on it.
class _AppSocket implements SocketService {
  final List<SocketAppEventHandler> _appHandlers = [];

  // The server of [_ChannelApi], so chat providers see one owner.
  @override
  final ServerConfig serverConfig = const ServerConfig(
    id: 'test-server',
    name: 'Test Server',
    url: 'https://example.com',
  );

  @override
  bool get isConnected => false;

  void deliverApp(Map<String, dynamic> event) {
    for (final handler in List.of(_appHandlers)) {
      handler(event);
    }
  }

  @override
  SocketEventSubscription addAppEventHandler(SocketAppEventHandler handler) {
    _appHandlers.add(handler);
    return SocketEventSubscription(() => _appHandlers.remove(handler));
  }

  @override
  SocketEventSubscription addChannelEventHandler({
    String? conversationId,
    String? sessionId,
    bool requireFocus = true,
    required SocketChannelEventHandler handler,
  }) => SocketEventSubscription(() {});

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

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
    this.channels = const [],
    this.interactionResponse = const {'type': 'ack'},
    this.interactionError,
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
  final List<Map<String, dynamic>> channels;
  final Map<String, dynamic> interactionResponse;
  final Object? interactionError;
  final List<String> reactedMessageIds = [];
  final List<String> interactions = [];
  final List<String> muteRequests = [];
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
      (channels, true);

  @override
  Future<Map<String, dynamic>> createAppInteraction(
    String appId, {
    required String messageId,
    required String actionId,
  }) async {
    interactions.add('$appId|$messageId|$actionId');
    if (interactionError case final error?) throw error;
    return interactionResponse;
  }

  @override
  Future<bool> updateMemberMuteStatus(
    String channelId, {
    required bool isChannelMuted,
  }) async {
    muteRequests.add('$channelId=$isChannelMuted');
    return isChannelMuted;
  }

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
