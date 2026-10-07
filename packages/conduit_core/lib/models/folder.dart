import 'package:freezed_annotation/freezed_annotation.dart';

part 'folder.freezed.dart';

bool? _safeBool(dynamic value) {
  if (value == null) return null;
  if (value is bool) return value;
  if (value is String) {
    final lower = value.toLowerCase();
    if (lower == 'true' || lower == '1') return true;
    if (lower == 'false' || lower == '0') return false;
  }
  if (value is num) return value != 0;
  return null;
}

@freezed
sealed class Folder with _$Folder {
  const factory Folder({
    required String id,
    required String name,
    String? parentId,
    String? userId,
    DateTime? createdAt,
    DateTime? updatedAt,
    @Default(false) bool isExpanded,
    @Default([]) List<String> conversationIds,
    Map<String, dynamic>? meta,
    Map<String, dynamic>? data,
    Map<String, dynamic>? items,

    /// True for folders returned by `GET /api/v1/folders/shared` — owned by
    /// another user and granted to this account.
    @Default(false) bool shared,

    /// Display name of the owner (`owner_name`); shared folders only.
    String? ownerName,

    /// `read` or `write` (`permission`); shared folders only.
    String? permission,

    /// The server's own verdict on this account's write access
    /// (`write_access`), present only on a folder read by id. Null is unknown,
    /// as for every folder listed.
    bool? writeAccess,
  }) = _Folder;

  const Folder._();

  /// Owned folders are always writable; shared ones only with a write grant.
  /// A server verdict that this account cannot write overrides what the listing
  /// last said.
  bool get canWrite =>
      writeAccess != false && (!shared || permission == 'write');

  factory Folder.fromJson(Map<String, dynamic> json) {
    List<String> extractConversationIds(dynamic source) {
      if (source is! List) {
        return const <String>[];
      }
      final ids = <String>[];
      for (final entry in source) {
        String value = '';
        if (entry is String) {
          value = entry;
        } else if (entry is Map<String, dynamic>) {
          final id = entry['id'];
          if (id is String) {
            value = id;
          } else if (id != null) {
            value = id.toString();
          }
        } else if (entry != null) {
          value = entry.toString();
        }

        if (value.isNotEmpty) {
          ids.add(value);
        }
      }
      return ids;
    }

    final items = json['items'] as Map<String, dynamic>?;
    final chats = items?['chats'];
    final explicitIds = extractConversationIds(json['conversation_ids']);
    final implicitIds = extractConversationIds(chats);
    final conversationIds = explicitIds.isNotEmpty ? explicitIds : implicitIds;

    // Handle Unix timestamp conversion
    DateTime? parseTimestamp(dynamic timestamp) {
      if (timestamp == null) return null;
      if (timestamp is int) {
        return DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
      }
      if (timestamp is String) {
        return DateTime.parse(timestamp);
      }
      return null;
    }

    // Create the modified JSON with proper field mapping
    return Folder(
      id: json['id'] as String,
      name: json['name'] as String,
      parentId: json['parent_id'] as String?,
      userId: json['user_id'] as String?,
      createdAt: parseTimestamp(json['created_at']),
      updatedAt: parseTimestamp(json['updated_at']),
      isExpanded: _safeBool(json['is_expanded']) ?? false,
      conversationIds: conversationIds,
      meta: json['meta'] as Map<String, dynamic>?,
      data: json['data'] as Map<String, dynamic>?,
      items: json['items'] as Map<String, dynamic>?,
      shared: _safeBool(json['shared']) ?? false,
      ownerName: json['owner_name']?.toString(),
      permission: json['permission']?.toString(),
      writeAccess: _safeBool(json['write_access']),
    );
  }
}

/// One `data.files` entry of a folder project, as the web client's
/// `FolderModal` writes it: `{type: file|collection|note, id, name, ...}`.
///
/// [raw] is the entry exactly as stored. The editor saves it back untouched,
/// so keys this client does not know survive a round trip.
class FolderProjectFile {
  const FolderProjectFile._({
    required this.id,
    required this.type,
    required this.name,
    required this.raw,
  });

  /// Reads one stored entry; null when it has no usable id (it cannot be
  /// listed, but the editor still keeps it in the list it saves).
  static FolderProjectFile? tryParse(Object? entry) {
    if (entry is! Map) return null;
    final id = entry['id'];
    if (id is! String || id.isEmpty) return null;
    final name = entry['name'];
    final type = entry['type'];
    return FolderProjectFile._(
      id: id,
      type: type is String ? type : 'file',
      name: name is String && name.isNotEmpty ? name : id,
      raw: Map<String, dynamic>.from(entry),
    );
  }

  /// A new reference to a knowledge collection or file picked in the editor.
  factory FolderProjectFile.reference({
    required String type,
    required String id,
    required String name,
  }) => FolderProjectFile._(
    id: id,
    type: type,
    name: name,
    raw: <String, dynamic>{'type': type, 'id': id, 'name': name},
  );

  final String id;
  final String type;
  final String name;
  final Map<String, dynamic> raw;
}

/// Project defaults live in a folder's `data` next to `system_prompt`: the
/// knowledge `files` and the ordered `model_ids` a new chat starts with. The
/// server applies `system_prompt` and `files` itself from the chat's
/// `folder_id`; only `model_ids` is the client's to apply.
extension FolderProjectDefaults on Folder {
  /// Every stored `files` entry, including ones that cannot be listed.
  List<Object?> get projectFileEntries {
    final value = data?['files'];
    return value is List ? List<Object?>.of(value) : const <Object?>[];
  }

  /// The listable `files` entries, in stored order.
  List<FolderProjectFile> get projectFiles => <FolderProjectFile>[
    for (final entry in projectFileEntries) ?FolderProjectFile.tryParse(entry),
  ];

  /// Every stored `model_ids` entry, in slot order.
  List<Object?> get projectModelIdEntries {
    final value = data?['model_ids'];
    return value is List ? List<Object?>.of(value) : const <Object?>[];
  }

  /// The saved model slots as ids, in order. Blank and non-string entries are
  /// not models, so they are skipped here and kept by [projectModelIdEntries].
  List<String> get projectModelIds => <String>[
    for (final entry in projectModelIdEntries)
      if (entry is String && entry.trim().isNotEmpty) entry,
  ];

  String get projectSystemPrompt {
    final value = data?['system_prompt'];
    return value is String ? value : '';
  }
}

/// Why a project edit was not written.
enum FolderProjectWriteFailure {
  /// The signed-in account, server or session is not the one that opened the
  /// editor.
  ownerChanged,

  /// The folder is gone or being deleted.
  unavailable,

  /// The account has no write grant on this shared folder.
  readOnly,
}

final class FolderProjectWriteException implements Exception {
  const FolderProjectWriteException(this.reason);

  final FolderProjectWriteFailure reason;

  @override
  String toString() => 'FolderProjectWriteException(${reason.name})';
}

extension FolderJsonExtension on Folder {
  Map<String, dynamic> toJson() {
    Map<String, dynamic>? normalizedItems;
    if (items != null) {
      normalizedItems = Map<String, dynamic>.from(items!);
    } else if (conversationIds.isNotEmpty) {
      normalizedItems = {'chats': List<String>.from(conversationIds)};
    }

    return {
      'id': id,
      'name': name,
      if (parentId != null) 'parent_id': parentId,
      if (userId != null) 'user_id': userId,
      if (createdAt != null) 'created_at': createdAt!.toIso8601String(),
      if (updatedAt != null) 'updated_at': updatedAt!.toIso8601String(),
      'is_expanded': isExpanded,
      'items': ?normalizedItems,
      if (meta != null) 'meta': Map<String, dynamic>.from(meta!),
      if (data != null) 'data': Map<String, dynamic>.from(data!),
      if (conversationIds.isNotEmpty)
        'conversation_ids': List<String>.from(conversationIds),
      if (shared) 'shared': true,
      if (ownerName != null) 'owner_name': ownerName,
      if (permission != null) 'permission': permission,
      if (writeAccess != null) 'write_access': writeAccess,
    };
  }
}
