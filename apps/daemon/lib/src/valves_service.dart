import 'dart:async';

import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/chat/models/personal_valves.dart';
import 'package:conduit_core/features/chat/providers/personal_valves_providers.dart';
import 'package:conduit_core/features/tools/providers/tools_providers.dart';
import 'package:conduit_core/features/workspace/models/workspace_resources.dart';
import 'package:conduit_core/features/workspace/models/workspace_valve_values.dart';
import 'package:conduit_core/models/model.dart' as core;
import 'package:conduit_core/models/tool.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/settings_service.dart'
    show appSettingsProvider;
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:riverpod/riverpod.dart';

import 'models_service.dart' show currentModel;
import 'settled.dart';

/// How long a valve set may take to load before the answer is "it could
/// not be loaded".
const _loadWait = Duration(seconds: 20);

/// Implements `valves.*`: the user's own settings ("personal valves") for
/// the tools, filters and pipe a chat uses, over the core's
/// [PersonalValvesEditor], which owns the account check, the `chat.valves`
/// policy and the per-user routes. The form's field list and the typing of
/// what the window sends back are the core's [WorkspaceValveValues] rules.
final class ValvesService {
  ValvesService(this._container);

  final ProviderContainer _container;

  /// What the chat's model, tools and filters offer personal valves for.
  Future<ValveTargets> targets(ValveTargetsQuery query) async {
    // Read for the account in use now: once another is, the targets (its
    // model's pipe among them) are not shown to it.
    final session = _container.read(openWebUiAuthSessionEpochProvider);
    void sameAccount() {
      if (!identical(
        session,
        _container.read(openWebUiAuthSessionEpochProvider),
      )) {
        throw const RpcError(
          code: ConduitErrorCodes.sessionExpired,
          debugMessage: 'the account changed',
        );
      }
    }

    final model = await _model(query.modelId);
    sameAccount();
    Map<String, dynamic>? permissions;
    try {
      permissions = await readSettled(
        _container,
        userPermissionsProvider.future,
      );
    } on Object {
      permissions = null;
    }
    List<core.Model> models;
    try {
      models = await readSettled(_container, modelsProvider.future);
    } on Object {
      models = _container.read(modelsProvider).value ?? const <core.Model>[];
    }
    List<Tool> tools;
    try {
      tools = await readSettled(_container, toolsListProvider.future);
    } on Object {
      tools = _container.read(toolsListProvider).value ?? const <Tool>[];
    }
    sameAccount();
    final found = personalValvesTargetsFor(
      model: model,
      user: _container.read(currentUserProvider2),
      permissions: permissions,
      models: models,
      tools: tools,
      selectedToolIds: query.toolIds,
      selectedFilterIds: query.filterIds,
    );
    return ValveTargets(
      targets: <ValveTarget>[
        for (final target in found)
          ValveTarget(
            kind: _kindOut(target.kind),
            id: target.id,
            label: target.label,
          ),
      ],
      advanced: _container.read(appSettingsProvider).advancedFeaturesEnabled,
    );
  }

  Future<ValvesDocument> get(ValvesRef ref) async {
    final target = PersonalValvesTarget(
      kind: _kindIn(ref.kind),
      id: ref.id,
      label: ref.label,
    );
    return _withEditor(
      target,
      (editor, state, current) async => _document(target, state),
    );
  }

  Future<ValvesDocument> save(ValvesSave request) async {
    final target = PersonalValvesTarget(
      kind: _kindIn(request.kind),
      id: request.id,
      label: request.label,
    );
    return _withEditor(target, (editor, state, current) async {
      final document = state.document;
      if (state.phase != PersonalValvesPhase.ready || document == null) {
        return _document(target, state);
      }
      final spec = document.spec!;
      final draft = Map<String, dynamic>.of(state.draft);
      for (final edit in request.values) {
        if (!spec.properties.containsKey(edit.key)) continue;
        draft[edit.key] = edit.isDefault
            ? null
            : typed(
                WorkspaceValveValues.propertySpec(spec, edit.key),
                edit.text,
                draft[edit.key],
              );
      }
      editor.setDraft(draft);
      final failure = await editor.save();
      if (failure != null) {
        throw RpcError(
          code: switch (failure.reason) {
            PersonalValvesFailureReason.invalid =>
              ConduitErrorCodes.invalidParams,
            PersonalValvesFailureReason.denied =>
              ConduitErrorCodes.unauthorized,
            PersonalValvesFailureReason.unavailable =>
              ConduitErrorCodes.notFound,
            PersonalValvesFailureReason.ownerChanged =>
              ConduitErrorCodes.conflict,
            PersonalValvesFailureReason.failed => ConduitErrorCodes.serverError,
          },
          args: <String, String>{
            'reason': failure.reason.name,
            // The server's own words for a rejected value; shown, not logged.
            'detail': ?failure.detail,
          },
          debugMessage: 'valves not saved: ${failure.reason.name}',
        );
      }
      return _document(target, current());
    });
  }

  /// Opens the core's editor for [target] as the signed-in account, waits
  /// for it to load, and runs [body] with it.
  Future<ValvesDocument> _withEditor(
    PersonalValvesTarget target,
    Future<ValvesDocument> Function(
      PersonalValvesEditor editor,
      PersonalValvesEditorState state,
      PersonalValvesEditorState Function() current,
    )
    body,
  ) async {
    final owner = PersonalValvesOwner.capture(_container.read);
    if (owner == null) {
      return ValvesDocument(
        kind: _kindOut(target.kind),
        id: target.id,
        label: target.label,
        phase: ValvesPhase.ownerChanged,
      );
    }
    final provider = personalValvesEditorProvider(
      PersonalValvesEditorKey(owner, target),
    );
    final loaded = Completer<void>();
    final subscription = _container.listen<PersonalValvesEditorState>(
      provider,
      (_, next) {
        if (next.phase != PersonalValvesPhase.loading && !loaded.isCompleted) {
          loaded.complete();
        }
      },
      fireImmediately: true,
    );
    try {
      await loaded.future.timeout(_loadWait);
      return await body(
        _container.read(provider.notifier),
        subscription.read(),
        subscription.read,
      );
    } on TimeoutException {
      return ValvesDocument(
        kind: _kindOut(target.kind),
        id: target.id,
        label: target.label,
        phase: ValvesPhase.loadFailed,
      );
    } finally {
      subscription.close();
    }
  }

  static ValvesDocument _document(
    PersonalValvesTarget target,
    PersonalValvesEditorState state,
  ) {
    final spec = state.document?.spec;
    return ValvesDocument(
      kind: _kindOut(target.kind),
      id: target.id,
      label: target.label,
      phase: switch (state.phase) {
        PersonalValvesPhase.ready => ValvesPhase.ready,
        PersonalValvesPhase.loading ||
        PersonalValvesPhase.loadFailed => ValvesPhase.loadFailed,
        PersonalValvesPhase.unavailable => ValvesPhase.unavailable,
        PersonalValvesPhase.ownerChanged => ValvesPhase.ownerChanged,
      },
      fields: spec == null
          ? const <ValveField>[]
          : <ValveField>[
              for (final key in spec.properties.keys)
                fieldOf(spec, key, state.draft[key]),
            ],
    );
  }

  /// One valve as the form draws it, by the schema's `type`, `enum` and
  /// `input` hints, as Open WebUI's own valve form reads them.
  static ValveField fieldOf(
    WorkspaceValveSpec spec,
    String key,
    Object? value,
  ) {
    final property = WorkspaceValveValues.propertySpec(spec, key);
    final options = property['enum'];
    final type = (options is List && options.isNotEmpty)
        ? ValveFieldType.choice
        : switch (property['type']) {
            'boolean' => ValveFieldType.boolean,
            'integer' => ValveFieldType.integer,
            'number' => ValveFieldType.number,
            'array' => ValveFieldType.list,
            _ => ValveFieldType.text,
          };
    final seed = WorkspaceValveValues.customValueFor(property);
    return ValveField(
      key: key,
      title: property['title']?.toString() ?? key,
      description: property['description']?.toString(),
      type: type,
      isRequired: spec.required.contains(key),
      password: WorkspaceValveValues.isPasswordProperty(property),
      options: options is List
          ? <String>[for (final option in options) option.toString()]
          : const <String>[],
      isDefault: value == null,
      hasDefault: property['default'] != null,
      text: value == null ? '' : _text(value),
      seed: seed == null ? '' : _text(seed),
    );
  }

  static String _text(Object value) =>
      value is List ? value.join(', ') : value.toString();

  /// What the form's [text] means for a valve of [property]'s type: an enum
  /// entry of its own runtime type, a switch's bool, a number, or the text.
  /// A switch or a number whose text does not read as one keeps [previous].
  static Object? typed(
    Map<String, dynamic> property,
    String text,
    Object? previous,
  ) {
    final options = property['enum'];
    if (options is List && options.isNotEmpty) {
      return WorkspaceValveValues.enumValueFor(options, text);
    }
    final type = property['type']?.toString();
    if (type == 'boolean') {
      return switch (text.trim().toLowerCase()) {
        'true' => true,
        'false' => false,
        _ => previous ?? WorkspaceValveValues.customValueFor(property),
      };
    }
    return WorkspaceValveValues.coerceText(
      type,
      text,
      previous ?? WorkspaceValveValues.customValueFor(property),
    );
  }

  Future<core.Model?> _model(String? modelId) async {
    if (modelId == null) return currentModel(_container);
    try {
      final models = await readSettled(_container, modelsProvider.future);
      return models.where((m) => m.id == modelId).firstOrNull;
    } on Object {
      return null;
    }
  }

  static PersonalValvesTargetKind _kindIn(ValveTargetKind kind) =>
      switch (kind) {
        ValveTargetKind.tool => PersonalValvesTargetKind.tool,
        ValveTargetKind.function => PersonalValvesTargetKind.function,
      };

  static ValveTargetKind _kindOut(PersonalValvesTargetKind kind) =>
      switch (kind) {
        PersonalValvesTargetKind.tool => ValveTargetKind.tool,
        PersonalValvesTargetKind.function => ValveTargetKind.function,
      };
}
