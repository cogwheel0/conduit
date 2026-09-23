import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';

import '../l10n/strings.g.dart';
import '../rpc/chat_providers.dart';

/// A folder, opened: everything in it, sortable (WP-3.1).
///
/// In the main pane rather than the sidebar, which only ever holds the
/// page of conversations it has loaded; this holds all of them.
class FolderPage extends StatefulComponent {
  const FolderPage({super.key});

  @override
  State<FolderPage> createState() => _FolderPageState();
}

enum _Sort { updated, title }

class _FolderPageState extends State<FolderPage> {
  _Sort _sort = _Sort.updated;

  @override
  Component build(BuildContext context) {
    final contents = context.watch(folderContentsProvider).value;
    final folders =
        context.watch(chatListProvider).value?.folders ??
        const <FolderSummary>[];
    final chats = <ChatSummary>[...?contents?.chats];
    if (_sort == _Sort.title) {
      chats.sort(
        (x, y) => x.title.toLowerCase().compareTo(y.title.toLowerCase()),
      );
    }
    final subfolders = <FolderSummary>[
      for (final folder in folders)
        if (contents != null && folder.parentId == contents.folder.id) folder,
    ];

    return section(classes: 'flex min-w-0 flex-1 flex-col', [
      header(
        classes:
            'flex h-12 shrink-0 items-center gap-3 border-b border-border '
            'px-6 text-ui-base font-medium',
        [
          span(classes: 'truncate', [
            Component.text(contents?.folder.name ?? t.app.loadingShort),
          ]),
          if (contents != null)
            span(classes: 'text-ui-sm font-normal text-foreground-subtle', [
              Component.text('${contents.chats.length}'),
            ]),
          div(classes: 'ml-auto flex items-center gap-2', [
            label(
              [Component.text(t.desktop.desktopSortBy)],
              htmlFor: 'folder-sort',
              classes: 'text-ui-sm font-normal text-foreground-subtle',
            ),
            select(
              [
                option(value: 'updated', selected: _sort == _Sort.updated, [
                  Component.text(t.desktop.desktopSortUpdated),
                ]),
                option(value: 'title', selected: _sort == _Sort.title, [
                  Component.text(t.desktop.desktopSortTitle),
                ]),
              ],
              id: 'folder-sort',
              classes:
                  'rounded-lg border border-border bg-panel px-2 py-1 '
                  'text-ui-sm font-normal',
              onChange: (values) => setState(
                () => _sort = values.firstOrNull == 'title'
                    ? _Sort.title
                    : _Sort.updated,
              ),
            ),
          ]),
        ],
      ),
      div(classes: 'min-h-0 flex-1 overflow-y-auto px-6 py-4', [
        div(classes: 'mx-auto max-w-3xl space-y-1', [
          for (final folder in subfolders)
            button(
              [Component.text('▸ ${folder.name}')],
              classes:
                  'block w-full rounded-lg px-3 py-2 text-left text-ui-base '
                  'hover:bg-hover',
              type: ButtonType.button,
              onClick: () =>
                  context.read(openFolderProvider.notifier).open(folder.id),
            ),
          if (contents != null && chats.isEmpty && subfolders.isEmpty)
            p(classes: 'py-8 text-ui-base text-foreground-subtle', [
              Component.text(t.desktop.desktopFolderEmpty),
            ]),
          for (final chat in chats)
            button(
              [
                span(classes: 'min-w-0 flex-1 truncate', [
                  Component.text(chat.title),
                ]),
                span(classes: 'shrink-0 text-ui-sm text-foreground-subtle', [
                  Component.text(_date(chat.updatedAtMs)),
                ]),
              ],
              classes:
                  'flex w-full items-center gap-3 rounded-lg px-3 py-2 '
                  'text-left text-ui-base hover:bg-hover',
              type: ButtonType.button,
              onClick: () => context.read(chatActionsProvider).select(chat.id),
            ),
        ]),
      ]),
    ]);
  }

  /// The day, year first: unambiguous whatever the locale's order, and it
  /// sorts the way it reads.
  static String _date(int ms) {
    final date = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${date.year}-${two(date.month)}-${two(date.day)}';
  }
}
