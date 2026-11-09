import 'dart:async';

import 'package:conduit_core/features/terminal/models/computer_models.dart';
import 'package:conduit_core/features/terminal/services/computer_service.dart';
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

void main() {
  test(
    'the chat header entry disappears while its connection scope refreshes',
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
