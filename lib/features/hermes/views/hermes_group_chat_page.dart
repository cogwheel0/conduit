import 'package:conduit_core/features/hermes/models/hermes_group_live_reply.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:mime/mime.dart';

import 'dart:convert';

import 'package:conduit_core/features/hermes/models/hermes_chat_input.dart';

import '../../chat/services/file_attachment_service.dart';

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:conduit_core/features/hermes/models/hermes_bot.dart';
import 'package:conduit_core/features/hermes/models/hermes_bot_group.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/platform_ui/platform_ui.dart';
import '../../../shared/widgets/markdown/streaming_markdown_widget.dart';
import '../providers/hermes_messages.dart';
import '../providers/hermes_mobile_navigation.dart';
import '../widgets/hermes_message_icon.dart';
import '../widgets/hermes_bot_avatar.dart';
import '../widgets/hermes_approval_card.dart';
import '../widgets/hermes_decision_card.dart';
import '../widgets/hermes_mobile_shell.dart'
    show HermesBottomNavigation, selectHermesWorkAreaRoot;
import '../../chat/widgets/modern_chat_input.dart';
import '../../chat/widgets/streaming_turn_footer.dart';
import '../../chat/widgets/streaming_status_widget.dart';
import 'hermes_group_workspace_page.dart';
import '../providers/hermes_group_runtime.dart';

import 'package:conduit_core/features/hermes/services/hermes_message_mapper.dart'
    show hermesToolDetailItem;

import '../providers/hermes_workspace.dart';
import '../widgets/hermes_conversation_drawer.dart';
import '../widgets/hermes_conversation_actions.dart';

class HermesGroupChatPage extends ConsumerStatefulWidget {
  const HermesGroupChatPage({super.key, required this.group});
  final HermesBotGroup group;
  @override
  ConsumerState<HermesGroupChatPage> createState() =>
      _HermesGroupChatPageState();
}

class _HermesGroupChatPageState extends ConsumerState<HermesGroupChatPage> {
  late HermesGroupRuntime _runtime;
  late final Object? _service;
  final _scroll = ScrollController();
  final _attachments = <LocalAttachment>[];
  bool _preparing = false;
  String? _lastReadMessage;
  bool _connectionChanged = false;
  HermesBotGroup get _group => _runtime.group;
  HermesGroupReply? get _reply => _runtime.reply;
  bool get _busy => _runtime.busy;
  bool get _failed => _runtime.failed;
  bool get _stopped => _runtime.stopped;
  bool get _current =>
      mounted &&
      !_connectionChanged &&
      identical(_service, ref.read(hermesApiServiceProvider));
  @override
  void initState() {
    super.initState();
    _service = ref.read(hermesApiServiceProvider);
    _runtime = ref.read(hermesGroupRuntimeProvider(widget.group.identity));
    _runtime.replaceGroup(widget.group);
    _runtime.addListener(_changed);
    _runtime.attach();
    scheduleMicrotask(() {
      if (mounted) {
        ref
            .read(hermesMessageReadReceiptsProvider.notifier)
            .seen('group:${widget.group.identity}');
      }
    });
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    if (ModalRoute.of(context)?.isCurrent == true &&
        _group.messages.isNotEmpty &&
        _lastReadMessage != _group.messages.last.id) {
      _lastReadMessage = _group.messages.last.id;
      ref
          .read(hermesMessageReadReceiptsProvider.notifier)
          .seen('group:${_group.identity}');
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients && _scroll.position.extentAfter < 240) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  void dispose() {
    _runtime.removeListener(_changed);
    _runtime.detach();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _settings() async {
    final oldId = _group.identity;
    var group = await Navigator.of(context).push<HermesBotGroup>(
      MaterialPageRoute(
        builder: (_) => HermesGroupWorkspacePage(group: _group),
      ),
    );
    if (!mounted) return;
    group ??= ref
        .read(hermesBotGroupsProvider)
        .asData
        ?.value
        .where((g) => g.previousRooms.any((r) => r['room_id'] == oldId))
        .firstOrNull;
    if (group != null) {
      if (_group.identity != group.identity) {
        final oldId = _group.identity;
        _runtime.removeListener(_changed);
        _runtime.detach();
        ref.invalidate(hermesGroupRuntimeProvider(oldId));
        _runtime = ref.read(hermesGroupRuntimeProvider(group.identity));
        _runtime.addListener(_changed);
        _runtime.attach();
      }
      _runtime.replaceGroup(group);
      setState(() {});
    }
  }

  Future<void> _send(String text) async {
    await _sendAccepted(text);
  }

  Future<void> _pickFiles() async {
    try {
      final picked = await FileAttachmentService().pickFiles();
      if (_current) _addAttachments(picked);
    } catch (_) {
      if (mounted) {
        AdaptiveSnackBar.show(context, message: 'Could not attach the file.');
      }
    }
  }

  Future<void> _addAttachments(List<LocalAttachment> files) async {
    if (!_current) return;
    if (_attachments.length + files.length > 4 ||
        files.fold<int>(0, (n, f) => n + f.sizeInBytes) +
                _attachments.fold<int>(0, (n, f) => n + f.sizeInBytes) >
            18 * 1024 * 1024) {
      AdaptiveSnackBar.show(
        context,
        message: 'Attach up to four files, totaling 18 MB.',
      );
      return;
    }
    setState(() => _attachments.addAll(files));
  }

  Future<bool> _sendAccepted(String text) async {
    if (_preparing || !_current) return false;
    final files = List<LocalAttachment>.of(_attachments);
    setState(() => _preparing = true);
    try {
      final parts = <HermesChatContentPart>[];
      for (final file in files) {
        final bytes = await file.file.readAsBytes();
        final type =
            lookupMimeType(
              file.displayName,
              headerBytes: bytes.take(16).toList(),
            ) ??
            'application/octet-stream';
        if (file.isImage && _group.raw['hosted'] != true) {
          parts.add(
            HermesInputImagePart('data:$type;base64,${base64Encode(bytes)}'),
          );
        } else {
          parts.add(
            HermesInputFilePart(
              filename: file.displayName,
              mediaType: type,
              base64Data: base64Encode(bytes),
            ),
          );
        }
      }
      if (!_current) return false;
      final accepted = await _runtime.send(text, files: parts);
      if (accepted && _current) {
        setState(() => _attachments.removeWhere(files.contains));
      }
      return accepted;
    } catch (_) {
      if (mounted) {
        AdaptiveSnackBar.show(
          context,
          message: 'Could not send. Your draft and files are kept.',
        );
      }
      return false;
    } finally {
      if (mounted) setState(() => _preparing = false);
    }
  }

  Future<void> _approval(String choice) => _runtime.approval(choice);
  Future<bool> _decision(String value) => _runtime.decision(value);

  Widget _bubble(HermesGroupMessage message, {bool streaming = false}) {
    final theme = context.conduitTheme;
    final bots =
        ref.watch(hermesMessagesBotsProvider).asData?.value ?? <HermesBot>[];
    final bot = bots.where((b) => b.name == message.botProfile).firstOrNull;
    final text = Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: message.isUser
            ? theme.surfaceContainerHighest
            : theme.surfaceContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          StreamingMarkdownWidget(
            content: message.text,
            isStreaming: streaming,
            stateScopeId: 'group:${_group.identity}:${message.id}',
            enableStreamingTextFade: streaming,
          ),
          if (message.toolUpdates.isNotEmpty)
            StreamingStatusWidget(
              updates: message.toolUpdates,
              isStreaming: streaming,
            ),
        ],
      ),
    );
    if (message.isUser) {
      return Align(
        alignment: AlignmentDirectional.centerEnd,
        child: FractionallySizedBox(widthFactor: .92, child: text),
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (bot != null)
          HermesBotAvatar(
            size: 28,
            label: bot.title,
            icon: bot.icon,
            shape: bot.avatarShape,
            color: bot.avatarColor,
          ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                bot?.title ?? message.speaker,
                style: Theme.of(context).textTheme.labelMedium
                    ?.copyWith(color: theme.textSecondary),
              ),
              const SizedBox(height: 4),
              text,
            ],
          ),
        ),
      ],
    );
  }

  Widget _liveReply(HermesGroupLiveReply reply) {
    final bot = ref
        .watch(hermesMessagesBotsProvider)
        .asData
        ?.value
        .where((b) => b.name == reply.profile)
        .firstOrNull;
    final updates = [
      for (final tool in reply.tools)
        ChatStatusUpdate(
          action: 'hermes_tool_${tool.toolName}',
          description: tool.detail ?? tool.toolName,
          done: tool.done,
          items: [
            ?hermesToolDetailItem('Arguments', tool.arguments),
            ?hermesToolDetailItem('Result', tool.result),
            ?hermesToolDetailItem('Changes', tool.inlineDiff),
          ],
        ),
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (reply.text.isEmpty)
            Row(
              children: [
                Text(
                  bot?.title ?? reply.profile,
                  style: Theme.of(context).textTheme.labelMedium,
                ),
                const SizedBox(width: 8),
                StreamingTurnFooter(
                  message: ChatMessage(
                    id: reply.id,
                    role: 'assistant',
                    content: '',
                    timestamp: DateTime.now(),
                    isStreaming: !reply.complete,
                  ),
                  inline: true,
                  show: !reply.complete,
                  suppressStreamingHaptics: true,
                ),
              ],
            )
          else
            _bubble(
              HermesGroupMessage(
                id: reply.id,
                text: reply.text,
                at: DateTime.now(),
                botProfile: reply.profile,
                speaker: bot?.title ?? reply.profile,
                toolUpdates: updates,
              ),
              streaming: !reply.complete,
            ),
          if (reply.text.isEmpty && updates.isNotEmpty)
            StreamingStatusWidget(
              updates: updates,
              isStreaming: !reply.complete,
            ),
          if (reply.reasoning.isNotEmpty)
            ExpansionTile(
              title: Text(AppLocalizations.of(context)!.messagesThinking),
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(reply.reasoning),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _activeReply() {
    final reply = _reply!, l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(reply.bot.title, style: Theme.of(context).textTheme.labelMedium),
        StreamingTurnFooter(
          message: reply.message,
          inline: true,
          show: reply.text.isEmpty,
        ),
        if (reply.text.isNotEmpty)
          _bubble(
            HermesGroupMessage(
              id: reply.id,
              text: reply.text,
              at: DateTime.now(),
              botProfile: reply.bot.name,
              speaker: reply.bot.title,
            ),
            streaming: true,
          ),
        if (reply.reasoning.isNotEmpty)
          ExpansionTile(
            title: Text(l10n.messagesThinking),
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: SelectableText(reply.reasoning),
              ),
            ],
          ),
        if (reply.tools.isNotEmpty)
          StreamingStatusWidget(updates: reply.message.statusHistory),
        if (reply.approval != null)
          HermesApprovalCard(
            state: reply.resolving
                ? HermesApprovalState.resolving
                : HermesApprovalState.pending,
            summary: reply.approval!.summary,
            choices: reply.approval!.choices,
            failed: reply.failed,
            onDecision: (approved) => _approval(approved ? 'once' : 'deny'),
            onChoice: _approval,
          ),
        if (reply.decision != null)
          HermesDecisionCard(
            key: ValueKey(reply.decision!.requestId),
            kind: reply.decision!.kind,
            prompt: reply.decision!.prompt,
            mcpServer: reply.decision!.raw['server'] is String
                ? reply.decision!.raw['server'] as String
                : null,
            mcpAction: reply.decision!.raw['action'] is String
                ? reply.decision!.raw['action'] as String
                : null,
            onSubmit: _decision,
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(hermesApiServiceProvider, (previous, next) {
      if (!identical(next, _service)) {
        setState(() => _connectionChanged = true);
      }
    });
    ref.listen(hermesBotGroupsProvider, (previous, next) {
      if (!_busy) {
        final remote = next.asData?.value
            .where((g) => g.identity == _group.identity)
            .firstOrNull;
        if (remote != null) {
          unawaited(() async {
            try {
              final archive = await ref.read(hermesGroupArchiveProvider.future);
              final full = await archive.read(remote);
              if (_current && !_busy) _runtime.replaceGroup(full);
            } catch (_) {
              if (context.mounted && _current && !_busy) {
                AdaptiveSnackBar.show(
                  context,
                  message: 'Could not refresh this group.',
                );
              }
            }
          }());
        }
      }
    });
    final l10n = AppLocalizations.of(context)!,
        bots =
            ref.watch(hermesMessagesBotsProvider).asData?.value ??
            <HermesBot>[];
    final missing =
        _group.hasScopedMembers ||
        !_group.memberProfiles.every((p) => bots.any((b) => b.name == p));
    final anotherRunning = ref.watch(isChatStreamingProvider);
    return AdaptiveScaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
              child: Row(
                children: [
                  CompactIconAction(
                    tooltip: 'Conversations',
                    icon: const Icon(HermesMessageIcons.menu),
                    onPressed: () => showHermesConversationDrawer(
                      context,
                      ref,
                      bots: true,
                      group: _group,
                    ),
                  ),
                  Expanded(
                    child: Center(
                      child: TextButton.icon(
                        onPressed: _settings,
                        icon: const Icon(HermesMessageIcons.groups, size: 22),
                        label: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: Text(
                                _group.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const Icon(Icons.keyboard_arrow_down, size: 16),
                          ],
                        ),
                        style: TextButton.styleFrom(
                          minimumSize: const Size(48, 48),
                          backgroundColor:
                              context.conduitTheme.surfaceContainerHighest,
                        ),
                      ),
                    ),
                  ),
                  HermesGroupActions(group: _group),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                controller: _scroll,
                padding: const EdgeInsets.all(20),
                children: [
                  if (_group.omitted > 0)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Text(
                        l10n.messagesGroupHistoryLimited,
                        style: TextStyle(
                          color: context.conduitTheme.textSecondary,
                        ),
                      ),
                    ),
                  for (final message in _group.messages)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: _bubble(message),
                    ),
                  for (final reply in _runtime.liveReplies) _liveReply(reply),
                  if (_reply != null) _activeReply(),
                  if (_failed)
                    Text(
                      l10n.messagesLoadFailed,
                      style: TextStyle(color: context.conduitTheme.error),
                    ),
                  if (_stopped)
                    TextButton(
                      onPressed: _runtime.resume,
                      child: const Text('Resume group'),
                    ),
                  for (final queued in _runtime.queue)
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            queued.text,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        CompactIconAction(
                          tooltip: 'Edit queued message',
                          icon: const Icon(HermesMessageIcons.edit),
                          onPressed: () async {
                            final text = await editHermesName(
                              context,
                              queued.text,
                              label: 'Message',
                              maxLength: 32000,
                            );
                            if (text != null && mounted) {
                              _runtime.editQueued(queued.id, text);
                            }
                          },
                        ),
                        CompactIconAction(
                          tooltip: 'Remove queued message',
                          icon: const Icon(HermesMessageIcons.close),
                          onPressed: () => _runtime.removeQueued(queued.id),
                        ),
                      ],
                    ),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: StreamingTurnFooter(
                      message: ChatMessage(
                        id: 'group-wait:${_group.identity}',
                        role: 'assistant',
                        content: '',
                        timestamp: DateTime.now(),
                        isStreaming: _busy,
                      ),
                      show:
                          _busy &&
                          _reply == null &&
                          _runtime.liveReplies.isEmpty,
                      suppressStreamingHaptics: true,
                    ),
                  ),
                  for (final action in _runtime.pendingActions)
                    if (action['kind'] == 'retry')
                      TextButton(
                        onPressed: () async {
                          final retry = await confirmHermesRemoval(
                            context,
                            'Retry this member?',
                            'The previous attempt may have completed an action before losing contact. Check its activity before retrying.',
                            confirmText: 'Retry',
                          );
                          if (retry && mounted) {
                            await _runtime.retryNative(
                              action['task_id'].toString(),
                            );
                          }
                        },
                        child: const Text('Retry member'),
                      )
                    else if (action['kind'] == 'approval')
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(action['member_id']?.toString() ?? 'Bot'),
                          HermesApprovalCard(
                            state: HermesApprovalState.pending,
                            onDecision: (approved) => _runtime.approveNative(
                              action,
                              approved ? 'once' : 'deny',
                            ),
                            summary:
                                action['command']?.toString() ??
                                action['description']?.toString() ??
                                'Approval requested',
                            choices: const ['once', 'deny'],
                            onChoice: (choice) =>
                                _runtime.approveNative(action, choice),
                          ),
                        ],
                      ),
                  if (missing) Text(l10n.messagesMissingMember),
                  if (_connectionChanged) Text(l10n.messagesLoadFailed),
                ],
              ),
            ),
            if (_busy)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: TextButton.icon(
                  onPressed: _runtime.stop,
                  icon: const Icon(Icons.stop_rounded),
                  label: Text(l10n.messagesStop),
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: ModernChatInput(
                key: ValueKey('group-composer-${_group.identity}'),
                draftOwner: 'group:${_group.identity}',
                composerTextInsertionTargetId: 'group:${_group.identity}',
                onSendMessage: _send,
                onSendAccepted: _sendAccepted,
                onFileAttachment: _pickFiles,
                onImageAttachment: () async {
                  final files = await FileAttachmentService().pickImages();
                  if (_current) await _addAttachments(files);
                },
                onPastedAttachments: _addAttachments,
                attachedOverlay: _attachments.isEmpty
                    ? null
                    : Wrap(
                        spacing: 8,
                        children: [
                          for (final file in _attachments)
                            InputChip(
                              label: Text(
                                file.displayName,
                                overflow: TextOverflow.ellipsis,
                              ),
                              onDeleted: () =>
                                  setState(() => _attachments.remove(file)),
                            ),
                        ],
                      ),
                enabled: !missing && !anotherRunning && !_connectionChanged,
                showModelSelector: false,
                placeholder: l10n.messagesMessageTo(_group.name),
              ),
            ),
            if (MediaQuery.viewInsetsOf(context).bottom == 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: HermesBottomNavigation(
                  selected: HermesWorkArea.chat,
                  onSelected: (area) {
                    Navigator.of(context).pop();
                    selectHermesWorkAreaRoot(ref, area);
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}
