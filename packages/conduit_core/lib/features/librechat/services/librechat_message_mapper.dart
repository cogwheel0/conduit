import 'dart:convert';

import 'package:conduit_core/database/mappers/chat_blob_mapper.dart';
import 'package:conduit_core/features/librechat/models/librechat_message.dart';
import 'package:conduit_core/features/librechat/models/librechat_model.dart';

/// The key LibreChat's own record sits under, in a stored message payload
/// and in a stored chat blob.
///
/// Deliberately not inside `metadata`: an Open WebUI payload's metadata is
/// remote input that parsing strips of LibreChat keys, so routing never
/// trusts it. Whatever reads this key reads it from the LibreChat database.
const String kLibreChatPayloadKey = 'libreChat';

/// Maps LibreChat conversations and messages into the shapes Conduit stores
/// and renders.
///
/// Conduit's local database and its message parser speak Open WebUI's chat
/// blob: `history.messages` keyed by id, each with `parentId`, `childrenIds`,
/// `role`, plain-text `content` and, for structured replies, `output` items.
/// A LibreChat reply's content parts become those output items: text becomes
/// `message`, reasoning `reasoning`, a tool call `function_call` with its
/// `function_call_output`, and a code run `code_interpreter`. The parser
/// then renders them exactly as it renders an Open WebUI reply, live and
/// from history, and `content` stays plain text for search.
abstract final class LibreChatMessageMapper {
  /// LibreChat's code interpreter tool.
  static const String codeToolName = 'execute_code';

  /// The chat blob for [conversation] with [messages].
  static Map<String, dynamic> chatBlob(
    LibreChatConversation conversation,
    List<LibreChatMessage> messages,
  ) {
    final children = <String, List<String>>{};
    final ids = {for (final message in messages) message.messageId};
    for (final message in messages) {
      final parent = message.parentMessageId;
      if (parent != null && ids.contains(parent)) {
        (children[parent] ??= <String>[]).add(message.messageId);
      }
    }
    return <String, dynamic>{
      'title': conversation.title,
      'history': <String, dynamic>{
        'messages': <String, dynamic>{
          for (final message in messages)
            message.messageId: messagePayload(
              message,
              childrenIds: children[message.messageId] ?? const <String>[],
              knownIds: ids,
            ),
        },
        'currentId': currentLeaf(messages),
      },
      'models': ?_modelIds(conversation),
      kLibreChatPayloadKey: conversation.raw,
    };
  }

  /// The picker id of what [conversation] runs on, as the chat's `models`,
  /// so opening it selects that model again.
  static List<String>? _modelIds(LibreChatConversation conversation) {
    final id = libreChatModelIdFor(
      endpoint: conversation.endpoint,
      model: conversation.model,
      agentId: conversation.agentId,
      spec: conversation.spec,
    );
    return id == null ? null : [id];
  }

  /// The rows [conversation] with [messages] is stored as.
  static ChatRows chatRows(
    LibreChatConversation conversation,
    List<LibreChatMessage> messages,
  ) {
    final createdAt = _epochSeconds(conversation.createdAt) ?? 0;
    return ChatBlobMapper.blobToRows(
      chatId: conversation.conversationId,
      blob: chatBlob(conversation, messages),
      title: conversation.title,
      pinned: conversation.pinned,
      archived: conversation.isArchived,
      createdAt: createdAt,
      updatedAt: _epochSeconds(conversation.updatedAt) ?? createdAt,
    );
  }

  /// One message in Open WebUI's history shape. A parent that is not among
  /// [knownIds] (a branch the server pruned) leaves the message a root.
  static Map<String, dynamic> messagePayload(
    LibreChatMessage message, {
    List<String> childrenIds = const <String>[],
    Set<String>? knownIds,
  }) {
    final parent = message.parentMessageId;
    final isUser = message.isCreatedByUser;
    final parts = message.content;
    final citations = LibreChatCitations.fromAttachments(message.attachments);
    final payload = <String, dynamic>{
      'id': message.messageId,
      'parentId': parent != null && (knownIds?.contains(parent) ?? true)
          ? parent
          : null,
      'childrenIds': childrenIds,
      'role': isUser ? 'user' : 'assistant',
      'content': plainText(message, citations: citations),
      'timestamp': _epochSeconds(message.createdAt) ?? 0,
      if (!isUser) 'model': message.model ?? message.endpoint ?? 'librechat',
      if (!isUser && message.sender != null) 'modelName': message.sender,
      if (!isUser) 'done': true,
    };
    final files = _files(message);
    if (files.isNotEmpty) payload['files'] = files;
    if (!isUser && parts.isNotEmpty) {
      final items = outputItems(parts, citations: citations);
      if (items.isNotEmpty) payload['output'] = items;
    }
    if (citations.sources.isNotEmpty) payload['sources'] = citations.sources;
    final error = _errorText(message);
    if (error != null) payload['error'] = {'content': error};
    payload[kLibreChatPayloadKey] = message.raw;
    return payload;
  }

  /// [message] as plain text: a reply's text parts (citation markers turned
  /// into `[n]`), else its `text`. A prompt is its `text`, else its text
  /// parts, which is all a prompt synced from an Assistants thread has.
  static String plainText(
    LibreChatMessage message, {
    LibreChatCitations? citations,
  }) {
    final parts = message.content;
    final cite = citations ?? LibreChatCitations.none();
    if (parts.isEmpty ||
        (message.isCreatedByUser && message.text.trim().isNotEmpty)) {
      return cite.rewrite(message.text);
    }
    final buffer = StringBuffer();
    for (final part in parts) {
      if (part['type'] != 'text') continue;
      final text = cite.rewrite(partText(part['text']));
      if (text.trim().isEmpty) continue;
      if (buffer.isNotEmpty) buffer.write('\n\n');
      buffer.write(text);
    }
    return buffer.isEmpty ? cite.rewrite(message.text) : buffer.toString();
  }

  /// Open WebUI output items for a reply's [parts]. [inProgress] marks the
  /// last reasoning, and every tool call still without a result, as still
  /// running; in a reply that has ended, such a call stopped unfinished.
  static List<Map<String, dynamic>> outputItems(
    List<Map<String, dynamic>> parts, {
    bool inProgress = false,
    LibreChatCitations? citations,
  }) {
    final cite = citations ?? LibreChatCitations.none();
    final items = <Map<String, dynamic>>[];
    final usedIds = <String>{};
    for (var index = 0; index < parts.length; index++) {
      final part = parts[index];
      final isLast = index == parts.length - 1;
      switch (part['type']) {
        case 'text':
          final text = cite.rewrite(partText(part['text']));
          if (text.trim().isEmpty) continue;
          items.add({
            'type': 'message',
            'role': 'assistant',
            'content': [
              {'type': 'output_text', 'text': text},
            ],
          });
        case 'think':
          final text = partText(part['think']);
          if (text.trim().isEmpty && !(inProgress && isLast)) continue;
          items.add({
            'type': 'reasoning',
            'content': [
              {'type': 'output_text', 'text': text},
            ],
            'status': inProgress && isLast ? 'in_progress' : 'completed',
          });
        case 'tool_call':
          final call = part['tool_call'];
          if (call is Map) {
            final map = Map<String, dynamic>.from(call);
            // Providers number calls per agent (`call_0`), so two agents in
            // one reply can share an id; a repeat is scoped to its part so
            // each call keeps its own result.
            var id = _callId(map);
            if (!usedIds.add(id)) usedIds.add(id = '$id#$index');
            items.addAll(_toolCallItems(map, id: id, running: inProgress));
          }
      }
    }
    return items;
  }

  /// The provider's id for [call], else its step, else its name.
  static String _callId(Map<String, dynamic> call) {
    final id = call['id'];
    if (id is String && id.isNotEmpty) return id;
    final function = call['function'];
    return (call['stepId'] ??
            (function is Map ? function['name'] : null) ??
            call['name'] ??
            call['type'] ??
            'tool')
        .toString();
  }

  /// [call] as output items. A call without a result is running while
  /// the reply is [running], and stopped unfinished once it has ended.
  static List<Map<String, dynamic>> _toolCallItems(
    Map<String, dynamic> call, {
    required String id,
    required bool running,
  }) {
    final unfinished = running ? 'in_progress' : 'incomplete';
    final type = call['type'];
    // Assistants history nests a call under its type: `function: {name,
    // arguments, output}` or `code_interpreter: {input, outputs}`.
    final interpreter = call['code_interpreter'];
    if (type == 'code_interpreter' && interpreter is Map) {
      final outputs = interpreter['outputs'];
      final logs = [
        if (outputs is List)
          for (final output in outputs)
            if (output is Map && output['logs'] is String)
              output['logs'] as String,
      ].join('\n');
      final done =
          call['progress'] == 1 || (outputs is List && outputs.isNotEmpty);
      return [
        {
          'type': 'code_interpreter',
          'id': id,
          'code': interpreter['input']?.toString() ?? '',
          'lang': 'python',
          'status': done ? 'completed' : unfinished,
          if (logs.isNotEmpty) 'output': logs,
        },
      ];
    }
    final function = call['function'];
    final source = function is Map ? function : call;
    final rawName = source['name'];
    final name = rawName is String && rawName.isNotEmpty
        ? rawName
        : (type == 'retrieval' || type == 'file_search')
        ? type as String
        : '';
    final args = function is Map ? function['arguments'] : call['args'];
    final output = source['output'] ?? call['output'];
    final done = output != null || call['progress'] == 1;
    if (name == codeToolName) {
      final parsed = args is Map ? args : _tryDecode(args);
      return [
        {
          'type': 'code_interpreter',
          'id': id,
          'code': parsed is Map ? parsed['code']?.toString() ?? '' : '',
          'lang': parsed is Map
              ? parsed['lang']?.toString() ?? 'python'
              : 'python',
          'status': done ? 'completed' : unfinished,
          'output': ?output,
        },
      ];
    }
    final awaitingApproval = !done && call['approval'] is Map;
    return [
      {
        'type': 'function_call',
        'call_id': id,
        'name': name.isEmpty ? 'tool' : name,
        // A complete JSON object, which a call without arguments may have
        // stored as an empty string.
        'arguments': args is String
            ? (args.trim().isEmpty ? '{}' : args)
            : jsonEncode(args ?? const {}),
        'status': done
            ? 'completed'
            : awaitingApproval
            ? 'pending'
            : unfinished,
      },
      if (done)
        {
          'type': 'function_call_output',
          'call_id': id,
          'output': output is String ? output : jsonEncode(output),
        },
    ];
  }

  /// A part's text, which LibreChat stores as a string or `{value}`.
  static String partText(Object? value) {
    if (value is String) return value;
    if (value is Map && value['value'] is String) {
      return value['value'] as String;
    }
    return '';
  }

  /// The leaf of the newest branch: from each root take the newest child,
  /// down to a message without children. LibreChat shows the latest branch
  /// unless the user picked another; the choice is not stored on the server.
  static String? currentLeaf(List<LibreChatMessage> messages) {
    if (messages.isEmpty) return null;
    final byId = {for (final message in messages) message.messageId: message};
    final children = <String?, List<LibreChatMessage>>{};
    for (final message in messages) {
      final parent = message.parentMessageId;
      final key = parent != null && byId.containsKey(parent) ? parent : null;
      (children[key] ??= <LibreChatMessage>[]).add(message);
    }
    LibreChatMessage? newest(List<LibreChatMessage>? candidates) {
      if (candidates == null || candidates.isEmpty) return null;
      return candidates.reduce((a, b) {
        final at = a.createdAt;
        final bt = b.createdAt;
        if (at == null) return b;
        if (bt == null) return a;
        // On a tie (an imported chat, say) the later one in the server's
        // list, as LibreChat's own branch walk picks.
        return bt.isBefore(at) ? a : b;
      });
    }

    var current = newest(children[null]);
    final seen = <String>{};
    while (current != null && seen.add(current.messageId)) {
      final next = newest(children[current.messageId]);
      if (next == null) break;
      current = next;
    }
    return current?.messageId;
  }

  static String? _errorText(LibreChatMessage message) {
    for (final part in message.content) {
      if (part['type'] != 'error') continue;
      final text = partText(part['error'] ?? part['text']);
      if (text.trim().isNotEmpty) return libreChatReadableError(text);
    }
    if (!message.isError) return null;
    final text = message.text.trim();
    return text.isEmpty ? 'The reply failed.' : libreChatReadableError(text);
  }

  /// Files the user attached and images the reply produced, as Open WebUI
  /// file descriptors. Server paths stay relative; whoever loads them adds
  /// the session (LibreChat serves `/images/` by cookie). A file named only
  /// by its `file_id` (an Assistants thread's upload) keeps that id and no
  /// URL, so it is remembered until something can load it.
  static List<Map<String, dynamic>> _files(LibreChatMessage message) {
    final files = <Map<String, dynamic>>[];
    void add(Map<String, dynamic> file) {
      final path = file['filepath'] ?? file['url'];
      final hasPath = path is String && path.isNotEmpty;
      final fileId = file['file_id'];
      if (!hasPath && (fileId is! String || fileId.isEmpty)) return;
      final type = file['type'];
      final isImage =
          (type is String && type.startsWith('image/')) ||
          file['width'] is num ||
          file['height'] is num;
      files.add({
        'type': isImage ? 'image' : 'file',
        'url': ?(hasPath ? path : null),
        'name': ?file['filename'],
        'size': ?file['bytes'],
        if (type is String) 'content_type': type,
        'libreChatFileId': ?file['file_id'],
      });
    }

    message.files.forEach(add);
    for (final attachment in message.attachments) {
      final type = attachment['type'];
      if (type == 'web_search' || type == 'file_search') continue;
      add(attachment);
    }
    for (final part in message.content) {
      if (part['type'] == 'image_file' && part['image_file'] is Map) {
        add(Map<String, dynamic>.from(part['image_file'] as Map));
      } else if (part['type'] == 'image_url') {
        final image = part['image_url'];
        final url = image is Map ? image['url'] : image;
        if (url is String && !url.startsWith('data:')) {
          add({'filepath': url, 'width': 0});
        }
      }
    }
    return files;
  }

  static Object? _tryDecode(Object? value) {
    if (value is! String || value.isEmpty) return null;
    try {
      return jsonDecode(value);
    } on FormatException {
      return null;
    }
  }

  static int? _epochSeconds(DateTime? time) =>
      time == null ? null : time.millisecondsSinceEpoch ~/ 1000;
}

/// The web sources a reply cites, and how its citation markers read as
/// Conduit's `[n]` references into them.
///
/// LibreChat's web search tool numbers results by search turn and kind;
/// the model cites them with private-use markers such as `\ue202turn0search1`
/// (or the same escape written out literally), grouped and highlighted by
/// further markers. See LibreChat's `client/src/utils/citations.ts`.
final class LibreChatCitations {
  LibreChatCitations._(this._byTurn);

  /// Citations of a reply without search results: markers are removed.
  LibreChatCitations.none() : _byTurn = const {};

  /// Reads the turns of the web and file search [attachments].
  factory LibreChatCitations.fromAttachments(
    List<Map<String, dynamic>> attachments,
  ) {
    final byTurn = <int, Map<String, dynamic>>{};
    var fileTurn = 0;
    for (final attachment in attachments) {
      final type = attachment['type'];
      final data = attachment[type];
      if (data is! Map) continue;
      // A turn can hold web and file results at once: each fills in its
      // own categories rather than replacing the other's. File results
      // keep a list of their own, apart from the web's `references`.
      if (type == 'web_search' && data['turn'] is int) {
        final turn = data['turn'] as int;
        byTurn[turn] = {...?byTurn[turn], ...Map<String, dynamic>.from(data)};
      } else if (type == 'file_search' && data['sources'] is List) {
        final turn = fileTurn++;
        byTurn[turn] = {
          ...?byTurn[turn],
          _fileSources: [
            for (final source in data['sources'] as List)
              if (source is Map)
                {
                  'title': source['fileName'] ?? 'File',
                  'link': '',
                  'type': 'file',
                },
          ],
        };
      }
    }
    return LibreChatCitations._(byTurn);
  }

  final Map<int, Map<String, dynamic>> _byTurn;
  final List<Map<String, dynamic>> _sources = <Map<String, dynamic>>[];
  final Map<String, int> _numbers = <String, int>{};

  /// The sources cited so far by [rewrite], in citation order.
  List<Map<String, dynamic>> get sources => List.unmodifiable(_sources);

  static final RegExp _anchor = RegExp(
    r'(?:\\ue202|\ue202)turn(\d+)(search|image|news|video|ref|file)(\d+)',
  );
  static final RegExp _markers = RegExp(r'\\ue20[0-6]|[\ue200-\ue206]');

  /// Where a turn keeps file search results.
  static const String _fileSources = 'conduitFileSources';

  static const Map<String, String> _kinds = {
    'search': 'organic',
    'news': 'topStories',
    'ref': 'references',
    'file': _fileSources,
    'image': 'images',
    'video': 'videos',
  };

  /// [text] with every citation anchor that names a known source turned
  /// into `[n]`, and every other citation marker removed.
  String rewrite(String text) {
    if (!text.contains('ue20') && !text.contains(RegExp('[\ue200-\ue206]'))) {
      return text;
    }
    final replaced = text.replaceAllMapped(_anchor, (match) {
      final turn = int.parse(match.group(1)!);
      var kind = _kinds[match.group(2)!]!;
      final index = int.parse(match.group(3)!);
      // LibreChat reads `ref` and `file` from one list, so a `ref` in a
      // turn without web references can only mean one of its files.
      if (kind == 'references' && _byTurn[turn]?['references'] is! List) {
        kind = _fileSources;
      }
      final list = _byTurn[turn]?[kind];
      if (list is! List || index >= list.length || list[index] is! Map) {
        return '';
      }
      final key = '$turn/$kind/$index';
      final number = _numbers[key] ??= () {
        final source = list[index] as Map;
        final link = source['link'] ?? source['imageUrl'] ?? '';
        _sources.add({
          'id': key,
          'title': source['title'] ?? source['attribution'] ?? link,
          'url': link,
          if (source['snippet'] is String) 'snippet': source['snippet'],
          'type': kind == _fileSources ? 'file' : 'web',
        });
        return _sources.length;
      }();
      return ' [$number]';
    });
    return replaced.replaceAll(_markers, '');
  }
}
