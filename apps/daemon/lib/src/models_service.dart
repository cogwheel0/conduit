import 'dart:async';

import 'package:conduit_core/models/model.dart' as core;
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:riverpod/riverpod.dart';

import 'event_bus.dart';
import 'settled.dart';

/// How long [currentModel] waits for the account's default to resolve.
///
/// Resolving reads the user's settings from the server. A server out of
/// reach is retried for much longer than a window should wait for its model
/// list, so past this the answer is "nothing chosen yet".
const _defaultModelWait = Duration(seconds: 5);

/// The model a turn that names none runs with: the account's selection, or
/// else its default.
///
/// The default is the one the server's user settings name, or the one last
/// used on this device. Resolving it also selects it, as the mobile chat
/// screen does when it opens. Nothing in the daemon resolved it before, so a
/// fresh sign-in reported no selection, and the first turn ran on whichever
/// model the server happened to list first.
Future<core.Model?> currentModel(ProviderContainer container) async {
  final selected = container.read(selectedModelProvider);
  if (selected != null) return selected;
  core.Model? resolved;
  try {
    resolved = await readSettled(
      container,
      defaultModelProvider.future,
    ).timeout(_defaultModelWait);
  } on Object catch (error) {
    DebugLogger.warning(
      'default-model-unresolved',
      scope: 'daemon/models',
      data: <String, Object?>{'error': '$error'},
    );
    return null;
  }
  return container.read(selectedModelProvider) ?? resolved;
}

/// Implements `models.*` over the core's model providers.
final class ModelsService {
  ModelsService(this._container, {EventBus? events}) {
    if (events != null) _announceChanges(events);
  }

  final ProviderContainer _container;

  /// Publishes `models.changed` when the ids on offer change.
  ///
  /// A direct connection's models are discovered after it is saved, over
  /// the network, so the list a window fetched straight after saving did
  /// not have them yet -- and nothing told it to look again.
  void _announceChanges(EventBus events) {
    List<String>? last;
    _container.listen<AsyncValue<List<core.Model>>>(modelsProvider, (_, next) {
      final models = next.value;
      if (models == null) return;
      final ids = models.map((model) => model.id).toList(growable: false);
      final previous = last;
      last = ids;
      if (previous == null || _sameIds(previous, ids)) return;
      events.emit(ConduitEventSpecs.modelsChanged, null);
    });
  }

  static bool _sameIds(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// The models on offer.
  ///
  /// When the server cannot be reached, the refresh behind the cached list
  /// fails, and the core keeps that list beside the error, as mobile shows
  /// it. The composer offers that list too, instead of no models at all.
  /// The failure is the answer only when there is no list.
  Future<List<core.Model>> _models() async {
    try {
      return await readSettled(_container, modelsProvider.future);
    } on Object catch (error) {
      final last = _container.read(modelsProvider).value;
      if (last == null) rethrow;
      DebugLogger.warning(
        'models-stale',
        scope: 'daemon/models',
        data: <String, Object?>{'count': last.length, 'error': '$error'},
      );
      return last;
    }
  }

  Future<ModelList> list() async {
    final models = await _models();
    return ModelList(
      models: models.map(_summarize).toList(growable: false),
      // The model the next turn runs with, not the first in the list: the
      // composer shows this, and showing a model the next turn would not
      // actually use is worse than showing none.
      selectedId: (await currentModel(_container))?.id,
    );
  }

  Future<ModelList> select(String id) async {
    final models = await _models();
    final model = models.where((candidate) => candidate.id == id).firstOrNull;
    if (model == null) {
      throw RpcError(
        code: ConduitErrorCodes.notFound,
        args: <String, String>{'id': id},
        debugMessage: 'this server does not offer $id',
      );
    }
    _container.read(selectedModelProvider.notifier).set(model);
    return list();
  }

  /// The capability names the server reported, as a flat list.
  ///
  /// `capabilities` is a free-form map on the server's side and gains keys
  /// without warning, so this reports the ones that are true rather than
  /// mapping them onto a fixed struct that would silently drop the rest.
  static ModelSummary _summarize(core.Model model) => ModelSummary(
    id: model.id,
    name: model.name,
    description: model.description,
    capabilities: <String>[
      for (final entry
          in (model.capabilities ?? const <String, dynamic>{}).entries)
        if (entry.value == true) entry.key,
    ]..sort(),
    connection: model.metadata?['direct'] == true
        ? (model.metadata?['directProfileName'] as String?)
        : null,
  );
}
