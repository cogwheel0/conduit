import 'package:conduit/core/models/model.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/features/tools/providers/tools_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('modelTerminalAutoSelectionProvider', () {
    test('applies a model terminal default on model change', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      container.read(modelTerminalAutoSelectionProvider);

      container
          .read(selectedModelProvider.notifier)
          .set(_model('code-model', terminalId: 'terminal-1'));

      await _flushMicrotasks();

      expect(container.read(selectedTerminalIdProvider), 'terminal-1');

      container.read(selectedTerminalIdProvider.notifier).clear();
      await _flushMicrotasks();

      expect(container.read(selectedTerminalIdProvider), isNull);
    });

    test(
      'preserves manual selection until a new model default overrides it',
      () async {
        final container = ProviderContainer();
        addTearDown(container.dispose);

        container.read(modelTerminalAutoSelectionProvider);
        container
            .read(selectedTerminalIdProvider.notifier)
            .set('manual-terminal');

        container
            .read(selectedModelProvider.notifier)
            .set(_model('chat-model'));
        await _flushMicrotasks();

        expect(container.read(selectedTerminalIdProvider), 'manual-terminal');

        container
            .read(selectedModelProvider.notifier)
            .set(_model('code-model', terminalId: 'model-terminal'));
        await _flushMicrotasks();

        expect(container.read(selectedTerminalIdProvider), 'model-terminal');
      },
    );
  });
}

Future<void> _flushMicrotasks() => Future<void>.delayed(Duration.zero);

Model _model(String id, {String? terminalId}) {
  final meta = <String, dynamic>{};
  if (terminalId != null) {
    meta['terminalId'] = terminalId;
  }

  return Model(
    id: id,
    name: id,
    metadata: {
      'info': {'meta': meta},
    },
  );
}
