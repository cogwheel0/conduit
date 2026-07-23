import 'package:checks/checks.dart';
import 'package:conduit/core/models/model.dart';
import 'package:conduit/features/chat/models/model_selector_layout.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final models = List<Model>.generate(
    7,
    (index) => Model(id: 'model-$index', name: 'Model $index'),
  );

  test('shows only pinned models in the featured group when pins exist', () {
    final layout = buildModelSelectorLayout(
      models: models,
      pinnedModelIds: const ['model-5', 'model-2'],
      defaultModelId: 'model-6',
    );

    check(
      layout.featured.map((model) => model.id).toList(),
    ).deepEquals(['model-5', 'model-2']);
    check(layout.more.map((model) => model.id)).contains('model-6');
  });

  test('falls back to first models and includes a later default', () {
    final layout = buildModelSelectorLayout(
      models: models,
      pinnedModelIds: const [],
      defaultModelId: 'model-6',
    );

    check(
      layout.featured.map((model) => model.id).toList(),
    ).deepEquals(['model-0', 'model-1', 'model-2', 'model-3', 'model-6']);
    check(
      layout.more.map((model) => model.id).toList(),
    ).deepEquals(['model-4', 'model-5']);
  });
}
