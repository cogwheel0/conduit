import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:conduit_core/conduit_core.dart';

/// The Flutter app's [ConnectivityPort].
///
/// Collapses `connectivity_plus`'s list of interface kinds into the single
/// optimistic boolean the core wants. Which kind of interface came up —
/// wifi, cellular, vpn, ethernet — never changed what the core did with the
/// answer, and keeping the enum in the core would drag the plugin along.
class FlutterConnectivityPort implements ConnectivityPort {
  FlutterConnectivityPort([Connectivity? connectivity])
    : _connectivity = connectivity ?? Connectivity();

  final Connectivity _connectivity;

  @override
  Future<bool> hasNetworkInterface() async =>
      _hasAny(await _connectivity.checkConnectivity());

  @override
  Stream<bool> get onChanged =>
      _connectivity.onConnectivityChanged.map(_hasAny);

  static bool _hasAny(List<ConnectivityResult> results) =>
      results.any((result) => result != ConnectivityResult.none);
}
