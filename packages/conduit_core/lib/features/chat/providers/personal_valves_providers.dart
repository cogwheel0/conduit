import 'dart:async';

import 'package:dio/dio.dart';
import 'package:riverpod/misc.dart' show ProviderListenable;
import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/auth/api_auth_interceptor.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/chat/models/personal_valves.dart';
import 'package:conduit_core/features/direct_connections/services/direct_model_registry.dart';
import 'package:conduit_core/features/hermes/models/hermes_model.dart';
import 'package:conduit_core/features/push/services/openwebui_push_backend.dart'
    show kConduitPushFunctionId;
import 'package:conduit_core/features/tools/providers/tools_providers.dart';
import 'package:conduit_core/features/workspace/models/workspace_valve_values.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/utils/debug_logger.dart';

/// Reads a provider; satisfied by both `Ref.read` and `WidgetRef.read`.
typedef ProviderReader = T Function<T>(ProviderListenable<T> provider);

/// The server, account, and API client that were active when an editor opened.
///
/// The editor holds this one owner through load, save, validation retries,
/// and credential changes. It is never recaptured: a mounted sheet or a stable
/// [ApiService] does not prove the same account is still signed in.
class PersonalValvesOwner {
  const PersonalValvesOwner._({
    required this.api,
    required this.serverId,
    required this.userId,
    required this.token,
    required this.authEpoch,
    required this.authSnapshot,
  });

  final ApiService api;
  final String serverId;
  final String? userId;
  final String token;
  final Object authEpoch;

  /// Binds every request to the bearer this owner opened with. The checks
  /// around each await cannot do that: Dio picks the token at dispatch, after
  /// the check, so a shared client that rotates to another account in between
  /// would send this owner's draft as that account.
  final ApiAuthSnapshot authSnapshot;

  /// Captures the active owner synchronously, or null when no OpenWebUI
  /// account is signed in. Call it at the user's action, before any await.
  static PersonalValvesOwner? capture(ProviderReader read) {
    final api = read(apiServiceProvider);
    final serverId = read(activeServerProvider).asData?.value?.id;
    final token = read(authTokenProvider3);
    if (api == null ||
        serverId == null ||
        api.serverConfig.id != serverId ||
        token == null ||
        token.isEmpty) {
      return null;
    }
    return PersonalValvesOwner._(
      api: api,
      serverId: serverId,
      userId: read(currentUserProvider2)?.id,
      token: token,
      authEpoch: read(openWebUiAuthSessionEpochProvider),
      authSnapshot: api.captureAuthSnapshot(),
    );
  }

  bool isCurrent(ProviderReader read) =>
      identical(api, read(apiServiceProvider)) &&
      serverId == read(activeServerProvider).asData?.value?.id &&
      userId == read(currentUserProvider2)?.id &&
      token == read(authTokenProvider3) &&
      identical(authEpoch, read(openWebUiAuthSessionEpochProvider));

  @override
  bool operator ==(Object other) =>
      other is PersonalValvesOwner &&
      identical(other.api, api) &&
      other.serverId == serverId &&
      other.userId == userId &&
      other.token == token &&
      identical(other.authEpoch, authEpoch);

  @override
  int get hashCode =>
      Object.hash(identityHashCode(api), serverId, userId, token);
}

class PersonalValvesEditorKey {
  const PersonalValvesEditorKey(this.owner, this.target);

  final PersonalValvesOwner owner;
  final PersonalValvesTarget target;

  @override
  bool operator ==(Object other) =>
      other is PersonalValvesEditorKey &&
      other.owner == owner &&
      other.target == target;

  @override
  int get hashCode => Object.hash(owner, target);
}

enum PersonalValvesPhase {
  loading,
  ready,
  unavailable,
  loadFailed,
  ownerChanged,
}

class PersonalValvesEditorState {
  const PersonalValvesEditorState({
    this.phase = PersonalValvesPhase.loading,
    this.document,
    this.draft = const {},
    this.saving = false,
  });

  final PersonalValvesPhase phase;
  final PersonalValvesDocument? document;

  /// The user's unsaved edits. It survives a rejected save so a validation
  /// error never costs the user their input.
  final Map<String, dynamic> draft;
  final bool saving;

  PersonalValvesEditorState copyWith({
    PersonalValvesPhase? phase,
    PersonalValvesDocument? document,
    Map<String, dynamic>? draft,
    bool? saving,
  }) => PersonalValvesEditorState(
    phase: phase ?? this.phase,
    document: document ?? this.document,
    draft: draft ?? this.draft,
    saving: saving ?? this.saving,
  );
}

/// Loads and saves one target's personal valves for the owner that opened it.
///
/// Only the per-user routes are called; the server-owner valve routes need
/// write access to the resource, which a user running a shared tool lacks.
final personalValvesEditorProvider = NotifierProvider.autoDispose
    .family<
      PersonalValvesEditor,
      PersonalValvesEditorState,
      PersonalValvesEditorKey
    >(PersonalValvesEditor.new);

class PersonalValvesEditor extends Notifier<PersonalValvesEditorState> {
  PersonalValvesEditor(this._key);

  final PersonalValvesEditorKey _key;

  PersonalValvesOwner get _owner => _key.owner;
  PersonalValvesTarget get _target => _key.target;

  @override
  PersonalValvesEditorState build() {
    scheduleMicrotask(_load);
    return const PersonalValvesEditorState();
  }

  bool get _ownerIsCurrent => ref.mounted && _owner.isCurrent(ref.read);

  /// The current `chat.valves` policy, read fresh for every load and save: an
  /// editor opened while allowed must not keep working once the server denies
  /// it, whether or not the account changed.
  bool get _policyPermits => _permitsPersonalValves(
    ref.read(currentUserProvider2),
    ref.read(userPermissionsProvider).asData?.value,
  );

  /// A load that policy now refuses reads nothing and shows nothing.
  void _denyLoad() {
    if (ref.mounted) {
      state = const PersonalValvesEditorState(
        phase: PersonalValvesPhase.unavailable,
      );
    }
  }

  /// Drops every value held for the previous owner.
  void _retireOwner() {
    if (ref.mounted) {
      state = const PersonalValvesEditorState(
        phase: PersonalValvesPhase.ownerChanged,
      );
    }
  }

  Future<void> _load() async {
    if (!ref.mounted) return;
    if (!_ownerIsCurrent) return _retireOwner();
    if (!_policyPermits) return _denyLoad();
    final api = _owner.api;
    final snapshot = _owner.authSnapshot;
    final id = _target.id;
    try {
      final spec = switch (_target.kind) {
        PersonalValvesTargetKind.tool => await api.getUserToolValvesSpec(
          id,
          authSnapshot: snapshot,
        ),
        PersonalValvesTargetKind.function =>
          await api.getUserFunctionValvesSpec(id, authSnapshot: snapshot),
      };
      if (!ref.mounted) return;
      // A different account must not read this target's stored values.
      if (!_ownerIsCurrent) return _retireOwner();
      if (!_policyPermits) return _denyLoad();
      final values = spec == null || spec.isEmpty
          ? null
          : switch (_target.kind) {
              PersonalValvesTargetKind.tool => await api.getUserToolValves(
                id,
                authSnapshot: snapshot,
              ),
              PersonalValvesTargetKind.function =>
                await api.getUserFunctionValves(id, authSnapshot: snapshot),
            };
      if (!ref.mounted) return;
      if (!_ownerIsCurrent) return _retireOwner();
      final document = PersonalValvesDocument(
        target: _target,
        spec: spec,
        values: WorkspaceValveValues.hydrate(spec, values ?? const {}),
      );
      state = PersonalValvesEditorState(
        phase: document.editable
            ? PersonalValvesPhase.ready
            : PersonalValvesPhase.unavailable,
        document: document,
        draft: document.values,
      );
    } catch (error) {
      if (!ref.mounted) return;
      if (!_ownerIsCurrent) return _retireOwner();
      _logFailure('load', error);
      state = PersonalValvesEditorState(
        phase: _isUnavailable(error)
            ? PersonalValvesPhase.unavailable
            : PersonalValvesPhase.loadFailed,
      );
    }
  }

  /// Records the form's current values. Ignored once the editor is no longer
  /// the owner's, so a late form callback cannot repopulate retired state.
  void setDraft(Map<String, dynamic> values) {
    if (state.phase != PersonalValvesPhase.ready || state.saving) return;
    state = state.copyWith(draft: Map<String, dynamic>.of(values));
  }

  /// Saves the draft. Returns null on success, otherwise why it failed; the
  /// draft is kept on every failure.
  Future<PersonalValvesFailure?> save() async {
    final document = state.document;
    if (state.phase != PersonalValvesPhase.ready ||
        state.saving ||
        document == null ||
        !document.editable) {
      return const PersonalValvesFailure(
        PersonalValvesFailureReason.unavailable,
      );
    }
    if (!_ownerIsCurrent) {
      _retireOwner();
      return const PersonalValvesFailure(
        PersonalValvesFailureReason.ownerChanged,
      );
    }
    // The draft stays in place so it survives if the policy is restored.
    if (!_policyPermits) {
      return const PersonalValvesFailure(PersonalValvesFailureReason.denied);
    }
    final api = _owner.api;
    final snapshot = _owner.authSnapshot;
    final id = _target.id;
    final body = WorkspaceValveValues.serialize(document.spec, state.draft);
    state = state.copyWith(saving: true);
    try {
      final saved = switch (_target.kind) {
        PersonalValvesTargetKind.tool => await api.updateUserToolValves(
          id,
          body,
          authSnapshot: snapshot,
        ),
        PersonalValvesTargetKind.function => await api.updateUserFunctionValves(
          id,
          body,
          authSnapshot: snapshot,
        ),
      };
      if (!ref.mounted) {
        return const PersonalValvesFailure(
          PersonalValvesFailureReason.ownerChanged,
        );
      }
      if (!_ownerIsCurrent) {
        _retireOwner();
        return const PersonalValvesFailure(
          PersonalValvesFailureReason.ownerChanged,
        );
      }
      // The server returns the values it stored; fall back to what was sent.
      final stored = WorkspaceValveValues.hydrate(document.spec, saved ?? body);
      state = PersonalValvesEditorState(
        phase: PersonalValvesPhase.ready,
        document: PersonalValvesDocument(
          target: _target,
          spec: document.spec,
          values: stored,
        ),
        draft: stored,
      );
      return null;
    } catch (error) {
      if (!ref.mounted) {
        return const PersonalValvesFailure(
          PersonalValvesFailureReason.ownerChanged,
        );
      }
      if (!_ownerIsCurrent) {
        _retireOwner();
        return const PersonalValvesFailure(
          PersonalValvesFailureReason.ownerChanged,
        );
      }
      _logFailure('save', error);
      state = state.copyWith(saving: false);
      return _saveFailure(error);
    }
  }

  PersonalValvesFailure _saveFailure(Object error) {
    if (error is DioException) {
      final status = error.response?.statusCode;
      if (status == 400 || status == 422) {
        return PersonalValvesFailure(
          PersonalValvesFailureReason.invalid,
          detail: _serverDetail(error.response?.data),
        );
      }
      if (_isUnavailable(error)) {
        return const PersonalValvesFailure(
          PersonalValvesFailureReason.unavailable,
        );
      }
    }
    return const PersonalValvesFailure(PersonalValvesFailureReason.failed);
  }

  /// Valve contents can be echoed in server errors, so only the target kind
  /// and failure type are logged.
  void _logFailure(String operation, Object error) {
    DebugLogger.error(
      'personal valves $operation failed',
      scope: 'chat/personal-valves',
      data: {
        'kind': _target.kind.name,
        'failureType': error.runtimeType.toString(),
        if (error is DioException) 'status': error.response?.statusCode,
      },
    );
  }
}

bool _isUnavailable(Object error) {
  if (error is! DioException) return false;
  final status = error.response?.statusCode;
  // Open WebUI reports a missing or inaccessible resource as 401, 403, or 404
  // depending on the route.
  return status == 401 || status == 403 || status == 404;
}

String? _serverDetail(Object? data) {
  if (data is Map) {
    final detail = data['detail'];
    if (detail is String && detail.trim().isNotEmpty) return detail.trim();
  }
  return null;
}

/// The id of the function behind a pipe model, by the server's own routing
/// rule: a manifold's submodel ids are `function.submodel`, so the function id
/// is everything before the first dot. A preset model runs its base model's
/// pipe, so the base model is the source of both the id and the schema flag.
/// Null when the model is not a pipe, its base is not visible, or the function
/// has no personal valves.
String? _pipeFunctionId(Model model, List<Model> models) {
  final info = model.metadata?['info'];
  final baseId =
      (model.baseModelId ?? (info is Map ? info['base_model_id'] : null))
          ?.toString();
  var source = model;
  if (baseId != null && baseId.isNotEmpty) {
    final baseKey = baseId.split(':').first;
    final base = models.where((m) => m.id == baseId || m.id == baseKey);
    if (base.isEmpty) return null;
    source = base.first;
  }
  final metadata = source.metadata;
  if (metadata?['pipe'] is! Map || metadata?['has_user_valves'] != true) {
    return null;
  }
  final dot = source.id.indexOf('.');
  final functionId = dot < 0 ? source.id : source.id.substring(0, dot);
  return functionId.isEmpty ? null : functionId;
}

/// Whether the account may open personal valves from chat. Open WebUI gates
/// this on the `chat.valves` permission, which defaults to allowed.
bool _permitsPersonalValves(User? user, Map<String, dynamic>? permissions) {
  if (user?.role == 'admin') return true;
  final chat = permissions?['chat'];
  final value = chat is Map ? chat['valves'] : null;
  return value is bool ? value : true;
}

/// Selected tools, filters, and the selected pipe that expose personal
/// valves to the signed-in account.
final personalValvesTargetsProvider = Provider<List<PersonalValvesTarget>>((
  ref,
) {
  final model = ref.watch(selectedModelProvider);
  if (model == null ||
      hasReservedDirectIdentity(model) ||
      isHermesModel(model)) {
    return const [];
  }
  final permissions = ref
      .watch(userPermissionsProvider)
      .maybeWhen(data: (value) => value, orElse: () => null);
  if (!_permitsPersonalValves(ref.watch(currentUserProvider2), permissions)) {
    return const [];
  }

  final targets = <PersonalValvesTarget>[];
  final seen = <String>{};
  void add(PersonalValvesTargetKind kind, String id, String label) {
    // Conduit Push keeps its subscriptions in user valves it manages itself.
    if (kind == PersonalValvesTargetKind.function &&
        id == kConduitPushFunctionId) {
      return;
    }
    if (seen.add('${kind.name}:$id')) {
      targets.add(PersonalValvesTarget(kind: kind, id: id, label: label));
    }
  }

  final models = ref
      .watch(modelsProvider)
      .maybeWhen(data: (value) => value, orElse: () => const <Model>[]);
  final pipeFunctionId = _pipeFunctionId(model, models);
  if (pipeFunctionId != null) {
    add(PersonalValvesTargetKind.function, pipeFunctionId, model.name);
  }

  final selectedFilters = ref.watch(selectedFilterIdsProvider).toSet();
  for (final filter in model.filters ?? const []) {
    if (filter.hasUserValves && selectedFilters.contains(filter.id)) {
      add(PersonalValvesTargetKind.function, filter.id, filter.name);
    }
  }

  final selectedTools = ref.watch(selectedToolIdsProvider).toSet();
  final tools = ref
      .watch(toolsListProvider)
      .maybeWhen(data: (value) => value, orElse: () => const []);
  for (final tool in tools) {
    if (tool.hasUserValves == true && selectedTools.contains(tool.id)) {
      add(PersonalValvesTargetKind.tool, tool.id, tool.name);
    }
  }
  return targets;
});

/// Whether the composer offers "Tool settings". Advanced gates only this new
/// command; it never changes which values are stored or used by requests.
final personalValvesCommandAvailableProvider = Provider<bool>((ref) {
  return ref.watch(
        appSettingsProvider.select(
          (settings) => settings.advancedFeaturesEnabled,
        ),
      ) &&
      ref.watch(personalValvesTargetsProvider).isNotEmpty;
});
