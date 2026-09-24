import 'dart:async';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:universal_web/web.dart' as web;

import '../desktop_shell.dart';
import '../keyboard.dart';
import '../l10n/strings.g.dart';
import '../rpc/chat_providers.dart';
import '../rpc/rpc_providers.dart';
import '../rpc/session_providers.dart';
import '../widgets/form_field.dart';
import '../widgets/markdown_view.dart';
import '../widgets/ui.dart';

/// The quick-ask panel: one question from anywhere, answered in
/// place, and continued in the main window when it turns into more.
///
/// Its own window with its own connection to the daemon, so it asks in a
/// new conversation of its own without touching what the main window has
/// open. Escape, or looking elsewhere, puts it away.
class QuickAskPage extends StatefulComponent {
  const QuickAskPage({super.key});

  @override
  State<QuickAskPage> createState() => _QuickAskPageState();
}

class _QuickAskPageState extends State<QuickAskPage> {
  String _text = '';
  bool _busy = false;
  String? _error;

  /// The conversation this panel started, once it has.
  String? _chatId;
  String? _asked;

  @override
  void initState() {
    super.initState();
    // The panel exists to be typed into.
    Future<void>.microtask(() {
      if (mounted) context.read(windowCommandsProvider).focus('quick-ask');
    });
  }

  Future<void> _ask() async {
    final text = _text.trim();
    if (text.isEmpty || _busy) return;
    final chats = context.read(chatActionsProvider);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // A fresh conversation for each question asked from a blank panel;
      // a follow-up stays in the one already open here.
      if (_chatId == null) chats.select(null);
      final accepted = await chats.send(text: text);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _chatId = accepted.chatId;
        _asked = text;
        _text = '';
      });
      context.read(windowCommandsProvider).setValue('quick-ask', '');
    } on RpcError {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = t.app.couldNotConnectGeneric;
      });
    }
  }

  void _continue() {
    final chatId = _chatId;
    if (chatId == null) return;
    context.read(desktopShellProvider).openInMain(OpenRequest.chat(chatId));
    _reset();
  }

  void _reset() {
    context.read(chatActionsProvider).select(null);
    setState(() {
      _chatId = null;
      _asked = null;
      _text = '';
      _error = null;
    });
  }

  EventCallback get _keys {
    final send = sendOnEnter(() => unawaited(_ask()));
    return (web.Event event) {
      final key = event as web.KeyboardEvent;
      if (key.key == 'Escape' && !key.isComposing) {
        event.preventDefault();
        context.read(desktopShellProvider).hideWindow();
        return;
      }
      send(event);
    };
  }

  @override
  Component build(BuildContext context) {
    final auth = context.watch(authStatusProvider).value;
    final directOnly = context.watch(directOnlyProvider).value ?? false;
    final ready = (auth?.isAuthenticated ?? false) || directOnly;
    final live = context.watch(liveTurnProvider).value;
    final answer = live != null && live.chatId == _chatId ? live : null;
    return div(
      // A floating panel: the composer's shell, and the answer under it.
      // Square outside, as its frameless window is.
      classes:
          'flex h-screen flex-col gap-2 overflow-hidden border '
          'border-border bg-window p-2 text-foreground',
      attributes: <String, String>{
        'role': 'dialog',
        'aria-label': t.desktop.desktopQuickAskTitle,
      },
      [
        if (!ready)
          p(classes: 'text-ui-base text-foreground-subtle', [
            Component.text(t.desktop.desktopQuickAskNeedsSetup),
          ])
        else ...[
          div(
            classes:
                'shrink-0 rounded-xl border border-border bg-panel shadow-sm '
                'transition-colors focus-within:border-ring',
            [
              textAreaField(
                id: 'quick-ask',
                labelText: t.desktop.desktopQuickAskTitle,
                hideLabel: true,
                placeholder: t.desktop.desktopQuickAskPlaceholder,
                value: _text,
                rows: 2,
                bare: true,
                onInput: (value) => setState(() => _text = value),
                onKeyDown: _keys,
              ),
              div(classes: 'flex items-center justify-end gap-1 px-2 pb-2', [
                if (_chatId != null) ...[
                  button(
                    [Component.text(t.app.newChat)],
                    classes: buttonClasses(
                      tone: ButtonTone.ghost,
                      size: ControlSize.sm,
                    ),
                    type: ButtonType.button,
                    onClick: _reset,
                  ),
                  button(
                    [Component.text(t.desktop.desktopQuickAskContinue)],
                    id: 'quick-ask-continue',
                    classes: buttonClasses(size: ControlSize.sm),
                    type: ButtonType.button,
                    onClick: _continue,
                  ),
                ],
                button(
                  [
                    icon(
                      _busy ? LucideIcon.loaderCircle : LucideIcon.arrowUp,
                      classes: 'size-4${_busy ? ' animate-spin' : ''}',
                    ),
                    span(classes: 'sr-only', [
                      Component.text(
                        _busy ? t.desktop.desktopSending : t.app.send,
                      ),
                    ]),
                  ],
                  id: 'quick-ask-send',
                  classes:
                      'ml-1 inline-flex size-8 shrink-0 items-center '
                      'justify-center rounded-full bg-primary '
                      'text-primary-foreground transition-colors '
                      'hover:bg-primary/85 disabled:bg-foreground-subtlest '
                      'disabled:text-panel',
                  type: ButtonType.button,
                  disabled: _busy || _text.trim().isEmpty,
                  onClick: () => unawaited(_ask()),
                ),
              ]),
            ],
          ),
          if (_error case final message?) formError(message),
          if (_asked case final question?)
            div(
              classes:
                  'min-h-0 flex-1 space-y-2 overflow-y-auto rounded-xl border '
                  'border-border bg-panel p-3 text-ui-base',
              attributes: const <String, String>{
                'role': 'log',
                'aria-live': 'polite',
              },
              [
                p(classes: 'text-ui-sm text-foreground-subtle', [
                  Component.text(question),
                ]),
                if (answer != null && answer.text.isNotEmpty)
                  MarkdownView(answer.text)
                else
                  p(classes: 'animate-pulse text-foreground-subtle', [
                    Component.text('▌'),
                  ]),
              ],
            ),
        ],
      ],
    );
  }
}
