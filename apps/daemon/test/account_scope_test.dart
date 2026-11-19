@TestOn('vm')
library;

import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:conduit_core/providers/app_providers.dart'
    show openWebUiAuthSessionEpochProvider;
import 'package:conduit_core/providers/backend_mode_providers.dart'
    show PrimaryAccountKind;
import 'package:conduit_core/providers/primary_account_providers.dart'
    show PrimaryAccountRef, primaryAccountProvider;
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/src/account_scope.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

/// The account a request began under, and the one check its commit points
/// go through.
void main() {
  late PrimaryAccountRef primary;
  late Object session;
  late ProviderContainer container;

  const ada = PrimaryAccountRef(PrimaryAccountKind.openWebUi, 'server-ada');
  const bo = PrimaryAccountRef(PrimaryAccountKind.libreChat, 'librechat:bo');

  setUp(() async {
    primary = ada;
    session = Object();
    PreferencesStore.debugOverride(InMemoryKeyValueStore());
    addTearDown(PreferencesStore.debugReset);
    await PreferencesStore.put(PreferenceKeys.activeServerId, 'server-ada');
    container = ProviderContainer(
      overrides: [
        primaryAccountProvider.overrideWith((ref) => primary),
        openWebUiAuthSessionEpochProvider.overrideWith((ref) => session),
      ],
    );
    addTearDown(container.dispose);
  });

  /// Another account takes charge (or the same one again).
  void putInCharge(PrimaryAccountRef next) {
    primary = next;
    container.invalidate(primaryAccountProvider);
    container.read(primaryAccountProvider);
  }

  final refused = throwsA(
    isA<RpcError>()
        .having((e) => e.code, 'code', ConduitErrorCodes.sessionExpired)
        .having((e) => e.args['reason'], 'reason', 'account'),
  );

  test('a request stays its account\'s while nobody else takes charge', () {
    final scope = AccountScope.capture(container);
    expect(scope.isCurrent, isTrue);
    scope.require('the note was saved');
    expect(scope.primary, ada);
    expect(scope.preferenceAccount, 'server-ada');

    putInCharge(bo);
    expect(scope.isCurrent, isFalse);
    expect(() => scope.require('the note was saved'), refused);
  });

  test('a change and back is still a change', () {
    final scope = AccountScope.capture(container);
    putInCharge(bo);
    putInCharge(ada);
    expect(container.read(primaryAccountProvider), ada);
    expect(scope.isCurrent, isFalse, reason: 'A, then B, then A again');
  });

  test('another session of the account, or another account\'s settings, is '
      'another account', () async {
    final scope = AccountScope.capture(container);
    session = Object();
    container.invalidate(openWebUiAuthSessionEpochProvider);
    expect(scope.isCurrent, isFalse, reason: 'signed in again');

    final settled = AccountScope.capture(container);
    await PreferencesStore.put(PreferenceKeys.activeServerId, 'server-cy');
    expect(settled.isCurrent, isFalse, reason: 'another account\'s settings');
  });
}
