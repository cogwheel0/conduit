import 'package:conduit_core/models/model.dart';

const int kModelSelectorFallbackCount = 4;

/// Discovery retains legacy bindings for saved conversations; ordinary new
/// choices exclude them. Manual IDs do not carry this discovery-only flag.
bool isOrdinaryModelChoice(Model model) =>
    model.capabilities?['ordinary_model_choice'] != false;

class ModelSelectorLayout {
  const ModelSelectorLayout({required this.featured, required this.more});

  final List<Model> featured;
  final List<Model> more;
}

ModelSelectorLayout buildModelSelectorLayout({
  required Iterable<Model> models,
  required Iterable<String> pinnedModelIds,
  String? defaultModelId,
  String? selectedModelId,
}) {
  final all = List<Model>.unmodifiable(models);
  final byId = <String, Model>{for (final model in all) model.id: model};
  final pins = pinnedModelIds.toList(growable: false);
  final featured = <Model>[];
  final featuredIds = <String>{};

  if (pins.isNotEmpty) {
    for (final id in pins) {
      final model = byId[id];
      if (model != null && featuredIds.add(id)) featured.add(model);
    }
  }
  if (featured.isEmpty) {
    for (final model
        in all.where(isOrdinaryModelChoice).take(kModelSelectorFallbackCount)) {
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
      all.where(
        (model) =>
            (isOrdinaryModelChoice(model) || model.id == defaultModelId) &&
            !featuredIds.contains(model.id),
      ),
    ),
  );
}
