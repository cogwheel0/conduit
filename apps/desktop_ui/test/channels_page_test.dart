@TestOn('vm')
library;

import 'package:conduit_desktop_ui/src/l10n/strings.g.dart';
import 'package:conduit_desktop_ui/src/pages/channels_page.dart';
import 'package:conduit_desktop_ui/src/rpc/channels_providers.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:jaspr_test/jaspr_test.dart';

class _RecordingActions extends ChannelActions {
  _RecordingActions(super.ref);

  final List<ChannelReact> reactions = <ChannelReact>[];
  final List<ChannelPost> posts = <ChannelPost>[];
  final List<String> reads = <String>[];

  @override
  Future<void> react(ChannelReact react) async => reactions.add(react);

  @override
  Future<void> post(ChannelPost post) async => posts.add(post);

  @override
  Future<void> markRead(String channelId) async => reads.add(channelId);

  @override
  Future<void> typing(String channelId, {required bool typing}) async {}
}

const _channels = ChannelList(
  enabled: true,
  channels: <ChannelSummary>[
    ChannelSummary(id: 'c1', name: 'general', unread: 0),
    ChannelSummary(id: 'c2', name: 'ops', unread: 4, private: true),
  ],
);

const _messages = ChannelMessages(
  channelId: 'c1',
  // Newest first, as the daemon sends them.
  messages: <ChannelMessageDto>[
    ChannelMessageDto(
      id: 'm2',
      channelId: 'c1',
      user: ChannelUser(id: 'u2', name: 'Grace'),
      content: 'Thanks <@U:u1|Ada>',
      createdAtMs: 2000,
    ),
    ChannelMessageDto(
      id: 'm1',
      channelId: 'c1',
      user: ChannelUser(id: 'u1', name: 'Ada'),
      content: 'Deploy is done',
      createdAtMs: 1000,
      replyCount: 2,
      pinned: true,
      reactions: <ChannelReaction>[
        ChannelReaction(name: '👍', count: 2, mine: true),
      ],
      mine: true,
    ),
  ],
);

void main() {
  late _RecordingActions actions;

  Component page({String? id}) => ProviderScope(
    overrides: [
      channelListProvider.overrideWith((ref) async => _channels),
      channelMessagesProvider.overrideWith((ref, key) async => _messages),
      channelTypingProvider.overrideWith(
        (ref, id) => Stream<List<String>>.value(const <String>['Grace']),
      ),
      channelActionsProvider.overrideWith(
        (ref) => actions = _RecordingActions(ref),
      ),
    ],
    child: ChannelsPage(channelId: id),
  );

  Finder buttonWith(String text) =>
      find.ancestor(of: find.text(text), matching: find.tag('button'));

  testComponents('lists channels with their unread counts', (tester) async {
    tester.pumpComponent(page());
    await pumpEventQueue();
    expect(find.text('general'), findsOneComponent);
    expect(find.text('ops'), findsOneComponent);
    expect(find.text('4'), findsOneComponent);
    expect(find.text('🔒'), findsOneComponent);
  });

  testComponents('a channel reads oldest first, and a reaction toggles', (
    tester,
  ) async {
    tester.pumpComponent(page(id: 'c1'));
    await pumpEventQueue();
    // Opening it marks it read.
    expect(actions.reads, <String>['c1']);
    expect(find.text('Deploy is done'), findsOneComponent);
    expect(find.text('Grace …'), findsOneComponent);
    expect(find.text(t.app.threadWithCount(count: 2)), findsOneComponent);

    // The user's own reaction: a click takes it back.
    await tester.click(buttonWith('👍 2'));
    await pumpEventQueue();
    expect(actions.reactions.single.add, isFalse);
    expect(actions.reactions.single.emoji, '👍');
  });

  testComponents('a thread opens beside the channel', (tester) async {
    tester.pumpComponent(page(id: 'c1'));
    await pumpEventQueue();
    await tester.click(buttonWith(t.app.threadWithCount(count: 2)));
    await pumpEventQueue();
    expect(find.text(t.app.thread), findsComponents);
  });
}
