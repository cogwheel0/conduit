import 'package:meta/meta.dart';

/// A single-sign-on provider a LibreChat server offers.
enum LibreChatSsoKind { openid, saml, google, github, discord, facebook, apple }

/// One sign-in button from a LibreChat server's startup config.
@immutable
final class LibreChatSsoProvider {
  const LibreChatSsoProvider({required this.kind, this.label, this.imageUrl});

  final LibreChatSsoKind kind;

  /// The admin's button text, for OpenID and SAML.
  final String? label;

  /// The admin's button icon, for OpenID and SAML.
  final String? imageUrl;

  /// The route that starts this provider's sign-in, under the server's
  /// `serverDomain`.
  String get path => '/oauth/${kind.name}';

  /// Whether the provider can complete inside the app's web view. Google
  /// refuses embedded browsers outright.
  bool get supportedInApp => kind != LibreChatSsoKind.google;

  @override
  bool operator ==(Object other) =>
      other is LibreChatSsoProvider &&
      other.kind == kind &&
      other.label == label &&
      other.imageUrl == imageUrl;

  @override
  int get hashCode => Object.hash(kind, label, imageUrl);
}

/// What a LibreChat server says about itself before anyone signs in: its
/// name and the ways to sign in (`GET /api/config` without a session).
@immutable
final class LibreChatServerInfo {
  const LibreChatServerInfo({
    required this.appTitle,
    this.emailLoginEnabled = true,
    this.registrationEnabled = false,
    this.passwordResetEnabled = false,
    this.ldapEnabled = false,
    this.ldapUsesUsername = false,
    this.ssoProviders = const <LibreChatSsoProvider>[],
    this.openidAutoRedirect = false,
    this.serverDomain,
    this.minPasswordLength,
    this.raw = const <String, dynamic>{},
  });

  final String appTitle;
  final bool emailLoginEnabled;
  final bool registrationEnabled;
  final bool passwordResetEnabled;

  /// LDAP replaces the local password check on the same form.
  final bool ldapEnabled;

  /// LDAP asks for a username rather than an email.
  final bool ldapUsesUsername;

  /// Buttons in the order the server lists them.
  final List<LibreChatSsoProvider> ssoProviders;

  /// The server sends everyone straight to its OpenID provider.
  final bool openidAutoRedirect;

  /// Where the server says it is reached (`DOMAIN_SERVER`). Single sign-on
  /// starts and returns there, which can differ from the address the user
  /// typed.
  final String? serverDomain;

  final int? minPasswordLength;
  final Map<String, dynamic> raw;

  /// Whether the form takes a password (local or LDAP). LibreChat refuses
  /// both while email login is off -- its login route checks that first --
  /// and its own sign-in page shows no password form then either.
  bool get passwordSignInEnabled => emailLoginEnabled;

  /// Whether [json] is LibreChat's startup config, rather than another
  /// server's `/api/config` (Open WebUI answers that path too).
  static bool isStartupConfig(Object? json) =>
      json is Map &&
      json['appTitle'] is String &&
      json.containsKey('emailLoginEnabled') &&
      json.containsKey('serverDomain');

  static LibreChatServerInfo? fromJson(Object? json) {
    if (!isStartupConfig(json)) return null;
    final map = Map<String, dynamic>.from(json as Map);
    bool flag(String key) => map[key] == true;
    String? text(String key) {
      final value = map[key];
      return value is String && value.trim().isNotEmpty ? value.trim() : null;
    }

    final providers = <LibreChatSsoProvider>[];
    if (flag('socialLoginEnabled')) {
      final order = map['socialLogins'];
      final names = order is List
          ? order.whereType<String>()
          : const ['google', 'facebook', 'openid', 'github', 'discord', 'saml'];
      for (final name in names) {
        final kind = LibreChatSsoKind.values
            .where((kind) => kind.name == name)
            .firstOrNull;
        if (kind == null || !flag('${kind.name}LoginEnabled')) continue;
        if (providers.any((provider) => provider.kind == kind)) continue;
        providers.add(
          LibreChatSsoProvider(
            kind: kind,
            label: switch (kind) {
              LibreChatSsoKind.openid => text('openidLabel'),
              LibreChatSsoKind.saml => text('samlLabel'),
              _ => null,
            },
            imageUrl: switch (kind) {
              LibreChatSsoKind.openid => text('openidImageUrl'),
              LibreChatSsoKind.saml => text('samlImageUrl'),
              _ => null,
            },
          ),
        );
      }
    }

    final ldap = map['ldap'];
    final minPasswordLength = map['minPasswordLength'];
    return LibreChatServerInfo(
      appTitle: text('appTitle') ?? 'LibreChat',
      emailLoginEnabled: map['emailLoginEnabled'] != false,
      registrationEnabled: flag('registrationEnabled'),
      passwordResetEnabled: flag('passwordResetEnabled'),
      ldapEnabled: ldap is Map && ldap['enabled'] == true,
      ldapUsesUsername: ldap is Map && ldap['username'] == true,
      ssoProviders: List.unmodifiable(providers),
      openidAutoRedirect: flag('openidAutoRedirect'),
      serverDomain: text('serverDomain'),
      minPasswordLength: minPasswordLength is int ? minPasswordLength : null,
      raw: Map<String, dynamic>.unmodifiable(map),
    );
  }
}
