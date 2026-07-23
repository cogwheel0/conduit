/// App-owned Responses output used to carry an exact direct-provider answer
/// through Open WebUI's persisted-history middleware.
///
/// Open WebUI reloads persisted messages before a completion and converts
/// standard Responses `output` items back into provider messages. Conduit's
/// visible message content is presentation-escaped, so this narrowly marked
/// item preserves the raw answer without teaching the server a custom shape.
const String kConduitDirectReplayOutputIdPrefix =
    'msg_conduit_direct_replay_v1_';
const String kConduitDirectNoFinalReplayOutputIdPrefix =
    'msg_conduit_direct_no_final_v1_';

const String kConduitDirectTransport = 'direct';
const String kConduitDirectRawAssistantContentMetadataKey =
    'conduitDirectRawAssistantContent';
const String kConduitDirectIncompleteAnswerReplayText =
    '[Previous response ended before producing a final answer.]';

final class ConduitDirectReplayOutputMirror {
  const ConduitDirectReplayOutputMirror({
    required this.item,
    required this.text,
    required this.isIncompleteAnswerSentinel,
  });

  final Map<String, dynamic> item;
  final String text;

  final bool isIncompleteAnswerSentinel;
}

/// Builds one standard Responses message item for Open WebUI history replay.
/// Empty answers normally do not need a mirror. A reasoning-only terminal
/// response uses an explicit non-empty sentinel so Open WebUI cannot fall back
/// to replaying Conduit's presentation-only reasoning markup.
List<Map<String, dynamic>>? buildConduitDirectReplayOutput({
  required String assistantMessageId,
  required String rawContent,
  bool useIncompleteAnswerSentinel = false,
}) {
  final replayContent = rawContent.trim().isEmpty
      ? useIncompleteAnswerSentinel
            ? kConduitDirectIncompleteAnswerReplayText
            : null
      : rawContent;
  if (replayContent == null) return null;
  final normalizedId = assistantMessageId.replaceAll(
    RegExp(r'[^A-Za-z0-9_-]'),
    '_',
  );
  final suffix = normalizedId.isEmpty
      ? 'message'
      : normalizedId.length <= 96
      ? normalizedId
      : normalizedId.substring(0, 96);
  final idPrefix = useIncompleteAnswerSentinel
      ? kConduitDirectNoFinalReplayOutputIdPrefix
      : kConduitDirectReplayOutputIdPrefix;
  return <Map<String, dynamic>>[
    <String, dynamic>{
      'type': 'message',
      'id': '$idPrefix$suffix',
      'role': 'assistant',
      'status': 'completed',
      'content': <Map<String, dynamic>>[
        <String, dynamic>{'type': 'output_text', 'text': replayContent},
      ],
    },
  ];
}

/// Recognizes only the exact versioned shape emitted above.
///
/// Requiring exact standard fields prevents an ordinary Open WebUI Responses
/// message from being mistaken for Conduit's replay channel. A direct Ollama
/// Cloud turn may also contain Conduit-owned function-call pairs; every
/// sibling item is validated before the mirror is trusted.
ConduitDirectReplayOutputMirror? parseConduitDirectReplayOutput(
  List<Map<String, dynamic>> output,
) {
  if (output.isEmpty) return null;
  final candidates = output
      .where((item) {
        final id = item['id'];
        return id is String &&
            (id.startsWith(kConduitDirectReplayOutputIdPrefix) ||
                id.startsWith(kConduitDirectNoFinalReplayOutputIdPrefix));
      })
      .toList(growable: false);
  if (candidates.length != 1 ||
      output.any(
        (item) =>
            !identical(item, candidates.single) &&
            !_isConduitDirectToolOutputItem(item),
      )) {
    return null;
  }
  final item = candidates.single;
  if (!_hasExactKeys(item, const <String>{
        'type',
        'id',
        'role',
        'status',
        'content',
      }) ||
      item['type'] != 'message' ||
      item['role'] != 'assistant' ||
      item['status'] != 'completed') {
    return null;
  }
  final id = item['id'];
  if (id is! String) {
    return null;
  }
  final isIncompleteId = id.startsWith(
    kConduitDirectNoFinalReplayOutputIdPrefix,
  );
  final matchedPrefix = isIncompleteId
      ? kConduitDirectNoFinalReplayOutputIdPrefix
      : id.startsWith(kConduitDirectReplayOutputIdPrefix)
      ? kConduitDirectReplayOutputIdPrefix
      : null;
  if (matchedPrefix == null || id.length == matchedPrefix.length) return null;
  final idSuffix = id.substring(matchedPrefix.length);
  if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(idSuffix)) return null;

  final content = item['content'];
  if (content is! List || content.length != 1) return null;
  final rawPart = content.single;
  if (rawPart is! Map) return null;
  final part = rawPart.map<String, dynamic>(
    (key, value) => MapEntry(key.toString(), value),
  );
  if (!_hasExactKeys(part, const <String>{'type', 'text'}) ||
      part['type'] != 'output_text') {
    return null;
  }
  final text = part['text'];
  if (text is! String || text.trim().isEmpty) return null;
  return ConduitDirectReplayOutputMirror(
    item: item,
    text: text,
    isIncompleteAnswerSentinel:
        isIncompleteId && text == kConduitDirectIncompleteAnswerReplayText,
  );
}

bool _isConduitDirectToolOutputItem(Map<String, dynamic> item) {
  final type = item['type'];
  if (type == 'function_call') {
    final id = item['id'];
    final callId = item['call_id'];
    return _hasExactKeys(item, const {
          'type',
          'id',
          'call_id',
          'name',
          'arguments',
          'status',
        }) &&
        id is String &&
        id.startsWith('ollama-') &&
        callId == id &&
        item['name'] is String &&
        item['arguments'] is Map &&
        (item['status'] == 'in_progress' || item['status'] == 'completed');
  }
  if (type == 'function_call_output') {
    final keys = item.keys.toSet();
    final hasAllowedKeys =
        keys.containsAll(const {'type', 'call_id', 'output'}) &&
        keys.difference(const {'type', 'call_id', 'output', 'error'}).isEmpty;
    final callId = item['call_id'];
    return hasAllowedKeys &&
        callId is String &&
        callId.startsWith('ollama-') &&
        (item['error'] == null || item['error'] is bool);
  }
  return false;
}

bool _hasExactKeys(Map<String, dynamic> value, Set<String> expected) {
  return value.length == expected.length &&
      value.keys.toSet().containsAll(expected);
}
