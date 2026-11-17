@TestOn('vm')
library;

import 'dart:async';

import 'package:conduit_core/models/backend_config.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduitd/src/server_rules.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

/// [readServerRule]: a server feature's rule once its sources settled.
void main() {
  test('a permissions read that fails while the config is read is a '
      'refusal, never an unhandled error', () async {
    final uncaught = <Object>[];
    final answered = Completer<bool>();
    // Run in a zone of its own, as the daemon runs its requests: an error
    // nobody handles lands in [uncaught].
    runZonedGuarded(() async {
      final config = _HeldConfig();
      // The account's permissions, answered when the test says.
      final permissions = Completer<Map<String, dynamic>>()..future.ignore();
      final container = ProviderContainer(
        retry: (_, _) => null,
        overrides: [
          backendConfigProvider.overrideWith(() => config),
          userPermissionsProvider.overrideWith((ref) => permissions.future),
        ],
      );
      final reading = readServerRule(
        container,
        () => true,
        stale: (_) => false,
      );
      // The permissions read fails while the config read still waits.
      await config.asked.future;
      permissions.completeError(StateError('permissions refused'));
      await pumpEventQueue();
      config.held.complete();
      final answer = await reading;
      container.dispose();
      answered.complete(answer);
    }, (error, _) => uncaught.add(error));
    expect(await answered.future, isTrue);
    expect(uncaught, isEmpty);
  });
}

/// The server's config, read only once [held] completes.
final class _HeldConfig extends BackendConfigNotifier {
  final asked = Completer<void>();
  final held = Completer<void>();

  @override
  Future<BackendConfig?> build() async {
    if (!asked.isCompleted) asked.complete();
    await held.future;
    return const BackendConfig();
  }
}
