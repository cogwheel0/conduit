import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';

import '../l10n/strings.g.dart';
import '../pages/notes_page.dart';
import '../pages/terminal_page.dart';
import '../rpc/chat_providers.dart';
import '../rpc/layout_providers.dart';
import '../rpc/notes_providers.dart';
import '../rpc/session_providers.dart';
import '../rpc/terminal_providers.dart';
import 'code_block.dart';
import 'controls_pane.dart';
import 'html_preview.dart';
import 'ui.dart';

/// The pane beside a conversation: its own tab
/// bar over controls and sources, the terminal's files and ports, notes,
/// and a preview of pages the answers wrote.
///
/// A tab only shows where it can do something: the terminal with a
/// terminal server, notes with an Open WebUI account.
class SidePane extends StatelessComponent {
  const SidePane({
    required this.chatId,
    required this.detail,
    this.controls = true,
    super.key,
  });

  final String chatId;
  final ChatDetail detail;

  /// Whether the conversation has server-kept settings to show: not a
  /// temporary chat, or one kept only on this computer.
  final bool controls;

  @override
  Component build(BuildContext context) {
    final terminals = context.watch(terminalServersProvider).value;
    final signedIn =
        context.watch(authStatusProvider).value?.isAuthenticated ?? false;
    final tabs = <UiTab>[
      if (controls)
        UiTab(
          id: SidePaneTab.controls.name,
          label: t.desktop.desktopControls,
          glyph: LucideIcon.slidersHorizontal,
        ),
      if (terminalOffered(terminals))
        UiTab(
          id: SidePaneTab.terminal.name,
          label: t.app.terminal,
          glyph: LucideIcon.squareTerminal,
        ),
      if (signedIn)
        UiTab(
          id: SidePaneTab.notes.name,
          label: t.app.notes,
          glyph: LucideIcon.notebookPen,
        ),
      UiTab(
        id: SidePaneTab.preview.name,
        label: t.desktop.desktopPreview,
        glyph: LucideIcon.eye,
      ),
    ];
    final wanted = context.watch(workspaceLayoutProvider).sidePaneTab;
    final tab = tabs.any((candidate) => candidate.id == wanted.name)
        ? wanted
        : SidePaneTab.values.byName(tabs.first.id);

    return div(classes: 'flex min-h-0 flex-1 flex-col', [
      div(
        classes:
            'flex h-11 shrink-0 items-center gap-1 border-b border-border '
            'bg-header pr-1 pl-1.5',
        [
          TabStrip(
            idPrefix: 'side-pane',
            label: t.desktop.desktopSidePane,
            tabs: tabs,
            selected: tab.name,
            classes: 'min-w-0 flex-1 overflow-x-auto',
            onSelect: (id) => context
                .read(workspaceLayoutProvider.notifier)
                .showTab(SidePaneTab.values.byName(id)),
          ),
          iconButton(
            id: 'close-side-pane',
            glyph: LucideIcon.x,
            label: t.desktop.desktopClosePane,
            tooltip: TooltipSide.left,
            onClick: () => context.read(controlsOpenProvider.notifier).close(),
          ),
        ],
      ),
      div(
        id: 'side-pane-panel-${tab.name}',
        classes: 'flex min-h-0 flex-1 flex-col',
        attributes: <String, String>{
          'role': 'tabpanel',
          'aria-labelledby': 'side-pane-tab-${tab.name}',
        },
        [
          switch (tab) {
            // Keyed on the conversation, so switching chats reseeds the
            // field instead of carrying one chat's draft into the next.
            SidePaneTab.controls => ControlsPane(
              key: ValueKey('controls-$chatId'),
              chatId: chatId,
              systemPrompt: detail.systemPrompt,
              sources: conversationSources(detail.messages),
            ),
            SidePaneTab.terminal => _TerminalTab(servers: terminals!),
            SidePaneTab.notes => const _NotesTab(),
            SidePaneTab.preview => _PreviewTab(
              key: ValueKey('preview-$chatId'),
              pages: previewablePages(detail.messages),
            ),
          },
        ],
      ),
    ]);
  }
}

/// Every source the conversation's answers cite, each once, in the order
/// they were first cited.
List<ChatSourceDto> conversationSources(List<ChatMessageDto> messages) {
  final seen = <String>{};
  return <ChatSourceDto>[
    for (final message in messages)
      for (final source in message.sources)
        if (seen.add(source.url ?? source.label)) source,
  ];
}

final RegExp _fence = RegExp(r'```([^\n`]*)\n([\s\S]*?)```');

/// The pages the answers wrote -- fenced HTML -- oldest first.
List<String> previewablePages(List<ChatMessageDto> messages) => <String>[
  for (final message in messages)
    if (message.role == 'assistant')
      for (final match in _fence.allMatches(message.content))
        if (CodeBlock.isPreviewable(match.group(1))) match.group(2)!,
];

/// The terminal's files and ports, with the shell a button away in a frame
/// under the conversation.
class _TerminalTab extends StatelessComponent {
  const _TerminalTab({required this.servers});

  final TerminalServers servers;

  @override
  Component build(BuildContext context) {
    final open = context.watch(shellOpenProvider);
    return div(classes: 'flex min-h-0 flex-1 flex-col', [
      div(classes: 'shrink-0 px-3 pt-3', [
        uiButton(
          id: 'toggle-shell',
          text: open ? t.desktop.desktopCloseShell : t.desktop.desktopOpenShell,
          leading: LucideIcon.squareTerminal,
          size: ControlSize.sm,
          attributes: <String, String>{'aria-pressed': '$open'},
          onClick: () =>
              context.read(shellOpenProvider.notifier).set(open: !open),
        ),
      ]),
      TerminalWorkspace(servers: servers, layout: TerminalLayout.files),
    ]);
  }
}

/// Notes beside the conversation: the list, or one note open to edit.
class _NotesTab extends StatelessComponent {
  const _NotesTab();

  @override
  Component build(BuildContext context) {
    final open = context.watch(paneNoteProvider);
    if (open != null) {
      return div(classes: 'flex min-h-0 flex-1 flex-col', [
        div(classes: 'shrink-0 px-2 pt-2', [
          uiButton(
            text: t.desktop.desktopAllNotes,
            leading: LucideIcon.arrowLeft,
            tone: ButtonTone.ghost,
            size: ControlSize.sm,
            onClick: () => context.read(paneNoteProvider.notifier).open(null),
          ),
        ]),
        NoteEditorPane(
          key: ValueKey('pane-note-$open'),
          id: open,
          compact: true,
          onDeleted: () => context.read(paneNoteProvider.notifier).open(null),
        ),
      ]);
    }
    final notes =
        context.watch(noteListProvider).value?.notes ?? const <NoteSummary>[];
    return div(classes: 'flex min-h-0 flex-1 flex-col gap-2 p-3', [
      uiButton(
        text: t.app.createNote,
        leading: LucideIcon.plus,
        size: ControlSize.sm,
        classes: 'self-start',
        onClick: () async {
          // Read now: after the await this tab may be gone.
          final pane = context.read(paneNoteProvider.notifier);
          final created = await context
              .read(noteActionsProvider)
              .save(const NoteSave(title: ''));
          pane.open(created.summary.id);
        },
      ),
      if (notes.isEmpty)
        p(classes: 'text-ui-sm text-foreground-subtle', [
          Component.text(t.app.noNotesYet),
        ])
      else
        ul(classes: 'min-h-0 flex-1 space-y-px overflow-y-auto', [
          for (final note in notes)
            li([
              button(
                [
                  span(classes: 'block truncate text-ui-base', [
                    Component.text(
                      note.title.isEmpty ? t.app.untitled : note.title,
                    ),
                  ]),
                  if (note.preview.isNotEmpty)
                    span(
                      classes:
                          'block truncate text-ui-sm text-foreground-subtle',
                      [Component.text(note.preview)],
                    ),
                ],
                classes:
                    'block w-full rounded-md px-2 py-1.5 text-left '
                    'transition-colors hover:bg-hover',
                type: ButtonType.button,
                onClick: () =>
                    context.read(paneNoteProvider.notifier).open(note.id),
              ),
            ]),
        ]),
    ]);
  }
}

/// The pages the answers wrote, one at a time, rendered as inertly as the
/// transcript's own preview: no scripts, no network.
class _PreviewTab extends StatefulComponent {
  const _PreviewTab({required this.pages, super.key});

  final List<String> pages;

  @override
  State<_PreviewTab> createState() => _PreviewTabState();
}

class _PreviewTabState extends State<_PreviewTab> {
  /// Which page, counted from the newest: a new answer's page shows as it
  /// arrives rather than the one that was being read being swapped out.
  int _fromNewest = 0;

  @override
  Component build(BuildContext context) {
    final pages = component.pages;
    if (pages.isEmpty) {
      return p(classes: 'p-3 text-ui-sm text-foreground-subtle', [
        Component.text(t.desktop.desktopNoPreview),
      ]);
    }
    final back = _fromNewest.clamp(0, pages.length - 1);
    final index = pages.length - 1 - back;
    return div(classes: 'flex min-h-0 flex-1 flex-col', [
      if (pages.length > 1)
        div(
          classes:
              'flex shrink-0 items-center justify-end gap-0.5 border-b '
              'border-border px-2 py-1 text-ui-xs text-foreground-subtle',
          [
            iconButton(
              glyph: LucideIcon.chevronLeft,
              label: t.desktop.desktopPreviousPreview,
              disabled: index == 0,
              onClick: () => setState(() => _fromNewest = back + 1),
            ),
            span(classes: 'tabular-nums', [
              Component.text(
                t.desktop.desktopPreviewPosition(
                  index: index + 1,
                  count: pages.length,
                ),
              ),
            ]),
            iconButton(
              glyph: LucideIcon.chevronRight,
              label: t.desktop.desktopNextPreview,
              disabled: back == 0,
              onClick: () => setState(() => _fromNewest = back - 1),
            ),
          ],
        ),
      HtmlPreview(key: ValueKey('page-$index'), html: pages[index], fill: true),
    ]);
  }
}
