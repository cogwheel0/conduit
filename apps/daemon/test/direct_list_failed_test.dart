@TestOn('vm')
library;

import 'dart:async';

import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/features/direct_connections/models/openwebui_direct_connection.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduitd/conduitd.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

/// `direct.list`'s word on the Open WebUI account's connections.
void main() {
  test("a failed read of the account's connections is reported with the "
      'list it was read for', () async {
    final account = _AccountConnections()..failing = true;
    // Whether Direct can carry the app: held, so two lists overlap.
    final usable = Completer<List<DirectConnectionProfile>>();
    final container = ProviderContainer(
      retry: (_, _) => null,
      overrides: [
        apiServiceProvider.overrideWith((ref) => null),
        directConnectionProfilesProvider.overrideWith(_NoProfiles.new),
        openWebUiDirectConnectionsAvailableProvider.overrideWithValue(true),
        openWebUiDirectConnectionsProvider.overrideWith(() => account),
        effectiveDirectConnectionProfilesFutureProvider.overrideWith(
          (ref) => usable.future,
        ),
      ],
    );
    addTearDown(container.dispose);
    final direct = DirectService(container);

    final failed = direct.list();
    await account.read.future;
    // Read again (another window, another account) and read fine.
    account
      ..failing = false
      ..read = Completer<void>();
    container.invalidate(openWebUiDirectConnectionsProvider);
    final fine = direct.list();
    await account.read.future;
    usable.complete(const <DirectConnectionProfile>[]);

    expect((await failed).openWebUiLoadFailed, isTrue);
    expect((await fine).openWebUiLoadFailed, isFalse);
  });
}

final class _NoProfiles extends DirectConnectionProfilesController {
  @override
  Future<List<DirectConnectionProfile>> build() async =>
      const <DirectConnectionProfile>[];
}

/// The account's connections: a read fails while [failing]; [read]
/// completes once one was answered.
final class _AccountConnections extends OpenWebUiDirectConnectionsController {
  bool failing = false;
  Completer<void> read = Completer<void>();

  @override
  Future<OpenWebUiDirectConnectionsSnapshot?> build() async {
    final answered = read;
    scheduleMicrotask(() {
      if (!answered.isCompleted) answered.complete();
    });
    if (failing) throw StateError('the account settings could not be read');
    return null;
  }
}
