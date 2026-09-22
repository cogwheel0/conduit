import 'dart:async';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';

import '../l10n/strings.g.dart';
import '../rpc/chat_providers.dart';
import '../widgets/form_field.dart';

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

    return nav(
      classes:
          'flex w-72 shrink-0 flex-col border-r border-border bg-background',
      attributes: <String, String>{'aria-label': t.desktop.desktopChatsLabel},
      [
        div(classes: 'p-3', [
          button(
            [Component.text(t.app.newChat)],
            classes:
                'w-full rounded-[--radius] bg-primary px-3 py-2 text-sm '
                'text-primary-foreground',
            type: ButtonType.button,
            onClick: () => context.read(chatActionsProvider).select(null),
          ),
        ]),
        div(classes: 'min-h-0 flex-1 overflow-y-auto px-2 pb-2', [
          chats.when(
            loading: () => _hint(t.app.loadingShort),
            error: (error, _) => _hint('$error'),
            data: (list) => list.chats.isEmpty
                ? _hint(t.desktop.desktopNoChatsYet)
                : ul(classes: 'space-y-0.5', [
                    for (final chat in list.chats)
                      _row(context, chat, selected == chat.id),
                  ]),
          ),
        ]),
      ],
    );
  }

  Component _row(
    BuildContext context,
    ChatSummary chat,
    bool isSelected,
  ) => li([
    button(
      [
        span(classes: 'truncate', [Component.text(chat.title)]),
        if (chat.pinned)
          span(
            classes: 'ml-1 text-xs',
            attributes: const <String, String>{'aria-hidden': 'true'},
            [Component.text('★')],
          ),
      ],
      classes:
          'flex w-full items-center rounded-[--radius] px-2 py-1.5 text-left '
          'text-sm '
          '${isSelected ? 'bg-accent text-accent-foreground' : 'text-muted-foreground hover:bg-accent/50'}',
      type: ButtonType.button,
      // `aria-current` rather than `aria-selected`: these are navigation
      // items, not options in a listbox.
      attributes: isSelected
          ? const <String, String>{'aria-current': 'true'}
          : null,
      onClick: () => context.read(chatActionsProvider).select(chat.id),
    ),
  ]);

  Component _hint(String text) => p(
    classes: 'px-2 py-4 text-sm text-muted-foreground',
    [Component.text(text)],
  );
}

class _Transcript extends StatelessComponent {
  const _Transcript();

  @override
  Component build(BuildContext context) {
    final detail = context.watch(chatDetailProvider);
    final live = context.watch(liveTurnProvider).value;
    final selected = context.watch(selectedChatIdProvider);

    return section(classes: 'flex min-w-0 flex-1 flex-col', [
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
          div(classes: 'mx-auto flex max-w-3xl flex-col gap-4', [
            ...detail.when(
              loading: () => <Component>[],
              error: (error, _) => <Component>[formError('$error')],
              data: (chat) => <Component>[
                for (final message in chat?.messages ?? const [])
                  _bubble(message.role, message.content),
              ],
            ),
            // Only for the chat on screen: a background turn in another
            // conversation must not paint into this one.
            if (live != null && live.chatId == selected)
              _bubble(
                'assistant',
                live.text.isEmpty ? '…' : live.text,
                streaming: !live.failed,
                failed: live.failed,
              ),
          ]),
        ],
      ),
      const _Composer(),
    ]);
  }

  Component _bubble(
    String role,
    String content, {
    bool streaming = false,
    bool failed = false,
  }) {
    final isUser = role == 'user';
    return article(
      classes:
          'rounded-[--radius] px-4 py-3 text-sm whitespace-pre-wrap '
          '${isUser ? 'ml-auto max-w-[80%] bg-primary text-primary-foreground' : 'mr-auto max-w-[90%] bg-card text-card-foreground'} '
          '${failed ? 'border border-destructive' : ''}',
      [
        Component.text(content),
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

    return div(classes: 'border-t border-border bg-background p-4', [
      form(
        [
          div(classes: 'mx-auto flex max-w-3xl items-end gap-2', [
            div(classes: 'flex-1', [
              textAreaField(
                id: 'composer',
                labelText: t.app.sendMessage,
                placeholder: t.app.messageHintText,
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
                    'rounded-[--radius] border border-border px-4 py-2 '
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
