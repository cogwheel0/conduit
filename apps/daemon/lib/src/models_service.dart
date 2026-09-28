import 'dart:async';

import 'package:conduit_core/models/model.dart' as core;
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:riverpod/riverpod.dart';

import 'event_bus.dart';
import 'settled.dart';

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
      events.publish(ConduitEvents.modelsChanged);
    });
  }

  static bool _sameIds(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Future<ModelList> list() async {
    final models = await readSettled(_container, modelsProvider.future);
    return ModelList(
      models: models.map(_summarize).toList(growable: false),
      // The account's current selection, not the first in the list: the
      // composer shows this, and showing a model the next turn would not
      // actually use is worse than showing none.
      selectedId: _container.read(selectedModelProvider)?.id,
    );
  }

  Future<ModelList> select(String id) async {
    final models = await readSettled(_container, modelsProvider.future);
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
