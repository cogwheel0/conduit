import 'dart:async';

import 'package:dio/dio.dart';
import 'package:meta/meta.dart';
import 'package:riverpod/riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:conduit_core/auth/api_auth_interceptor.dart';
import 'package:conduit_core/error/api_error.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/automations/models/automation.dart';
import 'package:conduit_core/models/backend_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/settings_service.dart';

part 'automation_providers.g.dart';

/// Thrown when the signed-in account may not use scheduled tasks: the server
/// has them off, or the account lacks the `features.automations` permission.
/// Nothing was sent.
final class AutomationsUnavailableException implements Exception {
  const AutomationsUnavailableException();

  @override
  String toString() =>
      'AutomationsUnavailableException: scheduled tasks are not available for '
      'this account';
}

/// Thrown when the account a task list, editor or detail was opened for is no
/// longer the signed-in one. Nothing was sent, so a form can keep its input.
final class AutomationsOwnerChangedException extends StateError {
  AutomationsOwnerChangedException()
    : super('The account changed since this task was opened');
}

/// The account a list, editor or detail was opened for.
///
/// The notifier outlives account switches and the [ApiService] can stay the
/// same across them, so holding either says nothing about whose tasks a later
/// Save, Run or Delete would touch. Capture the owner synchronously when the
/// surface opens, before any await, and pass it to every operation. An
/// operation is refused before any request once the API, auth session or
/// server no longer match, and its request is bound to the captured
/// [ApiAuthSnapshot] so a credential change that lands later cannot redirect
/// it.
@immutable
final class AutomationsOwner {
  const AutomationsOwner._(this._api, this._auth, this._ownership);

  final ApiService _api;
  final ApiAuthSnapshot _auth;
  final OpenWebUiCacheOwnershipSnapshot _ownership;
}

/// Which tasks the list shows.
enum AutomationStatusFilter {
  all(null),
  active('active'),
  paused('paused');

  const AutomationStatusFilter(this.query);

  /// The `status` query value, or null for both.
  final String? query;
}

/// The loaded pages of the account's tasks, newest first.
@immutable
final class AutomationsData {
  const AutomationsData({
    this.items = const <Automation>[],
    this.total = 0,
    this.query = '',
    this.status = AutomationStatusFilter.all,
    this.page = 1,
    this.exhausted = false,
    this.stale = false,
  });

  final List<Automation> items;

  /// Matches across every page for [query] and [status].
  final int total;
  final String query;
  final AutomationStatusFilter status;

  /// The highest page loaded; pages 1 through this are in [items].
  final int page;

  /// True once a page added nothing new, so asking for another would only
  /// repeat it.
  final bool exhausted;

  /// True when a change went through but reading the list back failed, so
  /// [items] may not show it yet.
  final bool stale;

  bool get hasMore => !exhausted && items.length < total;

  AutomationsData copyWith({bool? stale}) => AutomationsData(
    items: items,
    total: total,
    query: query,
    status: status,
    page: page,
    exhausted: exhausted,
    stale: stale ?? this.stale,
  );
}

/// Whether [user] may use scheduled tasks on [serverId].
///
/// Open WebUI offers them only when the server's `enable_automations` is on
/// and the account is an admin or holds `features.automations`. That
/// permission is off unless granted, so a missing one means denied. [config]
/// counts only when it was fetched from [serverId].
bool automationsPermitted({
  required BackendConfig? config,
  required String serverId,
  required User? user,
  required Map<String, dynamic> permissions,
}) {
  if (config == null ||
      config.serverId != serverId ||
      config.enableAutomations != true) {
    return false;
  }
  if (user?.role == 'admin') return true;
  final features = permissions['features'];
  return features is Map && features['automations'] == true;
}

/// Whether the signed-in account can use scheduled tasks right now, for
/// surfaces deciding whether to show them. False while the inputs load.
///
/// This only reads [userPermissionsProvider] and [backendConfigProvider]. The
/// operations recheck the same rule themselves.
final automationsAvailableProvider = Provider<bool>((ref) {
  final api = ref.watch(apiServiceProvider);
  ref.watch(openWebUiAuthSessionEpochProvider);
  final user = ref.watch(currentUserProvider2);
  final config = ref.watch(backendConfigProvider).asData?.value;
  final permissions =
      ref.watch(userPermissionsProvider).asData?.value ??
      (user?.role == 'admin' ? const <String, dynamic>{} : null);
  if (api == null || permissions == null) return false;
  return automationsPermitted(
    config: config,
    serverId: api.serverConfig.id,
    user: user,
    permissions: permissions,
  );
});

/// Whether Settings offers Scheduled tasks: the Advanced disclosure is on and
/// the server and account allow them. Flutter Settings and the native iOS
/// sheet both read this, so they cannot disagree about when the entry exists.
/// Turning Advanced off hides the entry only; tasks the server holds keep
/// running.
final scheduledTasksEntryVisibleProvider = Provider<bool>((ref) {
  return ref.watch(
        appSettingsProvider.select((s) => s.advancedFeaturesEnabled),
      ) &&
      ref.watch(automationsAvailableProvider);
});

/// The server's own explanation for a refused request, such as "Schedule too
/// frequent. Minimum interval is 3600 seconds.", or null when it gave none.
/// Never the request body.
///
/// The shared error layer keeps the server's wording for a 400 or 422 but
/// builds a 401, 403 or 404 from the status alone. The task limit is a 403
/// whose detail the user needs, so the response body is read when the typed
/// error has no text.
String? automationErrorDetail(Object error) {
  if (error is! DioException) return null;
  final apiError = error.error;
  final typed = apiError is ApiError
      ? (apiError.details?.message ?? apiError.message)
      : null;
  if (typed != null && typed.isNotEmpty) return typed;
  final body = error.response?.data;
  final detail = body is Map ? body['detail'] : null;
  return detail is String && detail.isNotEmpty ? detail : null;
}

// A refused or failed load is shown as it is. Riverpod's default would send
// the same authenticated request again, up to ten times, behind the user's
// back; the user's own refresh is the retry.
Duration? _doNotRetryAutomationsLoad(int retryCount, Object error) => null;

/// The signed-in account's Open WebUI scheduled tasks, kept on the server.
///
/// Management is online only: the server runs a task on its own schedule, so
/// nothing here schedules, queues or stores a task on the device. Every
/// operation, loads included, is admitted for an [AutomationsOwner] and
/// rechecks that account's capability before it sends.
@Riverpod(keepAlive: true, retry: _doNotRetryAutomationsLoad)
class Automations extends _$Automations {
  int _loadGeneration = 0;
  String _query = '';
  AutomationStatusFilter _status = AutomationStatusFilter.all;

  @override
  Future<AutomationsData> build() async {
    ref.watch(activeServerProvider.select((s) => s.asData?.value?.id));
    // A same-server account switch keeps the same ApiService, so the auth
    // session is what retires one account's tasks for the next.
    ref.watch(openWebUiAuthSessionEpochProvider);
    ref.watch(automationsAvailableProvider);
    final apiAlive = ref.watch(apiServiceProvider.select((a) => a != null));
    _query = '';
    _status = AutomationStatusFilter.all;
    final owner = apiAlive ? captureOwner() : null;
    if (owner == null) return const AutomationsData();

    final data = await _load(owner, pages: 1);
    if (!_isCurrent(owner)) return const AutomationsData();
    return data;
  }

  /// The account that is signed in now, for a surface to hold until it acts.
  /// Null when no signed-in account can own tasks at the moment.
  AutomationsOwner? captureOwner() {
    final api = ref.read(apiServiceProvider);
    if (api == null) return null;
    final ownership = captureOpenWebUiCacheOwnership(ref, api: api);
    if (ownership == null) return null;
    return AutomationsOwner._(api, api.captureAuthSnapshot(), ownership);
  }

  /// Whether [owner] is still the signed-in account.
  bool isCurrentOwner(AutomationsOwner owner) => _isCurrent(owner);

  /// Reloads the list for [owner], optionally with a new search or status.
  /// A change of either starts again from the first page. A result that
  /// arrives after the account has changed is dropped.
  Future<void> refresh({
    required AutomationsOwner owner,
    String? query,
    AutomationStatusFilter? status,
  }) async {
    if (!_isCurrent(owner)) return;
    final filterChanged =
        (query != null && query.trim() != _query) ||
        (status != null && status != _status);
    _query = query?.trim() ?? _query;
    _status = status ?? _status;
    if (!state.hasValue) state = const AsyncLoading<AutomationsData>();
    await _reload(owner, restart: filterChanged);
  }

  /// Loads the next page for [owner] and appends what is new.
  Future<void> loadMore({required AutomationsOwner owner}) async {
    final shown = state.asData?.value;
    if (shown == null || !shown.hasMore || !_isCurrent(owner)) return;
    final generation = ++_loadGeneration;
    try {
      final operation = await _admit(owner);
      final next = shown.page + 1;
      final page = await operation._api.getAutomations(
        query: shown.query,
        status: shown.status.query,
        page: next,
        authSnapshot: operation._auth,
      );
      if (generation != _loadGeneration || !_isCurrent(owner)) return;
      final known = {for (final item in shown.items) item.id};
      final added = [
        for (final item in page.items)
          if (!known.contains(item.id)) item,
      ];
      state = AsyncData(
        AutomationsData(
          items: List<Automation>.unmodifiable([...shown.items, ...added]),
          total: page.total,
          query: shown.query,
          status: shown.status,
          page: next,
          exhausted: added.isEmpty,
        ),
      );
    } catch (_) {
      if (generation != _loadGeneration || !_isCurrent(owner)) return;
      // The pages already loaded stay; the user's own refresh is the retry.
      state = AsyncData(shown.copyWith(stale: true));
    }
  }

  /// One task, read from the server. An answer that arrives after the account
  /// changed is dropped: it belongs to the previous account, and a surface must
  /// not adopt it for the next one.
  Future<Automation> fetch(String id, {required AutomationsOwner owner}) async {
    final operation = await _admit(owner);
    final task = await operation._api.getAutomation(
      id,
      authSnapshot: operation._auth,
    );
    return _stillOwned(owner, task);
  }

  Future<Automation> create(
    AutomationForm form, {
    required AutomationsOwner owner,
  }) async {
    final operation = await _admit(owner);
    final created = await operation._api.createAutomation(
      form,
      authSnapshot: operation._auth,
    );
    await _reload(owner);
    return created;
  }

  /// Replaces the task with [form], which must carry the task's whole `data`
  /// and `meta`: the server overwrites both.
  Future<Automation> updateTask(
    String id,
    AutomationForm form, {
    required AutomationsOwner owner,
  }) async {
    final operation = await _admit(owner);
    final updated = await operation._api.updateAutomation(
      id,
      form,
      authSnapshot: operation._auth,
    );
    await _reload(owner);
    return updated;
  }

  /// Makes the task active or paused, as the user asked.
  ///
  /// The server's route flips whatever it holds, so the state is read first: a
  /// task another client already put in the wanted state is left alone,
  /// instead of being flipped back by a switch that was showing stale state.
  /// The result is the server's state afterwards.
  Future<Automation> setActive(
    String id,
    bool active, {
    required AutomationsOwner owner,
  }) async {
    final operation = await _admit(owner);
    final current = await operation._api.getAutomation(
      id,
      authSnapshot: operation._auth,
    );
    if (current.isActive == active) {
      await _reload(owner);
      return current;
    }
    // Reading took time, and the account can have changed during it.
    if (!_isCurrent(owner)) throw AutomationsOwnerChangedException();
    final toggled = await operation._api.toggleAutomation(
      id,
      authSnapshot: operation._auth,
    );
    await _reload(owner);
    return toggled;
  }

  /// Asks the server to run the task now. Call this only from an explicit
  /// user action.
  ///
  /// Success means the server accepted the request. The run happens in the
  /// background and its outcome is recorded in the task's history when it
  /// finishes, so the returned definition says nothing about whether it
  /// worked.
  Future<Automation> run(String id, {required AutomationsOwner owner}) async {
    final operation = await _admit(owner);
    final accepted = await operation._api.runAutomation(
      id,
      authSnapshot: operation._auth,
    );
    await _reload(owner);
    return accepted;
  }

  Future<void> remove(String id, {required AutomationsOwner owner}) async {
    final operation = await _admit(owner);
    await operation._api.deleteAutomation(id, authSnapshot: operation._auth);
    await _reload(owner);
  }

  /// A page of the task's history, newest first, from offset [skip]. Runs are
  /// separate from the definition and are never merged into it.
  Future<List<AutomationRun>> runs(
    String id, {
    int skip = 0,
    int limit = automationRunsPageSize,
    required AutomationsOwner owner,
  }) async {
    final operation = await _admit(owner);
    final page = await operation._api.getAutomationRuns(
      id,
      skip: skip,
      limit: limit,
      authSnapshot: operation._auth,
    );
    return _stillOwned(owner, page);
  }

  /// Whether the account may post to [channelId], read from the channel. Like
  /// the other reads, an answer for an account that is no longer signed in is
  /// dropped rather than reported to the next one.
  Future<bool> channelWritable(
    String channelId, {
    required AutomationsOwner owner,
  }) async {
    final operation = await _admit(owner);
    final writable = await operation._api.getAutomationChannelWriteAccess(
      channelId,
      authSnapshot: operation._auth,
    );
    return _stillOwned(owner, writable);
  }

  bool _isCurrent(AutomationsOwner owner) =>
      ref.mounted && openWebUiCacheOwnershipIsCurrent(ref, owner._ownership);

  /// [answer] for a read, once [owner] is confirmed to still be signed in.
  /// Writes do not use this: a request already accepted for the account stays
  /// accepted, and the surface decides what to show the new one.
  T _stillOwned<T>(AutomationsOwner owner, T answer) {
    if (!_isCurrent(owner)) throw AutomationsOwnerChangedException();
    return answer;
  }

  /// Admits one operation for [owner]: the account must still be the signed-in
  /// one, and still be allowed scheduled tasks, both checked after the
  /// permission lookup so a change during it is caught.
  Future<AutomationsOwner> _admit(AutomationsOwner owner) async {
    if (!_isCurrent(owner)) throw AutomationsOwnerChangedException();

    // Read through the shared providers rather than fetching again. A failed
    // read is a denial: scheduled tasks default to off, not on.
    final permissions = await _settled(userPermissionsProvider);
    final config = await _settled(backendConfigProvider);
    if (!_isCurrent(owner)) throw AutomationsOwnerChangedException();
    if (permissions == null ||
        config == null ||
        !automationsPermitted(
          config: config.value,
          serverId: owner._ownership.serverId,
          user: ref.read(currentUserProvider2),
          permissions: permissions.value,
        )) {
      throw const AutomationsUnavailableException();
    }
    return owner;
  }

  /// The first settled value of [provider], or null when it failed or this
  /// notifier rebuilt first.
  ///
  /// Awaiting `provider.future` instead can wait forever: a build that an
  /// account switch replaced may never complete, and a Save would spin with no
  /// way out. This notifier rebuilds on every session change, and that also
  /// drops listeners made through its ref, so the rebuild itself ends the
  /// wait. The caller's ownership check then decides what it means.
  Future<({T value})?> _settled<T>(
    ProviderListenable<AsyncValue<T>> provider,
  ) async {
    final settled = Completer<({T value})?>();
    final subscription = ref.listen<AsyncValue<T>>(
      provider,
      fireImmediately: true,
      (_, next) {
        if (next.isLoading || settled.isCompleted) return;
        settled.complete(next.hasError ? null : (value: next.requireValue));
      },
    );
    final stopWatchingRebuild = ref.onDispose(() {
      if (!settled.isCompleted) settled.complete(null);
    });
    try {
      return await settled.future;
    } finally {
      subscription.close();
      stopWatchingRebuild();
    }
  }

  /// Loads pages 1 through [pages] under the current search and status.
  Future<AutomationsData> _load(
    AutomationsOwner owner, {
    required int pages,
  }) async {
    final operation = await _admit(owner);
    final items = <Automation>[];
    final known = <String>{};
    var total = 0;
    var exhausted = false;
    for (var page = 1; page <= pages; page++) {
      final result = await operation._api.getAutomations(
        query: _query,
        status: _status.query,
        page: page,
        authSnapshot: operation._auth,
      );
      total = result.total;
      final added = [
        for (final item in result.items)
          if (known.add(item.id)) item,
      ];
      items.addAll(added);
      if (added.isEmpty) {
        exhausted = true;
        break;
      }
    }
    return AutomationsData(
      items: List<Automation>.unmodifiable(items),
      total: total,
      query: _query,
      status: _status,
      page: pages,
      exhausted: exhausted,
    );
  }

  /// Replaces the list with the server's, unless a newer load started or the
  /// account changed. It reloads as many pages as were showing so a change
  /// does not drop the user's place, or starts again when [restart]. A failure
  /// keeps the list that was showing, marked stale.
  Future<void> _reload(AutomationsOwner owner, {bool restart = false}) async {
    final generation = ++_loadGeneration;
    final shown = state.asData?.value;
    final pages = restart || shown == null ? 1 : shown.page;
    try {
      final data = await _load(owner, pages: pages);
      if (generation != _loadGeneration || !_isCurrent(owner)) return;
      state = AsyncData(data);
    } catch (error, stackTrace) {
      if (generation != _loadGeneration || !_isCurrent(owner)) return;
      state = shown == null || restart
          ? AsyncError<AutomationsData>(error, stackTrace)
          : AsyncData(shown.copyWith(stale: true));
    }
  }
}
