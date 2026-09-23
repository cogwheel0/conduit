import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';

import '../l10n/strings.g.dart';
import '../rpc/chat_providers.dart';
import '../rpc/rpc_providers.dart';
import '../rpc/session_providers.dart';

/// Open WebUI's share modal, with its wording (WP-3.1).
///
/// A share is a snapshot: the server copies the conversation as it stands,
/// and the link shows that copy. So sharing again is "update", and the
/// dialog says so when the conversation has a link already.
class ShareDialog extends StatefulComponent {
  const ShareDialog({
    required this.chatId,
    required this.shared,
    required this.onClose,
    super.key,
  });

  final String chatId;

  /// Whether the conversation has a link from before.
  final bool shared;
  final void Function() onClose;

  @override
  State<ShareDialog> createState() => _ShareDialogState();
}

class _ShareDialogState extends State<ShareDialog> {
  bool _busy = false;
  bool _deleted = false;
  String? _link;
  String? _status;
  bool _failed = false;

  bool get _hasLink => (component.shared && !_deleted) || _link != null;

  @override
  Component build(BuildContext context) => div(
    classes:
        'fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-6',
    events: <String, EventCallback>{'click': (_) => component.onClose()},
    [
      div(
        classes:
            'w-full max-w-md space-y-4 rounded border border-border '
            'bg-popover p-5 text-sm text-popover-foreground shadow-lg',
        attributes: <String, String>{
          'role': 'dialog',
          'aria-modal': 'true',
          'aria-label': t.app.shareChat,
        },
        events: <String, EventCallback>{
          'click': (event) => event.stopPropagation(),
        },
        [
          h2(classes: 'text-base font-semibold', [
            Component.text(t.app.shareChat),
          ]),
          p(classes: 'text-muted-foreground', [
            Component.text(t.app.shareChatDescription),
          ]),
          if (_hasLink && _link == null)
            p(classes: 'text-muted-foreground', [
              Component.text('${t.app.shareChatExisting} '),
              button(
                [Component.text(t.app.shareChatDeleteLink)],
                classes: 'text-destructive underline underline-offset-2',
                type: ButtonType.button,
                disabled: _busy,
                onClick: () => unawaited(_delete(context)),
              ),
              Component.text(' ${t.app.shareChatDeleteAndCreate}'),
            ]),
          // Shown as well as copied: the clipboard can refuse, and a link
          // on screen can still be selected by hand.
          if (_link case final link?)
            input<String>(
              classes:
                  'w-full rounded border border-border bg-muted px-2 py-1.5 '
                  'font-mono text-xs',
              type: InputType.text,
              value: link,
              attributes: <String, String>{
                'readonly': '',
                'aria-label': t.app.copyLink,
              },
            ),
          if (_status case final status?)
            p(
              classes: _failed ? 'text-destructive' : 'text-muted-foreground',
              attributes: <String, String>{
                'role': _failed ? 'alert' : 'status',
              },
              [Component.text(status)],
            ),
          div(classes: 'flex justify-end gap-2', [
            button(
              [Component.text(t.app.close)],
              classes: 'rounded px-3 py-1.5 hover:bg-accent',
              type: ButtonType.button,
              onClick: component.onClose,
            ),
            button(
              [
                Component.text(
                  _hasLink ? t.app.updateAndCopyLink : t.app.copyLink,
                ),
              ],
              classes:
                  'rounded bg-primary px-3 py-1.5 text-primary-foreground '
                  'disabled:opacity-50',
              type: ButtonType.button,
              disabled: _busy,
              onClick: () => unawaited(_share(context)),
            ),
          ]),
        ],
      ),
    ],
  );

  Future<void> _share(BuildContext context) async {
    setState(() => _busy = true);
    try {
      final shareId = await context
          .read(chatActionsProvider)
          .share(component.chatId);
      final base = await _serverUrl(context);
      if (!mounted) return;
      if (shareId == null || base == null) throw StateError('no link');
      final link = '$base/s/$shareId';
      final copied = await context.read(windowCommandsProvider).copy(link);
      if (!mounted) return;
      setState(() {
        _link = link;
        _deleted = false;
        _failed = false;
        _status = copied ? t.app.sharedChatCopied : null;
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _failed = true;
        _status = t.app.chatShareFailed;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(BuildContext context) async {
    setState(() => _busy = true);
    try {
      await context.read(chatActionsProvider).unshare(component.chatId);
      if (!mounted) return;
      setState(() {
        _deleted = true;
        _link = null;
        _failed = false;
        _status = t.app.sharedLinkDeleted;
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _failed = true;
        _status = t.app.deleteSharedLinkFailed;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// The active server's address, which is what a share link lives under.
  static Future<String?> _serverUrl(BuildContext context) async {
    final servers = await context.read(serverListProvider.future);
    for (final server in servers.servers) {
      if (server.id == servers.activeServerId || server.isActive) {
        final url = server.url;
        return url.endsWith('/') ? url.substring(0, url.length - 1) : url;
      }
    }
    return null;
  }
}
