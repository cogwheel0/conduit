import 'package:dio/dio.dart';

import 'package:conduit_core/auth/api_auth_interceptor.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/sharing/models/resource_access.dart';
import 'package:conduit_core/features/workspace/models/workspace_common.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/sync/chat_locks.dart';
import 'package:conduit_core/utils/debug_logger.dart';

/// Why a sharing operation did not complete.
enum ResourceAccessFailure {
  /// The account or server changed after the sheet opened. Nothing was
  /// written, and nothing read afterwards was applied.
  sessionChanged,

  /// The server answered 403: the account may not see or change this access,
  /// which is not the same as the resource being gone.
  denied,

  /// The server answered 404.
  missing,

  /// The loaded access says the account cannot change it, so nothing was sent.
  notEditable,
}

class ResourceAccessException implements Exception {
  const ResourceAccessException(this.failure);

  final ResourceAccessFailure failure;

  @override
  String toString() => 'ResourceAccessException(${failure.name})';
}

/// Reads and saves the access grants of one chat, folder or note for the
/// session that opened the sharing sheet.
///
/// Everything that identifies the operation is captured in [open], before the
/// first load or any confirmation, and never re-read: the API, its auth
/// snapshot, the auth epoch, the server and the user, and the exact resource
/// id. A provider that outlives an account switch rebuilds for the new
/// account while the old sheet is still on screen, so reading the current
/// session when Save is pressed would let account A's form write as account B.
///
/// Access edits are online and live outside content sync: nothing here touches
/// the outbox or the note mutation path.
final class ResourceAccessController {
  ResourceAccessController._({
    required this.kind,
    required this.resourceId,
    required ApiService api,
    required ApiAuthSnapshot authSnapshot,
    required bool Function() isCurrent,
    Future<void> Function(ResourceAccessSnapshot fresh)? onSaved,
  }) : _api = api,
       _authSnapshot = authSnapshot,
       _isCurrent = isCurrent,
       _onSaved = onSaved;

  final ResourceKind kind;

  /// The resource's own id. For a chat that is the original chat id, never the
  /// `share_id` of its public link.
  final String resourceId;

  final ApiService _api;
  final ApiAuthSnapshot _authSnapshot;
  final bool Function() _isCurrent;
  final Future<void> Function(ResourceAccessSnapshot fresh)? _onSaved;

  /// Captures the active session for [resourceId], or returns null when there
  /// is no authenticated Open WebUI session to share from. [ref] is a `Ref`,
  /// `WidgetRef` or `ProviderContainer`.
  static ResourceAccessController? open(
    dynamic ref, {
    required ResourceKind kind,
    required String resourceId,
  }) {
    final session = _SessionKey.read(ref);
    if (session == null || resourceId.isEmpty) return null;
    final AppDatabase? db = kind == ResourceKind.note
        ? ref.read(appDatabaseProvider) as AppDatabase?
        : null;
    return ResourceAccessController._(
      kind: kind,
      resourceId: resourceId,
      api: session.api,
      authSnapshot: session.api.captureAuthSnapshot(),
      isCurrent: () => session.isCurrent(ref),
      // A saved note's grants and `write_access` are kept in its stored row,
      // beside the content and not through it, so the editor and the replay
      // check read the new answer without a sync.
      onSaved: db == null
          ? null
          : (fresh) async {
              // The lock can be held for a while by a pull or a save, and the
              // account can change in that wait: look again once it is ours.
              void ensureOurs() {
                if (!identical(ref.read(appDatabaseProvider), db) ||
                    !session.isCurrent(ref)) {
                  throw const ResourceAccessException(
                    ResourceAccessFailure.sessionChanged,
                  );
                }
              }

              ensureOurs();
              await (ref.read(noteLocksProvider) as NoteLocks).runExclusive(
                resourceId,
                () async {
                  ensureOurs();
                  await db.notesDao.storeNoteAccessProjection(
                    resourceId,
                    writeAccess: fresh.writeAccess,
                    accessGrants: fresh.rawGrants,
                  );
                },
              );
            },
    );
  }

  /// Whether the session this controller was opened under is still active.
  bool get isCurrent => _isCurrent();

  /// Reads the resource's current grants, and for a folder or note the
  /// caller's write access, from the server.
  Future<ResourceAccessSnapshot> load() async {
    _ensureCurrent();
    final snapshot = await _guard(_read);
    _ensureCurrent();
    return snapshot;
  }

  /// Replaces the resource's `user` and `group` grants with [edited], keeping
  /// the grants the sheet cannot represent, then reads the result back.
  ///
  /// [base] is what [load] returned for this sheet. It decides who may save
  /// and which rows are preserved. [audience] is the audience the user chose
  /// on purpose, if any; see [ResourceAccessSnapshot.bodyFor]. The returned snapshot is the server's own
  /// answer: update responses omit `write_access` and may filter grants the
  /// account was not allowed to give, so the form is replaced by it rather
  /// than trusted.
  Future<ResourceAccessSnapshot> save(
    ResourceAccessSnapshot base,
    Iterable<WorkspaceAccessGrantInput> edited, {
    ResourceAudience? audience,
  }) async {
    _ensureCurrent();
    if (!base.canEdit) {
      throw const ResourceAccessException(ResourceAccessFailure.notEditable);
    }
    final body = base.bodyFor(edited, audience: audience);
    await _guard(() => _write(body));
    // The write happened. Whatever is read next belongs to a session that no
    // longer exists if the account changed meanwhile, so it is dropped.
    _ensureCurrent();
    final fresh = await _guard(_read);
    _ensureCurrent();
    await _onSaved?.call(fresh);
    // Hydration may have waited for a lock; an answer that outlived its
    // session is refused, not reported as saved.
    _ensureCurrent();
    return fresh;
  }

  void _ensureCurrent() {
    if (!_isCurrent()) {
      throw const ResourceAccessException(ResourceAccessFailure.sessionChanged);
    }
  }

  Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on DioException catch (error) {
      // A request the interceptor refused because the account changed.
      if (error.type == DioExceptionType.cancel) {
        throw const ResourceAccessException(
          ResourceAccessFailure.sessionChanged,
        );
      }
      switch (error.response?.statusCode) {
        case 403:
          throw const ResourceAccessException(ResourceAccessFailure.denied);
        case 404:
          throw const ResourceAccessException(ResourceAccessFailure.missing);
      }
      DebugLogger.warning(
        'resource-access-failed',
        scope: 'sharing',
        data: {'kind': kind.name, 'status': error.response?.statusCode},
      );
      rethrow;
    }
  }

  Future<ResourceAccessSnapshot> _read() async {
    switch (kind) {
      case ResourceKind.chat:
        return ResourceAccessSnapshot(
          kind: kind,
          resourceId: resourceId,
          rawGrants: await _api.getChatAccessGrants(
            resourceId,
            authSnapshot: _authSnapshot,
          ),
        );
      case ResourceKind.folder:
        final folder = await _api.getFolderAccess(
          resourceId,
          authSnapshot: _authSnapshot,
        );
        return _fromDetail(folder);
      case ResourceKind.note:
        final note = await _api.getNoteForSession(
          resourceId,
          authSnapshot: _authSnapshot,
        );
        return _fromDetail(note);
    }
  }

  ResourceAccessSnapshot _fromDetail(Map<String, dynamic> detail) {
    final grants = detail['access_grants'];
    final writeAccess = detail['write_access'];
    return ResourceAccessSnapshot(
      kind: kind,
      resourceId: resourceId,
      rawGrants: [
        if (grants is List)
          for (final row in grants)
            if (row is Map) Map<String, dynamic>.from(row),
      ],
      writeAccess: writeAccess is bool ? writeAccess : null,
    );
  }

  Future<void> _write(List<Map<String, dynamic>> body) {
    switch (kind) {
      case ResourceKind.chat:
        return _api.updateChatAccessGrants(
          resourceId,
          body,
          authSnapshot: _authSnapshot,
        );
      case ResourceKind.folder:
        return _api.updateFolderAccessGrants(
          resourceId,
          body,
          authSnapshot: _authSnapshot,
        );
      case ResourceKind.note:
        return _api.updateNoteAccessGrants(
          resourceId,
          body,
          authSnapshot: _authSnapshot,
        );
    }
  }
}

/// The identity a sharing sheet opened under. Compared by identity for the
/// objects that survive an account switch, and by value for the ids.
class _SessionKey {
  const _SessionKey({
    required this.api,
    required this.authEpoch,
    required this.serverId,
    required this.userId,
  });

  final ApiService api;
  final Object authEpoch;
  final String serverId;
  final String userId;

  static _SessionKey? read(dynamic ref) {
    try {
      final bool authenticated = ref.read(isAuthenticatedProvider2) as bool;
      final ApiService? api = ref.read(apiServiceProvider) as ApiService?;
      final String? userId = ref.read(currentUserProvider2)?.id as String?;
      final String? serverId = ref.read(activeServerProvider).value?.id;
      if (!authenticated || api == null || userId == null) return null;
      return _SessionKey(
        api: api,
        authEpoch: ref.read(openWebUiAuthSessionEpochProvider) as Object,
        serverId: serverId ?? api.serverConfig.id,
        userId: userId,
      );
    } catch (_) {
      return null;
    }
  }

  bool isCurrent(dynamic ref) {
    final now = read(ref);
    return now != null &&
        identical(now.api, api) &&
        identical(now.authEpoch, authEpoch) &&
        now.serverId == serverId &&
        now.userId == userId;
  }
}
