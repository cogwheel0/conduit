import 'dart:async';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';

import '../l10n/strings.g.dart';
import '../rpc/chat_providers.dart';
import '../widgets/form_field.dart';
import '../widgets/markdown_view.dart';

/// The chat vertical: sidebar, transcript, composer (M3).
class ChatPage extends StatelessComponent {
  const ChatPage({super.key});

  @override
  Component build(BuildContext context) => div(
    classes: 'flex h-screen min-h-0',
    [const _Sidebar(), const _Transcript()],
  );
}

class _Sidebar extends StatelessComponent {
  const _Sidebar();

  @override
  Component build(BuildContext context) {
    final chats = context.watch(chatListProvider);
    final selected = context.watch(selectedChatIdProvider);
    final query = context.watch(searchQueryProvider);
    final search = context.watch(searchResultsProvider);

    return nav(
      classes:
          'flex w-72 shrink-0 flex-col border-r border-border bg-background',
      attributes: <String, String>{'aria-label': t.desktop.desktopChatsLabel},
      [
        div(classes: 'p-3', [
          button(
            [Component.text(t.app.newChat)],
            classes:
                'w-full rounded bg-primary px-3 py-2 text-sm '
                'text-primary-foreground',
            type: ButtonType.button,
            onClick: () => context.read(chatActionsProvider).select(null),
          ),
        ]),
        div(classes: 'px-3 pb-2', [
          textField(
            id: 'chat-search',
            labelText: t.desktop.desktopSearchChats,
            placeholder: t.desktop.desktopSearchChats,
            hideLabel: true,
            value: query,
            type: InputType.search,
            onInput: (value) =>
                context.read(searchQueryProvider.notifier).set(value),
          ),
        ]),
        div(classes: 'min-h-0 flex-1 overflow-y-auto px-2 pb-2', [
          // Results replace the list rather than filtering it: the list is
          // one loaded page, and filtering that would quietly miss every
          // older conversation -- which looks like a working search.
          //
          // Both branches read `value` rather than `when`. An `AsyncValue`
          // that is refetching reports `loading` while still holding the
          // previous data, so `when` emptied this pane on every keystroke
          // past the debounce and after every rename, pin and delete. The
          // data is only genuinely absent on the first fetch.
          if (query.trim().isNotEmpty)
            if (search.value?.hits case final hits?)
              hits.isEmpty
                  ? _hint(t.desktop.desktopSearchNoResults)
                  : ul(classes: 'space-y-0.5', [
                      for (final hit in hits)
                        _SearchRow(
                          hit: hit,
                          isSelected: selected == hit.chatId,
                        ),
                    ])
            else if (search.hasError)
              _hint('${search.error}')
            else
              _hint(t.app.loadingShort)
          else if (chats.value case final list?)
            list.chats.isEmpty
                ? _hint(t.desktop.desktopNoChatsYet)
                : ul(classes: 'space-y-0.5', [
                    for (final chat in list.chats)
                      _ChatRow(chat: chat, isSelected: selected == chat.id),
                  ])
          else if (chats.hasError)
            _hint('${chats.error}')
          else
            _hint(t.app.loadingShort),
        ]),
        // Pinned under the list rather than floating over the transcript,
        // which is where it used to sit -- on top of the send button.
        div(classes: 'shrink-0 border-t border-border p-2', [
          a(
            href: '/settings/appearance',
            classes:
                'block rounded px-2 py-1.5 text-sm text-muted-foreground '
                'hover:bg-accent hover:text-accent-foreground',
            [Component.text(t.desktop.desktopSettingsTitle)],
          ),
        ]),
      ],
    );
  }

  Component _hint(String text) => p(
    classes: 'px-2 py-4 text-sm text-muted-foreground',
    [Component.text(text)],
  );
}

/// One search hit: the title, and the matching text in context.
class _SearchRow extends StatelessComponent {
  const _SearchRow({required this.hit, required this.isSelected});

  final ChatSearchHit hit;
  final bool isSelected;

  @override
  Component build(BuildContext context) => li([
    button(
      [
        span(classes: 'block truncate text-sm', [Component.text(hit.title)]),
        if (hit.snippet case final snippet?)
          span(classes: 'block truncate text-xs opacity-70', [
            // The index's own snippet. Re-deriving one here would mean
            // reimplementing the tokenizer to agree with it.
            Component.text(snippet),
          ]),
      ],
      classes:
          'block w-full rounded px-2 py-1.5 text-left '
          '${isSelected ? 'bg-accent text-accent-foreground' : 'text-muted-foreground hover:bg-accent/50'}',
      type: ButtonType.button,
      onClick: () => context.read(chatActionsProvider).select(hit.chatId),
    ),
  ]);
}

/// One conversation, with its actions.
///
/// Stateful for the rename field: an inline input beats a modal here, because
/// renaming is a small correction and a dialog makes it feel like a decision.
class _ChatRow extends StatefulComponent {
  const _ChatRow({required this.chat, required this.isSelected});

  final ChatSummary chat;
  final bool isSelected;

  @override
  State<_ChatRow> createState() => _ChatRowState();
}

class _ChatRowState extends State<_ChatRow> {
  bool _renaming = false;
  bool _confirmingDelete = false;
  String _draftTitle = '';

  @override
  Component build(BuildContext context) {
    final chat = component.chat;
    final actions = context.read(chatActionsProvider);

    if (_renaming) {
      return li(classes: 'px-1 py-1', [
        form(
          [
            textField(
              id: 'rename-${chat.id}',
              labelText: t.desktop.desktopRenamePrompt,
              value: _draftTitle,
              autofocus: true,
              onInput: (value) => setState(() => _draftTitle = value),
            ),
          ],
          events: <String, EventCallback>{
            'submit': (event) {
              event.preventDefault();
              final title = _draftTitle.trim();
              setState(() => _renaming = false);
              if (title.isNotEmpty && title != chat.title) {
                unawaited(actions.rename(chat.id, title));
              }
            },
          },
        ),
      ]);
    }

    return li(classes: 'group relative', [
      div(classes: 'flex items-center gap-1', [
        button(
          [
            span(classes: 'truncate', [Component.text(chat.title)]),
            if (chat.pinned)
              span(
                classes: 'ml-1 text-xs',
                attributes: const <String, String>{'aria-hidden': 'true'},
                [Component.text('\u2605')],
              ),
          ],
          classes:
              'flex min-w-0 flex-1 items-center rounded px-2 py-1.5 '
              'text-left text-sm '
              '${component.isSelected ? 'bg-accent text-accent-foreground' : 'text-muted-foreground hover:bg-accent/50'}',
          type: ButtonType.button,
          // `aria-current` rather than `aria-selected`: these are navigation
          // items, not options in a listbox.
          attributes: component.isSelected
              ? const <String, String>{'aria-current': 'true'}
              : null,
          onClick: () => actions.select(chat.id),
        ),
        _actionsMenu(context, chat, actions),
      ]),
      if (_confirmingDelete)
        div(
          classes:
              'mt-1 rounded border border-destructive/40 '
              'bg-destructive/10 p-2 text-xs',
          // `alertdialog`: destructive and irreversible, so it should
          // interrupt rather than wait to be found.
          attributes: const <String, String>{'role': 'alertdialog'},
          [
            p(classes: 'text-destructive', [
              Component.text(t.desktop.desktopConfirmDelete),
            ]),
            div(classes: 'mt-2 flex gap-2', [
              button(
                [Component.text(t.desktop.desktopDeleteChat)],
                classes:
                    'rounded bg-destructive px-2 py-1 '
                    'text-destructive-foreground',
                type: ButtonType.button,
                onClick: () {
                  setState(() => _confirmingDelete = false);
                  unawaited(actions.delete(chat.id));
                },
              ),
              button(
                [Component.text(t.app.cancel)],
                classes: 'rounded px-2 py-1 text-foreground',
                type: ButtonType.button,
                onClick: () => setState(() => _confirmingDelete = false),
              ),
            ]),
          ],
        ),
    ]);
  }

  /// Always in the DOM, visually revealed on hover or focus.
  ///
  /// Not conditionally rendered: a control that only exists on hover cannot
  /// be reached by keyboard at all, and `group-focus-within` is what keeps it
  /// available to someone tabbing through the list.
  Component _actionsMenu(
    BuildContext context,
    ChatSummary chat,
    ChatActions actions,
  ) => div(
    classes:
        'flex shrink-0 gap-0.5 opacity-0 transition-opacity '
        'group-hover:opacity-100 group-focus-within:opacity-100',
    attributes: <String, String>{
      'role': 'group',
      'aria-label': t.desktop.desktopChatActions(title: chat.title),
    },
    [
      _action(
        label: chat.pinned
            ? t.desktop.desktopUnpinChat
            : t.desktop.desktopPinChat,
        glyph: '\u2605',
        onClick: () =>
            unawaited(actions.setPinned(chat.id, value: !chat.pinned)),
      ),
      _action(
        label: t.desktop.desktopRenameChat,
        glyph: '\u270e',
        onClick: () => setState(() {
          _renaming = true;
          _draftTitle = chat.title;
        }),
      ),
      _action(
        label: t.desktop.desktopArchiveChat,
        glyph: '\u25a4',
        onClick: () =>
            unawaited(actions.setArchived(chat.id, value: !chat.archived)),
      ),
      _action(
        label: t.desktop.desktopDeleteChat,
        glyph: '\u2715',
        destructive: true,
        onClick: () => setState(() => _confirmingDelete = true),
      ),
    ],
  );

  Component _action({
    required String label,
    required String glyph,
    required void Function() onClick,
    bool destructive = false,
  }) => button(
    [
      // The glyph is decoration; the accessible name comes from the label.
      span(
        attributes: const <String, String>{'aria-hidden': 'true'},
        [Component.text(glyph)],
      ),
    ],
    classes:
        'rounded px-1 text-xs '
        '${destructive ? 'text-destructive hover:bg-destructive/10' : 'text-muted-foreground hover:bg-accent'}',
    type: ButtonType.button,
    attributes: <String, String>{'aria-label': label, 'title': label},
    onClick: onClick,
  );
}

class _Transcript extends StatelessComponent {
  const _Transcript();

  @override
  Component build(BuildContext context) {
    final detail = context.watch(chatDetailProvider);
    final live = context.watch(liveTurnProvider).value;
    final selected = context.watch(selectedChatIdProvider);
    final pending = context.watch(pendingUserMessageProvider);

    // Once the server's copy of the sent message arrives, stop rendering the
    // local one -- otherwise the same words appear twice for a moment.
    final persisted = detail.value?.messages ?? const <ChatMessageDto>[];
    if (persisted.isNotEmpty) {
      Future<void>.microtask(
        () => context
            .read(pendingUserMessageProvider.notifier)
            .reconcile(persisted),
      );
    }
    final showPending =
        pending != null &&
        pending.chatId == selected &&
        !persisted.any((message) => message.id == pending.messageId);

    // The list already has the title, and it is on screen -- so falling
    // back to it means switching conversations renames the header at once
    // instead of showing "Loading" for as long as the fetch takes.
    final title =
        detail.value?.summary.title ??
        _titleIn(context.watch(chatListProvider).value, selected);
    // Keyed on the selection, not on the message count: a conversation whose
    // transcript is still being fetched has no messages either, and telling
    // someone to pick a conversation they just picked is worse than a pause.
    final nothingChosen = selected == null && !showPending && live == null;

    return section(classes: 'flex min-w-0 flex-1 flex-col', [
      // A window with no header cannot say which conversation it is showing,
      // and the sidebar selection is off-screen the moment the list scrolls.
      header(
        classes:
            'flex h-12 shrink-0 items-center border-b border-border px-6 '
            'text-sm font-medium text-foreground',
        [
          // A conversation the list has not caught up with yet is a
          // conversation this window just created.
          Component.text(title ?? t.desktop.desktopNewConversation),
        ],
      ),
      div(
        classes: 'min-h-0 flex-1 overflow-y-auto px-6 py-6',
        // `log` so a screen reader announces arriving messages without the
        // user having to go looking for them, and politely enough not to
        // interrupt what they are reading.
        attributes: const <String, String>{
          'role': 'log',
          'aria-live': 'polite',
        },
        [
          if (nothingChosen) _emptyState(),
          div(classes: 'mx-auto flex max-w-3xl flex-col gap-4', [
            ...detail.when(
              loading: () => <Component>[],
              error: (error, _) => <Component>[formError('$error')],
              data: (chat) => <Component>[
                for (final message in chat?.messages ?? const [])
                  _bubble(message.role, message.content),
              ],
            ),
            // The message just sent, until the server's copy arrives.
            if (showPending) _bubble('user', pending.text),
            // Only for the chat on screen: a background turn in another
            // conversation must not paint into this one. A settled turn also
            // stands down once the synced transcript contains it.
            if (live != null &&
                live.chatId == selected &&
                !persisted.any((message) => message.id == live.messageId))
              _bubble(
                'assistant',
                live.text.isEmpty && !live.failed ? '…' : live.text,
                streaming: !live.failed && !live.settled,
                // The server's words when it gave any, ours when it did not.
                // A red border around an empty bubble was the whole of what
                // a refused model used to say.
                failure: live.failed
                    ? (live.failedDetail ?? t.app.errorMessage)
                    : null,
              ),
          ]),
        ],
      ),
      const _Composer(),
    ]);
  }

  /// The sidebar's name for [chatId], if the list has been loaded.
  String? _titleIn(ChatList? list, String? chatId) {
    for (final chat in list?.chats ?? const <ChatSummary>[]) {
      if (chat.id == chatId) return chat.title;
    }
    return null;
  }

  /// What the pane says before there is anything to say.
  ///
  /// An empty transcript and a transcript still loading look identical when
  /// both render nothing, and the first is the state a new install is in --
  /// so the app's opening screen was a blank rectangle.
  Component _emptyState() => div(
    classes:
        'mx-auto flex max-w-3xl flex-col items-center gap-2 py-24 text-center',
    [
      p(classes: 'text-lg font-medium text-foreground', [
        Component.text(t.desktop.desktopPickAConversation),
      ]),
      p(classes: 'text-sm text-muted-foreground', [
        Component.text(t.desktop.desktopPickAConversationHint),
      ]),
    ],
  );

  Component _bubble(
    String role,
    String content, {
    bool streaming = false,
    String? failure,
  }) {
    final isUser = role == 'user';
    final failed = failure != null;
    return article(
      classes:
          'rounded px-4 py-3 text-sm '
          '${isUser ? 'ml-auto max-w-[80%] bg-primary text-primary-foreground whitespace-pre-wrap' : 'mr-auto max-w-[90%] bg-card text-card-foreground'} '
          '${failed ? 'border border-destructive' : ''}',
      [
        // The user's own text is rendered verbatim: they typed it, so
        // markdown they did not mean should not be interpreted, and a stray
        // asterisk should stay an asterisk.
        if (isUser)
          Component.text(content)
        else if (content.isNotEmpty)
          MarkdownView(content),
        if (failure case final message?)
          p(
            classes:
                '${content.isEmpty ? '' : 'mt-2 '}text-sm text-destructive',
            attributes: const <String, String>{'role': 'alert'},
            [Component.text(message)],
          ),
        if (streaming)
          span(
            classes: 'ml-1 animate-pulse',
            attributes: const <String, String>{'aria-hidden': 'true'},
            [Component.text('▌')],
          ),
      ],
    );
  }
}

class _Composer extends StatefulComponent {
  const _Composer();

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  String _text = '';
  bool _busy = false;
  String? _error;

  @override
  Component build(BuildContext context) {
    final live = context.watch(liveTurnProvider).value;
    final streaming = live != null && !live.failed;

    final models = context.watch(modelListProvider).value;

    return div(classes: 'border-t border-border bg-background p-4', [
      if (models != null && models.models.isNotEmpty)
        div(classes: 'mx-auto mb-2 flex max-w-3xl items-center gap-2', [
          label(
            [Component.text(t.app.chooseModel)],
            htmlFor: 'model',
            classes: 'text-xs text-muted-foreground',
          ),
          select(
            [
              for (final model in models.models)
                option(
                  value: model.id,
                  selected: models.selectedId == model.id,
                  [Component.text(model.name)],
                ),
            ],
            id: 'model',
            classes:
                'rounded border border-border bg-background '
                'px-2 py-1 text-xs text-foreground',
            disabled: _busy,
            onChange: (values) {
              if (values.isEmpty) return;
              unawaited(
                context.read(chatActionsProvider).selectModel(values.first),
              );
            },
          ),
        ]),
      form(
        [
          // `min-w-0` on the field: a flex item's automatic minimum is its
          // content's, and a textarea's is its `cols` -- without this the
          // field refuses to give ground and the row overflows instead.
          div(classes: 'mx-auto flex max-w-3xl items-end gap-2', [
            div(classes: 'min-w-0 flex-1', [
              textAreaField(
                id: 'composer',
                labelText: t.app.sendMessage,
                placeholder: t.app.messageHintText,
                hideLabel: true,
                value: _text,
                rows: 2,
                disabled: _busy,
                onInput: (value) => setState(() => _text = value),
              ),
            ]),
            if (streaming)
              button(
                [Component.text(t.app.stopGenerating)],
                classes:
                    'shrink-0 rounded border border-border px-4 py-2 '
                    'text-sm text-foreground',
                type: ButtonType.button,
                onClick: () => unawaited(
                  context.read(chatActionsProvider).stop(live.chatId),
                ),
              )
            else
              submitButton(
                labelText: t.app.send,
                busyLabel: t.desktop.desktopSending,
                busy: _busy,
                enabled: _text.trim().isNotEmpty,
                fullWidth: false,
              ),
          ]),
          if (_error case final message?)
            div(classes: 'mx-auto mt-2 max-w-3xl', [formError(message)]),
        ],
        events: <String, EventCallback>{
          'submit': (event) {
            event.preventDefault();
            unawaited(_send(context));
          },
        },
      ),
    ]);
  }

  Future<void> _send(BuildContext context) async {
    final text = _text.trim();
    if (text.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.read(chatActionsProvider).send(text: text);
      if (!mounted) return;
      // Cleared only on success: a failed send should leave the text where
      // the user can retry it rather than making them type it again.
      setState(() {
        _busy = false;
        _text = '';
      });
    } on RpcError catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = switch (error.code) {
          ConduitErrorCodes.unauthenticated => t.app.authSessionExpired,
          ConduitErrorCodes.unsupported => t.app.noModelsAvailable,
          ConduitErrorCodes.conflict => t.app.stopGenerating,
          _ => t.app.couldNotConnectGeneric,
        };
      });
    }
  }
}
