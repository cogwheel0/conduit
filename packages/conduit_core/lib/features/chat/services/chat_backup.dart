import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

/// Why a backup, restore or export did not complete.
enum ChatBackupFailure {
  /// The server's export was cut off or is not valid JSON, so a file written
  /// from it would look complete and not be.
  malformedExport,

  /// The chosen file is not UTF-8 JSON.
  notJson,

  /// The file is JSON but not a list of chats.
  notAList,

  /// The file holds no chats.
  emptyImport,

  /// The file is larger than one import request may be.
  fileTooLarge,

  /// An entry is not a chat this app can send: [ChatBackupException.index]
  /// names it.
  unrecognizedChat,

  /// An entry carries a field of the wrong type for the server's import form.
  invalidField,

  /// The user stopped it.
  cancelled,

  /// The server, account or sign-in session changed while it ran.
  ownerChanged,
}

final class ChatBackupException implements Exception {
  const ChatBackupException(this.failure, {this.index});

  final ChatBackupFailure failure;

  /// 0-based position of the offending chat in the file, when there is one.
  final int? index;

  @override
  String toString() => 'ChatBackupException(${failure.name}, index: $index)';
}

/// Where a library backup is written. Nothing is delivered to the user until
/// [commit]; [abort] discards whatever was written.
abstract interface class ChatBackupSink {
  Future<void> write(String text);

  Future<void> commit();

  Future<void> abort();
}

/// Decodes one JSON document. The default decodes inline; a caller may move
/// large documents off the UI isolate.
typedef ChatBackupDecoder = Future<Object?> Function(String json);

Future<Object?> _decodeInline(String json) async => jsonDecode(json);

@immutable
final class ChatLibraryBackupResult {
  const ChatLibraryBackupResult({required this.chats});

  /// Chats written to the backup.
  final int chats;
}

/// Writes the server's chat export to [sink] as one JSON array of the complete
/// raw envelopes, the file Open WebUI's own Data controls produce.
///
/// The server streams newline-delimited JSON, one `ChatResponse` per line, in
/// UTF-8 chunks that may split a character or a line anywhere; the last line may
/// have no newline. Each line is checked to be a chat envelope and then written
/// exactly as received, so every field the app does not know survives byte for
/// byte. A body that is one JSON array (what an older server sent) is accepted
/// only when it really is one, and written entry by entry.
///
/// A line that is not a chat, a cut-off line, invalid UTF-8 and a stream that
/// ends in an error all abort [sink] and throw, so no partial file is ever
/// delivered. [checkpoint] runs before every line and once more after [sink]
/// committed; it throws to stop.
Future<ChatLibraryBackupResult> writeChatLibraryBackup({
  required Stream<List<int>> body,
  required ChatBackupSink sink,
  ChatBackupDecoder decode = _decodeInline,
  void Function()? checkpoint,
}) async {
  var count = 0;
  var wroteAny = false;
  _BodyShape? shape;
  final arrayText = StringBuffer();

  Future<void> writeEnvelope(String json) async {
    await sink.write(wroteAny ? ',\n$json' : '[\n$json');
    wroteAny = true;
    count++;
  }

  try {
    await for (final line
        in utf8.decoder.bind(body).transform(const LineSplitter())) {
      checkpoint?.call();
      final text = shape == null ? _stripBom(line) : line;
      if (shape == null) {
        final trimmed = text.trimLeft();
        if (trimmed.isEmpty) continue;
        shape = trimmed.startsWith('[') ? _BodyShape.array : _BodyShape.lines;
      }
      if (shape == _BodyShape.array) {
        arrayText
          ..write(text)
          ..write('\n');
        continue;
      }
      final trimmed = text.trim();
      if (trimmed.isEmpty) continue;
      if (!_isChatEnvelope(await decode(trimmed))) {
        throw const ChatBackupException(ChatBackupFailure.malformedExport);
      }
      await writeEnvelope(trimmed);
    }

    if (shape == _BodyShape.array) {
      final decoded = await decode(arrayText.toString());
      if (decoded is! List) {
        throw const ChatBackupException(ChatBackupFailure.malformedExport);
      }
      for (final entry in decoded) {
        checkpoint?.call();
        if (!_isChatEnvelope(entry)) {
          throw const ChatBackupException(ChatBackupFailure.malformedExport);
        }
        await writeEnvelope(jsonEncode(entry));
      }
    }

    // A stop or an account change that landed after the last line was read must
    // not still deliver the file.
    checkpoint?.call();
    await sink.write(wroteAny ? '\n]\n' : '[]\n');
    await sink.commit();
    // Closing the file takes time of its own, and whoever stopped or left
    // meanwhile still decides whether it is handed over.
    checkpoint?.call();
  } on FormatException {
    await _abortQuietly(sink);
    throw const ChatBackupException(ChatBackupFailure.malformedExport);
  } catch (_) {
    await _abortQuietly(sink);
    rethrow;
  }
  return ChatLibraryBackupResult(chats: count);
}

enum _BodyShape { lines, array }

String _stripBom(String text) =>
    text.isNotEmpty && text.codeUnitAt(0) == 0xFEFF ? text.substring(1) : text;

Future<void> _abortQuietly(ChatBackupSink sink) async {
  try {
    await sink.abort();
  } catch (_) {
    // The original failure is the one to report.
  }
}

/// Whether [value] is a chat as the server's export carries it.
bool _isChatEnvelope(Object? value) =>
    value is Map &&
    value['id'] is String &&
    (value['id'] as String).isNotEmpty &&
    value['chat'] is Map;

/// Serializes envelopes as the JSON array Open WebUI's own export writes.
String encodeChatBackupJson(List<Map<String, dynamic>> envelopes) =>
    jsonEncode(envelopes);

/// The largest file one import request will carry. The server reads the whole
/// body, and the import is sent once, so a file past this is refused up front
/// rather than failing after an upload that cannot be repeated safely.
const int kMaxChatImportBytes = 128 * 1024 * 1024;

/// A chosen file, validated and turned into the exact request the server
/// expects.
@immutable
final class ChatImportPreview {
  const ChatImportPreview({
    required this.chats,
    required this.legacyChats,
    required this.messages,
    required this.body,
  });

  /// Chats the request carries.
  final int chats;

  /// Of [chats], those from a chat-only file (the legacy export format) rather
  /// than a full envelope.
  final int legacyChats;

  /// Messages across [chats], counted from each stored history.
  final int messages;

  /// The request body, UTF-8 JSON `{"chats": [...]}`, built once so what the
  /// user confirmed is exactly what is sent.
  final Uint8List body;
}

/// Validates [bytes] as an Open WebUI chat export and builds the import
/// request, or throws [ChatBackupException]. Nothing leaves the device.
///
/// Mirrors Open WebUI's own import (`Settings/DataControls.svelte`): an entry
/// with a `chat` object keeps that object untouched together with its meta,
/// variables, pinned and archived flags, folder and timestamps; any other entry
/// is a legacy chat-only export and becomes the `chat` itself. Every field the
/// app does not know stays inside `chat`, `meta` and `variables` exactly as
/// stored. Top-level fields outside the server's import form (`id`, `user_id`,
/// `share_id`, `title`) are not part of that form and are not sent.
///
/// Top-level so a worker isolate can run it for a large file.
ChatImportPreview prepareChatImport(Uint8List bytes) {
  if (bytes.isEmpty) {
    throw const ChatBackupException(ChatBackupFailure.emptyImport);
  }
  if (bytes.lengthInBytes > kMaxChatImportBytes) {
    throw const ChatBackupException(ChatBackupFailure.fileTooLarge);
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(_stripBom(utf8.decode(bytes)));
  } on FormatException {
    throw const ChatBackupException(ChatBackupFailure.notJson);
  }
  if (decoded is! List) {
    throw const ChatBackupException(ChatBackupFailure.notAList);
  }
  if (decoded.isEmpty) {
    throw const ChatBackupException(ChatBackupFailure.emptyImport);
  }

  final forms = <Map<String, dynamic>>[];
  var legacy = 0;
  var messages = 0;
  for (var index = 0; index < decoded.length; index++) {
    final entry = decoded[index];
    if (entry is! Map) {
      throw ChatBackupException(
        ChatBackupFailure.unrecognizedChat,
        index: index,
      );
    }
    final map = _stringKeyed(entry);
    final nested = map['chat'];
    if (nested is Map) {
      forms.add(<String, dynamic>{
        'chat': _stringKeyed(nested),
        'meta': _objectOrEmpty(map['meta'], index),
        'variables': _objectOrEmpty(map['variables'], index),
        'pinned': _flag(map['pinned'], index),
        'archived': _flag(map['archived'], index),
        'folder_id': _folderId(map['folder_id'], index),
        'created_at': _epoch(map['created_at'], index),
        'updated_at': _epoch(map['updated_at'], index),
      });
      messages += _messageCount(_stringKeyed(nested));
      continue;
    }
    if (_isTruthy(nested) || !_looksLikeLegacyChat(map)) {
      throw ChatBackupException(
        ChatBackupFailure.unrecognizedChat,
        index: index,
      );
    }
    legacy++;
    forms.add(<String, dynamic>{
      'chat': map,
      'meta': <String, dynamic>{},
      'pinned': false,
      'folder_id': null,
      'created_at': _epoch(map['created_at'], index),
      'updated_at': _epoch(map['updated_at'], index),
    });
    messages += _messageCount(map);
  }

  return ChatImportPreview(
    chats: forms.length,
    legacyChats: legacy,
    messages: messages,
    body: Uint8List.fromList(
      utf8.encode(jsonEncode(<String, dynamic>{'chats': forms})),
    ),
  );
}

Map<String, dynamic> _stringKeyed(Map<dynamic, dynamic> map) =>
    <String, dynamic>{
      for (final entry in map.entries) entry.key.toString(): entry.value,
    };

/// JavaScript truthiness for the one place Open WebUI branches on it
/// (`if (chat.chat)`): null, false, 0 and the empty string are falsy.
bool _isTruthy(Object? value) => switch (value) {
  null => false,
  final bool flag => flag,
  final num number => number != 0,
  final String text => text.isNotEmpty,
  _ => true,
};

bool _looksLikeLegacyChat(Map<String, dynamic> map) =>
    map['history'] is Map || map['messages'] is List;

Map<String, dynamic> _objectOrEmpty(Object? value, int index) {
  if (value == null) return <String, dynamic>{};
  if (value is Map) return _stringKeyed(value);
  throw ChatBackupException(ChatBackupFailure.invalidField, index: index);
}

bool _flag(Object? value, int index) {
  if (value == null) return false;
  if (value is bool) return value;
  throw ChatBackupException(ChatBackupFailure.invalidField, index: index);
}

String? _folderId(Object? value, int index) {
  if (value == null) return null;
  if (value is String) return value;
  throw ChatBackupException(ChatBackupFailure.invalidField, index: index);
}

int? _epoch(Object? value, int index) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is double && value.isFinite && value == value.truncateToDouble()) {
    return value.toInt();
  }
  throw ChatBackupException(ChatBackupFailure.invalidField, index: index);
}

int _messageCount(Map<String, dynamic> chat) {
  final history = chat['history'];
  final stored = history is Map ? history['messages'] : null;
  if (stored is Map) return stored.length;
  final legacy = chat['messages'];
  return legacy is List ? legacy.length : 0;
}
