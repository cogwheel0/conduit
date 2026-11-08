import 'dart:async';

import 'package:conduit_core/features/terminal/models/computer_models.dart';
import 'package:conduit_core/features/terminal/services/computer_service.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/features/terminal/models/terminal_models.dart';
import 'package:conduit_core/features/terminal/providers/computer_providers.dart';
import 'package:conduit_core/features/terminal/providers/terminal_providers.dart';
import 'package:conduit_core/features/terminal/services/terminal_service.dart';
import 'package:conduit_core/features/tools/providers/tools_providers.dart';
import 'package:mocktail/mocktail.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

class _Terminal extends Mock implements TerminalService {}

class _Computer extends Mock implements ComputerService {}

class _Messages extends ChatMessagesNotifier {
  @override
  List<ChatMessage> build() => [];
  void replace(List<ChatMessage> messages) => state = messages;
}

void main() {
  test(
    'manual entry disappears while its connection scope refreshes',
    () async {
      Completer<ComputerService?>? pending;
      final service = _Computer();
      final container = ProviderContainer.test(
        overrides: [
          computerEnabledProvider.overrideWithValue(true),
          computerServiceProvider.overrideWith(
            (ref) async => pending == null ? service : pending.future,
          ),
          computerCapabilitiesProvider.overrideWith(
            (ref) async => const ComputerCapabilities(desktop: true),
          ),
        ],
      );
      container.listen(computerAvailableProvider, (_, _) {});
      expect(container.read(computerAvailableProvider), isFalse);
      await container.read(computerServiceProvider.future);
      await container.read(computerCapabilitiesProvider.future);
      expect(container.read(computerAvailableProvider), isTrue);
      pending = Completer<ComputerService?>();
      container.invalidate(computerServiceProvider);
      expect(container.read(computerAvailableProvider), isFalse);
      pending.complete(null);
      await container.read(computerServiceProvider.future);
      expect(container.read(computerAvailableProvider), isFalse);
    },
  );

  test('activity follows this chat and disabling clears an explicit open', () {
    var enabled = true;
    var scope = 'chat-one';
    final container = ProviderContainer.test(
      overrides: [
        computerEnabledProvider.overrideWith((ref) => enabled),
        terminalSessionScopeIdProvider.overrideWith((ref) => scope),
        terminalServiceProvider.overrideWith((ref) => _Terminal()),
        chatMessagesProvider.overrideWith(_Messages.new),
      ],
    );
    container.listen(computerActiveProvider, (_, _) {});
    final messages = container.read(chatMessagesProvider.notifier) as _Messages;
    final computerTurn = ChatMessage(
      id: 'tool-turn',
      role: 'assistant',
      content: '',
      timestamp: DateTime.utc(2026),
      output: [
        {'type': 'function_call', 'name': 'desktop_action'},
      ],
    );
    expect(container.read(computerActiveProvider), isFalse);
    messages.replace([computerTurn]);
    expect(container.read(computerActiveProvider), isTrue);
    messages.replace([
      computerTurn,
      ChatMessage(
        id: 'next-turn',
        role: 'assistant',
        content: 'A fresh reply.',
        timestamp: DateTime.utc(2026),
      ),
    ]);
    expect(container.read(computerActiveProvider), isFalse);
    container.read(computerOpenedProvider.notifier).open();
    expect(container.read(computerActiveProvider), isTrue);
    scope = 'chat-two';
    container.invalidate(terminalSessionScopeIdProvider);
    expect(container.read(computerActiveProvider), isFalse);
    container.read(computerOpenedProvider.notifier).open();
    container.read(selectedTerminalIdProvider.notifier).set('another-terminal');
    expect(container.read(computerActiveProvider), isFalse);
    container.read(computerOpenedProvider.notifier).open();
    container.invalidate(terminalServiceProvider);
    expect(container.read(computerActiveProvider), isFalse);
    container.read(computerOpenedProvider.notifier).open();
    enabled = false;
    container.invalidate(computerEnabledProvider);
    expect(container.read(computerActiveProvider), isFalse);
    expect(container.read(computerAvailableProvider), isFalse);
    enabled = true;
    container.invalidate(computerEnabledProvider);
    expect(container.read(computerActiveProvider), isFalse);
  });

  test('disabled Computer never discovers a terminal', () async {
    var probes = 0;
    final container = ProviderContainer.test(
      overrides: [
        computerEnabledProvider.overrideWithValue(false),
        terminalSelectedServerProvider.overrideWith((ref) async {
          probes++;
          throw StateError('Disabled Computer must not probe');
        }),
      ],
    );
    expect(await container.read(computerServiceProvider.future), isNull);
    expect(probes, 0);
  });

  for (final scenario in [
    (scope: 'sidebar-terminal', selected: 'terminal', probes: 0),
    (scope: 'saved-chat', selected: null, probes: 0),
    (scope: 'saved-chat', selected: 'terminal', probes: 1),
  ]) {
    test(
      'Computer discovery requires a saved chat and selected terminal: $scenario',
      () async {
        var probes = 0;
        final container = ProviderContainer.test(
          overrides: [
            computerEnabledProvider.overrideWithValue(true),
            terminalSessionScopeIdProvider.overrideWithValue(scenario.scope),
            terminalServiceProvider.overrideWithValue(_Terminal()),
            terminalSelectedServerProvider.overrideWith((ref) async {
              probes++;
              return TerminalServerInfo(
                kind: TerminalServerKind.direct,
                selectionId: 'terminal',
                baseUrl: Uri.parse('https://terminal.example'),
              );
            }),
          ],
        );
        container
            .read(selectedTerminalIdProvider.notifier)
            .set(scenario.selected);
        final service = await container.read(computerServiceProvider.future);
        expect(probes, scenario.probes);
        expect(service?.scope, scenario.probes == 0 ? null : scenario.scope);
      },
    );
  }
}
