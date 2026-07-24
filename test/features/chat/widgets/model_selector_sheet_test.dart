import 'package:checks/checks.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conduit/core/models/model.dart';
import 'package:conduit/core/utils/model_sort_utils.dart';
import 'package:conduit/features/chat/widgets/model_selector_sheet.dart';
import 'package:conduit/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit/features/direct_connections/models/direct_remote_model.dart';
import 'package:conduit/features/direct_connections/services/direct_model_registry.dart';

void main() {
  group('sortModelsWithPinnedOrder', () {
    const models = [
      Model(id: 'alpha', name: 'Alpha'),
      Model(id: 'bravo', name: 'Bravo'),
      Model(id: 'charlie', name: 'Charlie'),
      Model(id: 'delta', name: 'Delta'),
    ];

    test('moves pinned models to the top in pinned order', () {
      final sorted = sortModelsWithPinnedOrder(models, ['charlie', 'alpha']);

      check(
        sorted.map((model) => model.id).toList(),
      ).deepEquals(['charlie', 'alpha', 'bravo', 'delta']);
    });

    test('ignores stale pinned ids and keeps unpinned order stable', () {
      final sorted = sortModelsWithPinnedOrder(models, ['missing', 'delta']);

      check(
        sorted.map((model) => model.id).toList(),
      ).deepEquals(['delta', 'alpha', 'bravo', 'charlie']);
    });

    test('deduplicates pinned ids using the first pinned position', () {
      final sorted = sortModelsWithPinnedOrder(models, [
        'bravo',
        'charlie',
        ' bravo ',
      ]);

      check(
        sorted.map((model) => model.id).toList(),
      ).deepEquals(['bravo', 'charlie', 'alpha', 'delta']);
    });
  });

  test('model selector search matches a displayed Direct source label', () {
    final profile = DirectConnectionProfile(
      id: 'home',
      name: 'Home Ollama',
      adapterKey: 'ollama',
      baseUrl: 'http://localhost:11434',
    );
    final model = DirectModelRegistry().replaceProfileModels(profile, [
      DirectRemoteModel(id: 'shared-name'),
    ]).single;

    check(modelSelectorQueryMatches(model, 'home ollama')).isTrue();
  });
}
