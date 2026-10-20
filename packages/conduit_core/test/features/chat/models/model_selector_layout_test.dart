import 'package:checks/checks.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/features/chat/models/model_selector_layout.dart';
import 'package:test/test.dart';

void main() {
  test('legacy discovery bindings stay available only for saved choices', () {
    final legacy = Model(
      id: 'legacy',
      name: 'Legacy',
      capabilities: {'ordinary_model_choice': false},
    );
    final current = Model(id: 'flash', name: 'Flash');
    final ordinary = buildModelSelectorLayout(
      models: [legacy, current],
      pinnedModelIds: const [],
    );
    expect(ordinary.featured.map((model) => model.id), ['flash']);
    expect(ordinary.more, isEmpty);
    for (final layout in [
      buildModelSelectorLayout(
        models: [legacy, current],
        pinnedModelIds: const ['legacy'],
      ),
      buildModelSelectorLayout(
        models: [legacy, current],
        pinnedModelIds: const [],
        defaultModelId: 'legacy',
      ),
      buildModelSelectorLayout(
        models: [legacy, current],
        pinnedModelIds: const [],
        selectedModelId: 'legacy',
      ),
    ]) {
      expect(layout.featured.map((model) => model.id), contains('legacy'));
    }
  });
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

    check(layout.featured.map((model) => model.id).toList())
        .deepEquals(['model-5', 'model-2']);
    check(layout.more.map((model) => model.id)).contains('model-6');
  });

  test('falls back to first models and includes a later default', () {
    final layout = buildModelSelectorLayout(
      models: models,
      pinnedModelIds: const [],
      defaultModelId: 'model-6',
    );

    check(layout.featured.map((model) => model.id).toList())
        .deepEquals(['model-0', 'model-1', 'model-2', 'model-3', 'model-6']);
    check(layout.more.map((model) => model.id).toList())
        .deepEquals(['model-4', 'model-5']);
  });

  test('falls back when every pinned model id is stale', () {
    final layout = buildModelSelectorLayout(
      models: models,
      pinnedModelIds: const ['removed-model', 'another-removed-model'],
      defaultModelId: 'model-6',
    );

    check(layout.featured.map((model) => model.id).toList())
        .deepEquals(['model-0', 'model-1', 'model-2', 'model-3', 'model-6']);
    check(layout.more.map((model) => model.id).toList())
        .deepEquals(['model-4', 'model-5']);
  });

  test('promotes a selected model from more into the featured group', () {
    final layout = buildModelSelectorLayout(
      models: models,
      pinnedModelIds: const ['model-5', 'model-2'],
      defaultModelId: 'model-6',
      selectedModelId: 'model-4',
    );

    check(layout.featured.map((model) => model.id).toList())
        .deepEquals(['model-5', 'model-2', 'model-4']);
    check(layout.more.map((model) => model.id).toList())
        .deepEquals(['model-0', 'model-1', 'model-3', 'model-6']);
  });

  test('does not duplicate a selected model that is already featured', () {
    final layout = buildModelSelectorLayout(
      models: models,
      pinnedModelIds: const [],
      defaultModelId: 'model-6',
      selectedModelId: 'model-2',
    );

    check(layout.featured.map((model) => model.id).toList())
        .deepEquals(['model-0', 'model-1', 'model-2', 'model-3', 'model-6']);
  });
}
