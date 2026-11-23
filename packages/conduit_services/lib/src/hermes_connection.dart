import 'dart:math';

import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:riverpod/riverpod.dart';

/// Names the Hermes connection in use, for requests and answers bound to
/// it (`HermesChanged.connection`).
///
/// The name changes whenever the core's Hermes service does (another
/// address, other credentials, Hermes turned off), and carries this
/// daemon run's own prefix, so a name never comes back after a restart.
/// A window sends the name it opened something under; [require] refuses it
/// once the connection changed, so nothing asked of one connection is done
/// on the next.
final class HermesConnectionKey {
  HermesConnectionKey(this._container) {
    _last = _container.read(hermesApiServiceProvider);
    _watch = _container.listen<Object?>(hermesApiServiceProvider, (_, _) {
      _sync();
    });
  }

  final ProviderContainer _container;
  late final ProviderSubscription<Object?> _watch;
  Object? _last;
  int _number = 1;

  static final String _run = () {
    final random = Random.secure();
    return List<String>.generate(
      4,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }();

  /// The connection in use now.
  String get current {
    _sync();
    return '$_run:$_number';
  }

  /// Read as it is now, not as the last listener heard it: a change the
  /// provider has not announced yet is still a change.
  void _sync() {
    final service = _container.read(hermesApiServiceProvider);
    if (identical(service, _last)) return;
    _last = service;
    _number++;
  }

  /// Refuses [asked] when it names a connection other than the one in use.
  /// A request without one (an older window) is not checked.
  void require(String? asked) {
    if (asked == null) return;
    final now = current;
    if (asked != now) throw stale(asked, now);
  }

  /// Refuses work begun under [began] once the connection is another one:
  /// called after each wait, before anything is changed or kept.
  void stillCurrent(String began) {
    final now = current;
    if (began != now) throw stale(began, now);
  }

  static RpcError stale(String asked, String now) => RpcError(
    code: ConduitErrorCodes.sessionExpired,
    args: <String, String>{'connection': asked},
    debugMessage:
        'the Hermes connection changed (asked under $asked, now $now)',
  );

  void dispose() => _watch.close();
}
