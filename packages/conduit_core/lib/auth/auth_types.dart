/// How a saved Open WebUI sign-in authenticates again: the `authType` of its
/// saved credentials.
abstract final class AuthTypes {
  /// Email and password (the default).
  static const String credentials = 'credentials';

  /// An LDAP sign-in, saved as the session token it issued.
  static const String ldap = 'ldap';

  /// A token or API key typed in by hand.
  static const String token = 'token';

  /// A session token from the in-app (WebView) SSO sign-in.
  static const String sso = 'sso';

  /// A session token from a sign-in in the system browser, renewed with the
  /// identity provider's refresh token kept for the account.
  static const String ssoBrowser = 'sso_browser';
}
