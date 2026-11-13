import 'dart:ui' show Locale;

import 'package:checks/checks.dart';
import 'package:conduit/features/auth/services/server_address_wording.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit_core/auth/openwebui_server_address.dart';
import 'package:flutter_test/flutter_test.dart';

/// The words the app shows for each of core's server address problems: the
/// strings the address editors showed before the problems moved to core.
void main() {
  // What each problem read as when the editors worded it themselves.
  final before = <ServerAddressProblem, String Function(AppLocalizations)>{
    ServerAddressProblem.addressEmpty: (l) => l.serverUrlEmpty,
    ServerAddressProblem.invalidAddress: (l) => l.invalidUrlFormat,
    ServerAddressProblem.unsupportedScheme: (l) => l.onlyHttpHttps,
    ServerAddressProblem.missingHost: (l) => l.serverAddressRequired,
    ServerAddressProblem.portOutOfRange: (l) => l.portRange,
    ServerAddressProblem.invalidIpAddress: (l) => l.invalidIpFormat,
    ServerAddressProblem.headerFieldMissing: (l) => l.authFieldRequired,
    ServerAddressProblem.headerNameTooLong: (l) => l.headerNameTooLong,
    ServerAddressProblem.headerNameInvalidCharacters: (l) =>
        l.headerNameInvalidChars,
    ServerAddressProblem.headerNameReserved: (l) =>
        l.headerNameReserved('X-Gate'),
    ServerAddressProblem.headerValueTooLong: (l) => l.headerValueTooLong,
    ServerAddressProblem.headerValueInvalidCharacters: (l) =>
        l.headerValueInvalidChars,
    ServerAddressProblem.headerValueUnsafe: (l) => l.headerValueUnsafe,
    ServerAddressProblem.headerAlreadyAdded: (l) =>
        l.headerAlreadyExists('X-Gate'),
    ServerAddressProblem.tooManyHeaders: (l) => l.maxHeadersReachedDetail,
    ServerAddressProblem.mutualTlsIncomplete: (l) =>
        l.mutualTlsMissingCredentialPair,
    ServerAddressProblem.certificatePemRequired: (l) =>
        l.mutualTlsCertificatePemRequired,
    ServerAddressProblem.privateKeyPemRequired: (l) =>
        l.mutualTlsPrivateKeyPemRequired,
    ServerAddressProblem.pemFileUnreadable: (l) => l.mutualTlsFileReadFailed,
    ServerAddressProblem.mutualTlsRefused: (l) => l.mutualTlsHandshakeFailed,
    ServerAddressProblem.mutualTlsConnectionClosed: (l) =>
        l.mutualTlsConnectionClosed,
    ServerAddressProblem.unreachable: (l) => l.couldNotConnectGeneric,
    ServerAddressProblem.notOpenWebUi: (l) => l.serverNotOpenWebUI,
    ServerAddressProblem.serverUnavailable: (l) => l.serverErrorUnavailable,
    ServerAddressProblem.serverError: (l) => l.serverErrorGeneric,
    ServerAddressProblem.certificateRejected: (l) => l.securityCertificateError,
    ServerAddressProblem.serverMissing: (l) => l.errorMessage,
    ServerAddressProblem.differentServer: (l) =>
        l.accountsAddressDifferentServer,
    ServerAddressProblem.needsSignIn: (l) => l.accountsAddressNeedsSignIn,
    ServerAddressProblem.proxySessionRevoked: (l) => l.proxyAuthFailed,
  };

  test('every problem reads as it did, in every language', () {
    check(before.keys.toSet()).deepEquals(ServerAddressProblem.values.toSet());
    for (final locale in AppLocalizations.supportedLocales) {
      final l10n = lookupAppLocalizations(locale);
      for (final MapEntry(key: problem, value: words) in before.entries) {
        check(
          because: '${problem.name} in $locale',
          serverAddressProblemText(problem, l10n, headerName: 'X-Gate'),
        ).equals(words(l10n));
      }
    }
  });

  test('a header is refused naming the header typed', () {
    final l10n = lookupAppLocalizations(const Locale('en'));
    check(serverAddressHeaderNameProblemText('Host', l10n))
        .equals(l10n.headerNameReserved('Host'));
    check(
      serverAddressHeaderProblemText(
        const {'X-Gate': 'v'},
        name: 'X-Gate',
        value: 'w',
        l10n: l10n,
      ),
    ).equals(l10n.headerAlreadyExists('X-Gate'));
    check(serverAddressHeaderValueProblemText('<b>', l10n))
        .equals(l10n.headerValueUnsafe);
    check(serverAddressHeaderNameProblemText('X-Gate', l10n)).isNull();
  });

  test('an error shown as it reads keeps its own text', () {
    final l10n = lookupAppLocalizations(const Locale('en'));
    check(
      serverAddressFailureText(
        const ServerAddressErrorText('HTTP 502 - from the server'),
        l10n,
      ),
    ).equals('HTTP 502 - from the server');
    check(
      serverAddressFailureText(
        const ServerAddressProblemFailure(ServerAddressProblem.unreachable),
        l10n,
      ),
    ).equals(l10n.couldNotConnectGeneric);
  });
}
