import 'dart:convert';

import 'package:meta/meta.dart';

import 'browser_sign_in_config.dart';

/// What an account signed in through the system browser keeps to sign in
/// again without the browser: the identity provider's refresh token, and
/// where and for whom it was issued.
///
/// Stored per account, in secure storage, only while the account's saved
/// sign-in is a browser sign-in. The id token and access token are never
/// stored.
@immutable
final class BrowserSignInSession {
  const BrowserSignInSession({
    required this.serverId,
    required this.provider,
    required this.clientId,
    required this.issuer,
    required this.tokenEndpoint,
    this.revocationEndpoint,
    required this.refreshToken,
    this.scope = '',
    required this.owuiUserId,
    this.subject,
  });

  static const int currentVersion = 1;

  /// The registry server the account was on when it signed in.
  final String serverId;

  /// The Open WebUI provider that exchanged the access token.
  final String provider;
  final String clientId;

  /// The issuer of the identity provider's discovery document.
  final String issuer;
  final String tokenEndpoint;
  final String? revocationEndpoint;
  final String refreshToken;

  /// The scopes granted, space-separated; empty when none were reported.
  final String scope;

  /// The Open WebUI user the exchange signed in as. A renewal that signs in
  /// as anyone else is refused.
  final String owuiUserId;

  /// The identity provider's user (its ID token's `sub`), when the sign-in
  /// came with an ID token. Null for a session saved before it was kept.
  final String? subject;

  /// Whether this session was issued under [config], the current browser
  /// sign-in settings of [serverId]'s server. A session issued to another
  /// client or provider must not be renewed under the new one.
  bool matches({required String serverId, BrowserSignInConfig? config}) {
    if (config == null || serverId != this.serverId) return false;
    if (config.provider != provider || config.clientId != clientId) {
      return false;
    }
    final configured = config.issuer;
    return configured == null ||
        normalizeBrowserSignInIssuer(configured) ==
            normalizeBrowserSignInIssuer(issuer);
  }

  /// Whether [other] may hold a refresh token of the same grant: the same
  /// client at the same identity provider, for the same user -- by
  /// [subject] when both know theirs, else the same Open WebUI user on the
  /// same server.
  ///
  /// Some providers end every refresh token of a user's grant to a client
  /// when one is revoked, so one such session is never revoked while the
  /// other is still in use.
  bool sharesGrantWith(BrowserSignInSession other) {
    if (other.clientId != clientId ||
        normalizeBrowserSignInIssuer(other.issuer) !=
            normalizeBrowserSignInIssuer(issuer)) {
      return false;
    }
    final mine = subject;
    final theirs = other.subject;
    if (mine != null && theirs != null) return mine == theirs;
    return other.serverId == serverId && other.owuiUserId == owuiUserId;
  }

  BrowserSignInSession copyWith({
    String? serverId,
    String? refreshToken,
    String? scope,
  }) => BrowserSignInSession(
    serverId: serverId ?? this.serverId,
    provider: provider,
    clientId: clientId,
    issuer: issuer,
    tokenEndpoint: tokenEndpoint,
    revocationEndpoint: revocationEndpoint,
    refreshToken: refreshToken ?? this.refreshToken,
    scope: scope ?? this.scope,
    owuiUserId: owuiUserId,
    subject: subject,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'version': currentVersion,
    'serverId': serverId,
    'provider': provider,
    'clientId': clientId,
    'issuer': issuer,
    'tokenEndpoint': tokenEndpoint,
    if (revocationEndpoint != null) 'revocationEndpoint': revocationEndpoint,
    'refreshToken': refreshToken,
    'scope': scope,
    'owuiUserId': owuiUserId,
    if (subject != null) 'subject': subject,
  };

  String encode() => jsonEncode(toJson());

  /// The session stored as [json], or null when it is not one, or one of
  /// another version: it cannot be renewed, so it reads as none.
  static BrowserSignInSession? tryFromJson(Object? json) {
    if (json is! Map) return null;
    if (json['version'] != currentVersion) return null;
    String? text(String key) {
      final value = json[key];
      return value is String && value.isNotEmpty ? value : null;
    }

    final serverId = text('serverId');
    final provider = text('provider');
    final clientId = text('clientId');
    final issuer = text('issuer');
    final tokenEndpoint = text('tokenEndpoint');
    final refreshToken = text('refreshToken');
    final owuiUserId = text('owuiUserId');
    final revocationEndpoint = json['revocationEndpoint'];
    final scope = json['scope'];
    final subject = json['subject'];
    if (serverId == null ||
        provider == null ||
        !browserSignInProviderPattern.hasMatch(provider) ||
        clientId == null ||
        issuer == null ||
        tokenEndpoint == null ||
        refreshToken == null ||
        owuiUserId == null ||
        (revocationEndpoint != null && revocationEndpoint is! String) ||
        (scope != null && scope is! String) ||
        (subject != null && subject is! String)) {
      return null;
    }
    return BrowserSignInSession(
      serverId: serverId,
      provider: provider,
      clientId: clientId,
      issuer: issuer,
      tokenEndpoint: tokenEndpoint,
      revocationEndpoint: switch (revocationEndpoint) {
        final String value when value.isNotEmpty => value,
        _ => null,
      },
      refreshToken: refreshToken,
      scope: scope as String? ?? '',
      owuiUserId: owuiUserId,
      subject: switch (subject) {
        final String value when value.isNotEmpty => value,
        _ => null,
      },
    );
  }

  /// [tryFromJson] of an [encode]d session; null for anything else.
  static BrowserSignInSession? tryDecode(String? source) {
    if (source == null || source.isEmpty) return null;
    try {
      return tryFromJson(jsonDecode(source));
    } on FormatException {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is BrowserSignInSession &&
      other.serverId == serverId &&
      other.provider == provider &&
      other.clientId == clientId &&
      other.issuer == issuer &&
      other.tokenEndpoint == tokenEndpoint &&
      other.revocationEndpoint == revocationEndpoint &&
      other.refreshToken == refreshToken &&
      other.scope == scope &&
      other.owuiUserId == owuiUserId &&
      other.subject == subject;

  @override
  int get hashCode => Object.hash(
    serverId,
    provider,
    clientId,
    issuer,
    tokenEndpoint,
    revocationEndpoint,
    refreshToken,
    scope,
    owuiUserId,
    subject,
  );

  @override
  String toString() => 'BrowserSignInSession($provider, <redacted>)';
}
