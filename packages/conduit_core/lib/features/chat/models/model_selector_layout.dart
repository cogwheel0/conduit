import 'package:conduit_core/models/model.dart';

const int kModelSelectorFallbackCount = 4;

class ModelSelectorLayout {
  const ModelSelectorLayout({
    required this.featured,
    required this.more,
    this.sections = const <ModelSelectorSection>[],
  });

  final List<Model> featured;

  /// The models past [featured] that belong to no section.
  final List<Model> more;

  /// The models past [featured] that belong to a section, by section.
  final List<ModelSelectorSection> sections;
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

/// Where a model sits in the picker's grouped list: the section's [label],
/// and the [order] sections sort by.
typedef ModelSelectorSectionKey = ({String label, int order});

/// A titled group of models past the featured ones.
class ModelSelectorSection {
  const ModelSelectorSection({required this.label, required this.models});

  final String label;
  final List<Model> models;
}

/// [sectionOf] groups the models past the featured ones; a model it gives
/// no section stays in [ModelSelectorLayout.more]. Sections sort by order,
/// then by where their first model was.
///
/// [fillsFallback] says which models may fill the first slots when nothing
/// is pinned; a model it refuses is featured only when pinned or selected.
ModelSelectorLayout buildModelSelectorLayout({
  required Iterable<Model> models,
  required Iterable<String> pinnedModelIds,
  String? defaultModelId,
  String? selectedModelId,
  ModelSelectorSectionKey? Function(Model model)? sectionOf,
  bool Function(Model model)? fillsFallback,
}) {
  final all = List<Model>.unmodifiable(models);
  final byId = <String, Model>{for (final model in all) model.id: model};
  final featured = availablePinnedModels(
    models: all,
    pinnedModelIds: pinnedModelIds,
  ).toList();
  final featuredIds = <String>{for (final model in featured) model.id};

  if (featured.isEmpty) {
    final candidates = fillsFallback == null ? all : all.where(fillsFallback);
    for (final model in candidates.take(kModelSelectorFallbackCount)) {
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

  final more = <Model>[];
  final grouped = <String, ({int order, List<Model> models})>{};
  for (final model in all) {
    if (featuredIds.contains(model.id)) continue;
    final section = sectionOf?.call(model);
    if (section == null) {
      more.add(model);
      continue;
    }
    grouped
        .putIfAbsent(
          section.label,
          () => (order: section.order, models: <Model>[]),
        )
        .models
        .add(model);
  }
  final firstSeen = <String, int>{
    for (final (index, label) in grouped.keys.indexed) label: index,
  };
  final sorted = grouped.keys.toList()
    ..sort((a, b) {
      final byOrder = grouped[a]!.order.compareTo(grouped[b]!.order);
      return byOrder != 0
          ? byOrder
          : firstSeen[a]!.compareTo(firstSeen[b]!);
    });

  return ModelSelectorLayout(
    featured: List.unmodifiable(featured),
    more: List.unmodifiable(more),
    sections: List.unmodifiable([
      for (final label in sorted)
        ModelSelectorSection(
          label: label,
          models: List.unmodifiable(grouped[label]!.models),
        ),
    ]),
  );
}
