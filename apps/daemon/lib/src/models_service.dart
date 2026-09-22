import 'dart:async';

import 'package:conduit_core/models/model.dart' as core;
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:riverpod/riverpod.dart';

import 'settled.dart';

/// Implements `models.*` over the core's model providers (M3).
final class ModelsService {
  ModelsService(this._container);

  final ProviderContainer _container;

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
  );
}
