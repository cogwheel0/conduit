import 'dart:convert';
import 'dart:io';

import 'package:conduit_core/utils/debug_logger.dart';

/// Certificate authorities the user installed on the device.
///
/// On Android, Dart's own TLS reads only the system store, so a server whose
/// certificate chains to a CA the user installed in Settings is refused even
/// though the browser and the WebView accept it. The host reads those CAs at
/// start-up and hands them over here.
abstract final class UserTrustedCertificates {
  static List<List<int>> _installed = const [];

  /// Trusts [pemCertificates] in [SecurityContext.defaultContext] and in
  /// every server-scoped context built afterwards, and returns how many were
  /// trusted. One that does not parse is skipped.
  static int install(Iterable<String> pemCertificates) {
    final installed = <List<int>>[];
    for (final pem in pemCertificates) {
      final bytes = utf8.encode(pem);
      try {
        SecurityContext.defaultContext.setTrustedCertificatesBytes(bytes);
      } on TlsException catch (error) {
        DebugLogger.warning(
          'user-ca-skipped',
          scope: 'net/tls',
          data: {'error': error.message},
        );
        continue;
      }
      installed.add(bytes);
    }
    _installed = List.unmodifiable(installed);
    return installed.length;
  }

  /// Trusts the installed CAs in [context], which does not inherit them from
  /// the default context.
  static void applyTo(SecurityContext context) {
    for (final bytes in _installed) {
      context.setTrustedCertificatesBytes(bytes);
    }
  }
}
