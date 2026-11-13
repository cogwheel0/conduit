import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit_core/auth/openwebui_server_address.dart';

/// What the app tells the user for [problem]. [headerName] is the header
/// [ServerAddressProblem.headerNameReserved] and
/// [ServerAddressProblem.headerAlreadyAdded] name.
String serverAddressProblemText(
  ServerAddressProblem problem,
  AppLocalizations l10n, {
  String headerName = '',
}) => switch (problem) {
  ServerAddressProblem.addressEmpty => l10n.serverUrlEmpty,
  ServerAddressProblem.invalidAddress => l10n.invalidUrlFormat,
  ServerAddressProblem.unsupportedScheme => l10n.onlyHttpHttps,
  ServerAddressProblem.missingHost => l10n.serverAddressRequired,
  ServerAddressProblem.portOutOfRange => l10n.portRange,
  ServerAddressProblem.invalidIpAddress => l10n.invalidIpFormat,
  ServerAddressProblem.headerFieldMissing => l10n.authFieldRequired,
  ServerAddressProblem.headerNameTooLong => l10n.headerNameTooLong,
  ServerAddressProblem.headerNameInvalidCharacters =>
    l10n.headerNameInvalidChars,
  ServerAddressProblem.headerNameReserved => l10n.headerNameReserved(
    headerName,
  ),
  ServerAddressProblem.headerValueTooLong => l10n.headerValueTooLong,
  ServerAddressProblem.headerValueInvalidCharacters =>
    l10n.headerValueInvalidChars,
  ServerAddressProblem.headerValueUnsafe => l10n.headerValueUnsafe,
  ServerAddressProblem.headerAlreadyAdded => l10n.headerAlreadyExists(
    headerName,
  ),
  ServerAddressProblem.tooManyHeaders => l10n.maxHeadersReachedDetail,
  ServerAddressProblem.mutualTlsIncomplete =>
    l10n.mutualTlsMissingCredentialPair,
  ServerAddressProblem.certificatePemRequired =>
    l10n.mutualTlsCertificatePemRequired,
  ServerAddressProblem.privateKeyPemRequired =>
    l10n.mutualTlsPrivateKeyPemRequired,
  ServerAddressProblem.pemFileUnreadable => l10n.mutualTlsFileReadFailed,
  ServerAddressProblem.mutualTlsRefused => l10n.mutualTlsHandshakeFailed,
  ServerAddressProblem.mutualTlsConnectionClosed =>
    l10n.mutualTlsConnectionClosed,
  ServerAddressProblem.unreachable => l10n.couldNotConnectGeneric,
  ServerAddressProblem.notOpenWebUi => l10n.serverNotOpenWebUI,
  ServerAddressProblem.serverUnavailable => l10n.serverErrorUnavailable,
  ServerAddressProblem.serverError => l10n.serverErrorGeneric,
  ServerAddressProblem.certificateRejected => l10n.securityCertificateError,
  ServerAddressProblem.serverMissing => l10n.errorMessage,
  ServerAddressProblem.differentServer => l10n.accountsAddressDifferentServer,
  ServerAddressProblem.needsSignIn => l10n.accountsAddressNeedsSignIn,
  ServerAddressProblem.proxySessionRevoked => l10n.proxyAuthFailed,
};

/// What the app tells the user for [failure]: its problem's words, or the
/// error's own sanitized text.
String serverAddressFailureText(
  ServerAddressFailure failure,
  AppLocalizations l10n,
) => switch (failure) {
  ServerAddressProblemFailure(:final problem) => serverAddressProblemText(
    problem,
    l10n,
  ),
  ServerAddressErrorText(:final text) => text,
};

/// What is wrong with [name] as a custom header's name, in words, or null.
String? serverAddressHeaderNameProblemText(String name, AppLocalizations l10n) {
  final problem = validateServerAddressHeaderName(name);
  return problem == null
      ? null
      : serverAddressProblemText(problem, l10n, headerName: name);
}

/// What is wrong with [value] as a custom header's value, in words, or
/// null.
String? serverAddressHeaderValueProblemText(
  String value,
  AppLocalizations l10n,
) {
  final problem = validateServerAddressHeaderValue(value);
  return problem == null ? null : serverAddressProblemText(problem, l10n);
}

/// What is wrong with adding header [name] with [value] to [headers], in
/// words, or null when it can be added.
String? serverAddressHeaderProblemText(
  Map<String, String> headers, {
  required String name,
  required String value,
  required AppLocalizations l10n,
}) {
  final problem = validateServerAddressHeader(
    headers,
    name: name,
    value: value,
  );
  return problem == null
      ? null
      : serverAddressProblemText(problem, l10n, headerName: name);
}
