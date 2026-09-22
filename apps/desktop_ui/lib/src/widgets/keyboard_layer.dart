import 'dart:async';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:jaspr_router/jaspr_router.dart';

import '../l10n/strings.g.dart';
import '../rpc/chat_providers.dart';
import '../rpc/rpc_providers.dart';
import '../shortcuts.dart';
import 'shortcuts_overlay.dart';

/// Binds the shortcut table to the running window (WP-3.7).
///
/// Lives in the shell rather than on the chat page, because a shortcut that
/// only works on one route is a shortcut the user has to think about. Focus
/// targets that are not on screen are simply missing, and focusing a missing
/// element does nothing -- so `Cmd+K` on the settings route is a no-op
/// rather than an error.
class KeyboardLayer extends StatefulComponent {
  const KeyboardLayer({super.key});

  @override
  State<KeyboardLayer> createState() => _KeyboardLayerState();
}

class _KeyboardLayerState extends State<KeyboardLayer> {
  bool _showShortcuts = false;
  String? _notice;
  Timer? _noticeTimer;

  @override
  void initState() {
    super.initState();
    context.read(shortcutBindingProvider).install(_dispatch);
  }

  @override
  void dispose() {
    _noticeTimer?.cancel();
    context.read(shortcutBindingProvider).dispose();
    super.dispose();
  }

  @override
  Component build(BuildContext context) {
    // Watched, not read on demand. A `read` of a provider nothing else is
    // watching starts it cold and answers `loading`, so the first
    // Cmd+Shift+C pressed on a route that does not show the transcript --
    // settings, say -- copied nothing and the second one worked. Declaring
    // the dependency is what keeps the answer available to a shortcut that
    // can be pressed from anywhere.
    context.watch(chatDetailProvider);
    context.watch(liveTurnProvider);

    return Component.fragment(<Component>[
      if (_showShortcuts)
        ShortcutsOverlay(
          isMac: context.read(shellBridgeProvider).platform == 'darwin',
          onClose: () => setState(() => _showShortcuts = false),
        ),
      if (_notice case final message?)
        div(
          classes:
              'fixed bottom-4 left-1/2 z-50 -translate-x-1/2 rounded border '
              'border-border bg-popover px-3 py-1.5 text-xs '
              'text-popover-foreground shadow',
          // `status` not `alert`: "Copied" is a confirmation, and an alert
          // interrupts whatever a screen reader was in the middle of
          // saying.
          attributes: const <String, String>{'role': 'status'},
          [Component.text(message)],
        ),
    ]);
  }

  void _dispatch(ShortcutAction action) {
    switch (action) {
      case ShortcutAction.newChat:
        if (RouteState.of(context).location != '/') {
          Router.of(context).push('/');
        }
        context.read(chatActionsProvider).select(null);
        context.read(windowCommandsProvider).focus('composer');
      case ShortcutAction.focusSearch:
        context.read(windowCommandsProvider).focus('chat-search');
      case ShortcutAction.focusComposer:
        context.read(windowCommandsProvider).focus('composer');
      case ShortcutAction.focusModelPicker:
        context.read(windowCommandsProvider).focus('model');
      case ShortcutAction.stopGenerating:
        // Esc means "back out of whatever is in front of me" first. Only
        // once there is no overlay does it reach the running turn.
        if (_showShortcuts) {
          setState(() => _showShortcuts = false);
          return;
        }
        final live = context.read(liveTurnProvider).value;
        if (live == null || live.settled) return;
        unawaited(context.read(chatActionsProvider).stop(live.chatId));
      case ShortcutAction.openSettings:
        Router.of(context).push('/settings/appearance');
      case ShortcutAction.showShortcuts:
        setState(() => _showShortcuts = !_showShortcuts);
      case ShortcutAction.copyLastResponse:
        unawaited(_copy(_lastReply()));
      case ShortcutAction.copyLastCodeBlock:
        final reply = _lastReply();
        unawaited(_copy(reply == null ? null : lastCodeBlock(reply)));
    }
  }

  /// The most recent assistant text, live turn included.
  ///
  /// The streaming answer counts: it is the one on screen, and waiting for
  /// it to be persisted before it can be copied would make the shortcut
  /// silently copy the previous reply instead.
  String? _lastReply() {
    final selected = context.read(selectedChatIdProvider);
    final live = context.read(liveTurnProvider).value;
    if (live != null && live.chatId == selected && live.text.isNotEmpty) {
      return live.text;
    }
    final messages =
        context.read(chatDetailProvider).value?.messages ??
        const <ChatMessageDto>[];
    for (final message in messages.reversed) {
      if (message.role == 'assistant' && message.content.isNotEmpty) {
        return message.content;
      }
    }
    return null;
  }

  Future<void> _copy(String? text) async {
    if (text == null || text.isEmpty) {
      _show(t.desktop.desktopNothingToCopy);
      return;
    }
    final copied = await context.read(windowCommandsProvider).copy(text);
    if (!mounted) return;
    _show(copied ? t.desktop.desktopCopied : t.app.errorMessage);
  }

  void _show(String message) {
    _noticeTimer?.cancel();
    setState(() => _notice = message);
    _noticeTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _notice = null);
    });
  }
}
