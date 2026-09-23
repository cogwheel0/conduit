import 'dart:async';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';

import '../l10n/strings.g.dart';
import '../rpc/chat_providers.dart';

/// Above the sidebar list: "Select", or what to do with what is selected
/// (WP-3.8).
class SelectionBar extends StatefulComponent {
  const SelectionBar({
    required this.folders,
    this.archivedIds = const <String>{},
    super.key,
  });

  final List<FolderSummary> folders;

  /// Which conversations are archived, so a selection of them can be taken
  /// back out.
  final Set<String> archivedIds;

  @override
  State<SelectionBar> createState() => _SelectionBarState();
}

class _SelectionBarState extends State<SelectionBar> {
  bool _confirmingDelete = false;
  bool _busy = false;
  String? _notice;

  @override
  Component build(BuildContext context) {
    final selection = context.watch(chatSelectionProvider);
    if (selection == null) {
      return div(classes: 'flex justify-end px-3 pb-1', [
        if (_notice case final notice?)
          p(
            classes: 'mr-auto text-ui-sm text-destructive',
            attributes: const <String, String>{'role': 'alert'},
            [Component.text(notice)],
          ),
        button(
          [Component.text(t.desktop.desktopSelect)],
          classes:
              'rounded px-2 py-0.5 text-ui-sm text-muted-foreground '
              'hover:bg-accent',
          type: ButtonType.button,
          onClick: () {
            setState(() => _notice = null);
            context.read(chatSelectionProvider.notifier).start();
          },
        ),
      ]);
    }

    final count = selection.length;
    final none = count == 0 || _busy;
    const action =
        'rounded px-2 py-0.5 text-ui-sm hover:bg-accent disabled:opacity-40';
    return div(
      classes: 'mx-2 mb-2 space-y-2 rounded border border-border p-2',
      attributes: <String, String>{
        'role': 'toolbar',
        'aria-label': t.desktop.desktopSelectedCount(count: count),
      },
      [
        div(classes: 'flex items-center gap-1', [
          span(
            classes: 'mr-auto text-ui-sm font-medium',
            attributes: const <String, String>{'aria-live': 'polite'},
            [Component.text(t.desktop.desktopSelectedCount(count: count))],
          ),
          button(
            [Component.text(t.desktop.desktopDone)],
            classes: action,
            type: ButtonType.button,
            onClick: _end,
          ),
        ]),
        if (_confirmingDelete)
          div(
            classes: 'space-y-2 text-ui-sm',
            attributes: const <String, String>{'role': 'alertdialog'},
            [
              p(classes: 'text-destructive', [
                Component.text(
                  t.desktop.desktopBulkDeleteConfirm(count: count),
                ),
              ]),
              div(classes: 'flex gap-2', [
                button(
                  [Component.text(t.app.delete)],
                  classes:
                      'rounded bg-destructive px-2 py-1 '
                      'text-destructive-foreground',
                  type: ButtonType.button,
                  onClick: () => unawaited(_run(BulkChatAction.delete)),
                ),
                button(
                  [Component.text(t.app.cancel)],
                  classes: 'rounded px-2 py-1',
                  type: ButtonType.button,
                  onClick: () => setState(() => _confirmingDelete = false),
                ),
              ]),
            ],
          )
        else
          div(classes: 'flex flex-wrap items-center gap-1', [
            if (selection.any(component.archivedIds.contains))
              button(
                [Component.text(t.app.unarchive)],
                classes: action,
                type: ButtonType.button,
                disabled: none,
                onClick: () => unawaited(_run(BulkChatAction.unarchive)),
              )
            else
              button(
                [Component.text(t.app.archive)],
                classes: action,
                type: ButtonType.button,
                disabled: none,
                onClick: () => unawaited(_run(BulkChatAction.archive)),
              ),
            if (component.folders.isNotEmpty)
              select(
                [
                  option(value: '', selected: true, [
                    Component.text(t.desktop.desktopMoveSelected),
                  ]),
                  option(value: '\u0000', [
                    Component.text(t.desktop.desktopNoFolder),
                  ]),
                  for (final folder in component.folders)
                    option(value: folder.id, [Component.text(folder.name)]),
                ],
                classes:
                    'rounded border border-border bg-background px-1 py-0.5 '
                    'text-ui-sm disabled:opacity-40',
                disabled: none,
                attributes: <String, String>{
                  'aria-label': t.desktop.desktopMoveSelected,
                },
                onChange: (values) {
                  final value = values.firstOrNull;
                  if (value == null || value.isEmpty) return;
                  unawaited(
                    _run(
                      BulkChatAction.move,
                      folderId: value == '\u0000' ? null : value,
                    ),
                  );
                },
              ),
            button(
              [Component.text(t.app.delete)],
              classes: '$action text-destructive',
              type: ButtonType.button,
              disabled: none,
              onClick: () => setState(() => _confirmingDelete = true),
            ),
          ]),
      ],
    );
  }

  Future<void> _run(BulkChatAction action, {String? folderId}) async {
    final selection = context.read(chatSelectionProvider);
    if (selection == null || selection.isEmpty) return;
    setState(() => _busy = true);
    List<String> failed;
    try {
      failed = await context
          .read(chatActionsProvider)
          .bulk(selection, action, folderId: folderId);
    } on Object {
      failed = selection.toList();
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _confirmingDelete = false;
      _notice = failed.isEmpty
          ? null
          : t.desktop.desktopBulkFailed(count: failed.length);
    });
    // Done unless something is left to retry, which stays selected.
    if (failed.isEmpty) {
      _end();
    } else {
      final notifier = context.read(chatSelectionProvider.notifier)..start();
      for (final id in failed) {
        notifier.toggle(id);
      }
    }
  }

  void _end() {
    setState(() => _confirmingDelete = false);
    context.read(chatSelectionProvider.notifier).end();
  }
}
