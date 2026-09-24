import 'dart:async';
import 'dart:math' as math;

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:jaspr_router/jaspr_router.dart';

import '../keyboard.dart';
import '../l10n/strings.g.dart';
import '../rpc/activity_providers.dart';
import '../rpc/channels_providers.dart' show channelListProvider;
import '../rpc/chat_providers.dart';
import '../rpc/rpc_providers.dart';
import '../rpc/session_providers.dart';
import '../rpc/workspace_providers.dart';
import '../rpc/hermes_providers.dart';
import '../rpc/layout_providers.dart';
import '../rpc/terminal_providers.dart';
import '../sidebar_model.dart';
import 'form_field.dart';
import 'ui.dart';
import 'context_menu.dart';
import 'selection_bar.dart';
import '../pages/terminal_page.dart' show terminalOffered;

/// The conversation sidebar: search, then
/// pinned, folders, and Today, Yesterday and Earlier, with the window's
/// other places at its foot. It lives in the workspace, beside every route
/// that has one, rather than inside the chat page.
class Sidebar extends StatelessComponent {
  const Sidebar({super.key});

  @override
  Component build(BuildContext context) {
    final chats = context.watch(chatListProvider);
    final selected = context.watch(selectedChatIdProvider);
    final query = context.watch(searchQueryProvider);
    final search = context.watch(searchResultsProvider);

    return nav(
      classes: 'flex min-h-0 w-full flex-col text-foreground',
      attributes: <String, String>{'aria-label': t.desktop.desktopChatsLabel},
      [
        div(classes: 'space-y-0.5 px-1 pt-1 pb-2', [
          _placeButton(
            glyph: LucideIcon.squarePen,
            label: t.app.newChat,
            onClick: () => context.read(chatActionsProvider).select(null),
          ),
          // The field, with the icon drawn over its start. Still a real
          // labelled search input: the label is off screen, not gone.
          div(classes: 'relative', [
            span(
              classes:
                  'pointer-events-none absolute inset-y-0 left-2 flex '
                  'items-center text-foreground-subtlest',
              [icon(LucideIcon.search, classes: 'size-3.5')],
            ),
            label(
              [Component.text(t.desktop.desktopSearchChats)],
              htmlFor: 'chat-search',
              classes: 'sr-only',
            ),
            input<Object?>(
              id: 'chat-search',
              type: InputType.search,
              value: query,
              classes:
                  '${fieldClasses()} h-8 bg-transparent pl-7 text-ui-sm '
                  'focus-visible:bg-panel',
              attributes: <String, String>{
                'placeholder': t.desktop.desktopSearchChats,
              },
              onInput: (value) => context
                  .read(searchQueryProvider.notifier)
                  .set(numberFieldText(value)),
            ),
          ]),
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
        div(classes: 'min-h-0 flex-1 overflow-y-auto px-1 pb-2', [
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
                  ul(classes: 'space-y-px', [
                    for (final hit in results.hits)
                      _SearchRow(hit: hit, isSelected: selected == hit.chatId),
                  ]),
                if (!results.complete)
                  p(
                    classes: 'px-2 py-3 text-ui-sm text-foreground-subtle',
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
                    // With no server there is nothing to sync, and never
                    // will be: a Hermes- or direct-only setup (M7).
                    (context.watch(syncStateProvider).value?.everCompleted ??
                                true) ||
                            switch (context.watch(serverListProvider).value) {
                              final servers? => servers.activeServerId == null,
                              null => false,
                            }
                        ? t.desktop.desktopNoChatsYet
                        : t.desktop.desktopSyncing,
                  )
                : _Sections(
                    list: withOpenChat(
                      list,
                      // Never a temporary or local chat: the server was
                      // never told of those, and the list is the server's.
                      selected == null ||
                              isLocalOnlyChatId(selected) ||
                              context
                                  .watch(temporaryChatIdsProvider)
                                  .contains(selected)
                          ? null
                          : switch (context.watch(
                              chatDetailProvider.select(
                                (detail) => detail.value?.summary,
                              ),
                            )) {
                              final open? when open.id == selected => open,
                              _ => null,
                            },
                    ),
                    selected: selected,
                  )
          else if (chats.hasError)
            _hint('${chats.error}')
          else
            _hint(t.app.loadingShort),
        ]),
        // Hermes Agent's latest conversations, once it is connected (M7):
        // its sessions are not in the chat list, which is Open WebUI's.
        if (query.trim().isEmpty &&
            (context.watch(hermesSettingsProvider).value?.usable ?? false))
          _HermesRecent(selected: selected),
        // Pinned under the list rather than floating over the transcript,
        // which is where it used to sit -- on top of the send button.
        div(classes: 'shrink-0 space-y-0.5 border-t border-border px-1 pt-1', [
          const _SyncIndicator(),
          // Notes live in the Open WebUI account, so only with one (M5).
          if (context.watch(authStatusProvider).value?.isAuthenticated ?? false)
            _place(LucideIcon.notebookPen, t.app.notes, '/notes'),
          // Channels too, when the server has them switched on.
          if ((context.watch(authStatusProvider).value?.isAuthenticated ??
                  false) &&
              (context.watch(channelListProvider).value?.enabled ?? false))
            _place(LucideIcon.hash, t.app.sidebarChannelsTab, '/channels'),
          // Hermes Agent's conversations and schedules, once connected (M7).
          if (context.watch(hermesSettingsProvider).value?.usable ?? false)
            _place(LucideIcon.bot, t.app.hermesAgentSettingsTitle, '/hermes'),
          // The terminal, when the account has a terminal server (M7).
          if (terminalOffered(context.watch(terminalServersProvider).value))
            _place(LucideIcon.squareTerminal, t.app.terminal, '/terminal'),
          // The workspace, when there is a section this account may manage
          // (M6).
          if (manageableSections(
            context.watch(workspaceAccessProvider).value ??
                const WorkspaceAccess(),
          ).isNotEmpty)
            _place(LucideIcon.layers, t.app.workspaceTitle, '/workspace'),
          // A plain link rather than the router's: settings opens over the
          // window, and a reload there should land on it.
          a(href: '/settings/appearance', classes: _placeClasses, [
            icon(LucideIcon.settings),
            span(classes: 'truncate', [
              Component.text(t.desktop.desktopSettingsTitle),
            ]),
          ]),
        ]),
      ],
    );
  }

  static const String _placeClasses =
      'flex h-8 w-full items-center gap-2 rounded-md px-2 text-left '
      'text-ui-base text-foreground-subtle transition-colors '
      'hover:bg-hover hover:text-foreground';

  /// A row that goes somewhere else in the window.
  Component _place(LucideIcon glyph, String text, String to) => Link(
    to: to,
    classes: _placeClasses,
    child: Component.fragment([
      icon(glyph),
      span(classes: 'truncate', [Component.text(text)]),
    ]),
  );

  Component _placeButton({
    required LucideIcon glyph,
    required String label,
    required void Function() onClick,
  }) => button(
    [
      icon(glyph),
      span(classes: 'truncate', [Component.text(label)]),
    ],
    classes: _placeClasses,
    type: ButtonType.button,
    onClick: onClick,
  );

  Component _hint(String text) => p(
    classes: 'px-2 py-4 text-ui-sm text-foreground-subtle',
    [Component.text(text)],
  );
}

/// [list] with the open conversation in it, where its date puts it, when
/// the pages loaded so far stop short of it -- a search hit or a link can
/// open one from years ago, and the sidebar should still say which is open.
@visibleForTesting
ChatList withOpenChat(ChatList list, ChatSummary? open) {
  if (open == null || list.chats.any((chat) => chat.id == open.id)) {
    return list;
  }
  final chats = List<ChatSummary>.of(list.chats);
  final at = chats.indexWhere((chat) => chat.updatedAtMs < open.updatedAtMs);
  chats.insert(at < 0 ? chats.length : at, open);
  return list.copyWith(chats: chats);
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
    _reveal(context, model);

    return div(classes: 'space-y-3', [
      if (model.pinned.isNotEmpty)
        _section(context, 'pinned', t.app.pinned, [
          for (final chat in model.pinned) _row(chat),
        ]),
      if (model.folders.isNotEmpty)
        _section(context, 'folders', t.app.folders, [
          for (final node in model.folders) _folder(context, node, open),
        ]),
      for (final group in groupRecent(model.recent))
        _section(
          context,
          group.group.name,
          _groupLabel(group.group),
          const <Component>[],
          dropOut: true,
          body: _chunked(group.chats, 'recent-${group.group.name}'),
        ),
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
          ul(classes: 'space-y-px', [
            for (final chat in model.archived) _row(chat),
          ]),
      ],
    ]);
  }

  /// Unfolds the way to the open conversation -- its section, and the
  /// folders around it -- once each time one is opened, after this frame.
  void _reveal(BuildContext context, SidebarModel model) {
    final id = selected;
    if (id == null || context.read(revealedChatProvider) == id) return;
    final folders = folderPathTo(id, model.folders);
    final String? section;
    if (model.pinned.any((chat) => chat.id == id)) {
      section = 'pinned';
    } else if (folders != null) {
      section = 'folders';
    } else {
      section = groupRecent(model.recent)
          .where((group) => group.chats.any((chat) => chat.id == id))
          .firstOrNull
          ?.group
          .name;
    }
    if (section == null) return;
    Future<void>.microtask(() {
      context.read(revealedChatProvider.notifier).set(id);
      context.read(collapsedSectionsProvider.notifier).open(section!);
      if (folders != null) {
        context.read(expandedFoldersProvider.notifier).reveal(folders);
      }
    });
  }

  Component _row(ChatSummary chat) =>
      _ChatRow(chat: chat, isSelected: selected == chat.id);

  /// Rows past this many are drawn a chunk at a time, when near the view.
  static const int _eagerRows = 200;
  static const int _chunkRows = 100;

  /// [chats] as rows: all of them for an ordinary group, and for a big one
  /// the first [_eagerRows], then chunks drawn only when scrolled near
  /// (WP-10.1). A group of thousands otherwise rebuilt every row on every
  /// sync event, and each "Load more" took seconds.
  Component _chunked(List<ChatSummary> chats, String key) {
    if (chats.length <= _eagerRows) {
      return ul(classes: 'space-y-px', [for (final chat in chats) _row(chat)]);
    }
    return div(classes: 'space-y-px', [
      ul(classes: 'space-y-px', [
        for (final chat in chats.take(_eagerRows)) _row(chat),
      ]),
      for (var start = _eagerRows; start < chats.length; start += _chunkRows)
        // The chunk holding the open conversation is always drawn: one
        // chosen from the palette or a link must show as chosen here too.
        if (selected != null &&
            chats
                .skip(start)
                .take(_chunkRows)
                .any((chat) => chat.id == selected))
          ul(classes: 'space-y-px', [
            for (final chat in chats.skip(start).take(_chunkRows)) _row(chat),
          ])
        else
          _LazyRows(
            key: ValueKey('$key-$start'),
            id: 'rows-$key-$start',
            count: math.min(_chunkRows, chats.length - start),
            build: () => <Component>[
              for (final chat in chats.skip(start).take(_chunkRows)) _row(chat),
            ],
          ),
    ]);
  }

  /// A heading and its rows, as a real heading so a screen reader can jump
  /// between sections instead of reading two hundred titles in a row. The
  /// heading holds a button that folds the section shut, and says whether
  /// it is.
  ///
  /// With [dropOut], the section takes a conversation dragged out of a
  /// folder: the recent list is where a conversation in no folder lives.
  Component _section(
    BuildContext context,
    String key,
    String title,
    List<Component> rows, {
    bool dropOut = false,
    Component? body,
  }) {
    final collapsed = context.watch(collapsedSectionsProvider).contains(key);
    final heading = h2([
      button(
        [
          span(classes: 'truncate', [Component.text(title)]),
          icon(
            collapsed ? LucideIcon.chevronRight : LucideIcon.chevronDown,
            // Shown while folded, so a folded section looks it; on hover
            // otherwise.
            classes: collapsed
                ? 'size-3 shrink-0'
                : 'size-3 shrink-0 opacity-0 transition-opacity '
                      'group-hover/section:opacity-100 '
                      'group-focus-within/section:opacity-100',
          ),
        ],
        id: 'section-$key',
        classes:
            'flex h-6 w-full items-center gap-1 rounded-md px-2 text-left '
            '$sectionLabelClasses hover:text-foreground',
        type: ButtonType.button,
        attributes: <String, String>{
          'aria-expanded': collapsed ? 'false' : 'true',
          'aria-controls': 'section-body-$key',
        },
        onClick: () =>
            context.read(collapsedSectionsProvider.notifier).toggle(key),
      ),
    ]);
    final list = div(
      id: 'section-body-$key',
      classes: collapsed ? 'hidden' : null,
      [body ?? ul(classes: 'space-y-px', rows)],
    );
    if (!dropOut) {
      return section(classes: 'group/section', [heading, list]);
    }
    final dragging = context.watch(draggingChatProvider);
    bool accepts() => context.read(draggingChatProvider)?.chat.folderId != null;
    return section(
      classes:
          'group/section rounded-md'
          '${dragging?.over == '' ? ' bg-selected' : ''}',
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
      [heading, list],
    );
  }

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
              'flex h-7 w-full items-center rounded-md text-ui-base '
              'text-foreground-subtle transition-colors hover:bg-hover '
              'hover:text-foreground'
              '${target ? ' bg-selected ring-1 ring-ring' : ''}'
              '${context.watch(openFolderProvider) == folderId ? ' bg-selected text-foreground' : ''}',
          [
            button(
              [
                icon(
                  isOpen ? LucideIcon.chevronDown : LucideIcon.chevronRight,
                  classes: 'size-3.5',
                ),
              ],
              classes:
                  'flex h-7 w-6 shrink-0 items-center justify-center pl-1 '
                  'text-foreground-subtlest hover:text-foreground',
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
                icon(
                  isOpen ? LucideIcon.folderOpen : LucideIcon.folder,
                  classes: 'size-3.5 shrink-0',
                ),
                span(classes: 'min-w-0 flex-1 truncate', [
                  Component.text(node.folder.name),
                ]),
                span(
                  classes: 'text-ui-xs tabular-nums text-foreground-subtle',
                  [Component.text('${node.totalChats}')],
                ),
              ],
              classes:
                  'flex h-7 min-w-0 flex-1 items-center gap-1.5 pr-2 '
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
          ul(classes: 'ml-3.5 space-y-px border-l border-border pl-1', [
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
    [
      if (expanded != null)
        icon(
          expanded ? LucideIcon.chevronDown : LucideIcon.chevronRight,
          classes: 'size-3.5',
        ),
      span(classes: 'truncate', [Component.text(label)]),
    ],
    classes:
        'flex h-7 w-full items-center gap-1.5 rounded-md px-2 text-left '
        'text-ui-sm text-foreground-subtle transition-colors hover:bg-hover '
        'hover:text-foreground',
    type: ButtonType.button,
    attributes: <String, String>{
      if (expanded != null) 'aria-expanded': expanded ? 'true' : 'false',
    },
    onClick: onClick,
  );

  static String _groupLabel(RecentGroup group) => switch (group) {
    RecentGroup.today => t.app.today,
    RecentGroup.yesterday => t.app.yesterday,
    RecentGroup.earlier => t.desktop.desktopEarlier,
  };
}

/// A chunk of sidebar rows, drawn only while near the view: otherwise one
/// empty list of about the same height, so the scrollbar stays honest.
class _LazyRows extends StatefulComponent {
  const _LazyRows({
    required this.id,
    required this.count,
    required this.build,
    super.key,
  });

  final String id;
  final int count;
  final List<Component> Function() build;

  /// A row's height with its gap: `text-ui-base` with `py-1.5`, and `space-y-0.5`.
  static const int rowHeight = 34;

  @override
  State<_LazyRows> createState() => _LazyRowsState();
}

class _LazyRowsState extends State<_LazyRows> {
  bool _near = false;
  void Function()? _stop;

  @override
  void initState() {
    super.initState();
    // Once the element exists to be observed.
    Future<void>.microtask(() {
      if (!mounted) return;
      _stop = context.read(windowCommandsProvider).observeNearView(
        component.id,
        (near) {
          if (mounted && near != _near) setState(() => _near = near);
        },
      );
    });
  }

  @override
  void dispose() {
    _stop?.call();
    super.dispose();
  }

  @override
  Component build(BuildContext context) => ul(
    id: component.id,
    classes: 'space-y-0.5',
    styles: _near
        ? null
        : Styles(
            raw: <String, String>{
              'height': '${component.count * _LazyRows.rowHeight}px',
            },
          ),
    attributes: <String, String>{
      // How many rows it stands for, drawn or not.
      'data-count': '${component.count}',
      if (!_near) 'aria-hidden': 'true',
    },
    _near ? component.build() : const <Component>[],
  );
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
          'px-2 py-1 text-ui-sm '
          '${detail == null ? 'text-foreground-subtle' : 'text-destructive'}',
      // `status`, so the change is announced without interrupting.
      attributes: <String, String>{'role': 'status', 'title': ?detail},
      [Component.text(text)],
    );
  }
}

/// The latest Hermes conversations, under the chat list. All of them are
/// on the Hermes page.
class _HermesRecent extends StatelessComponent {
  const _HermesRecent({required this.selected});

  final String? selected;

  @override
  Component build(BuildContext context) {
    final sessions =
        context.watch(hermesSessionsProvider).value?.sessions ??
        const <HermesSessionDto>[];
    if (sessions.isEmpty) return const Component.fragment([]);
    return section(
      classes: 'group/section shrink-0 border-t border-border px-1 py-2',
      // Named by its heading, "Hermes Agent": the Hermes page has its own
      // "Conversations" beside it.
      attributes: const <String, String>{
        'aria-labelledby': 'sidebar-hermes-heading',
      },
      [
        h2(
          id: 'sidebar-hermes-heading',
          classes: 'flex h-6 items-center px-2 $sectionLabelClasses',
          [Component.text(t.app.hermesAgentSettingsTitle)],
        ),
        ul(classes: 'space-y-px', [
          for (final session in sessions.take(5))
            li([
              button(
                [
                  Component.text(
                    session.title.isEmpty
                        ? t.app.hermesSessionUntitled
                        : session.title,
                  ),
                ],
                classes:
                    'block h-7 w-full truncate rounded-md px-2 text-left '
                    'text-ui-base transition-colors '
                    '${selected == session.chatId ? 'bg-selected text-foreground' : 'text-foreground-subtle hover:bg-hover hover:text-foreground'}',
                type: ButtonType.button,
                onClick: () =>
                    context.read(chatActionsProvider).select(session.chatId),
              ),
            ]),
        ]),
      ],
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
        span(classes: 'block truncate text-ui-base', [
          Component.text(hit.title),
        ]),
        if (hit.snippet case final snippet?)
          span(classes: 'block truncate text-ui-sm text-foreground-subtle', [
            // The index's own snippet. Re-deriving one here would mean
            // reimplementing the tokenizer to agree with it.
            Component.text(snippet),
          ]),
      ],
      classes:
          'block w-full rounded-md px-2 py-1 text-left transition-colors '
          '${isSelected ? 'bg-selected text-foreground' : 'text-foreground hover:bg-hover'}',
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
  static const Styles _rowSkippable = Styles(
    raw: <String, String>{
      'content-visibility': 'auto',
      'contain-intrinsic-size': 'auto 28px',
    },
  );

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
      return li(classes: 'rounded-md px-2 py-1 hover:bg-hover', [
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
      // Skipped off screen, as the transcript's messages are: a big account
      // lists thousands of rows (WP-10.1). But not while the right-click
      // menu is open -- `content-visibility` contains paint, which makes the
      // row the box a `fixed` child is placed in, and the menu would be
      // clipped to it.
      styles: _menuAt == null ? _rowSkippable : null,
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
              if (isShareableChatId(chat.id))
                ContextMenuItem(
                  t.app.shareChat,
                  () =>
                      context.read(shareDialogProvider.notifier).open(chat.id),
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
          classes: 'relative flex items-center',
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
                _statusDot(
                  context.watch(
                    chatActivityProvider.select((all) => all[chat.id]),
                  ),
                ),
                span(classes: 'min-w-0 flex-1 truncate', [
                  Component.text(chat.title),
                ]),
              ],
              classes:
                  'flex h-7 min-w-0 flex-1 items-center gap-1.5 rounded-md '
                  'pr-2 pl-1 text-left text-ui-base transition-colors '
                  '${component.isSelected ? 'bg-selected text-foreground' : 'text-foreground-subtle group-hover:bg-hover group-hover:text-foreground'}',
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
                'mx-1 mt-1 rounded-lg border border-destructive/40 '
                'bg-destructive/10 p-2 text-ui-sm',
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
                  classes: buttonClasses(
                    tone: ButtonTone.destructive,
                    size: ControlSize.sm,
                  ),
                  type: ButtonType.button,
                  onClick: () {
                    setState(() => _confirmingDelete = false);
                    unawaited(actions.delete(chat.id));
                  },
                ),
                button(
                  [Component.text(t.app.cancel)],
                  classes: buttonClasses(
                    tone: ButtonTone.ghost,
                    size: ControlSize.sm,
                  ),
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
        // Over the end of the title, fading it out; only the buttons take
        // the pointer, so the fade does not swallow a click on the row.
        'pointer-events-none absolute inset-y-0 right-0.5 flex items-center '
        'gap-px pl-4 opacity-0 transition-opacity group-hover:opacity-100 '
        'group-focus-within:opacity-100 bg-linear-to-r from-transparent '
        'via-window via-30% to-window',
    attributes: <String, String>{
      'role': 'group',
      'aria-label': t.desktop.desktopChatActions(title: chat.title),
    },
    [
      _action(
        label: chat.pinned
            ? t.desktop.desktopUnpinChat
            : t.desktop.desktopPinChat,
        glyph: chat.pinned ? LucideIcon.pinOff : LucideIcon.pin,
        onClick: () =>
            unawaited(actions.setPinned(chat.id, value: !chat.pinned)),
      ),
      _action(
        label: t.desktop.desktopRenameChat,
        glyph: LucideIcon.pencil,
        onClick: () => setState(() {
          _renaming = true;
          _draftTitle = chat.title;
        }),
      ),
      _action(
        // The same action both ways, so it has to say which way. An
        // archived chat offering "Archive" reads as already failed.
        label: chat.archived ? t.app.unarchive : t.desktop.desktopArchiveChat,
        glyph: LucideIcon.archive,
        onClick: () =>
            unawaited(actions.setArchived(chat.id, value: !chat.archived)),
      ),
      _action(
        label: t.desktop.desktopDeleteChat,
        glyph: LucideIcon.trash,
        destructive: true,
        onClick: () => setState(() => _confirmingDelete = true),
      ),
    ],
  );

  Component _action({
    required String label,
    required LucideIcon glyph,
    required void Function() onClick,
    bool destructive = false,
  }) => button(
    [icon(glyph, classes: 'size-3.5')],
    classes:
        'pointer-events-auto inline-flex size-6 items-center justify-center '
        'rounded-md text-foreground-subtle transition-colors '
        '${destructive ? 'hover:bg-destructive/10 hover:text-destructive' : 'hover:bg-hover hover:text-foreground'}',
    type: ButtonType.button,
    attributes: <String, String>{
      'aria-label': label,
      ...tooltipAttributes(label),
    },
    onClick: onClick,
  );

  /// The row's status: an answer being written, one finished or failed
  /// while the conversation was not on screen, or nothing. A dot for the
  /// eye, and words for a screen reader.
  static Component _statusDot(ChatActivity? activity) => span(
    classes: 'relative flex size-3 shrink-0 items-center justify-center',
    [
      if (activity != null) ...[
        span(
          classes:
              'size-1.5 rounded-full '
              '${switch (activity) {
                ChatActivity.running => 'animate-pulse bg-foreground-subtle',
                ChatActivity.unread => 'bg-info',
                ChatActivity.failed => 'bg-destructive',
              }}',
          const [],
        ),
        span(classes: 'sr-only', [
          Component.text(switch (activity) {
            ChatActivity.running => t.desktop.desktopChatRunning,
            ChatActivity.unread => t.desktop.desktopChatUnread,
            ChatActivity.failed => t.desktop.desktopChatFailed,
          }),
        ]),
      ],
    ],
  );
}
