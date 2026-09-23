@TestOn('vm')
library;

import 'package:conduit_desktop_ui/src/l10n/strings.g.dart';
import 'package:conduit_desktop_ui/src/pages/chat_page.dart';
import 'package:conduit_desktop_ui/src/rpc/chat_providers.dart';
import 'package:conduit_desktop_ui/src/rpc/rpc_providers.dart';
import 'package:conduit_desktop_ui/src/rpc/session_providers.dart';
import 'package:conduit_desktop_ui/src/attachments.dart';
import 'package:conduit_desktop_ui/src/window_commands.dart';
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

const _models = ModelList(
  models: <ModelSummary>[ModelSummary(id: 'm1', name: 'Model one')],
  selectedId: 'm1',
);

Component _scoped({
  ChatList chats = _chats,
  ChatDetail? detail,
  String? selected,
  LiveTurn? live,
  void Function(_RecordingActions)? onActions,
  String query = '',
  ChatSearchResults? results,
  RecordingWindowCommands? commands,
  RecordingAttachments? attachments,
  ModelList? models,
  ComposerOptions? composer,
  Capabilities? capabilities,
  Set<String>? chosen,
}) => ProviderScope(
  overrides: [
    if (chosen != null)
      chatSelectionProvider.overrideWith(() => _Chosen(chosen)),
    if (capabilities != null)
      serverCapabilitiesProvider.overrideWithValue(capabilities),
    if (composer != null)
      composerOptionsProvider.overrideWith((ref) async => composer),
    if (models != null) modelListProvider.overrideWith((ref) async => models),
    if (commands != null) windowCommandsProvider.overrideWithValue(commands),
    if (attachments != null) attachmentsProvider.overrideWithValue(attachments),
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

class _Chosen extends ChatSelection {
  _Chosen(this._initial);
  final Set<String> _initial;

  @override
  Set<String>? build() => _initial;
}

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

  @override
  Future<void> loadMore() async => calls.add('loadMore');

  @override
  Future<List<String>> bulk(
    Set<String> chatIds,
    BulkChatAction action, {
    String? folderId,
  }) async {
    calls.add('bulk(${action.name},${chatIds.join('+')},$folderId)');
    return const <String>[];
  }

  @override
  Future<void> rate({
    required String chatId,
    required String messageId,
    required int rating,
  }) async => calls.add('rate($messageId,$rating)');

  @override
  Future<SendTurnAccepted> edit({
    required String chatId,
    required String messageId,
    required String text,
  }) async {
    calls.add('edit($messageId,$text)');
    return SendTurnAccepted(
      chatId: chatId,
      userMessageId: 'u2',
      assistantMessageId: 'a2',
    );
  }

  @override
  Future<void> setArchivedVisible({required bool visible}) async =>
      calls.add('archivedVisible($visible)');

  @override
  Future<SendTurnAccepted> send({
    required String text,
    String? model,
    List<String> fileIds = const <String>[],
    List<String> toolIds = const <String>[],
    bool webSearch = false,
    bool imageGeneration = false,
  }) async {
    calls.add('send($text${fileIds.isEmpty ? '' : ',files=$fileIds'})');
    return const SendTurnAccepted(
      chatId: 'chat-1',
      userMessageId: 'u1',
      assistantMessageId: 'a1',
    );
  }

  @override
  Future<SendTurnAccepted> regenerate({
    required String chatId,
    required String messageId,
    String? model,
  }) async {
    calls.add('regenerate($chatId,$messageId)');
    return SendTurnAccepted(
      chatId: chatId,
      userMessageId: 'u1',
      assistantMessageId: 'a1',
    );
  }
}

/// Finds the single element carrying this `aria-label`.
///
/// Glyph-labelled buttons repeat across the page -- `\u2715` is both
/// "remove attachment" and "delete conversation" -- so the accessible name
/// is the only thing that tells them apart, which is also the point of
/// having one.
Finder _byLabel(String label) => find.byComponentPredicate((component) {
  if (component is! DomComponent) return false;
  return component.attributes?['aria-label'] == label;
});

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

  testComponents('a refused turn says why, in the server\'s words', (
    tester,
  ) async {
    tester.pumpComponent(
      _scoped(
        detail: _detail,
        selected: 'chat-1',
        live: const LiveTurn(
          chatId: 'chat-1',
          messageId: 'm3',
          text: '',
          failedCode: ConduitErrorCodes.serverError,
          failedDetail: 'Free tier users do not have access to this model',
          settled: true,
        ),
      ),
    );
    await pumpEventQueue();

    // This used to render as an ellipsis inside a red border: the user was
    // told a turn had failed and nothing about what to do next, while the
    // daemon had the server's sentence in hand the whole time.
    expect(
      find.text('Free tier users do not have access to this model'),
      findsOneComponent,
    );
    expect(find.text('…'), findsNothing);
  });

  testComponents('a failure after partial output keeps the partial output', (
    tester,
  ) async {
    tester.pumpComponent(
      _scoped(
        detail: _detail,
        selected: 'chat-1',
        live: const LiveTurn(
          chatId: 'chat-1',
          messageId: 'm3',
          text: 'The outbox drains',
          failedCode: ConduitErrorCodes.serverError,
          failedDetail: 'Upstream timed out',
          settled: true,
        ),
      ),
    );
    await pumpEventQueue();

    expect(find.text('The outbox drains'), findsOneComponent);
    expect(find.text('Upstream timed out'), findsOneComponent);
  });

  testComponents('an unexplained failure still says something', (tester) async {
    tester.pumpComponent(
      _scoped(
        detail: _detail,
        selected: 'chat-1',
        live: const LiveTurn(
          chatId: 'chat-1',
          messageId: 'm3',
          text: '',
          failedCode: ConduitErrorCodes.serverError,
          settled: true,
        ),
      ),
    );
    await pumpEventQueue();

    expect(find.text(t.app.errorMessage), findsOneComponent);
  });

  testComponents('names the conversation before its transcript arrives', (
    tester,
  ) async {
    // The sidebar already has the title on screen; showing "Loading" in the
    // header while the fetch runs renames the pane twice per selection.
    tester.pumpComponent(_scoped(selected: 'chat-1'));
    await pumpEventQueue();

    expect(find.text('Rewriting the sync engine'), findsNComponents(2));
  });

  testComponents('an incomplete index does not claim nothing matched', (
    tester,
  ) async {
    // During the first sync the index is still filling. "Nothing matched"
    // there is a claim the app cannot make yet.
    tester.pumpComponent(
      _scoped(
        query: 'outbox',
        results: const ChatSearchResults(complete: false),
      ),
    );
    await pumpEventQueue();

    expect(find.text(t.desktop.desktopSearchNoResults), findsNothing);
    expect(find.text(t.desktop.desktopSearchIncomplete), findsOneComponent);
  });

  testComponents('an empty list during the first sync says syncing', (
    tester,
  ) async {
    tester.pumpComponent(
      ProviderScope(
        overrides: [
          syncStateProvider.overrideWith(
            (ref) => Stream.value(const SyncState(running: true)),
          ),
        ],
        child: _scoped(chats: const ChatList()),
      ),
    );
    await pumpEventQueue();
    expect(find.text(t.desktop.desktopNoChatsYet), findsNothing);
    // Once here as the list's hint, once in the footer's indicator.
    expect(find.text(t.desktop.desktopSyncing), findsNComponents(2));
  });

  group('composer features', () {
    testComponents('offers only what the server allows', (tester) async {
      tester.pumpComponent(
        _scoped(composer: const ComposerOptions(imageGeneration: true)),
      );
      await pumpEventQueue();
      // A switch that is shown but does nothing is worse than none.
      expect(find.text(t.app.imageGeneration), findsOneComponent);
      expect(find.text(t.app.webSearch), findsNothing);
      expect(find.text(t.app.tools), findsNothing);
    });

    testComponents('a toggle says whether it is on', (tester) async {
      tester.pumpComponent(
        _scoped(composer: const ComposerOptions(webSearch: true)),
      );
      await pumpEventQueue();
      final chip = find.ancestor(
        of: find.text(t.app.webSearch),
        matching: find.tag('button'),
      );
      bool pressed() =>
          (chip.evaluate().whereType<DomElement>().first.component)
              .attributes?['aria-pressed'] ==
          'true';
      expect(pressed(), isFalse);
      await tester.click(chip);
      await pumpEventQueue();
      expect(pressed(), isTrue);
    });

    testComponents('tools open as a list and count what is chosen', (
      tester,
    ) async {
      tester.pumpComponent(
        _scoped(
          composer: const ComposerOptions(
            tools: <ToolSummary>[
              ToolSummary(id: 'viz', name: 'Inline Visualizer'),
            ],
          ),
        ),
      );
      await pumpEventQueue();
      expect(find.text('Inline Visualizer'), findsNothing);

      await tester.click(
        find.ancestor(of: find.text(t.app.tools), matching: find.tag('button')),
      );
      await pumpEventQueue();
      expect(find.text('Inline Visualizer'), findsOneComponent);
    });
  });

  group('temporary chat', () {
    testComponents('offered only before the first message', (tester) async {
      tester.pumpComponent(_scoped(models: _models));
      await pumpEventQueue();
      expect(find.text(t.app.temporaryChat), findsOneComponent);

      tester.pumpComponent(
        _scoped(models: _models, detail: _detail, selected: 'chat-1'),
      );
      await pumpEventQueue();
      // A conversation is temporary or not from its start.
      expect(find.text(t.app.temporaryChat), findsNothing);
    });

    testComponents('a temporary chat says so, and cannot branch', (
      tester,
    ) async {
      const temporary = ChatDetail(
        summary: ChatSummary(id: 'local:abc', title: 'Q', updatedAtMs: 1),
        messages: <ChatMessageDto>[
          ChatMessageDto(id: 'u', role: 'user', content: 'Q', timestampMs: 1),
          ChatMessageDto(
            id: 'a',
            role: 'assistant',
            content: 'A',
            timestampMs: 2,
          ),
        ],
      );
      tester.pumpComponent(
        _scoped(detail: temporary, selected: 'local:abc', onActions: (_) {}),
      );
      await pumpEventQueue();

      expect(find.text(t.app.temporaryChat), findsOneComponent);
      // Regenerate and edit branch the server's history, which a temporary
      // chat does not have.
      expect(find.text(t.app.regenerate), findsNothing);
      expect(find.text(t.app.edit), findsNothing);
      expect(find.text(t.app.copy), findsNComponents(2));
    });
  });

  group('sections', () {
    final now = DateTime.now().millisecondsSinceEpoch;
    final foldered = ChatList(
      chats: <ChatSummary>[
        ChatSummary(
          id: 'p',
          title: 'Pinned one',
          updatedAtMs: now,
          pinned: true,
        ),
        ChatSummary(
          id: 'f',
          title: 'Filed away',
          updatedAtMs: now,
          folderId: 'work',
        ),
        ChatSummary(id: 'r', title: 'Just now', updatedAtMs: now),
      ],
      folders: const <FolderSummary>[FolderSummary(id: 'work', name: 'Work')],
      hasMore: true,
      archivedCount: 3,
    );

    testComponents('draws the headings Open WebUI does', (tester) async {
      tester.pumpComponent(_scoped(chats: foldered));
      await pumpEventQueue();

      expect(find.text(t.app.pinned), findsOneComponent);
      expect(find.text(t.app.folders), findsOneComponent);
      expect(find.text(t.app.today), findsOneComponent);
      // As headings, so a screen reader can jump between them.
      expect(find.tag('h2'), findsNComponents(3));
    });

    testComponents('a folder hides its chats until it is opened', (
      tester,
    ) async {
      tester.pumpComponent(_scoped(chats: foldered));
      await pumpEventQueue();

      expect(find.text('Filed away'), findsNothing);
      await tester.click(
        find.ancestor(of: find.text('Work'), matching: find.tag('button')),
      );
      await pumpEventQueue();
      expect(find.text('Filed away'), findsOneComponent);
    });

    testComponents('a folder the account left open starts open', (
      tester,
    ) async {
      tester.pumpComponent(
        _scoped(
          chats: foldered.copyWith(
            folders: const <FolderSummary>[
              FolderSummary(id: 'work', name: 'Work', expanded: true),
            ],
          ),
        ),
      );
      await pumpEventQueue();
      await pumpEventQueue();

      expect(find.text('Filed away'), findsOneComponent);
    });

    testComponents('more and archived are offered, and ask the daemon', (
      tester,
    ) async {
      late _RecordingActions actions;
      tester.pumpComponent(
        _scoped(chats: foldered, onActions: (recording) => actions = recording),
      );
      await pumpEventQueue();

      await tester.click(
        find.ancestor(
          of: find.text(t.app.workspaceLoadMore),
          matching: find.tag('button'),
        ),
      );
      await tester.click(
        find.ancestor(
          of: find.text('${t.app.archived} (3)'),
          matching: find.tag('button'),
        ),
      );
      await pumpEventQueue();

      expect(actions.calls, <String>['loadMore', 'archivedVisible(true)']);
    });

    testComponents('an archived chat offers to unarchive, not archive', (
      tester,
    ) async {
      tester.pumpComponent(
        _scoped(
          chats: ChatList(
            chats: <ChatSummary>[
              ChatSummary(
                id: 'a',
                title: 'Old',
                updatedAtMs: now,
                archived: true,
              ),
            ],
            archivedCount: 1,
            archivedVisible: true,
          ),
        ),
      );
      await pumpEventQueue();

      expect(_byLabel(t.app.unarchive), findsOneComponent);
      expect(_byLabel(t.desktop.desktopArchiveChat), findsNothing);
    });
  });

  group('attachments', () {
    const file = PickedAttachment(
      handle: 'h1',
      name: 'notes.pdf',
      size: 1234,
      contentType: 'application/pdf',
    );

    Future<void> attach(ComponentTester tester) =>
        tester.click(_byLabel(t.desktop.desktopAttachFiles));

    testComponents('a picked file becomes a chip and is uploaded', (
      tester,
    ) async {
      final port = RecordingAttachments(picks: <PickedAttachment>[file]);
      tester.pumpComponent(_scoped(selected: 'chat-1', attachments: port));
      await pumpEventQueue();

      expect(find.text('notes.pdf'), findsNothing);
      await attach(tester);
      await pumpEventQueue();

      expect(find.text('notes.pdf'), findsOneComponent);
      expect(port.uploaded, <String>['h1']);
    });

    testComponents('removing a chip tells the port to let the file go', (
      tester,
    ) async {
      // Otherwise the browser holds a file handle for a file the user has
      // taken back, for as long as the window lives.
      final port = RecordingAttachments(picks: <PickedAttachment>[file]);
      tester.pumpComponent(_scoped(selected: 'chat-1', attachments: port));
      await pumpEventQueue();
      await attach(tester);
      await pumpEventQueue();

      await tester.click(
        _byLabel(t.desktop.desktopRemoveAttachment(name: 'notes.pdf')),
      );
      await pumpEventQueue();

      expect(port.discarded, <String>['h1']);
      expect(find.text('notes.pdf'), findsNothing);
    });

    testComponents('a failed upload names the file rather than the code', (
      tester,
    ) async {
      final port = RecordingAttachments(picks: <PickedAttachment>[file])
        ..failWith = StateError('nope');
      tester.pumpComponent(_scoped(selected: 'chat-1', attachments: port));
      await pumpEventQueue();
      await attach(tester);
      await pumpEventQueue();

      expect(
        find.text(t.desktop.desktopAttachmentFailed(name: 'notes.pdf')),
        findsOneComponent,
      );
      // And the chip stays, so the user can take it off and try again.
      expect(find.text('notes.pdf'), findsOneComponent);
    });

    testComponents('a dropped file becomes a chip and is uploaded', (
      tester,
    ) async {
      final port = RecordingAttachments()..transfer = <PickedAttachment>[file];
      tester.pumpComponent(_scoped(selected: 'chat-1', attachments: port));
      await pumpEventQueue();

      final composer = find.byKey(const ValueKey('composer'));
      tester.dispatchEvent(composer, 'dragenter');
      await pumpEventQueue();
      expect(find.text(t.desktop.desktopDropToAttach), findsOneComponent);

      tester.dispatchEvent(composer, 'drop');
      await pumpEventQueue();
      expect(find.text(t.desktop.desktopDropToAttach), findsNothing);
      expect(find.text('notes.pdf'), findsOneComponent);
      expect(port.uploaded, <String>['h1']);
    });

    testComponents('a pasted file is attached like a picked one', (
      tester,
    ) async {
      final port = RecordingAttachments()..transfer = <PickedAttachment>[file];
      tester.pumpComponent(_scoped(selected: 'chat-1', attachments: port));
      await pumpEventQueue();

      tester.dispatchEvent(find.byKey(const ValueKey('composer')), 'paste');
      await pumpEventQueue();
      expect(find.text('notes.pdf'), findsOneComponent);
      expect(port.uploaded, <String>['h1']);
    });

    testComponents('dragging text over the composer is not a file drop', (
      tester,
    ) async {
      // Nothing to attach, so no hint -- and the port left the event
      // alone, so the text still lands in the field.
      final port = RecordingAttachments();
      tester.pumpComponent(_scoped(selected: 'chat-1', attachments: port));
      await pumpEventQueue();

      final composer = find.byKey(const ValueKey('composer'));
      tester.dispatchEvent(composer, 'dragenter');
      await pumpEventQueue();
      expect(find.text(t.desktop.desktopDropToAttach), findsNothing);
      tester.dispatchEvent(composer, 'paste');
      await pumpEventQueue();
      expect(port.uploaded, isEmpty);
    });

    // Sending *with* an attachment is asserted in the Electron suite
    // instead. The form's submit handler calls `preventDefault`, which
    // throws on the VM -- `universal_web` stubs every real DOM call -- so
    // the one thing a component test cannot do here is submit a form.
  });

  group('selection', () {
    testComponents('Select turns rows into checkboxes', (tester) async {
      tester.pumpComponent(
        _scoped(capabilities: const Capabilities(bulkSelection: true)),
      );
      await pumpEventQueue();
      expect(find.tag('input'), findsOneComponent); // the search field

      await tester.click(
        find.componentWithText(button, t.desktop.desktopSelect),
      );
      await pumpEventQueue();
      // One per conversation, beside the search field.
      expect(find.tag('input'), findsNComponents(3));
      expect(
        find.text(t.desktop.desktopSelectedCount(count: 0)),
        findsOneComponent,
      );
    });

    testComponents('an action runs over everything chosen', (tester) async {
      late _RecordingActions actions;
      tester.pumpComponent(
        _scoped(
          capabilities: const Capabilities(bulkSelection: true),
          chosen: const <String>{'chat-1', 'chat-2'},
          onActions: (recording) => actions = recording,
        ),
      );
      await pumpEventQueue();
      await tester.click(find.componentWithText(button, t.app.archive));
      await pumpEventQueue();
      expect(actions.calls, contains('bulk(archive,chat-1+chat-2,null)'));
    });

    testComponents('deleting several asks first', (tester) async {
      late _RecordingActions actions;
      tester.pumpComponent(
        _scoped(
          capabilities: const Capabilities(bulkSelection: true),
          chosen: const <String>{'chat-2'},
          onActions: (recording) => actions = recording,
        ),
      );
      await pumpEventQueue();
      await tester.click(find.componentWithText(button, t.app.delete));
      await pumpEventQueue();
      expect(actions.calls, isEmpty);
      expect(
        find.text(t.desktop.desktopBulkDeleteConfirm(count: 1)),
        findsOneComponent,
      );
    });
  });

  group('rating', () {
    testComponents('thumbs appear on answers only when the server rates', (
      tester,
    ) async {
      tester.pumpComponent(_scoped(detail: _detail, selected: 'chat-1'));
      await pumpEventQueue();
      expect(_byLabel(t.desktop.desktopGoodResponse), findsNothing);
    });

    testComponents('rating an answer sends it', (tester) async {
      late _RecordingActions actions;
      tester.pumpComponent(
        _scoped(
          detail: _detail,
          selected: 'chat-1',
          capabilities: const Capabilities(messageRating: true),
          onActions: (recording) => actions = recording,
        ),
      );
      await pumpEventQueue();
      // One pair, under the answer and not the question.
      expect(_byLabel(t.desktop.desktopGoodResponse), findsOneComponent);
      await tester.click(_byLabel(t.desktop.desktopBadResponse));
      await pumpEventQueue();
      expect(actions.calls, contains('rate(m2,-1)'));
    });

    testComponents('a stored rating shows as pressed', (tester) async {
      tester.pumpComponent(
        _scoped(
          detail: const ChatDetail(
            summary: ChatSummary(id: 'chat-1', title: 'T', updatedAtMs: 1),
            messages: <ChatMessageDto>[
              ChatMessageDto(
                id: 'm2',
                role: 'assistant',
                content: 'Yes.',
                timestampMs: 2,
                rating: 1,
              ),
            ],
          ),
          selected: 'chat-1',
          capabilities: const Capabilities(messageRating: true),
        ),
      );
      await pumpEventQueue();
      expect(byAttribute('aria-pressed', 'true'), findsOneComponent);
    });
  });

  testComponents('a finished turn gives the send button back', (tester) async {
    // The provider keeps the last turn until a new one replaces it, which
    // is what holds a completed answer on screen while the sync catches
    // up. Reading that as "still streaming" left Stop on the composer with
    // no way back to Send.
    tester.pumpComponent(
      _scoped(
        detail: _detail,
        selected: 'chat-1',
        live: const LiveTurn(
          chatId: 'chat-1',
          messageId: 'm3',
          text: 'Done.',
          settled: true,
        ),
      ),
    );
    await pumpEventQueue();

    expect(find.text(t.app.send), findsOneComponent);
    expect(find.text(t.app.stopGenerating), findsNothing);
  });

  testComponents('deleting the open chat leaves the empty state, not a blank', (
    tester,
  ) async {
    // What deleting leaves behind: nothing selected, and a settled turn
    // for a conversation that no longer exists.
    tester.pumpComponent(
      _scoped(
        live: const LiveTurn(
          chatId: 'deleted',
          messageId: 'm',
          text: 'Old answer',
          settled: true,
        ),
      ),
    );
    await pumpEventQueue();

    expect(find.text(t.desktop.desktopPickAConversation), findsOneComponent);
    expect(find.text('Old answer'), findsNothing);
  });

  testComponents('the transcript follows the conversation', (tester) async {
    final commands = RecordingWindowCommands();
    tester.pumpComponent(
      _scoped(detail: _detail, selected: 'chat-1', commands: commands),
    );
    await pumpEventQueue();

    // Asked for on every build, because a streaming answer grows on each
    // delta. Whether it *moves* is the port's call: it declines when the
    // user has scrolled away, which is why this asks rather than scrolls.
    expect(commands.scrolled, contains('transcript'));
  });

  group('answer versions', () {
    const branched = ChatDetail(
      summary: ChatSummary(id: 'chat-1', title: 'T', updatedAtMs: 1),
      messages: <ChatMessageDto>[
        ChatMessageDto(id: 'u', role: 'user', content: 'Q', timestampMs: 1),
        ChatMessageDto(
          id: 'a',
          role: 'assistant',
          content: 'Third answer',
          timestampMs: 4,
          versions: <ChatMessageVersionDto>[
            ChatMessageVersionDto(
              id: 'a1',
              content: 'First answer',
              timestampMs: 2,
            ),
            ChatMessageVersionDto(
              id: 'a2',
              content: 'Second answer',
              timestampMs: 3,
            ),
          ],
        ),
      ],
    );

    testComponents('shows the newest answer, and says there are others', (
      tester,
    ) async {
      tester.pumpComponent(_scoped(detail: branched, selected: 'chat-1'));
      await pumpEventQueue();

      expect(find.text('Third answer'), findsOneComponent);
      expect(find.text('3/3'), findsOneComponent);
    });

    testComponents('the arrows reach every earlier answer', (tester) async {
      tester.pumpComponent(_scoped(detail: branched, selected: 'chat-1'));
      await pumpEventQueue();

      await tester.click(_byLabel(t.desktop.desktopPreviousAnswer));
      await pumpEventQueue();
      expect(find.text('Second answer'), findsOneComponent);

      await tester.click(_byLabel(t.desktop.desktopPreviousAnswer));
      await pumpEventQueue();
      // What regenerate replaced is still reachable, which is the point.
      expect(find.text('First answer'), findsOneComponent);
      expect(find.text('1/3'), findsOneComponent);
    });

    testComponents('copy takes the answer on screen', (tester) async {
      final commands = RecordingWindowCommands();
      tester.pumpComponent(
        _scoped(detail: branched, selected: 'chat-1', commands: commands),
      );
      await pumpEventQueue();
      await tester.click(_byLabel(t.desktop.desktopPreviousAnswer));
      await pumpEventQueue();

      await tester.click(
        find
            .ancestor(of: find.text(t.app.copy), matching: find.tag('button'))
            .last,
      );
      expect(commands.copied, <String>['Second answer']);
    });

    testComponents('a message with one answer shows no arrows', (tester) async {
      tester.pumpComponent(_scoped(detail: _detail, selected: 'chat-1'));
      await pumpEventQueue();
      expect(_byLabel(t.desktop.desktopPreviousAnswer), findsNothing);
    });
  });

  group('editing a question', () {
    testComponents('only questions offer Edit', (tester) async {
      tester.pumpComponent(
        _scoped(detail: _detail, selected: 'chat-1', onActions: (_) {}),
      );
      await pumpEventQueue();
      expect(find.text(t.app.edit), findsOneComponent);
    });

    testComponents('opens in place, seeded with the question', (tester) async {
      tester.pumpComponent(
        _scoped(detail: _detail, selected: 'chat-1', onActions: (_) {}),
      );
      await pumpEventQueue();
      await tester.click(
        find.ancestor(of: find.text(t.app.edit), matching: find.tag('button')),
      );
      await pumpEventQueue();

      expect(find.tag('textarea'), findsNComponents(2));
      expect(find.text('How does the outbox order writes?'), findsOneComponent);
    });

    testComponents('an unchanged question cannot be sent', (tester) async {
      // Asking the same thing again is what Regenerate is for; this would
      // branch the conversation for nothing.
      tester.pumpComponent(
        _scoped(detail: _detail, selected: 'chat-1', onActions: (_) {}),
      );
      await pumpEventQueue();
      await tester.click(
        find.ancestor(of: find.text(t.app.edit), matching: find.tag('button')),
      );
      await pumpEventQueue();

      final send = find
          .byComponentPredicate(
            (c) => c is button && c.disabled && c.type == ButtonType.button,
          )
          .evaluate();
      expect(send, isNotEmpty);
    });

    testComponents('an edit in flight replaces the old branch on screen', (
      tester,
    ) async {
      tester.pumpComponent(
        ProviderScope(
          overrides: [
            pendingUserMessageProvider.overrideWith(
              () => _FixedPending(
                const PendingUserMessage(
                  chatId: 'chat-1',
                  messageId: 'u-new',
                  text: 'What order does the outbox use?',
                  replaces: 'm1',
                ),
              ),
            ),
          ],
          child: _scoped(detail: _detail, selected: 'chat-1'),
        ),
      );
      await pumpEventQueue();

      // The edited question, and neither the original nor its answer --
      // they belong to the branch being left.
      expect(find.text('What order does the outbox use?'), findsOneComponent);
      expect(find.text('How does the outbox order writes?'), findsNothing);
      expect(find.text('Oldest first.'), findsNothing);
    });

    testComponents('cancel puts the question back', (tester) async {
      tester.pumpComponent(
        _scoped(detail: _detail, selected: 'chat-1', onActions: (_) {}),
      );
      await pumpEventQueue();
      await tester.click(
        find.ancestor(of: find.text(t.app.edit), matching: find.tag('button')),
      );
      await pumpEventQueue();
      await tester.click(
        find
            .ancestor(of: find.text(t.app.cancel), matching: find.tag('button'))
            .first,
      );
      await pumpEventQueue();

      expect(find.tag('textarea'), findsOneComponent);
      expect(find.text(t.app.edit), findsOneComponent);
    });
  });

  group('message actions', () {
    testComponents('copying a message hands over its text', (tester) async {
      final commands = RecordingWindowCommands();
      tester.pumpComponent(
        _scoped(detail: _detail, selected: 'chat-1', commands: commands),
      );
      await pumpEventQueue();

      await tester.click(
        find
            .ancestor(of: find.text(t.app.copy), matching: find.tag('button'))
            .first,
      );
      await pumpEventQueue();

      expect(commands.copied, <String>['How does the outbox order writes?']);
    });

    testComponents('only an assistant answer offers regenerate', (
      tester,
    ) async {
      tester.pumpComponent(
        _scoped(detail: _detail, selected: 'chat-1', onActions: (_) {}),
      );
      await pumpEventQueue();

      // Two messages, one of each role. Both can be copied; only the
      // answer can be redone.
      expect(find.text(t.app.copy), findsNComponents(2));
      expect(find.text(t.app.regenerate), findsOneComponent);
    });

    testComponents('regenerating names the answer, not the prompt', (
      tester,
    ) async {
      late _RecordingActions actions;
      tester.pumpComponent(
        _scoped(
          detail: _detail,
          selected: 'chat-1',
          onActions: (recording) => actions = recording,
        ),
      );
      await pumpEventQueue();

      await tester.click(
        find.ancestor(
          of: find.text(t.app.regenerate),
          matching: find.tag('button'),
        ),
      );
      await pumpEventQueue();

      // The assistant message id: it is what the button sits under, and a
      // prompt may already have several answers.
      expect(actions.calls, <String>['regenerate(chat-1,m2)']);
    });

    testComponents('nothing can be regenerated while a turn streams', (
      tester,
    ) async {
      // The daemon refuses a second turn in a chat, so a button that would
      // reliably fail is worse than one that is not offered.
      tester.pumpComponent(
        _scoped(
          detail: _detail,
          selected: 'chat-1',
          live: const LiveTurn(
            chatId: 'chat-1',
            messageId: 'm3',
            text: 'Still going',
          ),
          onActions: (_) {},
        ),
      );
      await pumpEventQueue();

      expect(find.text(t.app.regenerate), findsNothing);
    });
  });

  testComponents('an unselected pane invites a choice rather than blanking', (
    tester,
  ) async {
    tester.pumpComponent(_scoped());
    await pumpEventQueue();

    expect(find.text(t.desktop.desktopPickAConversation), findsOneComponent);
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

class _FixedPending extends PendingUserMessageNotifier {
  _FixedPending(this._value);
  final PendingUserMessage _value;
  @override
  PendingUserMessage? build() => _value;
}
