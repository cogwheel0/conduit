import 'dart:async';

import 'package:dio/dio.dart';
import 'package:meta/meta.dart';
import 'package:riverpod/misc.dart' show ProviderListenable;
import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/auth/api_auth_interceptor.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/channels/providers/channel_providers.dart';
import 'package:conduit_core/features/workspace/models/workspace_capabilities.dart';
import 'package:conduit_core/models/channel.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/utils/debug_logger.dart';

/// Reads a provider; satisfied by both `Ref.read` and `WidgetRef.read`.
typedef ChannelMembersReader = T Function<T>(ProviderListenable<T> provider);

/// Members shown per server page. The server fixes this at 30; the client only
/// uses it to size a page it has not seen yet, never to decide it is the last.
const int channelMembersPageSize = 30;

/// One member of a channel as the members route reports it.
@immutable
class ChannelMember {
  const ChannelMember({
    required this.id,
    required this.name,
    this.email,
    this.role,
    this.profileImageUrl,
    this.isActive = false,
  });

  final String id;
  final String name;
  final String? email;
  final String? role;
  final String? profileImageUrl;
  final bool isActive;

  /// Null when the entry has no user id: it cannot be told apart from other
  /// entries or removed, so it is not shown.
  static ChannelMember? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    if (id is! String || id.isEmpty) return null;
    String? text(String key) {
      final value = json[key];
      return value is String && value.isNotEmpty ? value : null;
    }

    return ChannelMember(
      id: id,
      name: text('name') ?? '',
      email: text('email'),
      role: text('role'),
      profileImageUrl: text('profile_image_url'),
      isActive: json['is_active'] == true,
    );
  }
}

/// The server, account, API client and channel that were active when a member
/// list opened.
///
/// The list holds this one owner through every page, search and mutation and
/// never recaptures it: a mounted sheet or a stable [ApiService] does not prove
/// the same account is still signed in, and the shared client can rotate its
/// token without replacing itself.
@immutable
class ChannelMembersOwner {
  const ChannelMembersOwner._({
    required this.api,
    required this.serverId,
    required this.userId,
    required this.token,
    required this.authEpoch,
    required this.authSnapshot,
    required this.databaseAccessPhase,
    required this.certifiedDatabaseServerId,
    required this.channelId,
  });

  final ApiService api;
  final String serverId;

  /// The signed-in user when the list opened; null while that user was still
  /// loading. Identity then rests on the token and auth epoch alone.
  final String? userId;
  final String token;
  final Object authEpoch;

  /// Binds every request to the bearer this owner opened with. Dio picks the
  /// token at dispatch, after any check made before an await, so without this a
  /// client that rotated to another account in between would send this owner's
  /// request as that account.
  final ApiAuthSnapshot authSnapshot;
  final OpenWebUiDatabaseAccessPhase databaseAccessPhase;
  final String? certifiedDatabaseServerId;
  final String channelId;

  /// Captures the active owner synchronously, or null when no OpenWebUI account
  /// is signed in. Call it at the user's action, before any await.
  static ChannelMembersOwner? capture(
    ChannelMembersReader read,
    String channelId,
  ) {
    final api = read(apiServiceProvider);
    // `.value` keeps the last resolved server through an AsyncLoading refresh,
    // which must not read as a different server.
    final serverId = read(activeServerProvider).value?.id;
    final token = read(authTokenProvider3);
    if (api == null ||
        serverId == null ||
        api.serverConfig.id != serverId ||
        token == null ||
        token.isEmpty) {
      return null;
    }
    return ChannelMembersOwner._(
      api: api,
      serverId: serverId,
      userId: read(currentUserProvider2)?.id,
      token: token,
      authEpoch: read(openWebUiAuthSessionEpochProvider),
      authSnapshot: api.captureAuthSnapshot(),
      databaseAccessPhase: read(openWebUiDatabaseAccessProvider),
      certifiedDatabaseServerId: read(openWebUiCertifiedDatabaseServerProvider),
      channelId: channelId,
    );
  }

  bool isCurrent(ChannelMembersReader read) {
    final capturedUser = userId;
    return identical(api, read(apiServiceProvider)) &&
        serverId == read(activeServerProvider).value?.id &&
        (capturedUser == null ||
            capturedUser == read(currentUserProvider2)?.id) &&
        token == read(authTokenProvider3) &&
        identical(authEpoch, read(openWebUiAuthSessionEpochProvider)) &&
        databaseAccessPhase == read(openWebUiDatabaseAccessProvider) &&
        certifiedDatabaseServerId ==
            read(openWebUiCertifiedDatabaseServerProvider);
  }

  @override
  bool operator ==(Object other) =>
      other is ChannelMembersOwner &&
      identical(other.api, api) &&
      other.serverId == serverId &&
      other.userId == userId &&
      other.token == token &&
      identical(other.authEpoch, authEpoch) &&
      other.channelId == channelId;

  @override
  int get hashCode =>
      Object.hash(identityHashCode(api), serverId, userId, token, channelId);
}

/// What the signed-in account may do to this channel's membership.
@immutable
class ChannelMemberManagement {
  const ChannelMemberManagement({
    this.canManage = false,
    this.allowUsers = false,
    this.allowGroups = false,
  });

  static const none = ChannelMemberManagement();

  /// Whether Add and Remove are offered and accepted.
  final bool canManage;

  /// Which kinds of principal the picker may offer when adding. These follow
  /// the account's sharing policy and never widen [canManage].
  final bool allowUsers;
  final bool allowGroups;

  @override
  bool operator ==(Object other) =>
      other is ChannelMemberManagement &&
      other.canManage == canManage &&
      other.allowUsers == allowUsers &&
      other.allowGroups == allowGroups;

  @override
  int get hashCode => Object.hash(canManage, allowUsers, allowGroups);
}

/// Decides membership management for [channel] from the account's current
/// facts. Everything is an input so the answer is the same for the sheet that
/// shows the controls and the controller that checks them again before a send.
///
/// The pinned web client offers Add and Remove only on a group channel the
/// account manages, and the server additionally accepts them only from the
/// channel's owner or an admin with the Channels feature on. Missing
/// permission flags follow the web client and mean allowed; an unreadable
/// permission document ([permissions] null) grants a non-admin nothing.
ChannelMemberManagement resolveChannelMemberManagement({
  required String channelId,
  required Channel? channel,
  required User? user,
  required bool advancedEnabled,
  required bool channelsEnabled,
  required Map<String, dynamic>? permissions,
}) {
  if (!advancedEnabled || !channelsEnabled) return ChannelMemberManagement.none;
  if (user == null || channel == null || channel.id != channelId) {
    return ChannelMemberManagement.none;
  }
  if (!channel.isGroup || !channel.isManager) {
    return ChannelMemberManagement.none;
  }
  final isAdmin = user.role == 'admin';
  if (isAdmin) {
    return const ChannelMemberManagement(
      canManage: true,
      allowUsers: true,
      allowGroups: true,
    );
  }
  if (permissions == null || channel.userId != user.id) {
    return ChannelMemberManagement.none;
  }
  final features = permissions['features'];
  if (features is Map && features['channels'] == false) {
    return ChannelMemberManagement.none;
  }
  final grants = WorkspaceCapabilities.fromPermissions(permissions);
  return ChannelMemberManagement(
    canManage: true,
    allowUsers: grants.allowUserGrants,
    allowGroups: grants.allowGroupGrants,
  );
}

/// The controls to show for an open member list. It reads the same inputs as
/// the controller's pre-send check, so a control is never offered that the
/// controller would then refuse for policy.
final channelMemberManagementProvider = Provider.autoDispose
    .family<ChannelMemberManagement, ChannelMembersOwner>((ref, owner) {
      if (!owner.isCurrent(ref.watch)) return ChannelMemberManagement.none;
      return resolveChannelMemberManagement(
        channelId: owner.channelId,
        channel: ref.watch(activeChannelProvider),
        user: ref.watch(currentUserProvider2),
        advancedEnabled: ref.watch(
          appSettingsProvider.select(
            (settings) => settings.advancedFeaturesEnabled,
          ),
        ),
        channelsEnabled: ref.watch(channelsFeatureEnabledProvider),
        permissions: ref.watch(userPermissionsProvider).asData?.value,
      );
    });

enum ChannelMembersPhase {
  /// The first page of the current query is on its way.
  loading,
  ready,

  /// The first page of the current query could not be read.
  failed,

  /// The account, server or API changed. Nothing from the old owner is kept.
  ownerChanged,
}

@immutable
class ChannelMembersState {
  const ChannelMembersState({
    this.phase = ChannelMembersPhase.loading,
    this.members = const [],
    this.total,
    this.query = '',
    this.nextPage = 1,
    this.hasMore = false,
    this.loadingMore = false,
    this.loadMoreFailed = false,
    this.mutating = false,
  });

  final ChannelMembersPhase phase;

  /// Unique by user id, in server order.
  final List<ChannelMember> members;

  /// The server's count for the current query.
  final int? total;
  final String query;
  final int nextPage;
  final bool hasMore;
  final bool loadingMore;
  final bool loadMoreFailed;
  final bool mutating;

  ChannelMembersState copyWith({
    ChannelMembersPhase? phase,
    List<ChannelMember>? members,
    int? total,
    String? query,
    int? nextPage,
    bool? hasMore,
    bool? loadingMore,
    bool? loadMoreFailed,
    bool? mutating,
  }) => ChannelMembersState(
    phase: phase ?? this.phase,
    members: members ?? this.members,
    total: total ?? this.total,
    query: query ?? this.query,
    nextPage: nextPage ?? this.nextPage,
    hasMore: hasMore ?? this.hasMore,
    loadingMore: loadingMore ?? this.loadingMore,
    loadMoreFailed: loadMoreFailed ?? this.loadMoreFailed,
    mutating: mutating ?? this.mutating,
  );
}

/// What happened to an add or remove request.
enum ChannelMemberMutationResult {
  /// The server accepted it and the list was read again.
  done,

  /// The account, server or API changed before or during the request. A request
  /// already sent may still have been applied; nothing here reflects it.
  ownerChanged,

  /// The account's current policy no longer allows it. Nothing was sent.
  notPermitted,

  /// The server refused it (401, 403 or 404).
  denied,

  /// The request did not complete.
  failed,

  /// Another change is still running.
  busy,
}

final channelMembersControllerProvider = NotifierProvider.autoDispose
    .family<ChannelMembersController, ChannelMembersState, ChannelMembersOwner>(
      ChannelMembersController.new,
    );

/// Pages, searches and changes one channel's members for the owner that opened
/// the list.
///
/// Members are listed by name, ascending, as the pinned web client does. Every
/// read and write carries the owner's auth snapshot, and each result is checked
/// against the owner, the query generation and, for a write, the account's
/// current policy before it touches state.
class ChannelMembersController extends Notifier<ChannelMembersState> {
  ChannelMembersController(this._owner);

  final ChannelMembersOwner _owner;

  /// Bumped by every search and refresh. A page or a refresh that finds a
  /// newer value than the one it started with belongs to a query the user has
  /// left and is dropped.
  int _generation = 0;

  @override
  ChannelMembersState build() {
    void check<T>(ProviderListenable<T> provider) =>
        ref.listen<T>(provider, (_, _) => _retireIfStale());
    check(apiServiceProvider);
    check(activeServerProvider);
    check(authTokenProvider3);
    check(currentUserProvider2);
    check(openWebUiAuthSessionEpochProvider);
    check(openWebUiDatabaseAccessProvider);
    check(openWebUiCertifiedDatabaseServerProvider);
    scheduleMicrotask(() => unawaited(_loadFirstPage('')));
    return const ChannelMembersState();
  }

  bool get _ownerIsCurrent => ref.mounted && _owner.isCurrent(ref.read);

  /// Drops everything held for the owner once it is no longer current.
  void _retire() {
    _generation += 1;
    if (ref.mounted) {
      state = const ChannelMembersState(
        phase: ChannelMembersPhase.ownerChanged,
      );
    }
  }

  void _retireIfStale() {
    if (!ref.mounted || state.phase == ChannelMembersPhase.ownerChanged) return;
    if (!_owner.isCurrent(ref.read)) _retire();
  }

  /// Whether a result that started at [generation] may still be applied.
  /// Retires the list when the owner is what changed.
  bool _mayApply(int generation) {
    if (!ref.mounted) return false;
    if (!_owner.isCurrent(ref.read)) {
      if (state.phase != ChannelMembersPhase.ownerChanged) _retire();
      return false;
    }
    return generation == _generation;
  }

  /// Reads the first page of [query], replacing the list.
  Future<void> _loadFirstPage(String query) async {
    if (!_ownerIsCurrent) {
      _retire();
      return;
    }
    final generation = ++_generation;
    state = ChannelMembersState(
      phase: ChannelMembersPhase.loading,
      query: query,
      mutating: state.mutating,
    );
    try {
      final result = await _readPage(query, 1);
      if (!_mayApply(generation)) return;
      final members = _dedupe(const [], result.users);
      state = state.copyWith(
        phase: ChannelMembersPhase.ready,
        members: members,
        total: result.total,
        nextPage: 2,
        hasMore: _hasMore(members.length, members.length, result.total),
      );
    } catch (error, stackTrace) {
      if (!_mayApply(generation)) return;
      _logFailure('load', error, stackTrace);
      state = state.copyWith(phase: ChannelMembersPhase.failed);
    }
  }

  Future<({List<ChannelMember> users, int total})> _readPage(
    String query,
    int page,
  ) async {
    final response = await _owner.api.getChannelMembers(
      _owner.channelId,
      query: query.isEmpty ? null : query,
      orderBy: 'name',
      direction: 'asc',
      page: page,
      authSnapshot: _owner.authSnapshot,
    );
    final raw = response['users'];
    final users = <ChannelMember>[
      if (raw is List)
        for (final item in raw) ?ChannelMember.fromJson(item),
    ];
    final total = response['total'];
    return (users: users, total: total is num ? total.toInt() : users.length);
  }

  /// [existing] followed by the users it does not already hold, by user id.
  List<ChannelMember> _dedupe(
    List<ChannelMember> existing,
    List<ChannelMember> page,
  ) {
    final seen = {for (final member in existing) member.id};
    return List.unmodifiable([
      ...existing,
      for (final member in page)
        if (seen.add(member.id)) member,
    ]);
  }

  /// Another page is worth asking for while the server reports more members
  /// than are held and the last page still added someone. The second condition
  /// ends the walk against a server that repeats a page instead of advancing.
  bool _hasMore(int held, int added, int total) => added > 0 && held < total;

  /// Searches for [query], starting again at the first page. Results of an
  /// earlier query that are still in flight are dropped.
  Future<void> setQuery(String query) async {
    final trimmed = query.trim();
    if (state.phase == ChannelMembersPhase.ownerChanged) return;
    if (trimmed == state.query && state.phase != ChannelMembersPhase.failed) {
      return;
    }
    await _loadFirstPage(trimmed);
  }

  /// Reads the first page of the current query again.
  Future<void> reload() => _loadFirstPage(state.query);

  /// Reads the next page of the current query.
  Future<void> loadMore() async {
    final current = state;
    if (current.phase != ChannelMembersPhase.ready ||
        current.loadingMore ||
        current.mutating ||
        !current.hasMore) {
      return;
    }
    if (!_ownerIsCurrent) {
      _retire();
      return;
    }
    final generation = _generation;
    final page = current.nextPage;
    state = current.copyWith(loadingMore: true, loadMoreFailed: false);
    try {
      final result = await _readPage(current.query, page);
      if (!_mayApply(generation)) return;
      final held = state.members;
      final members = _dedupe(held, result.users);
      state = state.copyWith(
        members: members,
        total: result.total,
        nextPage: page + 1,
        hasMore: _hasMore(
          members.length,
          members.length - held.length,
          result.total,
        ),
        loadingMore: false,
      );
    } catch (error, stackTrace) {
      if (!_mayApply(generation)) return;
      _logFailure('page', error, stackTrace);
      state = state.copyWith(loadingMore: false, loadMoreFailed: true);
    }
  }

  /// Adds the users and groups, then reads the list again from the server.
  Future<ChannelMemberMutationResult> addMembers({
    List<String> userIds = const [],
    List<String> groupIds = const [],
  }) => _mutate(
    (api, snapshot) => api.addChannelMembers(
      _owner.channelId,
      userIds: userIds,
      groupIds: groupIds,
      authSnapshot: snapshot,
    ),
    // The picker only offers the kinds the account may grant; a request for a
    // kind it may not is refused here rather than left to the server.
    admits: (management) =>
        (userIds.isEmpty || management.allowUsers) &&
        (groupIds.isEmpty || management.allowGroups) &&
        (userIds.isNotEmpty || groupIds.isNotEmpty),
  );

  /// Removes one user, then reads the list again from the server.
  Future<ChannelMemberMutationResult> removeMember(String userId) {
    if (!ref.mounted) {
      return Future.value(ChannelMemberMutationResult.ownerChanged);
    }
    // The web client disables removing yourself.
    if (userId == ref.read(currentUserProvider2)?.id) {
      return Future.value(ChannelMemberMutationResult.notPermitted);
    }
    return _mutate(
      (api, snapshot) => api.removeChannelMembers(
        _owner.channelId,
        userIds: [userId],
        authSnapshot: snapshot,
      ),
      admits: (_) => true,
    );
  }

  Future<ChannelMemberMutationResult> _mutate(
    Future<void> Function(ApiService api, ApiAuthSnapshot snapshot) send, {
    required bool Function(ChannelMemberManagement management) admits,
  }) async {
    if (!_ownerIsCurrent) {
      _retire();
      return ChannelMemberMutationResult.ownerChanged;
    }
    if (state.mutating) return ChannelMemberMutationResult.busy;
    state = state.copyWith(mutating: true);

    final denied = await _authorize(admits);
    if (denied != null) return denied;

    try {
      await send(_owner.api, _owner.authSnapshot);
    } catch (error, stackTrace) {
      if (!_ownerIsCurrent) {
        _retire();
        return ChannelMemberMutationResult.ownerChanged;
      }
      _logFailure('mutation', error, stackTrace);
      state = state.copyWith(mutating: false);
      return _isServerDenial(error)
          ? ChannelMemberMutationResult.denied
          : ChannelMemberMutationResult.failed;
    }
    if (!_ownerIsCurrent) {
      _retire();
      return ChannelMemberMutationResult.ownerChanged;
    }
    state = state.copyWith(mutating: false);
    await _loadFirstPage(state.query);
    return ChannelMemberMutationResult.done;
  }

  /// Checks the account's policy as it is now. Null means the request may be
  /// sent; otherwise the result to return, with the mutation flag cleared.
  Future<ChannelMemberMutationResult?> _authorize(
    bool Function(ChannelMemberManagement management) admits,
  ) async {
    Map<String, dynamic>? permissions;
    if (ref.read(currentUserProvider2)?.role != 'admin') {
      try {
        permissions = await ref.read(userPermissionsProvider.future);
      } catch (_) {
        // Unreadable permissions grant a non-admin nothing.
      }
    }
    if (!_ownerIsCurrent) {
      _retire();
      return ChannelMemberMutationResult.ownerChanged;
    }
    final management = resolveChannelMemberManagement(
      channelId: _owner.channelId,
      channel: ref.read(activeChannelProvider),
      user: ref.read(currentUserProvider2),
      advancedEnabled: ref.read(appSettingsProvider).advancedFeaturesEnabled,
      channelsEnabled: ref.read(channelsFeatureEnabledProvider),
      permissions: permissions,
    );
    if (management.canManage && admits(management)) return null;
    state = state.copyWith(mutating: false);
    return ChannelMemberMutationResult.notPermitted;
  }

  bool _isServerDenial(Object error) {
    if (error is! DioException) return false;
    final status = error.response?.statusCode;
    return status == 401 || status == 403 || status == 404;
  }

  void _logFailure(String stage, Object error, StackTrace stackTrace) {
    DebugLogger.error(
      'channel-members-$stage-failed',
      scope: 'channels/members',
      error: error,
      stackTrace: stackTrace,
    );
  }
}
