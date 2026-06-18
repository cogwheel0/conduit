import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/features/terminal/models/terminal_models.dart';
import 'package:conduit/features/terminal/providers/terminal_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

TerminalServerInfo _server() => TerminalServerInfo(
  kind: TerminalServerKind.direct,
  selectionId: 's1',
  baseUrl: Uri.parse('https://example.com/term'),
  name: 'srv',
);

void main() {
  test('live: a non-empty server list shows the tab', () async {
    final container = ProviderContainer(
      overrides: [
        terminalAvailableServersProvider.overrideWith(
          (ref) async => [_server()],
        ),
      ],
    );
    addTearDown(container.dispose);

    await container.read(terminalAvailableServersProvider.future);
    check(container.read(terminalTabVisibleProvider)).isTrue();
  });

  test('live: an empty server list hides the tab (terminal disabled)', () async {
    final container = ProviderContainer(
      overrides: [
        terminalAvailableServersProvider.overrideWith(
          (ref) async => const <TerminalServerInfo>[],
        ),
      ],
    );
    addTearDown(container.dispose);

    await container.read(terminalAvailableServersProvider.future);
    // Let the deferred cache write-back microtask run while alive.
    await Future<void>.delayed(Duration.zero);
    check(container.read(terminalTabVisibleProvider)).isFalse();
  });

  test(
    'offline (server list unresolved): falls back to the cached flag — a '
    'known-disabled terminal stays hidden instead of defaulting to visible',
    () {
      final container = ProviderContainer(
        overrides: [
          // Last-known state: terminal disabled.
          terminalFeatureEnabledProvider.overrideWith(
            () => _FixedTerminalFlag(false),
          ),
          // Offline: the server list never resolves (stays loading).
          terminalAvailableServersProvider.overrideWith(
            (ref) => Completer<List<TerminalServerInfo>>().future,
          ),
        ],
      );
      addTearDown(container.dispose);

      check(container.read(terminalTabVisibleProvider)).isFalse();
    },
  );

  test('offline with a known-enabled cache shows the tab', () {
    final container = ProviderContainer(
      overrides: [
        terminalFeatureEnabledProvider.overrideWith(
          () => _FixedTerminalFlag(true),
        ),
        terminalAvailableServersProvider.overrideWith(
          (ref) => Completer<List<TerminalServerInfo>>().future,
        ),
      ],
    );
    addTearDown(container.dispose);

    check(container.read(terminalTabVisibleProvider)).isTrue();
  });
}

class _FixedTerminalFlag extends TerminalFeatureEnabledNotifier {
  _FixedTerminalFlag(this._value);

  final bool _value;

  @override
  bool build() => _value;
}
