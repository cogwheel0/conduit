import 'dart:async';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:jaspr_router/jaspr_router.dart';

import '../keyboard.dart';
import '../l10n/strings.g.dart';
import '../palette.dart' show movePaletteIndex;
import '../prompt_trigger.dart';
import '../rpc/channels_providers.dart';
import '../rpc/chat_providers.dart' show OpenChannelId, openChannelIdProvider;
import '../rpc/rpc_providers.dart' show windowCommandsProvider;
import '../widgets/form_field.dart';
import '../widgets/markdown_view.dart';

/// Channels (M5): the list on the left, the conversation on the right, and
/// a thread beside it when one is open.
///
/// Open WebUI's channels, through the daemon: what anyone posts, edits or
/// reacts with arrives as it happens, and so does who is typing.
class ChannelsPage extends StatelessComponent {
  const ChannelsPage({this.channelId, super.key});

  final String? channelId;

  @override
  Component build(BuildContext context) {
    final id = channelId;
    return div(
      classes: 'flex min-h-0 min-w-0 flex-1 overflow-hidden rounded-lg border border-border bg-panel text-foreground',
      [
        _ChannelList(openId: id),
        if (id == null)
          main_(classes: 'flex min-w-0 flex-1', [
            div(classes: 'm-auto max-w-sm space-y-2 p-8 text-center', [
              p(classes: 'text-ui-base font-medium', [
                Component.text(t.app.sidebarChannelsTab),
              ]),
              p(classes: 'text-ui-base text-foreground-subtle', [
                Component.text(t.app.channelEmptyHint),
              ]),
            ]),
          ])
        else
          _ChannelView(key: ValueKey('channel-$id'), channelId: id),
      ],
    );
  }
}

class _ChannelList extends StatefulComponent {
  const _ChannelList({required this.openId});

  final String? openId;

  @override
  State<_ChannelList> createState() => _ChannelListState();
}

class _ChannelListState extends State<_ChannelList> {
  bool _creating = false;
  String _name = '';
  String _description = '';
  bool _private = false;
  String? _error;

  Future<void> _create() async {
    if (_name.trim().isEmpty) return;
    try {
      await context
          .read(channelActionsProvider)
          .save(
            ChannelEdit(
              name: _name,
              description: _description.trim().isEmpty ? null : _description,
              private: _private,
            ),
          );
      if (!mounted) return;
      setState(() {
        _creating = false;
        _name = '';
        _description = '';
        _private = false;
        _error = null;
      });
    } on Object {
      if (mounted) setState(() => _error = t.app.channelCreateError);
    }
  }

  @override
  Component build(BuildContext context) {
    final list = context.watch(channelListProvider);
    final channels = list.value?.channels ?? const <ChannelSummary>[];
    return nav(
      classes: 'flex w-64 shrink-0 flex-col gap-3 border-r border-border bg-card p-3',
      attributes: <String, String>{'aria-label': t.app.sidebarChannelsTab},
      [
        div(classes: 'flex items-center gap-2', [
          Link(
            to: '/',
            classes: 'rounded-lg px-2 py-1 text-ui-base hover:bg-hover',
            attributes: <String, String>{'aria-label': t.app.back},
            child: Component.text('←'),
          ),
          h1(classes: 'flex-1 text-ui-base font-semibold', [
            Component.text(t.app.sidebarChannelsTab),
          ]),
          button(
            [Component.text('+')],
            classes: 'rounded-lg px-2 py-0.5 text-ui-base hover:bg-hover',
            type: ButtonType.button,
            attributes: <String, String>{
              'aria-label': t.app.channelCreateTitle,
              'aria-expanded': '$_creating',
            },
            onClick: () => setState(() => _creating = !_creating),
          ),
        ]),
        if (_creating)
          div(
            classes: 'space-y-2 rounded-lg border border-border p-2',
            attributes: <String, String>{
              'role': 'group',
              'aria-label': t.app.channelCreateTitle,
            },
            [
              textField(
                id: 'channel-name',
                labelText: t.app.channelName,
                value: _name,
                onInput: (value) => setState(() => _name = value),
              ),
              textField(
                id: 'channel-description',
                labelText: t.app.channelDescription,
                value: _description,
                onInput: (value) => setState(() => _description = value),
              ),
              checkboxField(
                id: 'channel-private',
                text: t.app.channelPrivate,
                checked: _private,
                onChanged: ({required value}) =>
                    setState(() => _private = value),
              ),
              if (_error case final error?) formError(error),
              button(
                [Component.text(t.app.channelCreateTitle)],
                classes:
                    'w-full rounded-lg bg-primary px-2 py-1 text-ui-sm '
                    'text-primary-foreground disabled:opacity-50',
                type: ButtonType.button,
                disabled: _name.trim().isEmpty,
                onClick: () => unawaited(_create()),
              ),
            ],
          ),
        if (list.hasError && list.value == null)
          formError(t.app.channelLoadError)
        else if (list.value != null && channels.isEmpty)
          p(classes: 'text-ui-sm text-foreground-subtle', [
            Component.text(t.app.channelEmptyState),
          ]),
        ul(classes: 'min-h-0 flex-1 space-y-0.5 overflow-y-auto', [
          for (final channel in channels)
            li([
              Link(
                to: '/channels/${channel.id}',
                classes:
                    'flex items-center gap-2 rounded-lg px-2 py-1.5 text-ui-base '
                    'hover:bg-hover aria-[current=page]:bg-accent',
                attributes: <String, String>{
                  if (channel.id == component.openId) 'aria-current': 'page',
                },
                children: [
                  span(classes: 'text-foreground-subtle', [
                    Component.text(channel.private ? '🔒' : '#'),
                  ]),
                  span(
                    classes:
                        'min-w-0 flex-1 truncate '
                        '${channel.unread > 0 ? 'font-semibold' : ''}',
                    [Component.text(channel.name)],
                  ),
                  if (channel.unread > 0 && channel.id != component.openId)
                    span(
                      classes:
                          'rounded-full bg-primary px-1.5 text-ui-xs '
                          'text-primary-foreground',
                      [Component.text('${channel.unread}')],
                    ),
                ],
              ),
            ]),
        ]),
      ],
    );
  }
}

class _ChannelView extends StatefulComponent {
  const _ChannelView({required this.channelId, super.key});

  final String channelId;

  @override
  State<_ChannelView> createState() => _ChannelViewState();
}

class _ChannelViewState extends State<_ChannelView> {
  /// The message whose thread is open beside the channel.
  ChannelMessageDto? _thread;
  bool _confirmingDelete = false;
  bool _confirmingLeave = false;

  /// The channel's details being edited, by a manager; null when not.
  ({String name, String description, bool private})? _editing;

  /// Kept to say "no channel open" when this view goes: `dispose` cannot
  /// read the context.
  OpenChannelId? _open;

  @override
  void dispose() {
    final open = _open;
    final channelId = component.channelId;
    Future<void>.microtask(() => open?.close(channelId));
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    final channelId = component.channelId;
    // After this build: the provider it sets is watched by this subtree.
    Future<void>.microtask(() {
      if (!mounted) return;
      final open = context.read(openChannelIdProvider.notifier)..set(channelId);
      _open = open;
      unawaited(
        context
            .read(channelActionsProvider)
            .markRead(channelId)
            .catchError((Object _) {}),
      );
    });
  }

  @override
  Component build(BuildContext context) {
    final channelId = component.channelId;
    final channel = context
        .watch(channelListProvider)
        .value
        ?.channels
        .where((c) => c.id == channelId)
        .firstOrNull;
    final thread = _thread;
    return div(classes: 'flex min-w-0 flex-1', [
      main_(classes: 'flex min-w-0 flex-1 flex-col', [
        header(
          classes: 'flex h-12 shrink-0 items-center gap-3 border-b border-border px-6',
          [
            h2(classes: 'truncate text-ui-base font-semibold', [
              Component.text(channel == null ? '' : '# ${channel.name}'),
            ]),
            if (channel?.description case final description?
                when description.isNotEmpty)
              span(classes: 'truncate text-ui-sm text-foreground-subtle', [
                Component.text(description),
              ]),
            div(classes: 'flex-1', []),
            if (channel?.manager ?? false)
              button(
                [Component.text(t.app.channelEdit)],
                classes: 'rounded-lg px-2.5 py-1 text-ui-sm hover:bg-hover',
                type: ButtonType.button,
                onClick: () => setState(
                  () => _editing = (
                    name: channel!.name,
                    description: channel.description ?? '',
                    private: channel.private,
                  ),
                ),
              ),
            if (channel != null && !channel.manager)
              button(
                [Component.text(t.app.channelLeave)],
                classes: 'rounded-lg px-2.5 py-1 text-ui-sm hover:bg-hover',
                type: ButtonType.button,
                onClick: () => setState(() => _confirmingLeave = true),
              ),
            if (channel?.manager ?? false)
              button(
                [Component.text(t.app.channelDelete)],
                classes:
                    'rounded-lg px-2.5 py-1 text-ui-sm text-destructive '
                    'hover:bg-destructive/10',
                type: ButtonType.button,
                onClick: () => setState(() => _confirmingDelete = true),
              ),
          ],
        ),
        if (_editing case final editing?)
          div(
            classes: 'mx-6 mt-3 space-y-2 rounded-lg border border-border p-3',
            attributes: <String, String>{
              'role': 'group',
              'aria-label': t.app.channelEdit,
            },
            [
              textField(
                id: 'channel-edit-name',
                labelText: t.app.channelName,
                value: editing.name,
                onInput: (value) => setState(
                  () => _editing = (
                    name: value,
                    description: editing.description,
                    private: editing.private,
                  ),
                ),
              ),
              textField(
                id: 'channel-edit-description',
                labelText: t.app.channelDescription,
                value: editing.description,
                onInput: (value) => setState(
                  () => _editing = (
                    name: editing.name,
                    description: value,
                    private: editing.private,
                  ),
                ),
              ),
              checkboxField(
                id: 'channel-edit-private',
                text: t.app.channelPrivate,
                checked: editing.private,
                onChanged: ({required value}) => setState(
                  () => _editing = (
                    name: editing.name,
                    description: editing.description,
                    private: value,
                  ),
                ),
              ),
              div(classes: 'flex gap-2', [
                button(
                  [Component.text(t.app.save)],
                  classes:
                      'rounded-lg bg-primary px-2.5 py-1 text-ui-sm '
                      'text-primary-foreground disabled:opacity-50',
                  type: ButtonType.button,
                  disabled: editing.name.trim().isEmpty,
                  onClick: () async {
                    if (editing.name.trim().isEmpty) return;
                    await context
                        .read(channelActionsProvider)
                        .save(
                          ChannelEdit(
                            id: channelId,
                            name: editing.name,
                            description: editing.description.trim().isEmpty
                                ? null
                                : editing.description,
                            private: editing.private,
                          ),
                        );
                    if (mounted) setState(() => _editing = null);
                  },
                ),
                button(
                  [Component.text(t.app.cancel)],
                  classes: 'rounded-lg px-2.5 py-1 text-ui-sm hover:bg-hover',
                  type: ButtonType.button,
                  onClick: () => setState(() => _editing = null),
                ),
              ]),
            ],
          ),
        if (_confirmingLeave)
          div(
            classes: 'mx-6 mt-3 space-y-2 rounded-lg border border-border p-3 text-ui-base',
            attributes: const <String, String>{'role': 'alertdialog'},
            [
              p([Component.text(t.app.channelLeaveConfirm)]),
              div(classes: 'flex gap-2', [
                button(
                  [Component.text(t.app.channelLeave)],
                  classes:
                      'rounded-lg bg-primary px-2.5 py-1 text-ui-sm '
                      'text-primary-foreground',
                  type: ButtonType.button,
                  onClick: () async {
                    final router = Router.of(context);
                    await context.read(channelActionsProvider).leave(channelId);
                    router.replace('/channels');
                  },
                ),
                button(
                  [Component.text(t.app.cancel)],
                  classes: 'rounded-lg px-2.5 py-1 text-ui-sm hover:bg-hover',
                  type: ButtonType.button,
                  onClick: () => setState(() => _confirmingLeave = false),
                ),
              ]),
            ],
          ),
        if (_confirmingDelete)
          div(
            classes:
                'mx-6 mt-3 space-y-2 rounded-lg border border-destructive/40 '
                'bg-destructive/10 p-3 text-ui-base',
            attributes: const <String, String>{'role': 'alertdialog'},
            [
              p([Component.text(t.app.channelDeleteConfirm)]),
              div(classes: 'flex gap-2', [
                button(
                  [Component.text(t.app.delete)],
                  classes:
                      'rounded-lg bg-destructive px-2.5 py-1 text-ui-sm '
                      'text-destructive-foreground',
                  type: ButtonType.button,
                  onClick: () async {
                    final router = Router.of(context);
                    await context
                        .read(channelActionsProvider)
                        .delete(channelId);
                    router.replace('/channels');
                  },
                ),
                button(
                  [Component.text(t.app.cancel)],
                  classes: 'rounded-lg px-2.5 py-1 text-ui-sm hover:bg-hover',
                  type: ButtonType.button,
                  onClick: () => setState(() => _confirmingDelete = false),
                ),
              ]),
            ],
          ),
        _MessageList(
          channelId: channelId,
          canPost: channel?.canPost ?? true,
          onOpenThread: (message) => setState(() => _thread = message),
        ),
        if (channel?.canPost ?? true) _ChannelComposer(channelId: channelId),
      ]),
      if (thread != null)
        aside(
          classes: 'flex w-96 shrink-0 flex-col border-l border-border bg-card',
          attributes: <String, String>{'aria-label': t.app.thread},
          [
            div(
              classes:
                  'flex h-12 shrink-0 items-center border-b border-border px-4',
              [
                h3(classes: 'flex-1 text-ui-base font-semibold', [
                  Component.text(t.app.thread),
                ]),
                button(
                  [Component.text('×')],
                  classes: 'rounded-lg px-2 text-ui-base hover:bg-hover',
                  type: ButtonType.button,
                  attributes: <String, String>{'aria-label': t.app.close},
                  onClick: () => setState(() => _thread = null),
                ),
              ],
            ),
            div(classes: 'border-b border-border p-3', [
              _MessageRow(
                message: thread,
                channelId: channelId,
                inThread: true,
              ),
            ]),
            _MessageList(
              key: ValueKey('thread-${thread.id}'),
              channelId: channelId,
              parentId: thread.id,
              canPost: channel?.canPost ?? true,
            ),
            if (channel?.canPost ?? true)
              _ChannelComposer(
                key: ValueKey('reply-${thread.id}'),
                channelId: channelId,
                parentId: thread.id,
              ),
          ],
        ),
    ]);
  }
}

/// A channel's messages, oldest at the top, or a thread's replies.
class _MessageList extends StatelessComponent {
  const _MessageList({
    required this.channelId,
    this.parentId,
    required this.canPost,
    this.onOpenThread,
    super.key,
  });

  final String channelId;
  final String? parentId;
  final bool canPost;
  final void Function(ChannelMessageDto message)? onOpenThread;

  @override
  Component build(BuildContext context) {
    final result = context.watch(
      channelMessagesProvider((channelId: channelId, parentId: parentId)),
    );
    final value = result.value;
    final messages = value?.messages.reversed.toList() ?? const [];
    final typing = parentId == null
        ? context.watch(channelTypingProvider(channelId)).value ??
              const <String>[]
        : const <String>[];
    return div(
      classes: 'min-h-0 flex-1 space-y-1 overflow-y-auto px-6 py-4',
      attributes: <String, String>{
        'role': 'log',
        'aria-label': parentId == null
            ? t.app.sidebarChannelsTab
            : t.app.thread,
      },
      [
        if (value?.hasOlder ?? false)
          button(
            [Component.text(t.desktop.desktopLoadOlderMessages)],
            classes: 'mx-auto block rounded-lg px-2.5 py-1 text-ui-sm hover:bg-hover',
            type: ButtonType.button,
            onClick: () => unawaited(
              context
                  .read(channelActionsProvider)
                  .loadOlder(channelId, parentId: parentId),
            ),
          ),
        if (value != null && messages.isEmpty && parentId == null)
          p(classes: 'py-8 text-center text-ui-base text-foreground-subtle', [
            Component.text(t.app.channelNoMessages),
          ]),
        for (final message in messages)
          _MessageRow(
            key: ValueKey('m-${message.id}'),
            message: message,
            channelId: channelId,
            inThread: parentId != null,
            onOpenThread: onOpenThread,
          ),
        if (typing.isNotEmpty)
          p(
            classes: 'text-ui-sm italic text-foreground-subtle',
            attributes: const <String, String>{'role': 'status'},
            [Component.text('${typing.join(', ')} …')],
          ),
      ],
    );
  }
}

/// The reactions offered with one click: the common ones.
const List<String> _quickReactions = <String>['👍', '🎉', '❤️', '😂', '👀'];

class _MessageRow extends StatefulComponent {
  const _MessageRow({
    required this.message,
    required this.channelId,
    this.inThread = false,
    this.onOpenThread,
    super.key,
  });

  final ChannelMessageDto message;
  final String channelId;
  final bool inThread;
  final void Function(ChannelMessageDto message)? onOpenThread;

  @override
  State<_MessageRow> createState() => _MessageRowState();
}

class _MessageRowState extends State<_MessageRow> {
  bool _editing = false;
  late String _draft = component.message.content;
  bool _reacting = false;

  Future<void> _react(String emoji, {required bool add}) => context
      .read(channelActionsProvider)
      .react(
        ChannelReact(
          channelId: component.channelId,
          messageId: component.message.id,
          emoji: emoji,
          add: add,
        ),
      );

  @override
  Component build(BuildContext context) {
    final message = component.message;
    final actions = context.read(channelActionsProvider);
    final time = DateTime.fromMillisecondsSinceEpoch(message.createdAtMs);
    String two(int n) => n.toString().padLeft(2, '0');
    return article(
      classes: 'group relative rounded-lg px-2 py-1.5 hover:bg-hover',
      [
        div(classes: 'flex items-baseline gap-2', [
          span(classes: 'text-ui-base font-semibold', [
            Component.text(message.user?.name ?? t.app.channelUnknownMember),
          ]),
          span(classes: 'text-ui-sm text-foreground-subtle', [
            Component.text('${two(time.hour)}:${two(time.minute)}'),
          ]),
          if (message.editedAtMs != null)
            span(classes: 'text-ui-sm text-foreground-subtle', [
              Component.text('(${t.desktop.desktopMessageEdited})'),
            ]),
          if (message.pinned)
            span(
              classes: 'text-ui-sm',
              attributes: <String, String>{'aria-label': t.app.pin},
              [Component.text('📌')],
            ),
        ]),
        if (_editing)
          div(classes: 'mt-1 space-y-1', [
            textAreaField(
              id: 'edit-${message.id}',
              labelText: t.app.channelMessageEdit,
              hideLabel: true,
              value: _draft,
              rows: 2,
              onInput: (value) => setState(() => _draft = value),
              onKeyDown: submitOrCancel(
                submit: () => unawaited(_saveEdit()),
                cancel: () => setState(() => _editing = false),
              ),
            ),
            div(classes: 'flex gap-2', [
              button(
                [Component.text(t.app.save)],
                classes:
                    'rounded-lg bg-primary px-2 py-0.5 text-ui-sm '
                    'text-primary-foreground',
                type: ButtonType.button,
                onClick: () => unawaited(_saveEdit()),
              ),
              button(
                [Component.text(t.app.cancel)],
                classes: 'rounded-lg px-2 py-0.5 text-ui-sm hover:bg-hover',
                type: ButtonType.button,
                onClick: () => setState(() => _editing = false),
              ),
            ]),
          ])
        else
          div(classes: 'text-ui-base', [
            MarkdownView(channelMarkdown(message.content)),
          ]),
        if (message.reactions.isNotEmpty)
          div(classes: 'mt-1 flex flex-wrap gap-1', [
            for (final reaction in message.reactions)
              button(
                [Component.text('${reaction.name} ${reaction.count}')],
                classes:
                    'rounded-full border px-2 text-ui-sm '
                    '${reaction.mine ? 'border-primary bg-primary/10' : 'border-border'}',
                type: ButtonType.button,
                attributes: <String, String>{
                  'aria-pressed': '${reaction.mine}',
                },
                onClick: () =>
                    unawaited(_react(reaction.name, add: !reaction.mine)),
              ),
          ]),
        if (!component.inThread && message.replyCount > 0)
          button(
            [Component.text(t.app.threadWithCount(count: message.replyCount))],
            classes: 'mt-1 text-ui-sm text-primary hover:underline',
            type: ButtonType.button,
            onClick: () => component.onOpenThread?.call(message),
          ),
        if (_reacting)
          div(classes: 'mt-1 flex gap-1', [
            for (final emoji in _quickReactions)
              button(
                [Component.text(emoji)],
                classes: 'rounded-lg px-1.5 hover:bg-hover',
                type: ButtonType.button,
                onClick: () {
                  setState(() => _reacting = false);
                  final already = message.reactions.any(
                    (r) => r.name == emoji && r.mine,
                  );
                  unawaited(_react(emoji, add: !already));
                },
              ),
          ]),
        // The actions, where hovering or focusing the message finds them.
        div(
          classes:
              'absolute right-2 top-1 hidden gap-0.5 rounded-lg border '
              'border-border bg-popover px-1 text-ui-sm shadow-sm '
              'group-hover:flex group-focus-within:flex',
          [
            _action(t.app.channelMessageReact, () {
              setState(() => _reacting = !_reacting);
            }),
            if (!component.inThread)
              _action(
                t.app.channelMessageReply,
                () => component.onOpenThread?.call(message),
              ),
            _action(
              message.pinned ? t.app.unpin : t.app.pin,
              () => unawaited(
                actions.pin(
                  ChannelPin(
                    channelId: component.channelId,
                    messageId: message.id,
                    pinned: !message.pinned,
                  ),
                ),
              ),
            ),
            if (message.mine) ...[
              _action(t.app.channelMessageEdit, () {
                setState(() {
                  _draft = message.content;
                  _editing = true;
                });
              }),
              _action(
                t.app.channelMessageDelete,
                () => unawaited(
                  actions.deleteMessage(component.channelId, message.id),
                ),
                destructive: true,
              ),
            ],
          ],
        ),
      ],
    );
  }

  Component _action(
    String label,
    void Function() onClick, {
    bool destructive = false,
  }) => button(
    [Component.text(label)],
    classes:
        'rounded-lg px-1.5 py-0.5 hover:bg-hover '
        '${destructive ? 'text-destructive' : ''}',
    type: ButtonType.button,
    onClick: onClick,
  );

  Future<void> _saveEdit() async {
    final draft = _draft.trim();
    if (draft.isEmpty) return;
    await context
        .read(channelActionsProvider)
        .edit(
          ChannelMessageEdit(
            channelId: component.channelId,
            messageId: component.message.id,
            content: draft,
          ),
        );
    if (mounted) setState(() => _editing = false);
  }
}

/// Where a message is written: Enter sends, `@` offers the channel's
/// members, and others see that you are typing.
class _ChannelComposer extends StatefulComponent {
  const _ChannelComposer({required this.channelId, this.parentId, super.key});

  final String channelId;
  final String? parentId;

  @override
  State<_ChannelComposer> createState() => _ChannelComposerState();
}

class _ChannelComposerState extends State<_ChannelComposer> {
  String _text = '';
  int _highlighted = 0;
  bool _sending = false;
  String? _error;

  /// Mentions chosen from the menu, by the `@Name` shown for them: on send
  /// each becomes Open WebUI's markup, so it notifies that person.
  final Map<String, ChannelUser> _mentions = <String, ChannelUser>{};

  /// When the others were last told this user is typing; told again at
  /// most every few seconds, and that it stopped when the message goes.
  DateTime? _typingSaid;

  String get _fieldId => component.parentId == null
      ? 'channel-composer'
      : 'thread-composer-${component.parentId}';

  void _onInput(String value) {
    setState(() {
      _text = value;
      _highlighted = 0;
    });
    final now = DateTime.now();
    if (value.trim().isNotEmpty &&
        (_typingSaid == null ||
            now.difference(_typingSaid!) > const Duration(seconds: 3))) {
      _typingSaid = now;
      unawaited(
        context
            .read(channelActionsProvider)
            .typing(component.channelId, typing: true)
            .catchError((Object _) {}),
      );
    }
  }

  void _choose(ChannelUser user) {
    final trigger = mentionTriggerIn(_text);
    if (trigger == null) return;
    final shown = '@${user.name}';
    final text = '${_text.substring(0, trigger.start)}$shown ';
    setState(() {
      _mentions[shown] = user;
      _text = text;
    });
    context.read(windowCommandsProvider)
      ..setValue(_fieldId, text)
      ..focus(_fieldId);
  }

  Future<void> _send() async {
    var content = _text.trim();
    if (content.isEmpty || _sending) return;
    _mentions.forEach((shown, user) {
      content = content.replaceAll(shown, channelMention(user));
    });
    setState(() {
      _sending = true;
      _error = null;
    });
    final actions = context.read(channelActionsProvider);
    final commands = context.read(windowCommandsProvider);
    try {
      await actions.post(
        ChannelPost(
          channelId: component.channelId,
          content: content,
          parentId: component.parentId,
        ),
      );
      _typingSaid = null;
      unawaited(
        actions
            .typing(component.channelId, typing: false)
            .catchError((Object _) {}),
      );
      if (!mounted) return;
      setState(() {
        _text = '';
        _mentions.clear();
      });
      commands
        ..setValue(_fieldId, '')
        ..focus(_fieldId);
    } on Object {
      if (mounted) setState(() => _error = t.app.channelSendError);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Component build(BuildContext context) {
    final trigger = mentionTriggerIn(_text);
    final members = trigger == null
        ? const <ChannelUser>[]
        : (context
                      .watch(channelMembersProvider(component.channelId))
                      .value
                      ?.users ??
                  const <ChannelUser>[])
              .where((user) => user.name.toLowerCase().contains(trigger.query))
              .take(8)
              .toList();
    final highlighted = members.isEmpty
        ? -1
        : _highlighted.clamp(0, members.length - 1);
    return div(classes: 'relative border-t border-border p-3', [
      if (members.isNotEmpty)
        ul(
          classes:
              'absolute bottom-full left-3 mb-1 w-64 rounded-lg border '
              'border-border bg-popover p-1 shadow',
          attributes: const <String, String>{'role': 'listbox'},
          [
            for (final (index, user) in members.indexed)
              li(
                classes:
                    'cursor-pointer rounded-lg px-2 py-1 text-ui-base '
                    '${index == highlighted ? 'bg-selected' : ''}',
                attributes: <String, String>{
                  'role': 'option',
                  'aria-selected': '${index == highlighted}',
                },
                events: <String, EventCallback>{'click': (_) => _choose(user)},
                [Component.text(user.name)],
              ),
          ],
        ),
      if (_error case final error?) formError(error),
      textAreaField(
        id: _fieldId,
        labelText: t.app.channelMessageHint,
        hideLabel: true,
        placeholder: t.app.channelMessageHint,
        value: _text,
        rows: 2,
        onInput: _onInput,
        onKeyDown: composerKeys(
          menuOpen: () => members.isNotEmpty,
          move: ({required down}) => setState(
            () => _highlighted = movePaletteIndex(
              highlighted,
              members.length,
              down: down,
            ),
          ),
          choose: () => _choose(members[highlighted]),
          dismiss: () => setState(() => _text = '$_text '),
          send: () => unawaited(_send()),
        ),
      ),
    ]);
  }
}
