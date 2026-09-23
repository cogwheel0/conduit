import 'dart:async';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:jaspr_router/jaspr_router.dart';

import '../l10n/strings.g.dart';
import '../palette.dart';
import '../rpc/chat_providers.dart';
import '../rpc/rpc_providers.dart';
import '../rpc/ui_request_providers.dart';
import '../shortcuts.dart';
import 'command_palette.dart';
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
  bool _showPalette = false;
  String? _notice;
  Timer? _noticeTimer;
  ProviderSubscription<String?>? _lastReply;

  @override
  void initState() {
    super.initState();
    // A real subscription, not a `read` and not a `watch`.
    //
    // `read` is not enough: Riverpod 3 disposes a provider with no
    // listeners, so every read rebuilt it from `loading` and the copy
    // shortcuts answered null. `watch` is not right either: it rebuilds
    // this component whenever `liveTurnProvider` is torn down and remade,
    // which happens on every chat switch, and that churn left this
    // element permanently dirty -- `setState` scheduled a build that never
    // ran, and the shortcut overlay simply never opened. A container-level
    // listener keeps the value resolved and leaves rebuilding alone.
    _lastReply = ProviderScope.containerOf(
      context,
      listen: false,
    ).listen(lastReplyProvider, (_, _) {});
    context.read(shortcutBindingProvider).install(_dispatch);
  }

  @override
  void dispose() {
    _noticeTimer?.cancel();
    _lastReply?.close();
    context.read(shortcutBindingProvider).dispose();
    super.dispose();
  }

  @override
  Component build(BuildContext context) {
    final isMac = context.read(shellBridgeProvider).platform == 'darwin';
    return div(classes: 'contents', <Component>[
      if (_showPalette)
        CommandPalette(
          isMac: isMac,
          onClose: () => setState(() => _showPalette = false),
          onCommand: _run,
          onChat: _openChat,
        ),
      if (_showShortcuts)
        ShortcutsOverlay(
          isMac: isMac,
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
        _run(PaletteCommand.newChat);
      case ShortcutAction.openPalette:
        setState(() {
          _showPalette = !_showPalette;
          _showShortcuts = false;
        });
      case ShortcutAction.focusComposer:
        context.read(windowCommandsProvider).focus('composer');
      case ShortcutAction.focusModelPicker:
        context.read(windowCommandsProvider).focus('model');
      case ShortcutAction.stopGenerating:
        // Esc means "back out of whatever is in front of me" first. Only
        // once there is no overlay does it reach the running turn.
        if (_showPalette || _showShortcuts) {
          setState(() {
            _showPalette = false;
            _showShortcuts = false;
          });
          return;
        }
        final live = context.read(liveTurnProvider).value;
        if (live == null || live.settled) return;
        unawaited(context.read(chatActionsProvider).stop(live.chatId));
      case ShortcutAction.openSettings:
        Router.of(context).push('/settings/appearance');
      case ShortcutAction.showShortcuts:
        setState(() {
          _showShortcuts = !_showShortcuts;
          _showPalette = false;
        });
      case ShortcutAction.copyLastResponse:
        unawaited(_copy(_lastReply?.read()));
      case ShortcutAction.allowRequest || ShortcutAction.denyRequest:
        final waiting = context.read(uiRequestsProvider);
        if (waiting.isEmpty) return;
        // A prompt's answer is the text in its card. Allowing it from the
        // keyboard would submit nothing, so only a yes-or-no request takes
        // the chord. Denying is always safe.
        if (action == ShortcutAction.allowRequest &&
            waiting.first.kind == UiRequestKind.inputPrompt) {
          return;
        }
        unawaited(
          context
              .read(uiRequestsProvider.notifier)
              .answer(
                waiting.first,
                allow: action == ShortcutAction.allowRequest,
              ),
        );
      case ShortcutAction.copyLastCodeBlock:
        final reply = _lastReply?.read();
        unawaited(_copy(reply == null ? null : lastCodeBlock(reply)));
    }
  }

  /// A palette command, and the shortcuts that do the same thing.
  void _run(PaletteCommand command) {
    switch (command) {
      case PaletteCommand.newChat || PaletteCommand.newTemporaryChat:
        _goHome();
        context.read(chatActionsProvider).select(null);
        // Only ever switched on here. Plain New Chat leaves the toggle as
        // the user set it, as the sidebar's button does.
        if (command == PaletteCommand.newTemporaryChat) {
          context.read(temporaryChatProvider.notifier).set(value: true);
        }
        context.read(windowCommandsProvider).focus('composer');
      case PaletteCommand.chooseModel:
        _goHome();
        context.read(windowCommandsProvider).focus('model');
      case PaletteCommand.openSettings:
        Router.of(context).push('/settings/appearance');
      case PaletteCommand.showShortcuts:
        setState(() => _showShortcuts = true);
    }
  }

  void _openChat(String chatId) {
    _goHome();
    context.read(chatActionsProvider).select(chatId);
    context.read(windowCommandsProvider).focus('composer');
  }

  /// The chat page, from wherever the palette was opened.
  void _goHome() {
    if (RouteState.of(context).location != '/') {
      Router.of(context).push('/');
    }
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
