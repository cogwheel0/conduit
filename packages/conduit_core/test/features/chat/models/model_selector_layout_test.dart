import 'package:checks/checks.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/features/chat/models/model_selector_layout.dart';
import 'package:test/test.dart';

void main() {
  final models = List<Model>.generate(
    7,
    (index) => Model(id: 'model-$index', name: 'Model $index'),
  );

  test('available pins keep pin order, once each, without stale ones', () {
    final pinned = availablePinnedModels(
      models: models,
      pinnedModelIds: const ['model-5', 'removed-model', 'model-2', 'model-5'],
    );

    check(pinned.map((model) => model.id).toList())
        .deepEquals(['model-5', 'model-2']);
  });

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

  test('groups the models past the featured ones into sorted sections', () {
    const sections = <String, ModelSelectorSectionKey>{
      'model-4': (label: 'Ollama', order: 3),
      'model-5': (label: 'Agents', order: 1),
      'model-6': (label: 'OpenAI', order: 3),
      'model-1': (label: 'Agents', order: 1),
    };
    final layout = buildModelSelectorLayout(
      models: [
        ...models,
        const Model(id: 'model-7', name: 'Model 7'),
      ],
      pinnedModelIds: const [],
      sectionOf: (model) => sections[model.id],
    );

    // A featured model stays featured, whatever its section.
    check(layout.featured.map((model) => model.id).toList())
        .deepEquals(['model-0', 'model-1', 'model-2', 'model-3']);
    check(layout.more.map((model) => model.id).toList())
        .deepEquals(['model-7']);
    check(layout.sections.map((section) => section.label).toList())
        .deepEquals(['Agents', 'Ollama', 'OpenAI']);
    check(layout.sections.map((section) => section.models.single.id).toList())
        .deepEquals(['model-5', 'model-4', 'model-6']);
  });

  test('keeps everything past the featured models in more without '
      'sections', () {
    final layout = buildModelSelectorLayout(
      models: models,
      pinnedModelIds: const ['model-0'],
    );

    check(layout.sections).isEmpty();
    check(layout.more).length.equals(6);
  });

  test('a model kept out of the fallback leads only when pinned or '
      'selected', () {
    // A short account list with two coding agents after it: the agents stay
    // under their heading unless the user picked or pinned one.
    final listed = [
      const Model(id: 'model-0', name: 'Model 0'),
      const Model(id: 'agent:t:codex:a', name: 'Codex · a'),
      const Model(id: 'agent:t:pi:b', name: 'Pi · b'),
    ];
    ({String label, int order})? agents(Model model) =>
        model.id.startsWith('agent:') ? (label: 'Agents', order: 9) : null;
    bool notAgent(Model model) => !model.id.startsWith('agent:');

    final plain = buildModelSelectorLayout(
      models: listed,
      pinnedModelIds: const [],
      sectionOf: agents,
      fillsFallback: notAgent,
    );
    check(plain.featured.map((m) => m.id).toList()).deepEquals(['model-0']);
    check(plain.sections.single.models.map((m) => m.id).toList())
        .deepEquals(['agent:t:codex:a', 'agent:t:pi:b']);

    final picked = buildModelSelectorLayout(
      models: listed,
      pinnedModelIds: const [],
      selectedModelId: 'agent:t:pi:b',
      sectionOf: agents,
      fillsFallback: notAgent,
    );
    check(picked.featured.map((m) => m.id).toList())
        .deepEquals(['model-0', 'agent:t:pi:b']);
  });
}
