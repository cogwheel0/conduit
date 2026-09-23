import 'dart:async';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:jaspr_router/jaspr_router.dart';

import '../attachments.dart';
import '../keyboard.dart';
import '../palette.dart';
import '../prompt_trigger.dart';
import '../l10n/strings.g.dart';
import '../rpc/channels_providers.dart' show channelListProvider;
import '../rpc/chat_providers.dart';
import '../rpc/rpc_providers.dart';
import '../rpc/session_providers.dart';
import '../rpc/workspace_providers.dart';
import '../rpc/terminal_providers.dart';
import '../sidebar_model.dart';
import '../widgets/form_field.dart';
import '../widgets/chat_tags.dart';
import '../widgets/context_menu.dart';
import '../widgets/controls_pane.dart';
import '../widgets/folder_page.dart';
import '../widgets/markdown_view.dart';
import '../widgets/mcp_content_sheet.dart';
import '../widgets/message_files.dart';
import '../widgets/prompt_menu.dart';
import '../widgets/selection_bar.dart';
import '../widgets/share_dialog.dart';
import '../widgets/sources_list.dart';
import '../widgets/usage_details.dart';
import 'terminal_page.dart' show terminalOffered;

/// The chat vertical: sidebar, transcript, composer (M3).
class ChatPage extends StatelessComponent {
  const ChatPage({super.key});

  @override
  Component build(BuildContext context) {
    final selected = context.watch(selectedChatIdProvider);
    final temporaryIds = context.watch(temporaryChatIdsProvider);
    final showControls =
        context.watch(controlsOpenProvider) &&
        selected != null &&
        !temporaryIds.contains(selected) &&
        !isLocalOnlyChatId(selected);
    final detail = showControls
        ? context.watch(chatDetailProvider).value
        : null;
    final lightbox = context.watch(lightboxProvider);
    final folderOpen = context.watch(openFolderProvider) != null;
    return div(classes: 'flex h-screen min-h-0', [
      const _Sidebar(),
      if (folderOpen) const FolderPage() else const _Transcript(),
      if (lightbox != null)
        LightboxOverlay(
          key: ValueKey(lightbox.src),
          src: lightbox.src,
          name: lightbox.name,
        ),
      // Keyed on the conversation, so switching chats reseeds the field
      // instead of carrying one chat's draft into the next.
      if (showControls && detail != null && !folderOpen)
        ControlsPane(
          key: ValueKey('controls-$selected'),
          chatId: selected,
          systemPrompt: detail.systemPrompt,
        ),
    ]);
  }
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
        if (context.watch(serverCapabilitiesProvider).bulkSelection &&
            query.trim().isEmpty)
          SelectionBar(
            folders: chats.value?.folders ?? const <FolderSummary>[],
            archivedIds: <String>{
              for (final chat in chats.value?.chats ?? const <ChatSummary>[])
                if (chat.archived) chat.id,
            },
          ),
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
            if (search.value case final results?)
              div([
                if (results.hits.isEmpty)
                  // Only a settled index can say "nothing". An incomplete
                  // one says what it knows and why that may not be all.
                  if (results.complete)
                    _hint(t.desktop.desktopSearchNoResults)
                  else
                    const Component.fragment([])
                else
                  ul(classes: 'space-y-0.5', [
                    for (final hit in results.hits)
                      _SearchRow(hit: hit, isSelected: selected == hit.chatId),
                  ]),
                if (!results.complete)
                  p(
                    classes: 'px-2 py-3 text-xs text-muted-foreground',
                    attributes: const <String, String>{'role': 'status'},
                    [Component.text(t.desktop.desktopSearchIncomplete)],
                  ),
              ])
            else if (search.hasError)
              _hint('${search.error}')
            else
              _hint(t.app.loadingShort)
          else if (chats.value case final list?)
            list.chats.isEmpty && list.archivedCount == 0
                // "No conversations yet" is only true once a sync has
                // finished. Before that, it told someone with two hundred
                // conversations that they had none, for as long as the
                // first sync took.
                ? _hint(
                    context.watch(syncStateProvider).value?.everCompleted ??
                            true
                        ? t.desktop.desktopNoChatsYet
                        : t.desktop.desktopSyncing,
                  )
                : _Sections(list: list, selected: selected)
          else if (chats.hasError)
            _hint('${chats.error}')
          else
            _hint(t.app.loadingShort),
        ]),
        // Pinned under the list rather than floating over the transcript,
        // which is where it used to sit -- on top of the send button.
        div(classes: 'shrink-0 border-t border-border p-2', [
          const _SyncIndicator(),
          // Notes live in the Open WebUI account, so only with one (M5).
          if (context.watch(authStatusProvider).value?.isAuthenticated ?? false)
            Link(
              to: '/notes',
              classes:
                  'block rounded px-2 py-1.5 text-sm text-muted-foreground '
                  'hover:bg-accent hover:text-accent-foreground',
              child: Component.text(t.app.notes),
            ),
          // Channels too, when the server has them switched on.
          if ((context.watch(authStatusProvider).value?.isAuthenticated ??
                  false) &&
              (context.watch(channelListProvider).value?.enabled ?? false))
            Link(
              to: '/channels',
              classes:
                  'block rounded px-2 py-1.5 text-sm text-muted-foreground '
                  'hover:bg-accent hover:text-accent-foreground',
              child: Component.text(t.app.sidebarChannelsTab),
            ),
          // The terminal, when the account has a terminal server (M7).
          if (terminalOffered(context.watch(terminalServersProvider).value))
            Link(
              to: '/terminal',
              classes:
                  'block rounded px-2 py-1.5 text-sm text-muted-foreground '
                  'hover:bg-accent hover:text-accent-foreground',
              child: Component.text(t.app.terminal),
            ),
          // The workspace, when there is a section this account may manage
          // (M6).
          if (manageableSections(
            context.watch(workspaceAccessProvider).value ??
                const WorkspaceAccess(),
          ).isNotEmpty)
            Link(
              to: '/workspace',
              classes:
                  'block rounded px-2 py-1.5 text-sm text-muted-foreground '
                  'hover:bg-accent hover:text-accent-foreground',
              child: Component.text(t.app.workspaceTitle),
            ),
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

/// The sidebar's list, in the sections Open WebUI draws (WP-3.1).
///
/// The sorting lives in `buildSidebar`, which is pure and tested on its own;
/// this only draws what it decided.
class _Sections extends StatelessComponent {
  const _Sections({required this.list, required this.selected});

  final ChatList list;
  final String? selected;

  @override
  Component build(BuildContext context) {
    final model = buildSidebar(list, now: DateTime.now());
    final expanded = context.watch(expandedFoldersProvider);
    if (expanded == null && list.folders.isNotEmpty) {
      // After this frame: seeding is a state change, and making one while
      // building would modify the tree that is being built.
      Future<void>.microtask(
        () => context.read(expandedFoldersProvider.notifier).seed(list.folders),
      );
    }
    final open = expanded ?? const <String>{};
    final actions = context.read(chatActionsProvider);

    return div(classes: 'space-y-4', [
      if (model.pinned.isNotEmpty)
        _section(t.app.pinned, [for (final chat in model.pinned) _row(chat)]),
      if (model.folders.isNotEmpty)
        _section(t.app.folders, [
          for (final node in model.folders) _folder(context, node, open),
        ]),
      for (final group in model.recent)
        _section(_bucketLabel(group.bucket), [
          for (final chat in group.chats) _row(chat),
        ], dropOut: context),
      if (list.hasMore)
        _footerButton(
          t.app.workspaceLoadMore,
          () => unawaited(actions.loadMore()),
        ),
      if (list.archivedCount > 0) ...<Component>[
        _footerButton(
          '${t.app.archived} (${list.archivedCount})',
          () => unawaited(
            actions.setArchivedVisible(visible: !list.archivedVisible),
          ),
          expanded: list.archivedVisible,
        ),
        if (list.archivedVisible && model.archived.isNotEmpty)
          ul(classes: 'space-y-0.5', [
            for (final chat in model.archived) _row(chat),
          ]),
      ],
    ]);
  }

  Component _row(ChatSummary chat) =>
      _ChatRow(chat: chat, isSelected: selected == chat.id);

  /// A heading and its rows, as a real heading so a screen reader can jump
  /// between sections instead of reading two hundred titles in a row.
  ///
  /// With [dropOut], the section takes a conversation dragged out of a
  /// folder: the recent list is where a conversation in no folder lives.
  Component _section(
    String title,
    List<Component> rows, {
    BuildContext? dropOut,
  }) {
    if (dropOut == null) {
      return section([_heading(title), ul(classes: 'space-y-0.5', rows)]);
    }
    final context = dropOut;
    final dragging = context.watch(draggingChatProvider);
    bool accepts() => context.read(draggingChatProvider)?.chat.folderId != null;
    return section(
      classes: dragging?.over == '' ? 'rounded bg-accent/40' : null,
      events: <String, EventCallback>{
        'dragover': (event) {
          acceptDrop(accepts)(event);
          if (accepts()) context.read(draggingChatProvider.notifier).over('');
        },
        'drop': onDrop(() {
          final chat = context.read(draggingChatProvider)?.chat;
          context.read(draggingChatProvider.notifier).end();
          if (chat == null || chat.folderId == null) return;
          unawaited(context.read(chatActionsProvider).move(chat.id, null));
        }),
      },
      [_heading(title), ul(classes: 'space-y-0.5', rows)],
    );
  }

  Component _heading(String title) => h2(
    classes:
        'px-2 pb-1 text-xs font-medium tracking-wide text-muted-foreground',
    [Component.text(title)],
  );

  /// A folder and, when open, what is in it.
  ///
  /// Its contents are a nested `ul` inside the folder's own `li`, so the
  /// list structure a screen reader announces matches the tree on screen
  /// -- "list, 3 items, level 2" -- rather than one flat list with some
  /// rows pushed right.
  Component _folder(BuildContext context, FolderNode node, Set<String> open) {
    final isOpen = open.contains(node.folder.id);
    final folderId = node.folder.id;
    final target = context.watch(draggingChatProvider)?.over == folderId;
    bool accepts() {
      final chat = context.read(draggingChatProvider)?.chat;
      return chat != null && chat.folderId != folderId;
    }

    return li(
      events: <String, EventCallback>{
        'dragover': (event) {
          acceptDrop(accepts)(event);
          if (accepts()) {
            context.read(draggingChatProvider.notifier).over(folderId);
          }
        },
        'drop': onDrop(() {
          final chat = context.read(draggingChatProvider)?.chat;
          context.read(draggingChatProvider.notifier).end();
          if (chat == null || chat.folderId == folderId) return;
          unawaited(context.read(chatActionsProvider).move(chat.id, folderId));
        }),
      },
      [
        // Two controls: the arrow shows what is inside here, the name opens
        // the folder's page with all of it.
        div(
          classes:
              'flex w-full items-center rounded text-sm text-foreground '
              'hover:bg-accent/50'
              '${target ? ' bg-accent ring-1 ring-primary' : ''}'
              '${context.watch(openFolderProvider) == folderId ? ' bg-accent' : ''}',
          [
            button(
              [
                span(
                  attributes: const <String, String>{'aria-hidden': 'true'},
                  [Component.text(isOpen ? '\u25be' : '\u25b8')],
                ),
              ],
              classes: 'w-6 shrink-0 py-1.5 pl-2 text-left text-xs',
              type: ButtonType.button,
              attributes: <String, String>{
                'aria-expanded': isOpen ? 'true' : 'false',
                'aria-label': t.desktop.desktopToggleFolder(
                  name: node.folder.name,
                ),
              },
              onClick: () => context
                  .read(expandedFoldersProvider.notifier)
                  .toggle(node.folder.id),
            ),
            button(
              [
                span(classes: 'min-w-0 flex-1 truncate', [
                  Component.text(node.folder.name),
                ]),
                span(classes: 'text-xs tabular-nums opacity-60', [
                  Component.text('${node.totalChats}'),
                ]),
              ],
              classes:
                  'flex min-w-0 flex-1 items-center gap-1.5 py-1.5 pr-2 '
                  'text-left',
              type: ButtonType.button,
              attributes: <String, String>{
                if (context.watch(openFolderProvider) == folderId)
                  'aria-current': 'page',
              },
              onClick: () =>
                  context.read(openFolderProvider.notifier).open(folderId),
            ),
          ],
        ),
        if (isOpen)
          ul(classes: 'ml-3 space-y-0.5 border-l border-border pl-1', [
            for (final child in node.children) _folder(context, child, open),
            for (final chat in node.chats) _row(chat),
          ]),
      ],
    );
  }

  Component _footerButton(
    String label,
    void Function() onClick, {
    bool? expanded,
  }) => button(
    [Component.text(label)],
    classes:
        'w-full rounded px-2 py-1.5 text-left text-xs text-muted-foreground '
        'hover:bg-accent/50',
    type: ButtonType.button,
    attributes: <String, String>{
      if (expanded != null) 'aria-expanded': expanded ? 'true' : 'false',
    },
    onClick: onClick,
  );

  static String _bucketLabel(DateBucket bucket) => switch (bucket) {
    DateBucket.today => t.app.today,
    DateBucket.yesterday => t.app.yesterday,
    DateBucket.previous7Days => t.app.previous7Days,
    DateBucket.previous30Days => t.app.previous30Days,
    DateBucket.older => t.app.older,
  };
}

/// Whether the conversation list is still catching up (WP-3.1).
///
/// Quiet on purpose. When the sync is idle and healthy it renders nothing,
/// because a permanent "Synced" line is noise. It appears only while there
/// is something to know: the list may be incomplete, or the last sync
/// failed.
class _SyncIndicator extends StatelessComponent {
  const _SyncIndicator();

  @override
  Component build(BuildContext context) {
    final sync = context.watch(syncStateProvider).value;
    if (sync == null) return const Component.fragment([]);
    final String? text;
    String? detail;
    if (sync.running) {
      final progress = sync.progress;
      text = progress == null
          ? t.desktop.desktopSyncing
          : t.desktop.desktopSyncingPercent(percent: (progress * 100).round());
    } else if (sync.lastError case final error?) {
      text = t.desktop.desktopSyncFailed;
      detail = error;
    } else {
      text = null;
    }
    if (text == null) return const Component.fragment([]);
    return p(
      classes:
          'px-2 pb-1 text-xs '
          '${detail == null ? 'text-muted-foreground' : 'text-destructive'}',
      // `status`, so the change is announced without interrupting.
      attributes: <String, String>{'role': 'status', 'title': ?detail},
      [Component.text(text)],
    );
  }
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

  /// Where the right-click was, while its menu is open.
  ({double x, double y})? _menuAt;

  @override
  Component build(BuildContext context) {
    final chat = component.chat;
    final actions = context.read(chatActionsProvider);

    // Choosing, not opening: in the selection mode a row is a checkbox,
    // and its hover actions and drag handle stand down.
    if (context.watch(chatSelectionProvider) case final chosen?) {
      return li(classes: 'rounded px-2 py-1 hover:bg-accent/50', [
        checkboxField(
          id: 'select-${chat.id}',
          text: chat.title,
          checked: chosen.contains(chat.id),
          onChanged: ({required value}) =>
              context.read(chatSelectionProvider.notifier).toggle(chat.id),
        ),
      ]);
    }

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

    return li(
      classes: 'group relative',
      // Not `content-visibility` here, as the transcript has: it contains
      // paint, which makes the row the box a `fixed` child is placed in --
      // and the right-click menu is one, and would be clipped to the row.
      // The list is paged anyway.
      events: <String, EventCallback>{
        'contextmenu': contextMenuAt(
          (x, y) => setState(() => _menuAt = (x: x, y: y)),
        ),
      },
      [
        if (_menuAt case final at?)
          ContextMenu(
            x: at.x,
            y: at.y,
            label: t.desktop.desktopChatActions(title: chat.title),
            onClose: () => setState(() => _menuAt = null),
            items: <ContextMenuItem>[
              ContextMenuItem(
                chat.pinned
                    ? t.desktop.desktopUnpinChat
                    : t.desktop.desktopPinChat,
                () =>
                    unawaited(actions.setPinned(chat.id, value: !chat.pinned)),
              ),
              ContextMenuItem(
                t.desktop.desktopRenameChat,
                () => setState(() {
                  _renaming = true;
                  _draftTitle = chat.title;
                }),
              ),
              ContextMenuItem(
                t.app.shareChat,
                () => context.read(shareDialogProvider.notifier).open(chat.id),
              ),
              // Every folder, as drag-and-drop offers them -- for the same
              // move without a mouse held down across the sidebar.
              for (final folder
                  in context.read(chatListProvider).value?.folders ??
                      const <FolderSummary>[])
                if (folder.id != chat.folderId)
                  ContextMenuItem(
                    t.desktop.desktopMoveTo(folder: folder.name),
                    () => unawaited(actions.move(chat.id, folder.id)),
                  ),
              if (chat.folderId != null)
                ContextMenuItem(
                  t.desktop.desktopRemoveFromFolder,
                  () => unawaited(actions.move(chat.id, null)),
                ),
              ContextMenuItem(
                chat.archived ? t.app.unarchive : t.desktop.desktopArchiveChat,
                () => unawaited(
                  actions.setArchived(chat.id, value: !chat.archived),
                ),
              ),
              ContextMenuItem(
                t.desktop.desktopDeleteChat,
                () => setState(() => _confirmingDelete = true),
                destructive: true,
              ),
            ],
          ),
        div(
          classes: 'flex items-center gap-1',
          attributes: const <String, String>{'draggable': 'true'},
          events: <String, EventCallback>{
            'dragstart': startDrag(
              () => context.read(draggingChatProvider.notifier).start(chat),
            ),
            'dragend': (_) => context.read(draggingChatProvider.notifier).end(),
          },
          [
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
          ],
        ),
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
      ],
    );
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
        // The same action both ways, so it has to say which way. An
        // archived chat offering "Archive" reads as already failed.
        label: chat.archived ? t.app.unarchive : t.desktop.desktopArchiveChat,
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
    final temporaryIds = context.watch(temporaryChatIdsProvider);
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
    // A live turn only counts if it belongs to what is selected. The provider
    // keeps the last turn after it settles, and after deleting the open
    // conversation that turn belongs to a chat that no longer exists. The
    // pane then stayed blank instead of offering the empty state.
    final nothingChosen =
        selected == null &&
        !showPending &&
        (live == null || live.chatId != selected);
    // The answer the live turn is filling in, if the synced transcript
    // already has a row for it.
    //
    // It usually does now, and it is usually *empty*: the server creates
    // the assistant placeholder when the turn starts, and a pull can land
    // before a single token has. Suppressing the overlay whenever a row
    // with that id existed therefore replaced a streaming answer with a
    // blank bubble -- which is what `chats.get` returning real transcripts
    // turned from theoretical into the common case.
    final persistedLive = live == null
        ? null
        : persisted.where((m) => m.id == live.messageId).firstOrNull;
    // Stored as another answer's version counts too. Switching branches in
    // the overview can move the answer that just streamed off the path
    // shown, and the overlay then drew it a second time below the answer
    // that now carries it as a version.
    final persistedLiveHasText =
        (persistedLive?.content ?? '').isNotEmpty ||
        (live != null &&
            persisted.any(
              (m) => m.versions.any(
                (v) => v.id == live.messageId && v.content.isNotEmpty,
              ),
            ));

    // Read once here rather than in every block: the port is the page's
    // dependency, not the markdown renderer's, and threading the callback
    // keeps `MarkdownView` and `CodeBlock` testable without one.
    final commands = context.read(windowCommandsProvider);
    void copyCode(String source) => unawaited(commands.copy(source));
    final versions = context.watch(answerVersionProvider);
    final editing = context.watch(editingMessageProvider);
    final ratings = context.watch(ratingOverridesProvider);
    final canRate =
        context.watch(serverCapabilitiesProvider).messageRating &&
        selected != null &&
        !temporaryIds.contains(selected) &&
        !isLocalOnlyChatId(selected) &&
        (live == null || live.settled);

    // After the frame this build produces, not during it: the pane has to
    // have grown before there is anything new to scroll to. Every build,
    // because a streaming answer grows on each delta -- and it costs
    // nothing when the user has scrolled away, which is the case the
    // command exists to respect.
    Future<void>.microtask(() => commands.scrollToEnd('transcript'));

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
          span(classes: 'truncate', [
            Component.text(title ?? t.desktop.desktopNewConversation),
          ]),
          // Said where the conversation is named, not only at the toggle.
          // Someone who scrolls back through a temporary chat an hour later
          // should not have to remember that it will not be kept.
          if (temporaryIds.contains(selected) ||
              (selected == null && context.watch(temporaryChatProvider)))
            span(
              classes:
                  'ml-3 shrink-0 rounded-full border border-border px-2 py-0.5 '
                  'text-xs font-normal text-muted-foreground',
              attributes: <String, String>{
                'title': t.desktop.desktopTemporaryHint,
              },
              [Component.text(t.app.temporaryChat)],
            ),
          if (selected != null &&
              !temporaryIds.contains(selected) &&
              !isLocalOnlyChatId(selected) &&
              context.watch(serverCapabilitiesProvider).tags &&
              detail.value != null)
            ChatTags(
              key: ValueKey('tags-$selected'),
              tagIds: detail.value!.summary.tags,
              names:
                  context.watch(tagNamesProvider).value ??
                  const <String, String>{},
              onAdd: (name) => unawaited(
                context.read(chatActionsProvider).addTag(selected, name),
              ),
              onRemove: (name) => unawaited(
                context.read(chatActionsProvider).removeTag(selected, name),
              ),
              onFilter: (name) =>
                  context.read(searchQueryProvider.notifier).set('tag:$name'),
            ),
          if (selected != null &&
              !temporaryIds.contains(selected) &&
              !isLocalOnlyChatId(selected)) ...[
            button(
              [Component.text(t.app.shareChat)],
              classes:
                  'ml-auto shrink-0 rounded px-2 py-1 text-xs font-normal '
                  'text-muted-foreground hover:bg-accent',
              type: ButtonType.button,
              onClick: () =>
                  context.read(shareDialogProvider.notifier).open(selected),
            ),
            button(
              [Component.text(t.desktop.desktopControls)],
              classes:
                  'shrink-0 rounded px-2 py-1 text-xs font-normal '
                  'text-muted-foreground hover:bg-accent aria-pressed:bg-accent',
              type: ButtonType.button,
              attributes: <String, String>{
                'aria-pressed': '${context.watch(controlsOpenProvider)}',
              },
              onClick: () =>
                  context.read(controlsOpenProvider.notifier).toggle(),
            ),
          ],
        ],
      ),
      // Under the header rather than over the composer: it describes the
      // whole window, and the composer says the rest by pausing Send.
      if (context.watch(onlineProvider).value == false)
        div(
          classes:
              'shrink-0 border-b border-border bg-muted px-6 py-2 text-xs '
              'text-muted-foreground',
          attributes: const <String, String>{'role': 'status'},
          [Component.text(t.desktop.desktopOffline)],
        ),
      if (context.watch(shareDialogProvider) case final shareId?)
        ShareDialog(
          key: ValueKey('share-$shareId'),
          chatId: shareId,
          // From the open conversation when that is the one: list rows are
          // envelopes without a share id, so only the full copy knows.
          shared:
              (shareId == selected
                  ? detail.value?.summary.shared
                  : _summaryIn(
                      context.watch(chatListProvider).value,
                      shareId,
                    )?.shared) ??
              false,
          onClose: () => context.read(shareDialogProvider.notifier).close(),
        ),
      div(
        id: 'transcript',
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
            // `value`, not `when`. A refetch reports `loading` while still
            // holding the previous transcript, and `when` would blank the
            // whole conversation every time a turn finished.
            ...(detail.hasError && !detail.hasValue)
                ? <Component>[formError('${detail.error}')]
                : (() {
                    final chat = detail.value;
                    // An edit in flight hides the question it replaces and
                    // everything after it. Those belong to the old branch,
                    // and until the sync lands the transcript still holds
                    // them.
                    final all = chat?.messages ?? const <ChatMessageDto>[];
                    final cut = showPending && pending.replaces != null
                        ? all.indexWhere((m) => m.id == pending.replaces)
                        : -1;
                    final shown = cut < 0 ? all : all.sublist(0, cut);
                    return <Component>[
                      for (final message in shown)
                        if (message.role == 'user' && editing == message.id)
                          _QuestionEditor(
                            key: ValueKey('edit-${message.id}'),
                            original: message.content,
                            onCancel: () => context
                                .read(editingMessageProvider.notifier)
                                .stop(),
                            onSave: (text) {
                              context
                                  .read(editingMessageProvider.notifier)
                                  .stop();
                              if (selected == null) return;
                              unawaited(
                                context
                                    .read(chatActionsProvider)
                                    .edit(
                                      chatId: selected,
                                      messageId: message.id,
                                      text: text,
                                    ),
                              );
                            },
                          )
                        else
                        // Skipped while the overlay is showing it, so the two do
                        // not appear one above the other.
                        if (!(message.id == live?.messageId &&
                            !persistedLiveHasText))
                          _bubble(
                            message.role,
                            _shownContent(message, versions[message.id]),
                            sources: _shownSources(
                              message,
                              versions[message.id],
                            ),
                            usage: _shownUsage(message, versions[message.id]),
                            files: message.files,
                            // Only on the answer the server says is current:
                            // an older version's rating is not in the
                            // stored copy, so its thumb would be a guess.
                            rating: ratings[message.id] ?? message.rating,
                            onRate:
                                message.role == 'assistant' &&
                                    canRate &&
                                    (versions[message.id] == null ||
                                        versions[message.id] ==
                                            message.versions.length)
                                ? (rating) => unawaited(
                                    context
                                        .read(chatActionsProvider)
                                        .rate(
                                          chatId: selected,
                                          messageId: message.id,
                                          rating: rating,
                                        )
                                        .catchError((Object _) {}),
                                  )
                                : null,
                            onCopyCode: copyCode,
                            // Per version, so flicking between answers does not
                            // reuse a formula frame drawn for a different one.
                            mathIdPrefix:
                                '${message.id}-${versions[message.id] ?? message.versions.length}',
                            onCopy: () => unawaited(
                              commands.copy(
                                _shownContent(message, versions[message.id]),
                              ),
                            ),
                            onEdit:
                                message.role == 'user' &&
                                    selected != null &&
                                    !temporaryIds.contains(selected) &&
                                    (live == null || live.settled)
                                ? () => context
                                      .read(editingMessageProvider.notifier)
                                      .start(message.id)
                                : null,
                            // Arrows only on answers. A sibling *question* is a
                            // different branch of the whole conversation, and
                            // swapping just its text would show an old question
                            // above the new answer.
                            versionNav:
                                message.versions.isEmpty ||
                                    message.role != 'assistant'
                                ? null
                                : _versionNav(
                                    context,
                                    message,
                                    versions[message.id],
                                  ),
                            // Only once there is an answer to replace, and only
                            // when nothing is already streaming -- the daemon
                            // refuses a second turn in a chat, and a button that
                            // reliably fails is worse than one that is not there.
                            onRegenerate:
                                message.role == 'assistant' &&
                                    selected != null &&
                                    !temporaryIds.contains(selected) &&
                                    (live == null || live.settled)
                                ? () => unawaited(
                                    context
                                        .read(chatActionsProvider)
                                        .regenerate(
                                          chatId: selected,
                                          messageId: message.id,
                                        ),
                                  )
                                : null,
                          ),
                    ];
                  })(),
            // The message just sent, until the server's copy arrives.
            if (showPending)
              _bubble(
                'user',
                pending.text,
                onCopy: () => unawaited(commands.copy(pending.text)),
              ),
            // Only for the chat on screen: a background turn in another
            // conversation must not paint into this one. A settled turn also
            // stands down once the synced transcript contains it.
            if (live != null &&
                live.chatId == selected &&
                !persistedLiveHasText)
              _bubble(
                'assistant',
                live.text.isEmpty && !live.failed ? '…' : live.text,
                onCopyCode: copyCode,
                mathIdPrefix: live.messageId,
                onCopy: () => unawaited(commands.copy(live.text)),
                // Once it has finished, this is the same answer the synced
                // transcript will show, so it offers what that one would.
                // The overlay can outlive the stream by as long as the
                // sync takes, and a Regenerate that appears only later
                // reads as the button arriving at random.
                onRegenerate:
                    live.settled &&
                        !live.failed &&
                        selected != null &&
                        !temporaryIds.contains(selected)
                    ? () => unawaited(
                        context
                            .read(chatActionsProvider)
                            .regenerate(
                              chatId: selected,
                              messageId: live.messageId,
                            ),
                      )
                    : null,
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

  static const Styles _offscreenSkippable = Styles(
    raw: <String, String>{
      'content-visibility': 'auto',
      'contain-intrinsic-size': 'auto 120px',
    },
  );

  /// The sidebar's row for [chatId], if the list has been loaded.
  ChatSummary? _summaryIn(ChatList? list, String chatId) {
    for (final chat in list?.chats ?? const <ChatSummary>[]) {
      if (chat.id == chatId) return chat;
    }
    return null;
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
    void Function(String source)? onCopyCode,
    String? mathIdPrefix,
    void Function()? onCopy,
    void Function()? onRegenerate,
    void Function()? onEdit,
    Component? versionNav,
    bool streaming = false,
    String? failure,
    List<ChatSourceDto> sources = const <ChatSourceDto>[],
    ChatUsageDto? usage,
    int? rating,
    void Function(int rating)? onRate,
    List<ChatFileDto> files = const <ChatFileDto>[],
  }) {
    final isUser = role == 'user';
    final failed = failure != null;
    // The row exists so the actions have somewhere to sit *under* the
    // bubble rather than floating over the text they belong to.
    return div(
      classes:
          'group flex flex-col gap-1 '
          '${isUser ? 'items-end' : 'items-start'}',
      // The browser's own virtualisation: a message scrolled far out of
      // view is not laid out or painted, and `auto` in the size keeps the
      // height it last had, so the scrollbar does not jump as it returns.
      // Safe here because nothing in a message is `position: fixed`; the
      // paint containment this brings would clip anything that were.
      styles: _offscreenSkippable,
      [
        // Above a question, as they were attached before it was asked;
        // below an answer, as what it produced.
        if (isUser && files.isNotEmpty) MessageFiles(files, alignEnd: true),
        article(
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
              MarkdownView(
                content,
                onCopyCode: onCopyCode,
                mathIdPrefix: mathIdPrefix,
                sources: sources,
              ),
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
        ),
        if (!isUser && files.isNotEmpty) MessageFiles(files),
        if (!isUser && (sources.isNotEmpty || usage != null))
          div(classes: 'mr-auto flex max-w-[90%] items-start gap-4', [
            if (sources.isNotEmpty) SourcesList(sources),
            if (usage != null) UsageDetails(usage),
          ]),
        // In the DOM always, revealed on hover or focus. A control that
        // only exists on hover cannot be reached by keyboard at all.
        if (onCopy != null ||
            onRegenerate != null ||
            onEdit != null ||
            onRate != null ||
            versionNav != null)
          div(classes: 'flex items-center gap-1', [
            // Always visible, unlike the actions beside it. That there
            // *are* other answers is information in itself, and hiding it
            // behind a hover means nobody finds out.
            ?versionNav,
            div(
              classes:
                  'flex gap-1 opacity-0 transition-opacity '
                  'group-hover:opacity-100 group-focus-within:opacity-100',
              [
                if (onCopy case final copy?) _messageAction(t.app.copy, copy),
                if (onRegenerate case final again?)
                  _messageAction(t.app.regenerate, again),
                if (onEdit case final edit?) _messageAction(t.app.edit, edit),
              ],
            ),
            // After the other actions, and visible once used: a thumb that
            // hides again until hovered leaves the user unsure it stuck.
            if (onRate case final rate?)
              div(
                classes:
                    'flex gap-0.5 '
                    '${rating == null ? 'opacity-0 transition-opacity group-hover:opacity-100 group-focus-within:opacity-100' : ''}',
                [
                  _rateButton(
                    t.desktop.desktopGoodResponse,
                    '\u{1F44D}',
                    pressed: rating == 1,
                    onClick: () => rate(1),
                  ),
                  _rateButton(
                    t.desktop.desktopBadResponse,
                    '\u{1F44E}',
                    pressed: rating == -1,
                    onClick: () => rate(-1),
                  ),
                ],
              ),
          ]),
      ],
    );
  }

  /// The text for the answer [index] names, where the list is the
  /// message's versions (oldest first) followed by the message itself.
  /// The sources of the answer [index] names; each version has its own.
  static List<ChatSourceDto> _shownSources(ChatMessageDto message, int? index) {
    final i = index ?? message.versions.length;
    return i < message.versions.length
        ? message.versions[i].sources
        : message.sources;
  }

  static ChatUsageDto? _shownUsage(ChatMessageDto message, int? index) {
    final i = index ?? message.versions.length;
    return i < message.versions.length
        ? message.versions[i].usage
        : message.usage;
  }

  static String _shownContent(ChatMessageDto message, int? index) {
    final i = index ?? message.versions.length;
    return i < message.versions.length
        ? message.versions[i].content
        : message.content;
  }

  Component _versionNav(
    BuildContext context,
    ChatMessageDto message,
    int? selected,
  ) {
    final count = message.versions.length + 1;
    final index = (selected ?? count - 1).clamp(0, count - 1);
    void show(int next) =>
        context.read(answerVersionProvider.notifier).show(message.id, next);
    Component arrow(String glyph, String label, int? target) => button(
      [
        span(
          attributes: const <String, String>{'aria-hidden': 'true'},
          [Component.text(glyph)],
        ),
      ],
      classes:
          'rounded px-1.5 py-0.5 text-xs text-muted-foreground '
          'hover:bg-accent disabled:opacity-40',
      type: ButtonType.button,
      disabled: target == null,
      attributes: <String, String>{'aria-label': label, 'title': label},
      onClick: target == null ? null : () => show(target),
    );
    return div(
      classes: 'flex items-center text-xs text-muted-foreground',
      attributes: <String, String>{
        'role': 'group',
        'aria-label': t.desktop.desktopAnswerPosition(
          index: index + 1,
          count: count,
        ),
      },
      [
        arrow(
          '\u2039',
          t.desktop.desktopPreviousAnswer,
          index > 0 ? index - 1 : null,
        ),
        span(classes: 'tabular-nums', [Component.text('${index + 1}/$count')]),
        arrow(
          '\u203a',
          t.desktop.desktopNextAnswer,
          index < count - 1 ? index + 1 : null,
        ),
      ],
    );
  }

  Component _rateButton(
    String label,
    String glyph, {
    required bool pressed,
    required void Function() onClick,
  }) => button(
    [
      span(
        attributes: const <String, String>{'aria-hidden': 'true'},
        [Component.text(glyph)],
      ),
    ],
    classes:
        'rounded px-1 py-0.5 text-xs '
        '${pressed ? 'bg-accent' : 'opacity-60 hover:bg-accent hover:opacity-100'}',
    type: ButtonType.button,
    attributes: <String, String>{
      'aria-label': label,
      'title': label,
      'aria-pressed': '$pressed',
    },
    onClick: onClick,
  );

  Component _messageAction(String label, void Function() onClick) => button(
    [Component.text(label)],
    classes:
        'rounded px-1.5 py-0.5 text-xs text-muted-foreground '
        'hover:bg-accent hover:text-accent-foreground',
    type: ButtonType.button,
    attributes: <String, String>{'title': label},
    onClick: onClick,
  );
}

/// A sent question, reopened for editing in place (WP-3.2).
///
/// In place rather than in the composer. Editing a question from three
/// turns ago is a change to *that* turn, and moving it into the composer
/// would make it read as a new message at the bottom.
class _QuestionEditor extends StatefulComponent {
  const _QuestionEditor({
    required this.original,
    required this.onSave,
    required this.onCancel,
    super.key,
  });

  final String original;
  final void Function(String text) onSave;
  final void Function() onCancel;

  @override
  State<_QuestionEditor> createState() => _QuestionEditorState();
}

class _QuestionEditorState extends State<_QuestionEditor> {
  late String _text = component.original;

  bool get _changed =>
      _text.trim().isNotEmpty && _text.trim() != component.original.trim();

  @override
  Component build(BuildContext context) => div(
    classes: 'ml-auto flex w-full max-w-[80%] flex-col gap-2',
    [
      textAreaField(
        id: 'edit-question',
        labelText: t.app.edit,
        hideLabel: true,
        value: _text,
        rows: 3,
        onInput: (value) => setState(() => _text = value),
        onKeyDown: sendOnEnter(() {
          if (_changed) component.onSave(_text.trim());
        }),
      ),
      div(classes: 'flex justify-end gap-2', [
        button(
          [Component.text(t.app.cancel)],
          classes:
              'rounded px-3 py-1.5 text-sm text-muted-foreground '
              'hover:bg-accent',
          type: ButtonType.button,
          onClick: component.onCancel,
        ),
        button(
          [Component.text(t.app.send)],
          classes:
              'rounded bg-primary px-3 py-1.5 text-sm text-primary-foreground '
              'disabled:opacity-60',
          type: ButtonType.button,
          // Unchanged text would branch the conversation to ask the same
          // thing again, which is what Regenerate is for.
          disabled: !_changed,
          onClick: () => component.onSave(_text.trim()),
        ),
      ]),
    ],
  );
}

class _Composer extends StatefulComponent {
  const _Composer();

  @override
  State<_Composer> createState() => _ComposerState();
}

/// One attachment, from picked to uploaded.
///
/// Tracked per file rather than as one composer-wide "uploading" flag: a
/// user attaching five files wants to know which of them failed, and a
/// single flag cannot say.
class _Attachment {
  _Attachment(this.picked);

  final PickedAttachment picked;

  /// The server's id, once the upload finishes.
  String? id;
  double progress = 0;
  bool failed = false;

  bool get ready => id != null;
}

class _ComposerState extends State<_Composer> {
  String _text = '';
  bool _busy = false;
  String? _error;
  final List<_Attachment> _attachments = <_Attachment>[];

  // Kept across sends, as Open WebUI keeps them: turning on web search is a
  // choice about the conversation, not about one message.
  bool _webSearch = false;
  bool _imageGeneration = false;
  final Set<String> _toolIds = <String>{};
  bool _toolsOpen = false;

  /// The MCP content sheet (M4), for a direct model with MCP servers.
  bool _contentOpen = false;

  /// Counted rather than a flag: `dragleave` fires every time the pointer
  /// crosses into a child, so a flag flickered off over the text field.
  int _dragDepth = 0;

  // The `/` menu. Dismissed for exactly the text it was dismissed at, so
  // typing on brings it back without a separate "reopen" gesture.
  int _promptIndex = 0;
  String? _promptsDismissedAt;

  /// Knowledge bases a `#` added to the next message (WP-3.3).
  final List<KnowledgeSummary> _knowledge = <KnowledgeSummary>[];

  /// The model an `@` chose for the next message only (WP-3.3). Open
  /// WebUI's rule: the conversation's selected model is left as it was.
  ModelSummary? _atModel;

  // A chosen prompt that needs values before it can be inserted.
  PromptSummary? _asking;
  List<PromptInput> _askingFor = const <PromptInput>[];
  int _askingStart = 0;
  String? _askingClipboard;

  @override
  Component build(BuildContext context) {
    final live = context.watch(liveTurnProvider).value;
    // `settled` as well as `failed`. The provider holds the last turn until
    // a new one replaces it -- that is what keeps a finished answer on
    // screen while the sync catches up -- so a completed turn left this
    // reading "still streaming" and the composer offered Stop forever,
    // with no way back to Send short of starting another conversation.
    final streaming = live != null && !live.settled && !live.failed;

    final models = context.watch(modelListProvider).value;

    final uploading = _attachments.any((file) => !file.ready && !file.failed);

    final options = context.watch(composerOptionsProvider).value;

    final attachments = context.read(attachmentsProvider);

    final trigger = _promptsDismissedAt == _text || _asking != null
        ? null
        : slashTriggerIn(_text);
    final prompts = trigger == null
        ? const <PromptSummary>[]
        : matchPrompts(
            trigger.query,
            context.watch(promptListProvider).value?.prompts ??
                const <PromptSummary>[],
          );
    // `@model`, when no `/` menu is open: which model answers next.
    final mention =
        prompts.isNotEmpty || _promptsDismissedAt == _text || _asking != null
        ? null
        : mentionTriggerIn(_text);
    final mentioned = mention == null
        ? const <ModelSummary>[]
        : matchModels(mention.query, models?.models ?? const <ModelSummary>[]);
    // `#knowledge`, when neither of those is open.
    final hash =
        prompts.isNotEmpty ||
            mentioned.isNotEmpty ||
            _promptsDismissedAt == _text ||
            _asking != null
        ? null
        : knowledgeTriggerIn(_text);
    final knowledgeHits = hash == null
        ? const <KnowledgeSummary>[]
        : context.watch(knowledgeSearchProvider(hash.query)).value?.items ??
              const <KnowledgeSummary>[];
    final menuLength = prompts.isNotEmpty
        ? prompts.length
        : mentioned.isNotEmpty
        ? mentioned.length
        : knowledgeHits.length;
    final highlighted = menuLength == 0
        ? -1
        : _promptIndex.clamp(0, menuLength - 1);

    return div(
      key: const ValueKey('composer'),
      classes:
          'border-t border-border bg-background p-4'
          '${_dragDepth > 0 ? ' ring-2 ring-inset ring-primary' : ''}',
      // Files arrive three ways: the + button, a drop anywhere on the
      // composer, and a paste into it. The last two go through the port,
      // which is what may call `preventDefault` -- that throws on the VM.
      events: <String, EventCallback>{
        'dragenter': (event) {
          if (attachments.claimDrag(event)) setState(() => _dragDepth++);
        },
        // Every `dragover` has to be claimed, not just the first, or the
        // browser refuses the drop.
        'dragover': attachments.claimDrag,
        'dragleave': (_) {
          if (_dragDepth > 0) setState(() => _dragDepth--);
        },
        'drop': (event) {
          setState(() => _dragDepth = 0);
          _upload(attachments, attachments.takeFiles(event));
        },
        'paste': (event) => _upload(attachments, attachments.takeFiles(event)),
      },
      [
        if (options != null &&
            (options.webSearch ||
                options.imageGeneration ||
                _toolsOffered(options).isNotEmpty))
          _features(options),
        if (_asking case final prompt?)
          PromptInputsForm(
            key: ValueKey('fill-${prompt.command}'),
            title: prompt.title,
            inputs: _askingFor,
            onSubmit: (values) =>
                unawaited(_renderPrompt(context, prompt, values: values)),
            onCancel: () => setState(() => _asking = null),
          )
        else if (prompts.isNotEmpty)
          PromptMenu(
            prompts: prompts,
            highlighted: highlighted,
            onChoose: (prompt) => unawaited(_choosePrompt(context, prompt)),
            onHighlight: (index) => setState(() => _promptIndex = index),
          )
        else if (mentioned.isNotEmpty)
          SuggestionMenu(
            idPrefix: 'model',
            label: t.desktop.desktopModelMenu,
            items: <({String key, String title, String? detail})>[
              for (final model in mentioned)
                (
                  key: model.id,
                  title: modelLabel(model),
                  detail: model.name == model.id ? null : model.id,
                ),
            ],
            highlighted: highlighted,
            onChoose: (index) => _chooseModel(context, mentioned[index]),
            onHighlight: (index) => setState(() => _promptIndex = index),
          )
        else if (knowledgeHits.isNotEmpty)
          SuggestionMenu(
            idPrefix: 'knowledge',
            label: t.desktop.desktopKnowledgeMenu,
            items: <({String key, String title, String? detail})>[
              for (final hit in knowledgeHits)
                (key: hit.id, title: hit.name, detail: hit.description),
            ],
            highlighted: highlighted,
            onChoose: (index) =>
                _chooseKnowledge(context, knowledgeHits[index]),
            onHighlight: (index) => setState(() => _promptIndex = index),
          ),
        if (_atModel case final model?)
          div(classes: 'mx-auto mb-2 flex max-w-3xl', [
            span(
              classes:
                  'flex items-center gap-1 rounded-full border border-border '
                  'py-0.5 pl-2 pr-1 text-xs text-muted-foreground',
              [
                Component.text(
                  t.desktop.desktopAnswerWith(model: modelLabel(model)),
                ),
                button(
                  [
                    span(
                      attributes: const <String, String>{'aria-hidden': 'true'},
                      [Component.text('×')],
                    ),
                  ],
                  classes: 'rounded-full px-1 hover:text-foreground',
                  type: ButtonType.button,
                  attributes: <String, String>{
                    'aria-label': t.desktop.desktopClearMention,
                    'title': t.desktop.desktopClearMention,
                  },
                  onClick: () => setState(() => _atModel = null),
                ),
              ],
            ),
          ]),
        if (_attachments.isNotEmpty || _knowledge.isNotEmpty)
          div(
            classes: 'mx-auto mb-2 flex max-w-3xl flex-wrap gap-2',
            attributes: <String, String>{'aria-label': t.app.attachments},
            [
              for (final attachment in _attachments) _chip(context, attachment),
              for (final knowledge in _knowledge)
                span(
                  classes:
                      'flex items-center gap-1 rounded-full border '
                      'border-border py-0.5 pl-2 pr-1 text-xs',
                  [
                    Component.text('# ${knowledge.name}'),
                    button(
                      [
                        span(
                          attributes: const <String, String>{
                            'aria-hidden': 'true',
                          },
                          [Component.text('×')],
                        ),
                      ],
                      classes: 'rounded-full px-1 hover:bg-accent',
                      type: ButtonType.button,
                      attributes: <String, String>{
                        'aria-label': t.desktop.desktopRemoveAttachment(
                          name: knowledge.name,
                        ),
                      },
                      onClick: () =>
                          setState(() => _knowledge.remove(knowledge)),
                    ),
                  ],
                ),
            ],
          ),
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
                    [Component.text(modelLabel(model))],
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
            // Only before the first message. A conversation is temporary or
            // not from the start: switching an existing chat would mean
            // deleting it from the server, which is what Delete is for.
            if (context.watch(selectedChatIdProvider) == null)
              div(classes: 'ml-auto', [
                checkboxField(
                  id: 'temporary-chat',
                  text: t.app.temporaryChat,
                  checked: context.watch(temporaryChatProvider),
                  onChanged: ({required value}) => context
                      .read(temporaryChatProvider.notifier)
                      .set(value: value),
                ),
              ]),
          ]),
        form(
          [
            // `min-w-0` on the field: a flex item's automatic minimum is its
            // content's, and a textarea's is its `cols` -- without this the
            // field refuses to give ground and the row overflows instead.
            div(classes: 'mx-auto flex max-w-3xl items-end gap-2', [
              button(
                [
                  span(
                    attributes: const <String, String>{'aria-hidden': 'true'},
                    [Component.text('\u002b')],
                  ),
                ],
                classes:
                    'shrink-0 rounded border border-border px-3 py-2 text-sm '
                    'text-muted-foreground hover:bg-accent',
                type: ButtonType.button,
                attributes: <String, String>{
                  'aria-label': t.desktop.desktopAttachFiles,
                  'title': t.desktop.desktopAttachFiles,
                },
                onClick: () => unawaited(_attach(context)),
              ),
              div(classes: 'min-w-0 flex-1', [
                textAreaField(
                  id: 'composer',
                  labelText: t.app.sendMessage,
                  placeholder: t.app.messageHintText,
                  hideLabel: true,
                  value: _text,
                  rows: 2,
                  // Not disabled while the turn is being accepted. The send
                  // button is, which is what prevents a double send -- and
                  // greying out the field costs the user the caret twice: a
                  // disabled element cannot be focused, so the refocus below
                  // was a no-op against a DOM that had not rebuilt yet, and
                  // they were left typing into nothing.
                  onInput: (value) => setState(() {
                    _text = value;
                    _promptIndex = 0;
                  }),
                  onKeyDown: composerKeys(
                    menuOpen: () => menuLength > 0,
                    move: ({required down}) {
                      final next = movePaletteIndex(
                        highlighted,
                        menuLength,
                        down: down,
                      );
                      setState(() => _promptIndex = next);
                      final prefix = prompts.isNotEmpty
                          ? 'prompt'
                          : mentioned.isNotEmpty
                          ? 'model'
                          : 'knowledge';
                      Future<void>.microtask(
                        () => context
                            .read(windowCommandsProvider)
                            .reveal('$prefix-option-$next'),
                      );
                    },
                    choose: () => prompts.isNotEmpty
                        ? unawaited(
                            _choosePrompt(context, prompts[highlighted]),
                          )
                        : mentioned.isNotEmpty
                        ? _chooseModel(context, mentioned[highlighted])
                        : _chooseKnowledge(context, knowledgeHits[highlighted]),
                    dismiss: () => setState(() => _promptsDismissedAt = _text),
                    send: () => unawaited(_send(context)),
                  ),
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
                  // An attachment still climbing is not a reason to grey the
                  // button out -- the user would watch it and wonder. The
                  // send waits for the upload instead, and says so.
                  enabled:
                      (_text.trim().isNotEmpty || _attachments.isNotEmpty) &&
                      context.watch(onlineProvider).value != false,
                  fullWidth: false,
                ),
            ]),
            if (_dragDepth > 0)
              p(classes: 'mx-auto mt-1.5 max-w-3xl text-xs text-primary', [
                Component.text(t.desktop.desktopDropToAttach),
              ])
            else if (_error case final message?)
              div(classes: 'mx-auto mt-2 max-w-3xl', [formError(message)])
            else if (uploading)
              p(
                classes:
                    'mx-auto mt-1.5 max-w-3xl text-xs text-muted-foreground',
                [Component.text(t.desktop.desktopAttachmentsUploading)],
              )
            else
              // Said once, quietly, under the field -- rather than left for
              // the user to discover by pressing Enter and watching their
              // message not send.
              p(
                classes:
                    'mx-auto mt-1.5 max-w-3xl text-xs text-muted-foreground',
                [Component.text(t.desktop.desktopComposerHint)],
              ),
          ],
          events: <String, EventCallback>{
            'submit': (event) {
              event.preventDefault();
              unawaited(_send(context));
            },
          },
        ),
      ],
    );
  }

  /// Web search, image generation and tools: switches for the next turn.
  ///
  /// Only what the daemon says this account and model may use. A switch
  /// that is shown but does nothing is worse than none.
  /// The tools the answering model can use: the server's for its own
  /// models, the app's MCP servers for a direct connection's (M4).
  List<ToolSummary> _toolsOffered(ComposerOptions? options) {
    if (options == null) return const <ToolSummary>[];
    return _answeredDirectly ? options.mcpTools : options.tools;
  }

  /// Whether the next answer comes from a direct connection's model.
  bool get _answeredDirectly {
    final answering =
        _atModel?.id ?? context.read(modelListProvider).value?.selectedId;
    return answering != null && answering.startsWith('direct:');
  }

  Component _features(ComposerOptions options) {
    Component toggle(
      String label, {
      required bool on,
      required void Function() flip,
    }) => button(
      [Component.text(label)],
      classes:
          'rounded-full border px-3 py-1 text-xs '
          '${on ? 'border-primary bg-primary text-primary-foreground' : 'border-border text-muted-foreground hover:bg-accent'}',
      type: ButtonType.button,
      attributes: <String, String>{'aria-pressed': on ? 'true' : 'false'},
      onClick: () => setState(flip),
    );
    return div(classes: 'mx-auto mb-2 max-w-3xl', [
      div(classes: 'flex flex-wrap items-center gap-2', [
        if (options.webSearch)
          toggle(
            t.app.webSearch,
            on: _webSearch,
            flip: () => _webSearch = !_webSearch,
          ),
        if (options.imageGeneration)
          toggle(
            t.app.imageGeneration,
            on: _imageGeneration,
            flip: () => _imageGeneration = !_imageGeneration,
          ),
        if (_toolsOffered(options).isNotEmpty)
          button(
            [
              Component.text(
                _toolIds.isEmpty
                    ? t.app.tools
                    : '${t.app.tools} (${_toolIds.length})',
              ),
            ],
            classes:
                'rounded-full border px-3 py-1 text-xs '
                '${_toolIds.isNotEmpty ? 'border-primary text-foreground' : 'border-border text-muted-foreground'} '
                'hover:bg-accent',
            type: ButtonType.button,
            attributes: <String, String>{
              'aria-expanded': _toolsOpen ? 'true' : 'false',
              'aria-controls': 'composer-tools',
            },
            onClick: () => setState(() => _toolsOpen = !_toolsOpen),
          ),
        // Prompts and resources from the same servers, as text to send.
        if (_answeredDirectly && options.mcpTools.isNotEmpty)
          button(
            [Component.text(t.app.directMcpContentAction)],
            classes:
                'rounded-full border px-3 py-1 text-xs '
                '${_contentOpen ? 'border-primary text-foreground' : 'border-border text-muted-foreground'} '
                'hover:bg-accent',
            type: ButtonType.button,
            attributes: <String, String>{
              'aria-expanded': _contentOpen ? 'true' : 'false',
            },
            onClick: () => setState(() => _contentOpen = !_contentOpen),
          ),
      ]),
      if (_contentOpen && _answeredDirectly && options.mcpTools.isNotEmpty)
        McpContentSheet(
          servers: options.mcpTools,
          draft: _text,
          onClose: () => setState(() => _contentOpen = false),
          onInsert: (text) {
            setState(() {
              _text = text;
              _contentOpen = false;
            });
            context.read(windowCommandsProvider)
              ..setValue('composer', text)
              ..focus('composer');
          },
        ),
      if (_toolsOpen && _toolsOffered(options).isNotEmpty)
        div(
          id: 'composer-tools',
          classes: 'mt-2 space-y-2 rounded border border-border p-3',
          [
            for (final tool in _toolsOffered(options))
              div([
                checkboxField(
                  id: 'tool-${tool.id}',
                  text: tool.name,
                  checked: _toolIds.contains(tool.id),
                  onChanged: ({required value}) => setState(
                    () => value
                        ? _toolIds.add(tool.id)
                        : _toolIds.remove(tool.id),
                  ),
                ),
                if (tool.description case final description?)
                  p(
                    classes: 'ml-6 line-clamp-2 text-xs text-muted-foreground',
                    [Component.text(description)],
                  ),
              ]),
          ],
        ),
    ]);
  }

  /// One chip per attachment: name, progress while it climbs, and a way
  /// to take it back off.
  Component _chip(BuildContext context, _Attachment attachment) {
    final name = attachment.picked.name;
    return div(
      classes:
          'flex items-center gap-2 rounded border px-2 py-1 text-xs '
          '${attachment.failed ? 'border-destructive text-destructive' : 'border-border text-muted-foreground'}',
      [
        span(classes: 'max-w-48 truncate', [Component.text(name)]),
        if (!attachment.ready && !attachment.failed)
          span(
            classes: 'tabular-nums',
            // The number is decoration; the state is announced by the
            // progress element's own semantics below.
            attributes: const <String, String>{'aria-hidden': 'true'},
            [Component.text('${(attachment.progress * 100).round()}%')],
          ),
        button(
          [
            span(
              attributes: const <String, String>{'aria-hidden': 'true'},
              [Component.text('\u2715')],
            ),
          ],
          classes: 'rounded px-1 hover:bg-accent',
          type: ButtonType.button,
          attributes: <String, String>{
            'aria-label': t.desktop.desktopRemoveAttachment(name: name),
            'title': t.desktop.desktopRemoveAttachment(name: name),
          },
          onClick: () {
            context.read(attachmentsProvider).discard(attachment.picked.handle);
            setState(() => _attachments.remove(attachment));
          },
        ),
      ],
    );
  }

  /// Picks files and starts uploading them.
  ///
  /// Each upload runs on its own rather than as a batch: one failing should
  /// not take the others with it, and the chip that failed is the one the
  /// user needs to see.
  Future<void> _attach(BuildContext context) async {
    final port = context.read(attachmentsProvider);
    final picked = await port.pick();
    if (!mounted) return;
    _upload(port, picked);
  }

  /// Takes the `#name` out of the text and adds the knowledge base to the
  /// next message, once.
  void _chooseKnowledge(BuildContext context, KnowledgeSummary knowledge) {
    final start = knowledgeTriggerIn(_text)?.start ?? _text.length;
    final text = _text.substring(0, start);
    setState(() {
      if (!_knowledge.any((chosen) => chosen.id == knowledge.id)) {
        _knowledge.add(knowledge);
      }
      _text = text;
    });
    context.read(windowCommandsProvider)
      ..setValue('composer', text)
      ..focus('composer');
  }

  /// Takes the `@name` out of the text and remembers the model for the
  /// next message.
  void _chooseModel(BuildContext context, ModelSummary model) {
    final start = mentionTriggerIn(_text)?.start ?? _text.length;
    final text = _text.substring(0, start);
    setState(() {
      _atModel = model;
      _text = text;
    });
    context.read(windowCommandsProvider)
      ..setValue('composer', text)
      ..focus('composer');
  }

  /// Puts [prompt] where its `/command` was typed, or asks for its values.
  Future<void> _choosePrompt(BuildContext context, PromptSummary prompt) async {
    final start = slashTriggerIn(_text)?.start ?? _text.length;
    // Read now, while the user's gesture is fresh: the browser only hands
    // over the clipboard to a focused document, and only for a prompt
    // that asked for it.
    final clipboard = prompt.usesClipboard
        ? await context.read(windowCommandsProvider).readClipboard()
        : null;
    if (!mounted) return;
    setState(() {
      _askingStart = start;
      _askingClipboard = clipboard;
    });
    await _renderPrompt(context, prompt);
  }

  Future<void> _renderPrompt(
    BuildContext context,
    PromptSummary prompt, {
    Map<String, String> values = const <String, String>{},
  }) async {
    final RenderedPrompt rendered;
    try {
      rendered = await context
          .read(chatActionsProvider)
          .renderPrompt(
            RenderPrompt(
              command: prompt.command,
              values: values,
              clipboard: _askingClipboard,
            ),
          );
    } on Object {
      if (!mounted) return;
      setState(() {
        _asking = null;
        _error = t.app.errorMessage;
      });
      return;
    }
    if (!mounted) return;
    if (rendered.inputs.isNotEmpty) {
      setState(() {
        _asking = prompt;
        _askingFor = rendered.inputs;
      });
      return;
    }
    final text =
        _text.substring(0, _askingStart.clamp(0, _text.length)) +
        rendered.content;
    setState(() {
      _asking = null;
      _text = text;
      _error = null;
    });
    context.read(windowCommandsProvider)
      ..setValue('composer', text)
      ..focus('composer');
  }

  /// Shows [picked] as chips and uploads each, however they arrived.
  void _upload(AttachmentPort port, List<PickedAttachment> picked) {
    if (picked.isEmpty) return;
    final added = picked.map(_Attachment.new).toList(growable: false);
    setState(() => _attachments.addAll(added));

    for (final attachment in added) {
      unawaited(
        port
            .upload(
              attachment.picked.handle,
              onProgress: (fraction) {
                if (!mounted) return;
                setState(() => attachment.progress = fraction);
              },
            )
            .then((id) {
              if (!mounted) return;
              setState(() => attachment.id = id);
            })
            .catchError((Object _) {
              if (!mounted) return;
              setState(() {
                attachment.failed = true;
                _error = t.desktop.desktopAttachmentFailed(
                  name: attachment.picked.name,
                );
              });
            }),
      );
    }
  }

  Future<void> _send(BuildContext context) async {
    final text = _text.trim();
    // A message may be attachments alone -- "look at this" with a file is a
    // complete thought -- but it may not be nothing.
    if ((text.isEmpty && _attachments.isEmpty) || _busy) return;
    // Enter as well as the button: the banner already says why.
    if (context.read(onlineProvider).value == false) return;
    if (_attachments.any((file) => !file.ready && !file.failed)) {
      setState(() => _error = t.desktop.desktopAttachmentsUploading);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final commands = context.read(windowCommandsProvider);
      await context
          .read(chatActionsProvider)
          .send(
            text: text,
            model: _atModel?.id,
            knowledge: List<KnowledgeSummary>.of(_knowledge),
            fileIds: <String>[for (final file in _attachments) ?file.id],
            // Only what the server still offers. A tool removed on the server,
            // or a feature the new model lacks, must not ride along from an
            // earlier choice.
            toolIds: <String>[
              for (final tool in _toolsOffered(
                context.read(composerOptionsProvider).value,
              ))
                if (_toolIds.contains(tool.id)) tool.id,
            ],
            webSearch:
                _webSearch &&
                (context.read(composerOptionsProvider).value?.webSearch ??
                    false),
            imageGeneration:
                _imageGeneration &&
                (context.read(composerOptionsProvider).value?.imageGeneration ??
                    false),
          );
      if (!mounted) return;
      // Cleared only on success: a failed send should leave the text where
      // the user can retry it rather than making them type it again.
      setState(() {
        _busy = false;
        _text = '';
        // Sent, so they belong to the message now rather than the box.
        _attachments.clear();
        // One message only, as in Open WebUI.
        _atModel = null;
        _knowledge.clear();
      });
      // The field as well as the state. A textarea's value stops tracking
      // its markup the moment the user types into it, so `_text = ''` alone
      // left the sent message sitting in the box.
      commands.setValue('composer', '');
      // Sending with Enter should leave the caret where it was, ready for
      // the next message.
      commands.focus('composer');
    } on RpcError catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = switch (error.code) {
          ConduitErrorCodes.unauthenticated => t.app.authSessionExpired,
          ConduitErrorCodes.unsupported => t.app.noModelsAvailable,
          // Not `stopGenerating`, which is a button's label and reads as
          // an instruction with no verb when it appears as an error.
          ConduitErrorCodes.conflict => t.desktop.desktopAlreadyGenerating,
          _ => t.app.couldNotConnectGeneric,
        };
      });
    }
  }
}
