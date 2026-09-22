@TestOn('vm')
library;

import 'package:conduit_desktop_ui/src/l10n/strings.g.dart';
import 'package:conduit_desktop_ui/src/pages/chat_page.dart';
import 'package:conduit_desktop_ui/src/rpc/chat_providers.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr/dom.dart';
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
  void Function(_RecordingActions)? onActions,
  String query = '',
  ChatSearchResults? results,
}) => ProviderScope(
  overrides: [
    chatListProvider.overrideWith((ref) async => chats),
    searchQueryProvider.overrideWith(() => _FixedQuery(query)),
    searchResultsProvider.overrideWith((ref) async => results),
    chatDetailProvider.overrideWith((ref) async => detail),
    liveTurnProvider.overrideWith((ref) => Stream<LiveTurn?>.value(live)),
    selectedChatIdProvider.overrideWith(() => _FixedSelection(selected)),
    if (onActions != null)
      chatActionsProvider.overrideWith((ref) {
        final recording = _RecordingActions(ref);
        onActions(recording);
        return recording;
      }),
  ],
  child: const ChatPage(),
);

class _FixedQuery extends SearchQuery {
  _FixedQuery(this._initial);
  final String _initial;

  @override
  String build() => _initial;
}

class _FixedSelection extends SelectedChatId {
  _FixedSelection(this._initial);
  final String? _initial;

  @override
  String? build() => _initial;
}

/// Finds an element component by one of its attributes.
///
/// `jaspr_test` has no attribute finder, and these controls are identified by
/// `aria-label` on purpose -- their visible content is a decorative glyph, so
/// there is no text to find them by. Asserting on the accessible name is also
/// the assertion worth making.
/// Finds an element component by one of its attributes.
///
/// `jaspr_test` has no attribute finder, and these controls are identified by
/// `aria-label` on purpose: their visible content is a decorative glyph, so
/// there is no text to find them by -- and asserting on the accessible name
/// is the assertion worth making anyway.
///
/// Restricted to the `button`/`div` *components*, because a Jaspr element
/// appears in the tree twice -- once as the component and once as the DOM
/// element it builds -- and counting both would make "two conversations"
/// read as four.
Finder byAttribute(String name, String value) =>
    find.byComponentPredicate((component) {
      if (component is! button && component is! div) return false;
      final dynamic candidate = component;
      final attributes = candidate.attributes as Map<String, String>?;
      return attributes != null && attributes[name] == value;
    }, description: '$name="$value"');

/// Records what the sidebar asked the daemon to do.
class _RecordingActions extends ChatActions {
  _RecordingActions(super.ref);

  final List<String> calls = <String>[];

  @override
  Future<void> rename(String id, String title) async =>
      calls.add('rename($id,$title)');

  @override
  Future<void> setPinned(String id, {required bool value}) async =>
      calls.add('pin($id,$value)');

  @override
  Future<void> setArchived(String id, {required bool value}) async =>
      calls.add('archive($id,$value)');

  @override
  Future<void> delete(String id) async => calls.add('delete($id)');
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

  group('search', () {
    const hits = ChatSearchResults(
      hits: <ChatSearchHit>[
        ChatSearchHit(
          chatId: 'chat-9',
          title: 'An older conversation',
          snippet: 'the <b>outbox</b> drains oldest-first',
          updatedAtMs: 1758000000000,
        ),
      ],
    );

    testComponents('results replace the list rather than filtering it', (
      tester,
    ) async {
      tester.pumpComponent(_scoped(query: 'outbox', results: hits));
      await pumpEventQueue();

      // The loaded page is one page. Filtering it would quietly miss every
      // older conversation, which looks like a working search.
      expect(find.text('An older conversation'), findsOneComponent);
      expect(find.text('Rewriting the sync engine'), findsNothing);
    });

    testComponents('a hit shows the index\'s own snippet', (tester) async {
      tester.pumpComponent(_scoped(query: 'outbox', results: hits));
      await pumpEventQueue();

      expect(
        find.text('the <b>outbox</b> drains oldest-first'),
        findsOneComponent,
      );
    });

    testComponents('no matches says so rather than showing nothing', (
      tester,
    ) async {
      tester.pumpComponent(
        _scoped(query: 'zzz', results: const ChatSearchResults()),
      );
      await pumpEventQueue();

      // An empty pane with no explanation reads as a failed load.
      expect(find.text(t.desktop.desktopSearchNoResults), findsOneComponent);
    });

    testComponents('an empty query shows the list again', (tester) async {
      tester.pumpComponent(_scoped());
      await pumpEventQueue();

      expect(find.text('Rewriting the sync engine'), findsOneComponent);
    });
  });

  group('sidebar actions', () {
    late _RecordingActions actions;

    // Built inside the override, because `ChatActions` takes the provider
    // `Ref` it will read from.
    Component scoped() =>
        _scoped(onActions: (recording) => actions = recording);

    testComponents('every action is a real control with a name', (
      tester,
    ) async {
      tester.pumpComponent(scoped());
      await pumpEventQueue();

      // Named, because the glyphs are `aria-hidden` -- a row of unlabelled
      // symbols is unusable by ear and ambiguous by eye.
      for (final label in <String>[
        t.desktop.desktopRenameChat,
        t.desktop.desktopArchiveChat,
        t.desktop.desktopDeleteChat,
      ]) {
        expect(
          byAttribute('aria-label', label),
          findsNComponents(2),
          reason: '$label should exist for each of the two conversations',
        );
      }

      // The pin control names what it will do, not what the row is -- so
      // the pinned conversation offers "Unpin" and the other "Pin". A single
      // label for both would make the button a state display rather than an
      // action.
      expect(
        byAttribute('aria-label', t.desktop.desktopUnpinChat),
        findsOneComponent,
      );
      expect(
        byAttribute('aria-label', t.desktop.desktopPinChat),
        findsOneComponent,
      );
    });

    testComponents('the actions are in the DOM, not conditional on hover', (
      tester,
    ) async {
      tester.pumpComponent(scoped());
      await pumpEventQueue();

      // The whole point of revealing them with opacity rather than by
      // rendering them conditionally: a control that only exists on hover
      // cannot be reached by keyboard at all.
      expect(byAttribute('role', 'group'), findsNComponents(2));
    });

    testComponents('pinning sends the opposite of the current state', (
      tester,
    ) async {
      tester.pumpComponent(scoped());
      await pumpEventQueue();

      // The first conversation is pinned, so its button must unpin.
      await tester.click(byAttribute('aria-label', t.desktop.desktopUnpinChat));
      expect(actions.calls, <String>['pin(chat-1,false)']);
    });

    testComponents('deleting asks first', (tester) async {
      tester.pumpComponent(scoped());
      await pumpEventQueue();

      await tester.click(
        byAttribute('aria-label', t.desktop.desktopDeleteChat).first,
      );
      await pumpEventQueue();

      // Nothing sent yet: destructive and irreversible, so it interrupts.
      expect(actions.calls, isEmpty);
      expect(byAttribute('role', 'alertdialog'), findsOneComponent);
      expect(find.text(t.desktop.desktopConfirmDelete), findsOneComponent);
    });

    testComponents('confirming the delete sends it', (tester) async {
      tester.pumpComponent(scoped());
      await pumpEventQueue();

      await tester.click(
        byAttribute('aria-label', t.desktop.desktopDeleteChat).first,
      );
      await pumpEventQueue();
      // The button, not the text node inside it: `click` needs a DOM
      // element, and a text node is not one.
      await tester.click(
        find
            .ancestor(
              of: find.text(t.desktop.desktopDeleteChat),
              matching: find.tag('button'),
            )
            .last,
      );
      await pumpEventQueue();

      expect(actions.calls, <String>['delete(chat-1)']);
    });

    testComponents('cancelling the delete sends nothing', (tester) async {
      tester.pumpComponent(scoped());
      await pumpEventQueue();

      await tester.click(
        byAttribute('aria-label', t.desktop.desktopDeleteChat).first,
      );
      await pumpEventQueue();
      await tester.click(
        find.ancestor(
          of: find.text(t.app.cancel),
          matching: find.tag('button'),
        ),
      );
      await pumpEventQueue();

      expect(actions.calls, isEmpty);
      expect(byAttribute('role', 'alertdialog'), findsNothing);
    });

    testComponents('renaming opens a field seeded with the current title', (
      tester,
    ) async {
      tester.pumpComponent(scoped());
      await pumpEventQueue();

      await tester.click(
        byAttribute('aria-label', t.desktop.desktopRenameChat).first,
      );
      await pumpEventQueue();

      // Seeded, so a small correction does not mean retyping the whole
      // title.
      expect(
        find.byComponentPredicate(
          (component) =>
              component is input<String> &&
              component.value == 'Rewriting the sync engine',
          description: 'a field seeded with the current title',
        ),
        findsOneComponent,
      );
    });
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
