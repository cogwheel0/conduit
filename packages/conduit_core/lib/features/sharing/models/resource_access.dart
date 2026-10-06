import 'package:meta/meta.dart';

import 'package:conduit_core/features/workspace/models/workspace_common.dart';

/// A resource whose access the everyday UI edits.
enum ResourceKind { chat, folder, note }

/// Who a chat is shared with beyond named users and groups, as Open WebUI's
/// access editor shows it: nobody else, every user on the server (a `user`
/// grant for `*`), or anyone with the link (an `anyone` grant for `*`).
enum ResourceAudience { private, public, open }

/// What the server currently says about who can reach one resource, as read
/// from that resource's own endpoint.
///
/// Grants stay raw maps. The access sheet edits `user` and `group` rows; any
/// other principal kind (a chat link can be open to `anyone`) is carried back
/// to the server untouched so saving never rewrites it into something else.
@immutable
class ResourceAccessSnapshot {
  const ResourceAccessSnapshot({
    required this.kind,
    required this.resourceId,
    required this.rawGrants,
    this.writeAccess,
  });

  final ResourceKind kind;
  final String resourceId;
  final List<Map<String, dynamic>> rawGrants;

  /// The caller's `write_access` from a folder or note detail. A chat has no
  /// such field: its route answers only for the owner or an admin.
  final bool? writeAccess;

  /// Whether the signed-in account may change these grants. Folders and notes
  /// accept the owner, an admin and a write recipient, which is exactly when
  /// the server reports `write_access`; a chat that could be read at all is
  /// the account's own.
  bool get canEdit => kind == ResourceKind.chat ? true : writeAccess == true;

  static bool _isEditableKind(Object? principalType) =>
      principalType == 'user' || principalType == 'group';

  static bool _isWildcardRead(Map<String, dynamic> row, String principalType) =>
      row['principal_type'] == principalType &&
      row['principal_id'] == '*' &&
      row['permission'] == 'read';

  static bool _isWildcardAnyone(Map<String, dynamic> row) =>
      row['principal_type'] == 'anyone' && row['principal_id'] == '*';

  /// The audience the grants add up to. Open outranks Public, as in the web
  /// editor, so a chat holding both reads as Open.
  ResourceAudience get audience {
    if (rawGrants.any((row) => _isWildcardRead(row, 'anyone'))) {
      return ResourceAudience.open;
    }
    if (rawGrants.any((row) => _isWildcardRead(row, 'user'))) {
      return ResourceAudience.public;
    }
    return ResourceAudience.private;
  }

  /// The `user` and `group` grants, in the form the access sheet edits.
  List<WorkspaceAccessGrantInput> get editableGrants => [
    for (final row in rawGrants)
      if (_isEditableKind(row['principal_type']))
        WorkspaceAccessGrantInput.fromGrant(WorkspaceAccessGrant.fromJson(row)),
  ];

  /// Grants of a principal kind the sheet cannot represent.
  List<Map<String, dynamic>> get preservedGrants => [
    for (final row in rawGrants)
      if (!_isEditableKind(row['principal_type'])) _essential(row),
  ];

  /// The `access_grants` body for saving [edited], with the preserved rows
  /// appended so they are not dropped by the full-replace update.
  ///
  /// [audience] is set only when the user deliberately picked one. As in the
  /// web editor's `setVisibility`, that replaces the wildcard rows: the
  /// `anyone` rows are dropped here (the caller drops the wildcard `user` rows
  /// from [edited]) and Open adds its single read row. Left null, the
  /// wildcard rows travel back as the server sent them.
  List<Map<String, dynamic>> bodyFor(
    Iterable<WorkspaceAccessGrantInput> edited, {
    ResourceAudience? audience,
  }) => [
    for (final grant in edited) grant.toJson(),
    for (final row in preservedGrants)
      if (audience == null || !_isWildcardAnyone(row)) row,
    if (audience == ResourceAudience.open)
      {'principal_type': 'anyone', 'principal_id': '*', 'permission': 'read'},
  ];

  static Map<String, dynamic> _essential(Map<String, dynamic> row) => {
    'principal_type': row['principal_type'],
    'principal_id': row['principal_id'],
    'permission': row['permission'],
  };
}
