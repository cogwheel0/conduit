@TestOn('vm')
library;

import 'package:conduit_core/providers/app_providers.dart'
    show apiServiceProvider, openWebUiAuthSessionEpochProvider;
import 'package:conduit_core/providers/backend_mode_providers.dart'
    show PrimaryAccountKind;
import 'package:conduit_core/providers/primary_account_providers.dart'
    show PrimaryAccountRef, primaryAccountProvider;
import 'package:conduitd/conduitd.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

/// A chat belongs to the account it was opened under, whichever backend
/// that account is on.
void main() {
  test('another LibreChat account takes the last one\'s chats with it', () async {
    var primary = const PrimaryAccountRef(
      PrimaryAccountKind.libreChat,
      'librechat-a',
    );
    // Open WebUI's session stays as it was: only the LibreChat account in
    // charge changes.
    final epoch = Object();
    final container = ProviderContainer(
      overrides: [
        primaryAccountProvider.overrideWith((ref) => primary),
        openWebUiAuthSessionEpochProvider.overrideWith((ref) => epoch),
        apiServiceProvider.overrideWith((ref) => null),
      ],
    );
    addTearDown(container.dispose);
    final turns = TurnsService(container, EventBus());
    addTearDown(turns.dispose);
    turns.temporary.start('local:sketch-ideas');
    expect(turns.temporary.contains('local:sketch-ideas'), isTrue);

    primary = const PrimaryAccountRef(
      PrimaryAccountKind.libreChat,
      'librechat-b',
    );
    container.invalidate(primaryAccountProvider);
    container.read(primaryAccountProvider);

    expect(turns.temporary.contains('local:sketch-ideas'), isFalse);
  });
}
