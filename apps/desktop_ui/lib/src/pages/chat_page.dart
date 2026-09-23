import 'dart:async';
import 'dart:math' as math;

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';

import '../attachments.dart';
import '../keyboard.dart';
import '../palette.dart';
import '../prompt_trigger.dart';
import '../l10n/strings.g.dart';
import '../rpc/chat_providers.dart';
import '../rpc/rpc_providers.dart';
import '../rpc/session_providers.dart';
import '../rpc/layout_providers.dart';
import '../rpc/terminal_providers.dart';
import '../rpc/voice_providers.dart';
import '../voice.dart';
import '../widgets/form_field.dart';
import '../widgets/chat_tags.dart';
import '../widgets/desktop_integration.dart' show composerPrefillProvider;
import '../widgets/folder_page.dart';
import '../widgets/markdown_view.dart';
import '../widgets/mcp_content_sheet.dart';
import '../widgets/message_files.dart';
import '../widgets/prompt_menu.dart';
import '../widgets/share_dialog.dart';
import '../widgets/side_pane.dart';
import '../widgets/sources_list.dart';
import '../widgets/usage_details.dart';
import '../widgets/ui.dart';
import '../widgets/voice_controls.dart';
import '../widgets/workspace_frame.dart';
import 'terminal_page.dart'
    show TerminalLayout, TerminalWorkspace, terminalOffered;

/// The chat vertical: the conversation frame -- header, transcript,
/// composer -- and the side pane's frame beside it (M3; the frames are
/// docs/desktop/REDESIGN.md's). The sidebar is the workspace's.
class ChatPage extends StatelessComponent {
  const ChatPage({super.key});

  @override
  Component build(BuildContext context) {
    final selected = context.watch(selectedChatIdProvider);
    final temporaryIds = context.watch(temporaryChatIdsProvider);
    // The pane is for any open conversation; its Controls tab only for
    // one the server keeps, since that is where the settings are saved.
    final showPane = context.watch(controlsOpenProvider) && selected != null;
    final serverChat =
        selected != null &&
        !temporaryIds.contains(selected) &&
        !isLocalOnlyChatId(selected);
    final detail = showPane ? context.watch(chatDetailProvider).value : null;
    final lightbox = context.watch(lightboxProvider);
    final folderOpen = context.watch(openFolderProvider) != null;
    final layout = context.watch(workspaceLayoutProvider);
    final sidePane = showPane && detail != null && !folderOpen;
    final terminals = context.watch(terminalServersProvider).value;
    final shell =
        context.watch(shellOpenProvider) &&
        !folderOpen &&
        terminals != null &&
        terminalOffered(terminals);
    return div(classes: 'flex min-h-0 min-w-0 flex-1', [
      div(classes: 'flex min-h-0 min-w-0 flex-1 flex-col', [
        div(classes: '$frameClasses flex-1', [
          if (folderOpen) const FolderPage() else const _Transcript(),
        ]),
        // The shell, in a frame of its own under the conversation.
        if (shell) ...[
          ResizeHandle(
            id: 'resize-shell',
            label: t.desktop.desktopResizeShell,
            value: layout.shellHeight,
            min: WorkspaceLayout.shellHeights.min,
            max: WorkspaceLayout.shellHeights.max,
            horizontal: true,
            onResize: context
                .read(workspaceLayoutProvider.notifier)
                .setShellHeight,
          ),
          div(
            classes: '$frameClasses shrink-0',
            styles: Styles(
              raw: <String, String>{'height': '${layout.shellHeight}px'},
            ),
            [
              div(
                classes:
                    'flex h-8 shrink-0 items-center gap-2 border-b '
                    'border-border bg-header pr-1 pl-3 text-ui-sm '
                    'text-foreground-subtle',
                [
                  icon(LucideIcon.squareTerminal, classes: 'size-3.5'),
                  span(classes: 'flex-1', [
                    Component.text(t.desktop.desktopShell),
                  ]),
                  iconButton(
                    id: 'close-shell',
                    glyph: LucideIcon.x,
                    label: t.desktop.desktopCloseShell,
                    tooltip: TooltipSide.left,
                    onClick: () => context
                        .read(shellOpenProvider.notifier)
                        .set(open: false),
                  ),
                ],
              ),
              TerminalWorkspace(
                servers: terminals,
                layout: TerminalLayout.console,
              ),
            ],
          ),
        ],
      ]),
      if (lightbox != null)
        LightboxOverlay(
          key: ValueKey(lightbox.src),
          src: lightbox.src,
          name: lightbox.name,
        ),
      if (sidePane) ...[
        ResizeHandle(
          id: 'resize-side-pane',
          label: t.desktop.desktopResizeSidePane,
          value: layout.sidePaneWidth,
          min: WorkspaceLayout.sidePaneWidths.min,
          max: WorkspaceLayout.sidePaneWidths.max,
          growsLeft: false,
          onResize: context
              .read(workspaceLayoutProvider.notifier)
              .setSidePaneWidth,
        ),
        div(
          classes: '$frameClasses shrink-0',
          styles: Styles(
            raw: <String, String>{'width': '${layout.sidePaneWidth}px'},
          ),
          [SidePane(chatId: selected, detail: detail, controls: serverChat)],
        ),
      ],
    ]);
  }
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
    context.watch(transcriptWindowProvider);
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
            'flex h-11 shrink-0 items-center gap-2 border-b border-border '
            'bg-header pr-2 pl-4 text-ui-base font-medium text-foreground',
        [
          // A conversation the list has not caught up with yet is a
          // conversation this window just created.
          span(classes: 'min-w-0 truncate', [
            Component.text(title ?? t.desktop.desktopNewConversation),
          ]),
          // Said where the conversation is named, not only at the toggle.
          // Someone who scrolls back through a temporary chat an hour later
          // should not have to remember that it will not be kept.
          if (temporaryIds.contains(selected) ||
              (selected == null && context.watch(temporaryChatProvider)))
            span(
              classes:
                  'shrink-0 rounded-full bg-surface px-2 py-0.5 '
                  'text-ui-xs font-normal text-foreground-subtle',
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
          if (selected != null) ...[
            div(classes: 'min-w-0 flex-1', const []),
            if (!temporaryIds.contains(selected) &&
                !isLocalOnlyChatId(selected) &&
                isShareableChatId(selected))
              iconButton(
                id: 'share-chat',
                glyph: LucideIcon.share2,
                label: t.app.shareChat,
                onClick: () =>
                    context.read(shareDialogProvider.notifier).open(selected),
              ),
            // Beside the pane it opens, rather than in the window's bar.
            iconButton(
              id: 'toggle-side-pane',
              glyph: LucideIcon.panelRight,
              label: t.desktop.desktopSidePane,
              pressed: context.watch(controlsOpenProvider),
              tooltip: TooltipSide.left,
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
              'flex shrink-0 items-center gap-2 border-b border-border '
              'bg-surface px-4 py-1.5 text-ui-sm text-foreground-subtle',
          attributes: const <String, String>{'role': 'status'},
          [
            icon(LucideIcon.wifiOff, classes: 'size-3.5 shrink-0'),
            Component.text(t.desktop.desktopOffline),
          ],
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
        classes: 'min-h-0 flex-1 overflow-y-auto px-6 pt-6 pb-4',
        // `log` so a screen reader announces arriving messages without the
        // user having to go looking for them, and politely enough not to
        // interrupt what they are reading.
        attributes: const <String, String>{
          'role': 'log',
          'aria-live': 'polite',
        },
        [
          if (nothingChosen) _emptyState(),
          div(classes: 'mx-auto flex max-w-3xl flex-col gap-6', [
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
                    final kept = cut < 0 ? all : all.sublist(0, cut);
                    // The latest messages only; older ones on request.
                    final limit = context
                        .read(transcriptWindowProvider.notifier)
                        .countFor(selected);
                    final hidden = math.max(0, kept.length - limit);
                    final shown = hidden == 0 ? kept : kept.sublist(hidden);
                    return <Component>[
                      if (hidden > 0)
                        div(classes: 'flex justify-center', [
                          button(
                            [
                              Component.text(
                                t.desktop.desktopLoadOlderMessages,
                              ),
                            ],
                            id: 'transcript-older',
                            classes: buttonClasses(size: ControlSize.sm),
                            type: ButtonType.button,
                            onClick: () => context
                                .read(transcriptWindowProvider.notifier)
                                .more(selected),
                          ),
                        ]),
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
                            readAloud: message.role == 'assistant'
                                ? ReadAloudButton(
                                    id: message.id,
                                    text: _shownContent(
                                      message,
                                      versions[message.id],
                                    ),
                                  )
                                : null,
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
      p(classes: 'text-ui-xl font-medium text-foreground', [
        Component.text(t.desktop.desktopPickAConversation),
      ]),
      p(classes: 'text-ui-base text-foreground-subtle', [
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
    Component? readAloud,
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
        // A question is a quiet bubble on the right; an answer is the page
        // itself, full width, as reading it is what the window is for.
        article(
          classes:
              'text-ui-base leading-relaxed '
              '${isUser ? 'ml-auto max-w-[80%] rounded-xl bg-muted px-3.5 py-2 text-foreground whitespace-pre-wrap' : 'w-full min-w-0 text-foreground'} '
              '${failed ? 'rounded-xl border border-destructive/50 px-3.5 py-2' : ''}',
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
                    '${content.isEmpty ? '' : 'mt-2 '}text-ui-base text-destructive',
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
          div(classes: 'mr-auto flex w-full items-start gap-4', [
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
          div(classes: 'flex items-center gap-0.5 text-foreground-subtle', [
            // Always visible, unlike the actions beside it. That there
            // *are* other answers is information in itself, and hiding it
            // behind a hover means nobody finds out.
            ?versionNav,
            ?readAloud,
            div(
              classes:
                  'flex gap-0.5 opacity-0 transition-opacity '
                  'group-hover:opacity-100 group-focus-within:opacity-100',
              [
                if (onCopy case final copy?)
                  iconAction(
                    glyph: LucideIcon.copy,
                    label: t.app.copy,
                    onClick: copy,
                  ),
                if (onRegenerate case final again?)
                  iconAction(
                    glyph: LucideIcon.refreshCw,
                    label: t.app.regenerate,
                    onClick: again,
                  ),
                if (onEdit case final edit?)
                  iconAction(
                    glyph: LucideIcon.pencil,
                    label: t.app.edit,
                    onClick: edit,
                  ),
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
                    LucideIcon.thumbsUp,
                    pressed: rating == 1,
                    onClick: () => rate(1),
                  ),
                  _rateButton(
                    t.desktop.desktopBadResponse,
                    LucideIcon.thumbsDown,
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
    Component arrow(LucideIcon glyph, String label, int? target) => iconButton(
      glyph: glyph,
      label: label,
      disabled: target == null,
      onClick: target == null ? null : () => show(target),
    );
    return div(
      classes: 'flex items-center text-ui-sm text-foreground-subtle',
      attributes: <String, String>{
        'role': 'group',
        'aria-label': t.desktop.desktopAnswerPosition(
          index: index + 1,
          count: count,
        ),
      },
      [
        arrow(
          LucideIcon.chevronLeft,
          t.desktop.desktopPreviousAnswer,
          index > 0 ? index - 1 : null,
        ),
        span(classes: 'px-0.5 text-ui-xs tabular-nums', [
          Component.text('${index + 1}/$count'),
        ]),
        arrow(
          LucideIcon.chevronRight,
          t.desktop.desktopNextAnswer,
          index < count - 1 ? index + 1 : null,
        ),
      ],
    );
  }

  Component _rateButton(
    String label,
    LucideIcon glyph, {
    required bool pressed,
    required void Function() onClick,
  }) => iconButton(
    glyph: glyph,
    label: label,
    pressed: pressed,
    onClick: onClick,
    classes: pressed ? 'text-foreground' : '',
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
  Component build(BuildContext context) =>
      div(classes: 'ml-auto flex w-full max-w-[80%] flex-col gap-2', [
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
            classes: buttonClasses(tone: ButtonTone.ghost),
            type: ButtonType.button,
            onClick: component.onCancel,
          ),
          button(
            [Component.text(t.app.send)],
            classes: buttonClasses(tone: ButtonTone.primary),
            type: ButtonType.button,
            // Unchanged text would branch the conversation to ask the same
            // thing again, which is what Regenerate is for.
            disabled: !_changed,
            onClick: () => component.onSave(_text.trim()),
          ),
        ]),
      ]);
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

  /// Whether the terminal chooser is open (M7).
  bool _terminalOpen = false;
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

  /// What dictation hears, into the field (WP-8.1).
  StreamSubscription<String>? _dictated;

  @override
  void initState() {
    super.initState();
    _dictated = context
        .read(dictationProvider.notifier)
        .results
        .listen(_insertDictation);
  }

  @override
  void dispose() {
    unawaited(_dictated?.cancel());
    super.dispose();
  }

  void _insertDictation(String text) {
    if (!mounted) return;
    final joined = _text.trim().isEmpty ? text : '${_text.trimRight()} $text';
    setState(() => _text = joined);
    final commands = context.read(windowCommandsProvider)
      ..setValue('composer', joined);
    if (context.read(voiceSettingsProvider).value?.autoSend ?? false) {
      unawaited(_send(context));
    } else {
      commands.focus('composer');
    }
  }

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

    // A `conduit://new?q=` link, or a quick ask continued here (M9).
    if (context.watch(composerPrefillProvider) != null) {
      Future<void>.microtask(() {
        if (!mounted) return;
        final draft = context.read(composerPrefillProvider.notifier).take();
        if (draft == null) return;
        setState(() {
          if (draft.text case final text?) _text = text;
          // Uploaded already, by the shell: attached and ready.
          for (final file in draft.files) {
            _attachments.add(
              _Attachment(
                  PickedAttachment(
                    handle: 'opened-${file.id}',
                    name: file.name,
                    size: file.size,
                    contentType: file.contentType ?? '',
                  ),
                )
                ..id = file.id
                ..progress = 1,
            );
          }
        });
        final commands = context.read(windowCommandsProvider);
        if (draft.text case final text?) commands.setValue('composer', text);
        commands.focus('composer');
      });
    }

    // Voice needs something to transcribe it: the server (M8), or whisper
    // on this computer (M11).
    final voiceSettings = context.watch(voiceSettingsProvider).value;
    final voice = voiceSettings != null && canTranscribe(voiceSettings);
    final dictationProblem = dictationProblemText(
      context.watch(dictationProvider).problem,
    );

    return div(
      key: const ValueKey('composer'),
      classes: 'shrink-0 px-4 pt-1 pb-3',
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
        // Always in the tree: it watches the call, which keeps the call
        // following its answer.
        const VoiceCallPanel(),
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
        form(
          [
            // One shell for everything that goes with the message: what is
            // attached, the field, and the controls for how it is sent.
            div(
              classes:
                  'mx-auto max-w-3xl rounded-2xl border bg-panel shadow-sm '
                  'transition-colors focus-within:border-ring '
                  'focus-within:ring-1 focus-within:ring-ring '
                  '${_dragDepth > 0 ? 'border-ring ring-2 ring-ring/30' : 'border-border'}',
              [
                if (_atModel case final model?)
                  div(classes: 'flex px-3 pt-2.5', [
                    span(
                      classes:
                          'flex items-center gap-1 rounded-full border border-border '
                          'py-0.5 pl-2 pr-1 text-ui-sm text-foreground-subtle',
                      [
                        Component.text(
                          t.desktop.desktopAnswerWith(model: modelLabel(model)),
                        ),
                        button(
                          [
                            span(
                              attributes: const <String, String>{
                                'aria-hidden': 'true',
                              },
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
                    classes: 'flex flex-wrap gap-1.5 px-3 pt-2.5',
                    attributes: <String, String>{
                      'aria-label': t.app.attachments,
                    },
                    [
                      for (final attachment in _attachments)
                        _chip(context, attachment),
                      for (final knowledge in _knowledge)
                        span(
                          classes:
                              'flex items-center gap-1 rounded-full border '
                              'border-border py-0.5 pl-2 pr-1 text-ui-sm',
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
                              classes: 'rounded-full px-1 hover:bg-hover',
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
                div(classes: 'px-1', [
                  textAreaField(
                    id: 'composer',
                    labelText: t.app.sendMessage,
                    placeholder: t.app.messageHintText,
                    hideLabel: true,
                    value: _text,
                    rows: 2,
                    bare: true,
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
                          : _chooseKnowledge(
                              context,
                              knowledgeHits[highlighted],
                            ),
                      dismiss: () =>
                          setState(() => _promptsDismissedAt = _text),
                      send: () => unawaited(_send(context)),
                    ),
                  ),
                ]),
                div(classes: 'flex items-center gap-0.5 px-2 pb-2', [
                  iconButton(
                    glyph: LucideIcon.plus,
                    label: t.desktop.desktopAttachFiles,
                    size: ControlSize.md,
                    tooltip: TooltipSide.top,
                    onClick: () => unawaited(_attach(context)),
                  ),
                  if (models != null && models.models.isNotEmpty) ...[
                    // The label is there for a screen reader; the menu
                    // says what it is by showing the model.
                    label(
                      [Component.text(t.app.chooseModel)],
                      htmlFor: 'model',
                      classes: 'sr-only',
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
                          'h-7 max-w-56 min-w-0 truncate rounded-lg border-0 '
                          'bg-transparent px-1.5 text-ui-sm '
                          'text-foreground-subtle transition-colors '
                          'hover:bg-hover hover:text-foreground',
                      disabled: _busy,
                      onChange: (values) {
                        if (values.isEmpty) return;
                        unawaited(
                          context
                              .read(chatActionsProvider)
                              .selectModel(values.first),
                        );
                      },
                    ),
                  ],
                  // Only before the first message. A conversation is
                  // temporary or not from the start: switching an existing
                  // chat would mean deleting it from the server, which is
                  // what Delete is for.
                  // With a model to answer, as the field is only then of use.
                  if (models != null &&
                      models.models.isNotEmpty &&
                      context.watch(selectedChatIdProvider) == null)
                    div(classes: 'px-1.5 [&_label]:text-ui-sm', [
                      checkboxField(
                        id: 'temporary-chat',
                        text: t.app.temporaryChat,
                        checked: context.watch(temporaryChatProvider),
                        onChanged: ({required value}) => context
                            .read(temporaryChatProvider.notifier)
                            .set(value: value),
                      ),
                    ]),
                  div(classes: 'min-w-0 flex-1', const []),
                  if (voice) ...[
                    const DictationButton(),
                    const VoiceCallButton(),
                  ],
                  if (streaming)
                    button(
                      [
                        icon(LucideIcon.square, classes: 'size-3 fill-current'),
                        span(classes: 'sr-only', [
                          Component.text(t.app.stopGenerating),
                        ]),
                      ],
                      classes:
                          'ml-1 inline-flex size-8 shrink-0 items-center '
                          'justify-center rounded-full bg-primary '
                          'text-primary-foreground transition-colors '
                          'hover:bg-primary/85',
                      type: ButtonType.button,
                      attributes: tooltipAttributes(
                        t.app.stopGenerating,
                        side: TooltipSide.top,
                      ),
                      onClick: () => unawaited(
                        context.read(chatActionsProvider).stop(live.chatId),
                      ),
                    )
                  else
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
                      classes:
                          'ml-1 inline-flex size-8 shrink-0 items-center '
                          'justify-center rounded-full bg-primary '
                          'text-primary-foreground transition-colors '
                          'hover:bg-primary/85 disabled:bg-foreground-subtlest '
                          'disabled:text-panel',
                      type: ButtonType.submit,
                      // An attachment still climbing is not a reason to
                      // grey the button out -- the user would watch it and
                      // wonder. The send waits for the upload instead, and
                      // says so.
                      disabled:
                          _busy ||
                          !((_text.trim().isNotEmpty ||
                                  _attachments.isNotEmpty) &&
                              context.watch(onlineProvider).value != false),
                      attributes: <String, String>{
                        if (_busy) 'aria-busy': 'true',
                        ...tooltipAttributes(t.app.send, side: TooltipSide.top),
                      },
                    ),
                ]),
              ],
            ),
            if (_dragDepth > 0)
              p(
                classes:
                    'mx-auto mt-1.5 max-w-3xl px-3 text-ui-xs text-foreground',
                [Component.text(t.desktop.desktopDropToAttach)],
              )
            else if (_error case final message?)
              div(classes: 'mx-auto mt-1.5 max-w-3xl px-3', [
                formError(message),
              ])
            else if (uploading)
              p(
                classes:
                    'mx-auto mt-1.5 max-w-3xl px-3 text-ui-xs '
                    'text-foreground-subtle',
                [Component.text(t.desktop.desktopAttachmentsUploading)],
              )
            else if (dictationProblem case final message?)
              p(
                classes:
                    'mx-auto mt-1.5 max-w-3xl px-3 text-ui-xs text-destructive',
                attributes: const <String, String>{'role': 'status'},
                [Component.text(message)],
              )
            else
              // Said once, quietly, under the field -- rather than left for
              // the user to discover by pressing Enter and watching their
              // message not send.
              p(
                classes:
                    'mx-auto mt-1.5 max-w-3xl px-3 text-ui-xs '
                    'text-foreground-subtle',
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
    if (options == null || _answeredByHermes) return const <ToolSummary>[];
    return _answeredDirectly ? options.mcpTools : options.tools;
  }

  /// Whether the next answer comes from Hermes Agent (M7), which has its
  /// own tools and search: Open WebUI's switches would do nothing there.
  bool get _answeredByHermes {
    final answering =
        _atModel?.id ?? context.read(modelListProvider).value?.selectedId;
    return answering != null && answering.startsWith('hermes:agent:');
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
          'h-7 rounded-full border px-2.5 text-ui-sm transition-colors '
          '${on ? 'border-transparent bg-selected text-foreground' : 'border-border text-foreground-subtle hover:bg-hover hover:text-foreground'}',
      type: ButtonType.button,
      attributes: <String, String>{'aria-pressed': on ? 'true' : 'false'},
      onClick: () => setState(flip),
    );
    final terminals = context.watch(terminalServersProvider).value;
    final selectedTerminal = terminals?.servers
        .where((server) => server.id == terminals.selectedId)
        .firstOrNull;
    return div(classes: 'mx-auto mb-2 max-w-3xl', [
      div(classes: 'flex flex-wrap items-center gap-2', [
        if (options.webSearch && !_answeredByHermes)
          toggle(
            t.app.webSearch,
            on: _webSearch,
            flip: () => _webSearch = !_webSearch,
          ),
        if (options.imageGeneration && !_answeredByHermes)
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
                'h-7 rounded-full border px-2.5 text-ui-sm transition-colors '
                'hover:bg-hover '
                '${_toolIds.isNotEmpty ? 'border-transparent bg-selected text-foreground' : 'border-border text-foreground-subtle hover:text-foreground'}',
            type: ButtonType.button,
            attributes: <String, String>{
              'aria-expanded': _toolsOpen ? 'true' : 'false',
              'aria-controls': 'composer-tools',
            },
            onClick: () => setState(() => _toolsOpen = !_toolsOpen),
          ),
        // The terminal the model may use, from the account's (M7). Direct
        // models answer here, without Open WebUI's terminal.
        if (!_answeredDirectly &&
            !_answeredByHermes &&
            terminalOffered(terminals))
          button(
            [
              Component.text(
                selectedTerminal == null
                    ? t.app.terminal
                    : '${t.app.terminal}: ${selectedTerminal.name}',
              ),
            ],
            classes:
                'h-7 rounded-full border px-2.5 text-ui-sm transition-colors '
                'hover:bg-hover '
                '${selectedTerminal != null ? 'border-transparent bg-selected text-foreground' : 'border-border text-foreground-subtle hover:text-foreground'}',
            type: ButtonType.button,
            attributes: <String, String>{
              'aria-expanded': _terminalOpen ? 'true' : 'false',
              'aria-controls': 'composer-terminal',
            },
            onClick: () => setState(() => _terminalOpen = !_terminalOpen),
          ),
        // Prompts and resources from the same servers, as text to send.
        if (_answeredDirectly && options.mcpTools.isNotEmpty)
          button(
            [Component.text(t.app.directMcpContentAction)],
            classes:
                'rounded-full border px-3 py-1 text-ui-sm '
                '${_contentOpen ? 'border-primary text-foreground' : 'border-border text-foreground-subtle'} '
                'hover:bg-hover',
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
      if (_terminalOpen && !_answeredDirectly && terminalOffered(terminals))
        div(
          id: 'composer-terminal',
          classes:
              'mt-2 flex flex-wrap gap-2 rounded-lg border border-border p-3',
          attributes: <String, String>{
            'role': 'group',
            'aria-label': t.app.terminalSelectServer,
          },
          [
            for (final (id, name) in <(String?, String)>[
              (null, t.app.workspaceModelSelectNone),
              for (final server in terminals!.servers) (server.id, server.name),
            ])
              button(
                [Component.text(name)],
                classes:
                    'rounded-full border px-3 py-1 text-ui-sm '
                    '${terminals.selectedId == id ? 'border-primary bg-primary text-primary-foreground' : 'border-border hover:bg-hover'}',
                type: ButtonType.button,
                attributes: <String, String>{
                  'aria-pressed': terminals.selectedId == id ? 'true' : 'false',
                },
                onClick: () async {
                  setState(() => _terminalOpen = false);
                  await context.read(terminalActionsProvider).select(id);
                  context.invalidate(terminalServersProvider);
                },
              ),
          ],
        ),
      if (_toolsOpen && _toolsOffered(options).isNotEmpty)
        div(
          id: 'composer-tools',
          classes: 'mt-2 space-y-2 rounded-lg border border-border p-3',
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
                    classes:
                        'ml-6 line-clamp-2 text-ui-sm text-foreground-subtle',
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
          'flex items-center gap-2 rounded-lg border px-2 py-1 text-ui-sm '
          '${attachment.failed ? 'border-destructive text-destructive' : 'border-border text-foreground-subtle'}',
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
          classes: 'rounded-lg px-1 hover:bg-hover',
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
