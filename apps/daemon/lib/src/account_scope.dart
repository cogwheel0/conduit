import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart'
    show currentUserProvider2;
import 'package:conduit_core/models/openwebui_registry.dart'
    show openWebUiServerIdentityUrl;
import 'package:conduit_core/persistence/account_scoped_preferences.dart'
    show currentPreferenceAccountId;
import 'package:conduit_core/providers/app_providers.dart'
    show activeServerProvider, openWebUiAuthSessionEpochProvider;
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
    required String? user,
    required String? server,
    required int switches,
  }) : _session = session,
       _user = user,
       _server = server,
       _switches = switches;

  /// Who is in charge now.
  factory AccountScope.capture(ProviderContainer container) => AccountScope._(
    container,
    primary: _read(() => container.read(primaryAccountProvider)),
    session: _read(() => container.read(openWebUiAuthSessionEpochProvider)),
    preferenceAccount: currentPreferenceAccountId(),
    user: _read(() => container.read(currentUserProvider2))?.id,
    server: _serverAddress(container),
    switches: _read(() => container.read(accountSwitchCountProvider)) ?? 0,
  );

  final ProviderContainer _container;

  /// The account in charge when the request began (null when it could not
  /// be read).
  final PrimaryAccountRef? primary;

  /// The account the request's settings and notes belong to.
  final String? preferenceAccount;

  final Object? _session;
  final String? _user;

  /// The address of the server in charge, in its comparable form
  /// ([openWebUiServerIdentityUrl]); null when none could be read.
  final String? _server;
  final int _switches;

  /// Who the account is, apart from its session: the server's address (in
  /// its comparable form), the primary account, the account its settings
  /// belong to, and the signed-in user. A renewed token or a rebuilt client
  /// of that account keeps it; another user, or another server, does not --
  /// a saved server whose address changed in place included (it keeps its
  /// id but may reach another server, with the same user id there).
  Object get identity => (_server, primary, preferenceAccount, _user);

  /// Whether the account in charge now is the same account as the one the
  /// request began under, however often its session was renewed since.
  /// For work that belongs to the account rather than to one session of it
  /// (a server mirror of a change it already made); every commit point of
  /// a request still goes through [require]. Begun while no user was known,
  /// nothing but the same session proves it is the same account
  /// ([isCurrent]).
  bool get isSameAccount {
    if (_user == null) return isCurrent;
    return AccountScope.capture(_container).identity == identity;
  }

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

  /// The server address, read only from a server state already kept: a
  /// capture never starts one (a container without the app's storage could
  /// not build it).
  static String? _serverAddress(ProviderContainer container) {
    if (!container.read(activeServerProvider.exists)) return null;
    final url = _read(() => container.read(activeServerProvider))?.value?.url;
    return url == null ? null : openWebUiServerIdentityUrl(url);
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
