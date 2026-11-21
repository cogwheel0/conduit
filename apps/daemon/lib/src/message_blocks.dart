import 'dart:collection';
import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:conduit_core/features/chat/views/assistant_message_blocks.dart';
import 'package:conduit_core/features/chat/utils/openwebui_tasks.dart';
import 'package:conduit_core/features/chat/views/chat_status_display.dart';
import 'package:conduit_core/features/hermes/models/hermes_error_surface.dart';
import 'package:conduit_core/features/hermes/models/hermes_inline_diff.dart';
import 'package:conduit_core/features/hermes/models/hermes_model.dart'
    show hermesDesktopModel;
import 'package:conduit_core/features/mcp_apps/openwebui_mcp_app.dart';
import 'package:conduit_core/models/chat_message.dart' as core;
import 'package:conduit_core/services/chat_completion_transport.dart'
    show isHeldReplyUnresolvedError;
import 'package:conduit_core/services/structured_output.dart'
    show displayedChatFiles;
import 'package:conduit_core/utils/source_reference_helper.dart';
import 'package:conduit_markdown/conduit_markdown.dart' as md;
import 'package:conduit_core/features/tether/tether_relay_failure.dart';
import 'package:conduit_protocol/conduit_protocol.dart';

import 'apple_models_service.dart' show appleErrorType;

/// Assistant messages as wire blocks: the core's display blocks
/// ([assistantMessageBlocks]) put into [MessageBlockDto]s, with the blocks
/// of stored messages cached.
///
/// Opening a chat parses every answer in it, and a long answer costs
/// milliseconds; opening it again, or refetching it after `chats.changed`,
/// should not cost that again. So each message's blocks are kept, keyed by
/// its id, and reused while its content and everything else the blocks are
/// made from are unchanged.
final class MessageBlocks {
  MessageBlocks({this.capacity = 4000});

  /// Messages kept, least recently used first out.
  final int capacity;

  final LinkedHashMap<String, _Cached> _cache =
      LinkedHashMap<String, _Cached>();

  /// Lookups answered from the cache, for tests and diagnostics.
  int hits = 0;

  /// Lookups that parsed.
  int misses = 0;

  /// [message]'s blocks; empty for anything but an assistant message.
  List<MessageBlockDto> forMessage(core.ChatMessage message) {
    if (message.role != 'assistant') return const <MessageBlockDto>[];
    return _cached(
      message.id,
      message.content,
      messageBlockInputsHash(message),
      () => toDtos(assistantMessageBlocks(message)),
    );
  }

  /// The blocks of [version], an earlier answer kept on [message].
  List<MessageBlockDto> forVersion(
    core.ChatMessage message,
    core.ChatMessageVersion version,
  ) => _cached(
    '${message.id}#${version.id}',
    version.content,
    _versionInputsHash(version),
    () => toDtos(assistantVersionBlocks(version)),
  );

  List<MessageBlockDto> _cached(
    String key,
    String content,
    int inputs,
    List<MessageBlockDto> Function() build,
  ) {
    final cached = _cache.remove(key);
    if (cached != null &&
        cached.inputs == inputs &&
        cached.content == content) {
      _cache[key] = cached;
      hits++;
      return cached.blocks;
    }
    misses++;
    final blocks = build();
    _cache[key] = _Cached(content, inputs, blocks);
    while (_cache.length > capacity) {
      _cache.remove(_cache.keys.first);
    }
    return blocks;
  }

  /// The core's blocks, as the wire carries them.
  static List<MessageBlockDto> toDtos(List<AssistantBlock> blocks) =>
      List<MessageBlockDto>.unmodifiable(blocks.map(_toDto));

  static MessageBlockDto _toDto(AssistantBlock block) => switch (block) {
    AssistantFilesBlock(:final files) => MessageBlockDto(
      kind: MessageBlockKind.files,
      files: chatFileDtos(files),
    ),
    AssistantEmbedsBlock(:final embeds) => MessageBlockDto(
      kind: MessageBlockKind.embeds,
      embeds: embedDtos(embeds),
    ),
    AssistantStatusBlock() => MessageBlockDto(
      kind: MessageBlockKind.status,
      pending: block.pending,
      summary: block.toolSummary,
      statuses: <MessageStatusDto>[
        for (final line in block.lines)
          MessageStatusDto(
            description: line.description,
            phrase: switch (line.phrase) {
              null => null,
              ChatStatusPhrase.knowledgeSearch => StatusPhrase.knowledgeSearch,
              ChatStatusPhrase.searching => StatusPhrase.searching,
              ChatStatusPhrase.querying => StatusPhrase.querying,
              ChatStatusPhrase.sourcesRetrieved =>
                StatusPhrase.sourcesRetrieved,
              ChatStatusPhrase.processing => StatusPhrase.processing,
            },
            count: line.count,
            query: line.query,
            action: line.action,
            done: line.done,
            queries: line.queries,
            links: <ChatSourceDto>[
              for (final link in line.links)
                ChatSourceDto(
                  label: (link.title?.trim().isNotEmpty ?? false)
                      ? link.title!.trim()
                      : statusLinkDomain(link.url),
                  url: _isWebAddress(link.url) ? link.url : null,
                ),
            ],
            details: <ChatSourceDto>[
              for (final item in line.details)
                ChatSourceDto(label: item.title ?? '', snippet: item.snippet),
            ],
          ),
      ],
    ),
    AssistantMarkdownBlock(:final block) => _markdownDto(block),
    AssistantErrorBlock() => MessageBlockDto(
      kind: MessageBlockKind.error,
      error: block.text,
      type: block.toolsUnsupported
          ? 'directToolsUnsupported'
          : isHeldReplyUnresolvedError(block.text)
          // A polling-only server's reply Conduit stopped waiting for: the
          // core keeps its words in English; the window says it its way.
          ? 'heldReplyStillRunning'
          : switch (block.relayFailure) {
              TetherRelayFailure.interrupted => 'tetherInterrupted',
              TetherRelayFailure.unavailable => 'tetherUnavailable',
              TetherRelayFailure.busy => 'tetherBusy',
              null => appleErrorType(block.text),
            },
      hermesError: switch (block.hermes) {
        final surface? => hermesErrorDto(surface),
        null => null,
      },
    ),
    AssistantChangedFilesBlock(:final files) => MessageBlockDto(
      kind: MessageBlockKind.changedFiles,
      changedFiles: changedFileDtos(files),
    ),
    AssistantCodeExecutionBlock(:final execution) => MessageBlockDto(
      kind: MessageBlockKind.codeExecution,
      id: execution.id,
      name: (execution.name?.isNotEmpty ?? false) ? execution.name : null,
      code: execution.code ?? '',
      language: execution.language ?? '',
      output: execution.result?.output,
      error: execution.result?.error,
      done: block.done,
      pending: !block.done,
      isError: block.isError,
      files: chatFileDtos(<Map<String, dynamic>>[
        for (final file
            in execution.result?.files ?? <core.ChatExecutionFile>[])
          <String, dynamic>{'name': ?file.name, 'url': ?file.url},
      ]),
    ),
    AssistantSourcesBlock(:final sources) => MessageBlockDto(
      kind: MessageBlockKind.sources,
      sources: chatSourceDtos(sources),
    ),
    AssistantFollowUpsBlock(:final followUps) => MessageBlockDto(
      kind: MessageBlockKind.followUps,
      followUps: followUps,
    ),
  };

  static MessageBlockDto _markdownDto(md.MessageBlock block) => switch (block) {
    md.TextMessageBlock(:final markdown) => MessageBlockDto(
      kind: MessageBlockKind.text,
      markdown: markdown,
    ),
    md.AlertMessageBlock(:final type, :final markdown) => MessageBlockDto(
      kind: MessageBlockKind.alert,
      type: type,
      markdown: markdown,
    ),
    md.ReasoningMessageBlock() => _reasoningDto(block),
    md.ToolCallsMessageBlock(:final calls) => MessageBlockDto(
      kind: MessageBlockKind.toolCalls,
      calls: <ToolCallDto>[
        for (final call in calls)
          ToolCallDto(
            id: call.id,
            name: call.name,
            arguments: call.arguments,
            result: call.result,
            done: call.done,
            pending: call.pending,
            status: call.status,
            isError: call.isError,
            files: call.files,
            embeds: call.embeds,
            shownEmbeds: embedDtos(
              assistantEmbeds(call.embeds, argsText: call.arguments),
            ),
          ),
      ],
    ),
    md.CodeInterpreterMessageBlock() => MessageBlockDto(
      kind: MessageBlockKind.codeInterpreter,
      code: block.code,
      language: block.language,
      output: block.output,
      done: block.done,
      pending: block.pending,
    ),
    md.DetailsMessageBlock() => MessageBlockDto(
      kind: MessageBlockKind.details,
      type: block.type,
      summary: block.summary,
      body: block.body,
      done: block.done,
      pending: block.pending,
    ),
  };

  static MessageBlockDto _reasoningDto(md.ReasoningMessageBlock block) {
    final title = block.title;
    return MessageBlockDto(
      kind: MessageBlockKind.reasoning,
      summary: block.summary,
      title: switch (title.kind) {
        md.ReasoningTitleKind.thinking => ReasoningTitle.thinking,
        md.ReasoningTitleKind.thoughtFor => ReasoningTitle.thoughtFor,
        md.ReasoningTitleKind.summary => ReasoningTitle.summary,
        md.ReasoningTitleKind.thoughts => ReasoningTitle.thoughts,
      },
      durationSeconds: title.kind == md.ReasoningTitleKind.thoughtFor
          ? title.seconds
          : block.durationSeconds,
      done: block.done,
      pending: block.pending,
      body: block.body,
    );
  }

  static bool _isWebAddress(String url) =>
      url.startsWith('https://') || url.startsWith('http://');
}

final class _Cached {
  _Cached(this.content, this.inputs, this.blocks);

  final String content;
  final int inputs;
  final List<MessageBlockDto> blocks;
}

const DeepCollectionEquality _deep = DeepCollectionEquality();

/// A hash of everything besides the content that [message]'s blocks are
/// made from: whether it is still streaming, its files, status timeline,
/// error, code executions, sources and follow-ups. Two messages with the
/// same content and the same hash have the same blocks.
int messageBlockInputsHash(core.ChatMessage message) => Object.hash(
  message.isStreaming,
  message.metadata?['responseDone'],
  message.metadata?['openwebuiRecoverableError'],
  _deep.hash(message.files),
  _deep.hash(message.embeds),
  _deep.hash(displayedChatFiles(message.output)),
  _deep.hash(message.attachmentIds),
  _deep.hash(message.statusHistory),
  message.error,
  _deep.hash(message.codeExecutions),
  _deep.hash(message.sources),
  _deep.hash(message.followUps),
  // A Hermes failure's card.
  _deep.hash(message.metadata?[kHermesErrorSurfaceMeta]),
);

int _versionInputsHash(core.ChatMessageVersion version) => Object.hash(
  _deep.hash(version.files),
  _deep.hash(version.embeds),
  _deep.hash(displayedChatFiles(version.output)),
  version.error,
  _deep.hash(version.codeExecutions),
  _deep.hash(version.sources),
  _deep.hash(version.followUps),
);

/// Labels and links as the mobile app shows them, from the helper both
/// apps share: Open WebUI nests a source's name differently for web
/// results, files and knowledge bases.
///
/// An inline citation reads as the mobile app's badge does: the source's
/// site ([ChatSourceDto.inlineLabel]), or with "show citation titles" its
/// own title ([ChatSourceDto.inlineTitle]), shortened the same way.
List<ChatSourceDto> chatSourceDtos(List<core.ChatSourceReference> sources) =>
    <ChatSourceDto>[
      for (var i = 0; i < sources.length; i++)
        ChatSourceDto(
          label: SourceReferenceHelper.getSourceLabel(sources[i], i),
          url: SourceReferenceHelper.getSourceUrl(sources[i]),
          snippet: sources[i].snippet,
          inlineLabel: SourceReferenceHelper.formatDisplayTitle(
            SourceReferenceHelper.getInlineSourceLabel(sources[i], i),
          ),
          inlineTitle: SourceReferenceHelper.formatDisplayTitle(
            SourceReferenceHelper.getInlineSourceLabel(
              sources[i],
              i,
              preferTitle: true,
            ),
          ),
          type: (sources[i].type?.trim().isNotEmpty ?? false)
              ? sources[i].type!.trim()
              : null,
        ),
    ];

/// The core's embeds, as the wire carries them.
List<EmbedDto> embedDtos(List<AssistantEmbed> embeds) => <EmbedDto>[
  for (final embed in embeds)
    switch (embed.kind) {
      AssistantEmbedKind.html => EmbedDto(
        kind: EmbedKind.html,
        source: embed.source,
        argsText: embed.argsText,
      ),
      AssistantEmbedKind.url => EmbedDto(
        kind: EmbedKind.url,
        source: embed.source,
      ),
      AssistantEmbedKind.mcpApp => EmbedDto(
        kind: EmbedKind.mcpApp,
        app: mcpAppDto(embed.app!),
      ),
    },
];

/// [app] as the wire carries it: its input and result as JSON text.
McpAppDto mcpAppDto(OpenWebUiMcpApp app) => McpAppDto(
  serverId: app.serverId,
  toolName: app.toolName,
  binding: app.binding,
  arguments: jsonEncode(app.arguments),
  result: jsonEncode(app.result),
);

/// Open WebUI's file descriptors, reduced to what the window draws.
///
/// The id is found wherever this server version put it: `file_id`, `id`,
/// a `/api/v1/files/{id}/content` URL, or a bare id in `url`. A remote
/// http(s) URL is dropped rather than passed on -- the window would load
/// it straight from the internet, which is what a tracking pixel is.
List<ChatFileDto> chatFileDtos(List<Map<String, dynamic>>? files) =>
    <ChatFileDto>[
      for (final file in files ?? const <Map<String, dynamic>>[])
        ?chatFileDto(file),
    ];

/// One file of [chatFileDtos], or null when there is nothing to load it by.
ChatFileDto? chatFileDto(Map<String, dynamic> file) {
  final url = file['url']?.toString() ?? '';
  final nested = file['file'] is Map
      ? Map<String, dynamic>.from(file['file'] as Map)
      : const <String, dynamic>{};
  final meta = nested['meta'] is Map
      ? Map<String, dynamic>.from(nested['meta'] as Map)
      : const <String, dynamic>{};
  String? id = file['file_id']?.toString() ?? nested['id']?.toString();
  // Matched on the path: a query (`?attachment=false`) is not the id's.
  final fromUrl = RegExp(r'/api/v1/files/([^/]+)(?:/content)?$')
      .firstMatch(Uri.tryParse(url)?.path ?? url);
  if (id == null && fromUrl != null) id = fromUrl.group(1);
  if (id == null &&
      url.isNotEmpty &&
      !url.startsWith('data:') &&
      !url.startsWith('http') &&
      !url.startsWith('/')) {
    id = url;
  }
  id ??= file['id']?.toString();
  final dataUrl = url.startsWith('data:') ? url : null;
  if (id == null && dataUrl == null) return null;
  final contentType = (file['content_type'] ?? meta['content_type'])
      ?.toString();
  final image =
      file['type'] == 'image' || (contentType?.startsWith('image/') ?? false);
  String? named(Object? value) {
    final text = value?.toString();
    return text == null || text.isEmpty ? null : text;
  }

  final name =
      named(file['name']) ??
      named(file['filename']) ??
      named(meta['name']) ??
      named(nested['filename']) ??
      (image ? 'image' : 'file');
  return ChatFileDto(
    id: dataUrl == null ? id : null,
    name: name,
    image: image,
    contentType: contentType,
    dataUrl: dataUrl,
  );
}

/// Open WebUI's task checklist in a conversation's [metadata], as the wire
/// carries it.
List<ChatTaskDto> chatTaskDtos(Map<String, dynamic>? metadata) => <ChatTaskDto>[
  for (final task in openWebUiTasksOf(metadata))
    ChatTaskDto(id: task.id, content: task.content, status: task.status),
];

/// A Hermes failure's card, as [now] sees it: the fixes the desktop can
/// perform, best first (Use Credits is left to a phone or the web, and
/// signing in to a gateway again to Settings, so the next fix shows
/// instead, as mobile does where it cannot perform one).
HermesErrorDto hermesErrorDto(HermesErrorSurface surface, {DateTime? now}) {
  final at = now ?? DateTime.now();
  final suggestion = surface.suggestions.firstOrNull;
  return HermesErrorDto(
    kind: surface.kind.name,
    blocking: surface.severityAt(at) == HermesErrorSeverity.blocking,
    message: surface.message,
    provider: surface.providerName,
    model: surface.model,
    resetsAtMs: surface.resetsAt?.millisecondsSinceEpoch,
    partial: surface.partial,
    actions: <String>[
      for (final action in surface.actionsAt(at))
        if (action != HermesErrorAction.useCredits &&
            action != HermesErrorAction.signInToGateway)
          action.name,
    ],
    switchTo: suggestion == null
        ? null
        : HermesModelChoiceDto(
            modelId: hermesDesktopModel(
              modelId: suggestion.model,
              name: suggestion.label,
              provider: suggestion.provider,
            ).id,
            label: suggestion.label,
          ),
    billingUrl: surface.billingPageUrl,
    providerSettingsUrl: surface.providerSettingsUrl,
  );
}

/// The files a Hermes reply changed, each with its lines, under the full
/// path Hermes sent (the window shortens it against the chat's working
/// directory, `HermesWork.workingDirectory`).
List<ChangedFileDto> changedFileDtos(List<HermesDiffFile> files) =>
    <ChangedFileDto>[
      for (final file in files)
        ChangedFileDto(
          path: file.path,
          added: file.added,
          removed: file.removed,
          lines: <DiffLineDto>[
            for (final line in file.lines)
              DiffLineDto(
                kind: switch (line.kind) {
                  HermesDiffLineKind.context => DiffLineKind.context,
                  HermesDiffLineKind.added => DiffLineKind.added,
                  HermesDiffLineKind.removed => DiffLineKind.removed,
                  HermesDiffLineKind.hunk => DiffLineKind.hunk,
                  HermesDiffLineKind.note => DiffLineKind.note,
                },
                text: line.text,
                oldNumber: line.oldNumber,
                newNumber: line.newNumber,
              ),
          ],
        ),
    ];
