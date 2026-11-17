import 'package:conduit_core/persistence/account_scoped_preferences.dart'
    show currentPreferenceAccountId;
import 'package:conduit_core/providers/app_providers.dart'
    show openWebUiAuthSessionEpochProvider;
import 'package:conduit_core/providers/primary_account_providers.dart'
    show PrimaryAccountRef, primaryAccountProvider;
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:riverpod/riverpod.dart';

/// Counts account changes in this daemon: the account in charge, or the
/// Open WebUI session behind it, changing. A request that waited across a
/// change and back (A, then B, then A again) sees a newer count, though
/// the account in charge reads the same.
final accountSwitchCountProvider = NotifierProvider<AccountSwitchCount, int>(
  AccountSwitchCount.new,
);

final class AccountSwitchCount extends Notifier<int> {
  @override
  int build() {
    void changed(Object? _, Object? _) => state++;
    ref
      ..listen<PrimaryAccountRef>(primaryAccountProvider, changed)
      ..listen<Object>(openWebUiAuthSessionEpochProvider, changed);
    return 0;
  }
}

/// The account a request began under, captured at its entry before its
/// first wait, and the one check every commit point of that request goes
/// through: a write, a switch, a turn started, an answer with data.
///
/// It holds every sign of who is in charge -- the primary account, the Open
/// WebUI session, the account the settings are read for -- and the count of
/// account changes. Any of them moving means another account (or another
/// session of it) is in charge than the one the request was made for.
final class AccountScope {
  AccountScope._(
    this._container, {
    required this.primary,
    required Object? session,
    required this.preferenceAccount,
    required int switches,
  }) : _session = session,
       _switches = switches;

  /// Who is in charge now.
  factory AccountScope.capture(ProviderContainer container) => AccountScope._(
    container,
    primary: _read(() => container.read(primaryAccountProvider)),
    session: _read(() => container.read(openWebUiAuthSessionEpochProvider)),
    preferenceAccount: currentPreferenceAccountId(),
    switches: _read(() => container.read(accountSwitchCountProvider)) ?? 0,
  );

  final ProviderContainer _container;

  /// The account in charge when the request began (null when it could not
  /// be read).
  final PrimaryAccountRef? primary;

  /// The account the request's settings and notes belong to.
  final String? preferenceAccount;

  final Object? _session;
  final int _switches;

  /// Whether the account in charge is still the one the request began
  /// under, with nothing changed in between.
  bool get isCurrent {
    final now = AccountScope.capture(_container);
    return now.primary == primary &&
        identical(now._session, _session) &&
        now.preferenceAccount == preferenceAccount &&
        now._switches == _switches;
  }

  /// Refuses with `auth.sessionExpired`, `reason: account`, once another
  /// account is in charge than the one the request began under. [what]
  /// names the commit point in the log line.
  void require(String what) {
    if (isCurrent) return;
    throw RpcError(
      code: ConduitErrorCodes.sessionExpired,
      args: const <String, String>{'reason': 'account'},
      debugMessage: 'the account changed before $what',
    );
  }

  /// A sign the container cannot give (a test's container without it)
  /// counts as none, the same at capture and at every check.
  static T? _read<T>(T Function() read) {
    try {
      return read();
    } on Object {
      return null;
    }
  }
}
