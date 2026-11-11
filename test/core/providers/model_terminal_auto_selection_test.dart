import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/chat_picks_session.dart';
import 'package:conduit_core/features/tools/providers/tools_providers.dart';
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
      'a terminal the user chose stays through a switch of model, as on '
      'Open WebUI 0.12.5',
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

        expect(container.read(selectedTerminalIdProvider), 'manual-terminal');
      },
    );

    test('a new chat on the same model starts from its default terminal',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      container.read(modelTerminalAutoSelectionProvider);
      container
          .read(selectedModelProvider.notifier)
          .set(_model('code-model', terminalId: 'model-terminal'));
      await _flushMicrotasks();
      container.read(selectedTerminalIdProvider.notifier).set('other');
      await _flushMicrotasks();

      // The next chat keeps the same model, which emits nothing.
      container.read(chatPicksSessionProvider.notifier).newConversation();
      await _flushMicrotasks();

      expect(container.read(selectedTerminalIdProvider), 'model-terminal');
    });

    test('a model\'s default terminal goes with it on a switch to a model '
        'with none', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      container.read(modelTerminalAutoSelectionProvider);
      container
          .read(selectedModelProvider.notifier)
          .set(_model('code-model', terminalId: 'model-terminal'));
      await _flushMicrotasks();
      expect(container.read(selectedTerminalIdProvider), 'model-terminal');

      container.read(selectedModelProvider.notifier).set(_model('chat-model'));
      await _flushMicrotasks();

      expect(container.read(selectedTerminalIdProvider), isNull);
    });

    test('a coding agent selects its own terminal, which then stays like the '
        'user\'s pick', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      container.read(modelTerminalAutoSelectionProvider);
      container.read(selectedTerminalIdProvider.notifier).set('other');
      container
          .read(selectedModelProvider.notifier)
          .set(_model('agent:build%20box:codex:gpt-5.1'));
      await _flushMicrotasks();
      expect(container.read(selectedTerminalIdProvider), 'build box');

      container.read(selectedModelProvider.notifier).set(_model('chat-model'));
      await _flushMicrotasks();
      expect(container.read(selectedTerminalIdProvider), 'build box');
    });
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
