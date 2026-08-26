import 'dart:async';

import 'package:checks/checks.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/features/terminal/models/terminal_models.dart';
import 'package:conduit/features/terminal/providers/terminal_providers.dart';
import 'package:conduit/features/terminal/services/terminal_service.dart';

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
        terminalServiceProvider.overrideWithValue(null),
        terminalAvailableServersProvider.overrideWith(
          (ref) async => [_server()],
        ),
      ],
    );
    addTearDown(container.dispose);

    await container.read(terminalAvailableServersProvider.future);
    check(container.read(terminalTabVisibleProvider)).isTrue();
  });

  test(
    'live: an empty server list hides the tab (terminal disabled)',
    () async {
      final container = ProviderContainer(
        overrides: [
          terminalServiceProvider.overrideWithValue(null),
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
    },
  );

  test(
    'offline (server list unresolved): falls back to the cached flag — a '
    'known-disabled terminal stays hidden instead of defaulting to visible',
    () {
      final container = ProviderContainer(
        overrides: [
          terminalServiceProvider.overrideWithValue(null),
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
        terminalServiceProvider.overrideWithValue(null),
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

  test(
    'a stale scope probe cannot overwrite the current terminal flag',
    () async {
      var scopeId = 'saved-chat';
      final service = _DelayedTerminalService();
      final container = ProviderContainer(
        overrides: [
          terminalServiceProvider.overrideWithValue(service),
          terminalSessionScopeIdProvider.overrideWith((ref) => scopeId),
          terminalFeatureEnabledProvider.overrideWith(
            () => _FixedTerminalFlag(true),
          ),
        ],
      );
      addTearDown(container.dispose);

      final oldScopeProbe = container.read(
        terminalAvailableServersProvider.future,
      );
      await Future<void>.delayed(Duration.zero);

      scopeId = 'sidebar-terminal';
      container.invalidate(terminalSessionScopeIdProvider);
      final currentScopeProbe = container.read(
        terminalAvailableServersProvider.future,
      );
      await Future<void>.delayed(Duration.zero);

      service.requests[1].complete([_savedChatServer()]);
      await currentScopeProbe;
      await Future<void>.delayed(Duration.zero);
      check(container.read(terminalFeatureEnabledProvider)).isFalse();

      service.requests[0].complete([_savedChatServer()]);
      await oldScopeProbe;
      await Future<void>.delayed(Duration.zero);
      check(container.read(terminalFeatureEnabledProvider)).isFalse();
    },
  );

  test('unresolved scopes use only their own cached flag', () async {
    var scopeId = 'saved-chat';
    final service = _DelayedTerminalService();
    final container = ProviderContainer(
      overrides: [
        terminalServiceProvider.overrideWithValue(service),
        terminalSessionScopeIdProvider.overrideWith((ref) => scopeId),
        terminalFeatureEnabledProvider.overrideWith(
          () => _FixedTerminalFlag(false),
        ),
      ],
    );
    addTearDown(container.dispose);

    final savedChatProbe = container.read(
      terminalAvailableServersProvider.future,
    );
    await Future<void>.delayed(Duration.zero);
    service.requests[0].complete([_savedChatServer()]);
    await savedChatProbe;
    await Future<void>.delayed(Duration.zero);
    check(container.read(terminalTabVisibleProvider)).isTrue();

    scopeId = 'sidebar-terminal';
    container.invalidate(terminalSessionScopeIdProvider);
    final sidebarProbe = container.read(
      terminalAvailableServersProvider.future,
    );
    await Future<void>.delayed(Duration.zero);

    check(container.read(terminalTabVisibleProvider)).isFalse();
    service.requests[1].complete([_savedChatServer()]);
    await sidebarProbe;
    await Future<void>.delayed(Duration.zero);

    scopeId = 'saved-chat';
    container.invalidate(terminalSessionScopeIdProvider);
    container.read(terminalAvailableServersProvider.future);
    await Future<void>.delayed(Duration.zero);

    check(container.read(terminalTabVisibleProvider)).isTrue();
  });
}

TerminalServerInfo _savedChatServer() => TerminalServerInfo(
  kind: TerminalServerKind.system,
  selectionId: 'saved-chat-terminal',
  baseUrl: Uri.parse('https://example.com/saved-chat-terminal'),
  requiresSavedChatContext: true,
);

class _FixedTerminalFlag extends TerminalFeatureEnabledNotifier {
  _FixedTerminalFlag(this._value);

  final bool _value;

  @override
  bool build() => _value;
}

class _MockApiService extends Mock implements ApiService {}

class _DelayedTerminalService extends TerminalService {
  _DelayedTerminalService() : super(_MockApiService());

  final requests = <Completer<List<TerminalServerInfo>>>[];

  @override
  Future<List<TerminalServerInfo>> getAvailableServers() {
    final request = Completer<List<TerminalServerInfo>>();
    requests.add(request);
    return request.future;
  }
}
