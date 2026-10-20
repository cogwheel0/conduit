import 'dart:async';

import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/workspace/models/workspace_common.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:conduit_core/utils/user_avatar_utils.dart';

/// The server path of a user's profile picture. Open WebUI serves it to any
/// verified user and falls back to a generated image, so it is safe to show
/// for every person in an access list.
String workspaceUserProfileImagePath(String userId) =>
    '/api/v1/users/${Uri.encodeComponent(userId)}/profile/image';

/// [preview] with an absolute picture URL on [api]'s server. User search and
/// user info answers carry no picture field; the picture route stands in.
WorkspacePrincipalPreview withWorkspaceUserPicture(
  ApiService api,
  WorkspacePrincipalPreview preview,
) {
  if (preview.type != WorkspacePrincipalType.user || preview.id.isEmpty) {
    return preview;
  }
  final raw = preview.profileImageUrl?.trim();
  return WorkspacePrincipalPreview(
    id: preview.id,
    type: preview.type,
    name: preview.name,
    email: preview.email,
    profileImageUrl: resolveUserProfileImageUrl(
      api,
      raw == null || raw.isEmpty
          ? workspaceUserProfileImagePath(preview.id)
          : raw,
    ),
  );
}

/// What a lookup knows about one person or group.
enum WorkspacePrincipalResolution {
  /// Not asked yet, or the last request failed and may be retried.
  unknown,

  /// Being asked now.
  pending,

  /// The server described it; see [WorkspacePrincipalLookup.cached].
  resolved,

  /// The server has no such principal, or will not describe it to this
  /// account. Shown as an unknown person or group, never as its id.
  unresolvable,
}

/// Names, emails and pictures for the people and groups an access list
/// mentions, which grants carry only by id.
///
/// One lookup belongs to one signed-in account. [workspacePrincipalLookupProvider]
/// builds a new, empty one whenever the server, user, API client or auth
/// session changes, and every request made by [WorkspacePrincipalLookup.forApi]
/// carries the auth snapshot taken when the lookup was built. A name read for
/// one account is therefore never cached for, or shown to, another; callers
/// that outlive an account switch also check that the lookup they hold is
/// still the provider's current one before showing what it returns.
///
/// Answers are cached for the lookup's lifetime. A user the server has no
/// record of is remembered as [WorkspacePrincipalResolution.unresolvable]; a
/// failed request is not remembered, so the next [resolve] asks again.
final class WorkspacePrincipalLookup {
  WorkspacePrincipalLookup({
    required Future<WorkspacePrincipalPreview?> Function(String id) fetchUser,
    required Future<List<WorkspacePrincipalPreview>> Function() fetchGroups,
    this.maxConcurrentUsers = 4,
    this.owner,
  }) : _fetchUser = fetchUser,
       _fetchGroups = fetchGroups;

  /// A lookup that asks [api]'s server, bound to the account signed in now.
  factory WorkspacePrincipalLookup.forApi(ApiService api, {Object? owner}) {
    final authSnapshot = api.captureAuthSnapshot();
    return WorkspacePrincipalLookup(
      owner: owner,
      fetchUser: (id) async {
        final preview = await api.getWorkspaceUserInfo(
          id,
          authSnapshot: authSnapshot,
        );
        return preview == null ? null : withWorkspaceUserPicture(api, preview);
      },
      fetchGroups: () => api.getWorkspaceGroups(authSnapshot: authSnapshot),
    );
  }

  final Future<WorkspacePrincipalPreview?> Function(String id) _fetchUser;
  final Future<List<WorkspacePrincipalPreview>> Function() _fetchGroups;

  /// How many user requests run at once.
  final int maxConcurrentUsers;

  /// The account session this lookup answers for. Two lookups with equal
  /// owners name principals for the same account, so a sheet may move to the
  /// newer one when the provider rebuilds without the account changing.
  final Object? owner;

  /// Resolved users, and null for users the server does not describe.
  final Map<String, WorkspacePrincipalPreview?> _users = {};
  final Map<String, Future<void>> _pendingUsers = {};

  /// The groups this account can list, once listed.
  Map<String, WorkspacePrincipalPreview>? _groups;
  Future<void>? _pendingGroups;

  /// Groups seen through [remember] before the list was loaded.
  final Map<String, WorkspacePrincipalPreview> _rememberedGroups = {};

  /// What is known about [type]/[id] without asking the server.
  WorkspacePrincipalPreview? cached(WorkspacePrincipalType type, String id) {
    return switch (type) {
      WorkspacePrincipalType.user => _users[id],
      WorkspacePrincipalType.group => _groups?[id] ?? _rememberedGroups[id],
    };
  }

  WorkspacePrincipalResolution resolutionOf(
    WorkspacePrincipalType type,
    String id,
  ) {
    switch (type) {
      case WorkspacePrincipalType.user:
        if (_users.containsKey(id)) {
          return _users[id] == null
              ? WorkspacePrincipalResolution.unresolvable
              : WorkspacePrincipalResolution.resolved;
        }
        return _pendingUsers.containsKey(id)
            ? WorkspacePrincipalResolution.pending
            : WorkspacePrincipalResolution.unknown;
      case WorkspacePrincipalType.group:
        if (_rememberedGroups.containsKey(id)) {
          return WorkspacePrincipalResolution.resolved;
        }
        final groups = _groups;
        if (groups != null) {
          return groups.containsKey(id)
              ? WorkspacePrincipalResolution.resolved
              : WorkspacePrincipalResolution.unresolvable;
        }
        return _pendingGroups != null
            ? WorkspacePrincipalResolution.pending
            : WorkspacePrincipalResolution.unknown;
    }
  }

  /// Keeps what a search or picker already returned, so a principal that was
  /// just added shows its name without another request. Answers from the
  /// server for the same principal later replace it.
  void remember(Iterable<WorkspacePrincipalPreview> previews) {
    for (final preview in previews) {
      if (preview.id.isEmpty || preview.name.trim().isEmpty) continue;
      switch (preview.type) {
        case WorkspacePrincipalType.user:
          _users[preview.id] = preview;
        case WorkspacePrincipalType.group:
          // A group seen in a picker is known; the full list is still asked
          // for if another group is missing.
          _rememberedGroups[preview.id] = preview;
      }
    }
  }

  /// Asks the server about every principal in [principals] it has not
  /// answered for yet. Completes when every request has finished, whether or
  /// not it succeeded; failures are logged and left unknown.
  Future<void> resolve(
    Iterable<({WorkspacePrincipalType type, String id})> principals,
  ) async {
    final users = <String>{};
    var needsGroups = false;
    for (final principal in principals) {
      if (principal.id.isEmpty || principal.id == '*') continue;
      switch (principal.type) {
        case WorkspacePrincipalType.user:
          if (!_users.containsKey(principal.id)) users.add(principal.id);
        case WorkspacePrincipalType.group:
          if (_groups == null && !_rememberedGroups.containsKey(principal.id)) {
            needsGroups = true;
          }
      }
    }
    await Future.wait([
      if (needsGroups) _loadGroups(),
      if (users.isNotEmpty) _loadUsers(users),
    ]);
  }

  Future<void> _loadGroups() {
    return _pendingGroups ??= () async {
      try {
        final groups = await _fetchGroups();
        _groups = {
          for (final group in groups)
            if (group.id.isNotEmpty) group.id: group,
        };
      } catch (error, stackTrace) {
        DebugLogger.error(
          'principal group lookup failed',
          scope: 'sharing',
          error: error,
          stackTrace: stackTrace,
        );
      } finally {
        _pendingGroups = null;
      }
    }();
  }

  Future<void> _loadUsers(Set<String> ids) async {
    final waits = <Future<void>>[];
    final queue = <String>[];
    for (final id in ids) {
      final pending = _pendingUsers[id];
      if (pending != null) {
        waits.add(pending);
      } else {
        queue.add(id);
      }
    }
    // Every queued id is marked pending before the first request starts, so
    // a second resolve made meanwhile waits for these instead of asking again.
    final done = {for (final id in queue) id: Completer<void>()};
    for (final entry in done.entries) {
      _pendingUsers[entry.key] = entry.value.future;
    }
    var next = 0;
    Future<void> worker() async {
      while (next < queue.length) {
        final id = queue[next++];
        try {
          _users[id] = await _fetchUser(id);
        } catch (error, stackTrace) {
          DebugLogger.error(
            'principal user lookup failed',
            scope: 'sharing',
            error: error,
            stackTrace: stackTrace,
          );
        } finally {
          _pendingUsers.remove(id);
          done[id]!.complete();
        }
      }
    }

    final workers = queue.isEmpty
        ? 0
        : (queue.length < maxConcurrentUsers
              ? queue.length
              : maxConcurrentUsers);
    await Future.wait([...waits, for (var i = 0; i < workers; i++) worker()]);
  }

  @override
  String toString() =>
      'WorkspacePrincipalLookup(users: ${_users.length}, '
      'groups: ${_groups?.length})';
}

/// The principal lookup of the account signed in now, or null without an
/// authenticated Open WebUI session.
///
/// The provider rebuilds, with an empty cache, whenever the API client, the
/// server, the user or the auth session changes. Hold the instance read when
/// an access sheet opened and compare it with the current one before showing
/// anything it answers.
final workspacePrincipalLookupProvider = Provider<WorkspacePrincipalLookup?>((
  ref,
) {
  final api = ref.watch(apiServiceProvider);
  final serverId = ref.watch(
    activeServerProvider.select((value) => value.asData?.value?.id),
  );
  final userId = ref.watch(currentUserProvider2.select((user) => user?.id));
  final epoch = ref.watch(openWebUiAuthSessionEpochProvider);
  if (api == null || serverId == null || userId == null) return null;
  return WorkspacePrincipalLookup.forApi(
    api,
    owner: (serverId: serverId, userId: userId, epoch: epoch),
  );
});
