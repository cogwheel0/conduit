import '../../../core/models/model.dart';

const int kModelSelectorFallbackCount = 4;

class ModelSelectorLayout {
  const ModelSelectorLayout({required this.featured, required this.more});

  final List<Model> featured;
  final List<Model> more;
}

ModelSelectorLayout buildModelSelectorLayout({
  required Iterable<Model> models,
  required Iterable<String> pinnedModelIds,
  String? defaultModelId,
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
  } else {
    for (final model in all.take(kModelSelectorFallbackCount)) {
      if (featuredIds.add(model.id)) featured.add(model);
    }
    final defaultModel = byId[defaultModelId];
    if (defaultModel != null && featuredIds.add(defaultModel.id)) {
      featured.add(defaultModel);
    }
  }

  return ModelSelectorLayout(
    featured: List.unmodifiable(featured),
    more: List.unmodifiable(
      all.where((model) => !featuredIds.contains(model.id)),
    ),
  );
}
