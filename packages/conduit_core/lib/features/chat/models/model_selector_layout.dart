import 'package:conduit_core/models/model.dart';

const int kModelSelectorFallbackCount = 4;

class ModelSelectorLayout {
  const ModelSelectorLayout({required this.featured, required this.more});

  final List<Model> featured;
  final List<Model> more;
}

/// The pinned models that are in [models], in pin order and each once. A pin
/// whose model is no longer offered is left out.
List<Model> availablePinnedModels({
  required Iterable<Model> models,
  required Iterable<String> pinnedModelIds,
}) {
  final byId = <String, Model>{for (final model in models) model.id: model};
  final seen = <String>{};
  return List.unmodifiable([
    for (final id in pinnedModelIds)
      if (byId[id] case final model? when seen.add(id)) model,
  ]);
}

ModelSelectorLayout buildModelSelectorLayout({
  required Iterable<Model> models,
  required Iterable<String> pinnedModelIds,
  String? defaultModelId,
  String? selectedModelId,
}) {
  final all = List<Model>.unmodifiable(models);
  final byId = <String, Model>{for (final model in all) model.id: model};
  final featured = availablePinnedModels(
    models: all,
    pinnedModelIds: pinnedModelIds,
  ).toList();
  final featuredIds = <String>{for (final model in featured) model.id};

  if (featured.isEmpty) {
    for (final model in all.take(kModelSelectorFallbackCount)) {
      if (featuredIds.add(model.id)) featured.add(model);
    }
    final defaultModel = byId[defaultModelId];
    if (defaultModel != null && featuredIds.add(defaultModel.id)) {
      featured.add(defaultModel);
    }
  }
  final selectedModel = byId[selectedModelId];
  if (selectedModel != null && featuredIds.add(selectedModel.id)) {
    featured.add(selectedModel);
  }

  return ModelSelectorLayout(
    featured: List.unmodifiable(featured),
    more: List.unmodifiable(
      all.where((model) => !featuredIds.contains(model.id)),
    ),
  );
}
