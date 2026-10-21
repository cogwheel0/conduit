import 'package:meta/meta.dart';

/// Matches an Open WebUI OAuth provider name, as it appears in
/// `/oauth/{provider}/login`.
final RegExp browserSignInProviderPattern = RegExp(r'^[a-z0-9_-]+$');

/// The comparable form of an issuer typed as an issuer or as its discovery
/// document's URL: trimmed, without the well-known suffix or a trailing
/// slash.
String normalizeBrowserSignInIssuer(String value) {
  const suffix = '/.well-known/openid-configuration';
  var issuer = value.trim();
  if (issuer.endsWith(suffix)) {
    issuer = issuer.substring(0, issuer.length - suffix.length);
  }
  while (issuer.endsWith('/')) {
    issuer = issuer.substring(0, issuer.length - 1);
  }
  return issuer;
}

/// How a server's accounts sign in through the system browser: the Open WebUI
/// OAuth provider whose token exchange takes the identity provider's access
/// token, and the public client registered for Conduit at that provider.
///
/// Saved once per server and shared by its accounts and addresses. Not a
/// secret: a public client has no secret, so a sign-out that keeps server
/// details keeps it.
@immutable
final class BrowserSignInConfig {
  const BrowserSignInConfig({
    required this.provider,
    required this.clientId,
    this.issuer,
  });

  /// The Open WebUI provider name: `oidc`, `microsoft` or `google`.
  final String provider;

  /// Conduit's client id at the identity provider. Never Open WebUI's own.
  final String clientId;

  /// The issuer, or its discovery document's URL, when discovery from the
  /// provider's login redirect could not find it. Null when it was found.
  final String? issuer;

  Map<String, Object?> toJson() => <String, Object?>{
    'provider': provider,
    'clientId': clientId,
    if (issuer != null) 'issuer': issuer,
  };

  /// The config stored as [json], or null when it is not one: a value an
  /// older or newer build wrote must not make the registry unreadable.
  static BrowserSignInConfig? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final provider = json['provider'];
    final clientId = json['clientId'];
    final issuer = json['issuer'];
    if (provider is! String ||
        !browserSignInProviderPattern.hasMatch(provider)) {
      return null;
    }
    if (clientId is! String || clientId.trim().isEmpty) return null;
    if (issuer != null && (issuer is! String || issuer.trim().isEmpty)) {
      return null;
    }
    return BrowserSignInConfig(
      provider: provider,
      clientId: clientId,
      issuer: issuer as String?,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is BrowserSignInConfig &&
      other.provider == provider &&
      other.clientId == clientId &&
      other.issuer == issuer;

  @override
  int get hashCode => Object.hash(provider, clientId, issuer);

  @override
  String toString() => 'BrowserSignInConfig($provider)';
}
