import '../models/model.dart';

List<Model> sortModelsWithPinnedOrder(
  List<Model> models,
  List<String> pinnedModelIds,
) {
  if (models.isEmpty || pinnedModelIds.isEmpty) {
    return List<Model>.of(models, growable: false);
  }

  final pinnedOrder = <String, int>{};
  for (final modelId in pinnedModelIds) {
    final trimmed = modelId.trim();
    if (trimmed.isEmpty || pinnedOrder.containsKey(trimmed)) {
      continue;
    }
    pinnedOrder[trimmed] = pinnedOrder.length;
  }

  if (pinnedOrder.isEmpty) {
    return List<Model>.of(models, growable: false);
  }

  final pinned = <Model>[];
  final unpinned = <Model>[];
  for (final model in models) {
    if (pinnedOrder.containsKey(model.id)) {
      pinned.add(model);
    } else {
      unpinned.add(model);
    }
  }

  pinned.sort((a, b) => pinnedOrder[a.id]!.compareTo(pinnedOrder[b.id]!));
  return [...pinned, ...unpinned];
}
