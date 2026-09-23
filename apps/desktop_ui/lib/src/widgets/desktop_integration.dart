import 'package:conduit_markdown/conduit_markdown.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';

import '../desktop_shell.dart';
import '../l10n/strings.g.dart';
import '../pages/workspace/workspace_common.dart' show workspaceGo;
import '../rpc/channels_providers.dart';
import '../rpc/chat_providers.dart';
import '../rpc/rpc_providers.dart';
import '../shortcuts.dart';

/// The shell's settings, as the main process keeps them (M9).
final shellSettingsProvider = FutureProvider<ShellSettings>(
  (ref) => ref.read(desktopShellProvider).settings(),
);

/// The shortcut table in force: the defaults with the user's own keys.
final shortcutTableProvider = Provider<List<Shortcut>>(
  (ref) => applyShortcutOverrides(
    ref.watch(shellSettingsProvider).value?.shortcuts ??
        const <String, String>{},
  ),
);

/// Text for the composer to take up: a `conduit://new?q=` link, or the
/// quick-ask panel's question continued here.
final composerPrefillProvider = NotifierProvider<ComposerPrefill, String?>(
  ComposerPrefill.new,
);

class ComposerPrefill extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? text) => state = text;

  /// The text, once: whoever takes it clears it.
  String? take() {
    final text = state;
    if (text != null) state = null;
    return text;
  }
}

/// The main window's side of the desktop (M9): opening what a link, a
/// notification or the tray asks for, and notifying when an answer or a
/// channel message arrives out of sight.
class DesktopIntegration extends StatefulComponent {
  const DesktopIntegration({super.key});

  @override
  State<DesktopIntegration> createState() => _DesktopIntegrationState();
}

class _DesktopIntegrationState extends State<DesktopIntegration> {
  final List<ProviderSubscription<Object?>> _subscriptions =
      <ProviderSubscription<Object?>>[];
  Map<String, int>? _unread;

  @override
  void initState() {
    super.initState();
    final shell = context.read(desktopShellProvider);
    if (!shell.available) return;
    shell.onOpen(_open);
    final container = ProviderScope.containerOf(context, listen: false);
    _subscriptions
      ..add(
        container.listen<AsyncValue<LiveTurn?>>(
          liveTurnProvider,
          (previous, next) => _onTurn(previous?.value, next.value),
        ),
      )
      ..add(
        container.listen<AsyncValue<ChannelList>>(
          channelListProvider,
          (_, next) => _onChannels(next.value),
        ),
      )
      // Held so a notification can name its conversation.
      ..add(container.listen(chatListProvider, (_, _) {}));
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      subscription.close();
    }
    super.dispose();
  }

  void _open(OpenRequest request) {
    if (!mounted) return;
    final chats = context.read(chatActionsProvider);
    switch (request.kind) {
      case 'chat':
        chats.select(request.id);
        workspaceGo(context, '/');
      case 'newChat':
        chats.select(null);
        if (request.text case final text?) {
          context.read(composerPrefillProvider.notifier).set(text);
        }
        workspaceGo(context, '/');
      case 'channel':
        workspaceGo(context, '/channels/${Uri.encodeComponent(request.id!)}');
      case 'note':
        workspaceGo(context, '/notes/${Uri.encodeComponent(request.id!)}');
      case 'settings':
        workspaceGo(context, '/settings/${request.tab ?? 'appearance'}');
    }
  }

  Future<bool> _wants(bool Function(ShellSettings settings) pick) async {
    final shell = context.read(desktopShellProvider);
    if (shell.focused) return false;
    try {
      return pick(await context.read(shellSettingsProvider.future));
    } on Object {
      return false;
    }
  }

  void _onTurn(LiveTurn? previous, LiveTurn? next) {
    if (next == null || !next.settled || next.failedCode != null) return;
    // Once per answer: the settled turn is kept, and repeats.
    if (previous != null &&
        previous.settled &&
        previous.messageId == next.messageId) {
      return;
    }
    final text = ConduitMarkdownPreprocessor.cleanText(
      stripDetailsForSpeech(next.text),
    ).replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.isEmpty) return;
    final shell = context.read(desktopShellProvider);
    final title = _chatTitle(next.chatId);
    () async {
      if (!await _wants((settings) => settings.notifyAnswers)) return;
      await shell.notify(
        title: title,
        body: text.length > 160 ? '${text.substring(0, 157)}…' : text,
        open: OpenRequest.chat(next.chatId),
      );
    }();
  }

  String _chatTitle(String chatId) {
    final chats = context.read(chatListProvider).value?.chats;
    for (final chat in chats ?? const <ChatSummary>[]) {
      if (chat.id == chatId && chat.title.trim().isNotEmpty) return chat.title;
    }
    return 'Conduit';
  }

  void _onChannels(ChannelList? list) {
    if (list == null) return;
    final before = _unread;
    _unread = <String, int>{
      for (final channel in list.channels) channel.id: channel.unread,
    };
    // The first list is what was already there, not news.
    if (before == null) return;
    final open = context.read(openChannelIdProvider);
    final shell = context.read(desktopShellProvider);
    for (final channel in list.channels) {
      if (channel.unread <= (before[channel.id] ?? 0)) continue;
      if (channel.id == open && shell.focused) continue;
      () async {
        if (!await _wants((settings) => settings.notifyChannels)) return;
        await shell.notify(
          title: '#${channel.name}',
          body: t.app.notificationDefaultTitle,
          open: OpenRequest('channel', id: channel.id),
        );
      }();
    }
  }

  @override
  Component build(BuildContext context) => const Component.fragment([]);
}
