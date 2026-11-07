import 'package:conduit_core/features/terminal/models/terminal_models.dart';
import 'package:conduit_core/features/terminal/providers/computer_providers.dart';
import 'package:conduit_core/features/terminal/providers/terminal_providers.dart';
import 'package:conduit_core/features/terminal/services/terminal_service.dart';
import 'package:conduit_core/features/tools/providers/tools_providers.dart';
import 'package:mocktail/mocktail.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

class _Terminal extends Mock implements TerminalService {}

void main() {
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
