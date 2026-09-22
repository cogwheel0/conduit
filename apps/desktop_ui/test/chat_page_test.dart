@TestOn('vm')
library;

import 'package:conduit_desktop_ui/src/l10n/strings.g.dart';
import 'package:conduit_desktop_ui/src/pages/chat_page.dart';
import 'package:conduit_desktop_ui/src/rpc/chat_providers.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:jaspr_test/jaspr_test.dart';

const _chats = ChatList(
  chats: <ChatSummary>[
    ChatSummary(
      id: 'chat-1',
      title: 'Rewriting the sync engine',
      updatedAtMs: 1758412800000,
      pinned: true,
    ),
    ChatSummary(
      id: 'chat-2',
      title: 'Weekend plans',
      updatedAtMs: 1758312800000,
    ),
  ],
);

const _detail = ChatDetail(
  summary: ChatSummary(
    id: 'chat-1',
    title: 'Rewriting the sync engine',
    updatedAtMs: 1,
  ),
  messages: <ChatMessageDto>[
    ChatMessageDto(
      id: 'm1',
      role: 'user',
      content: 'How does the outbox order writes?',
      timestampMs: 1,
    ),
    ChatMessageDto(
      id: 'm2',
      role: 'assistant',
      content: 'Oldest first.',
      timestampMs: 2,
    ),
  ],
);

Component _scoped({
  ChatList chats = _chats,
  ChatDetail? detail,
  String? selected,
  LiveTurn? live,
}) => ProviderScope(
  overrides: [
    chatListProvider.overrideWith((ref) async => chats),
    chatDetailProvider.overrideWith((ref) async => detail),
    liveTurnProvider.overrideWith((ref) => Stream<LiveTurn?>.value(live)),
    selectedChatIdProvider.overrideWith(() => _FixedSelection(selected)),
  ],
  child: const ChatPage(),
);

class _FixedSelection extends SelectedChatId {
  _FixedSelection(this._initial);
  final String? _initial;

  @override
  String? build() => _initial;
}

void main() {
  testComponents('lists conversations in the sidebar', (tester) async {
    tester.pumpComponent(_scoped());
    await pumpEventQueue();

    expect(find.text('Rewriting the sync engine'), findsOneComponent);
    expect(find.text('Weekend plans'), findsOneComponent);
  });

  testComponents('says so when there are no conversations', (tester) async {
    tester.pumpComponent(_scoped(chats: const ChatList()));
    await pumpEventQueue();

    // An empty sidebar with no explanation reads as a failed load.
    expect(find.text(t.desktop.desktopNoChatsYet), findsOneComponent);
  });

  testComponents('renders the selected transcript', (tester) async {
    tester.pumpComponent(_scoped(detail: _detail, selected: 'chat-1'));
    await pumpEventQueue();

    expect(find.text('How does the outbox order writes?'), findsOneComponent);
    expect(find.text('Oldest first.'), findsOneComponent);
  });

  testComponents('shows a streaming answer for the chat on screen', (
    tester,
  ) async {
    tester.pumpComponent(
      _scoped(
        detail: _detail,
        selected: 'chat-1',
        live: const LiveTurn(
          chatId: 'chat-1',
          messageId: 'm3',
          text: 'Drains oldest',
        ),
      ),
    );
    await pumpEventQueue();

    expect(find.text('Drains oldest'), findsOneComponent);
  });

  testComponents('does not paint another chat\'s turn into this one', (
    tester,
  ) async {
    tester.pumpComponent(
      _scoped(
        detail: _detail,
        selected: 'chat-1',
        live: const LiveTurn(
          chatId: 'chat-2',
          messageId: 'm9',
          text: 'Answer for the other conversation',
        ),
      ),
    );
    await pumpEventQueue();

    // A background turn elsewhere must not appear in the open transcript.
    expect(find.text('Answer for the other conversation'), findsNothing);
  });

  testComponents('offers stop while streaming, send otherwise', (tester) async {
    tester.pumpComponent(_scoped(detail: _detail, selected: 'chat-1'));
    await pumpEventQueue();
    expect(find.text(t.app.send), findsOneComponent);
    expect(find.text(t.app.stopGenerating), findsNothing);

    tester.pumpComponent(
      _scoped(
        detail: _detail,
        selected: 'chat-1',
        live: const LiveTurn(chatId: 'chat-1', messageId: 'm3', text: 'x'),
      ),
    );
    await pumpEventQueue();
    // Both at once would let a user start a second turn into the same
    // placeholder, which the daemon rejects with `resource.conflict`.
    expect(find.text(t.app.stopGenerating), findsOneComponent);
    expect(find.text(t.app.send), findsNothing);
  });
}
