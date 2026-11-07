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
ModelSelectorLayout buildModelSelectorLayout({
  required Iterable<Model> models,
  required Iterable<String> pinnedModelIds,
  String? defaultModelId,
  String? selectedModelId,
  ModelSelectorSectionKey? Function(Model model)? sectionOf,
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
  final labels = grouped.keys.toList();
  final sorted = [...labels]
    ..sort((a, b) {
      final byOrder = grouped[a]!.order.compareTo(grouped[b]!.order);
      return byOrder != 0
          ? byOrder
          : labels.indexOf(a).compareTo(labels.indexOf(b));
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
