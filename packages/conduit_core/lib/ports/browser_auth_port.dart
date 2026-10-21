/// The redirect a browser sign-in ends on unless a provider needs its own.
/// Android's callback activity is registered for exactly this.
const String browserAuthDefaultRedirect = 'conduit://oauth/callback';

/// Runs a sign-in page in the system browser and returns the redirect it
/// ends on.
///
/// The system browser, unlike an in-app WebView, can use the passkeys and
/// security keys an identity provider asks for. iOS runs the page in
/// `ASWebAuthenticationSession`; Android in an Auth Tab, else a Custom Tab,
/// else the default browser. The core owns everything around the page:
/// building the URL, and checking the redirect again before trusting it.
abstract interface class BrowserAuthPort {
  /// Whether this host has a system browser to sign in with.
  ///
  /// False hides the browser sign-in entry points.
  bool get isSupported;

  /// The redirect a sign-in ends on unless a provider needs its own:
  /// [browserAuthDefaultRedirect].
  Uri get defaultRedirectUri;

  /// Opens [url] and completes once the browser reaches [redirectUri]
  /// (matched exactly on scheme, host and path), is dismissed, or fails.
  ///
  /// Never throws. Starting another sign-in ends this one as failed with
  /// [BrowserAuthErrorCodes.superseded]. [preferEphemeral] asks the browser
  /// not to share cookies with its other sessions.
  Future<BrowserAuthResult> authorize(
    Uri url, {
    required Uri redirectUri,
    bool preferEphemeral = false,
  });

  /// Ends the sign-in in progress as cancelled, if any.
  Future<void> cancel();
}

/// How a browser sign-in ended.
enum BrowserAuthOutcome {
  /// The browser reached the redirect: see [BrowserAuthResult.callbackUri].
  success,

  /// The user closed the browser, or the sign-in was cancelled.
  cancelled,

  /// This device cannot run the sign-in: no browser, or none that can return
  /// to this redirect.
  unavailable,

  /// The browser could not be shown, or ended somewhere unexpected.
  failed,
}

/// The stable reasons a browser sign-in did not finish, as the platform
/// reports them in [BrowserAuthResult.errorCode].
abstract final class BrowserAuthErrorCodes {
  /// The browser could not be shown over the app.
  static const String presentationFailed = 'presentation_failed';

  /// No browser is installed.
  static const String noBrowser = 'no_browser';

  /// The browser refused to start.
  static const String startFailed = 'start_failed';

  /// The browser ended on a different redirect.
  static const String unexpectedCallback = 'unexpected_callback';

  /// The redirect can only return to the app through an Android Auth Tab,
  /// which the default browser does not support.
  static const String authTabRequired = 'auth_tab_required';

  /// A newer sign-in replaced this one.
  static const String superseded = 'superseded';

  /// The URL or the redirect was not usable.
  static const String invalidRequest = 'invalid_request';
}

/// The browser surfaces a sign-in can run in, as reported in
/// [BrowserAuthResult.channel].
abstract final class BrowserAuthChannels {
  static const String webAuthenticationSession = 'web_authentication_session';
  static const String authTab = 'auth_tab';
  static const String customTabs = 'custom_tabs';
  static const String externalBrowser = 'external_browser';
}

/// How a browser sign-in ended, and where.
final class BrowserAuthResult {
  const BrowserAuthResult({
    required this.outcome,
    this.callbackUri,
    this.errorCode,
    this.channel,
  });

  const BrowserAuthResult.cancelled({String? channel})
    : this(outcome: BrowserAuthOutcome.cancelled, channel: channel);

  const BrowserAuthResult.unavailable(String errorCode, {String? channel})
    : this(
        outcome: BrowserAuthOutcome.unavailable,
        errorCode: errorCode,
        channel: channel,
      );

  const BrowserAuthResult.failed(String errorCode, {String? channel})
    : this(
        outcome: BrowserAuthOutcome.failed,
        errorCode: errorCode,
        channel: channel,
      );

  final BrowserAuthOutcome outcome;

  /// The redirect, with the authorization response in its query, for
  /// [BrowserAuthOutcome.success]. Holds a one-time code: never log it.
  final Uri? callbackUri;

  /// One of [BrowserAuthErrorCodes], when the sign-in did not succeed and
  /// the platform said why.
  final String? errorCode;

  /// One of [BrowserAuthChannels], when the platform said.
  final String? channel;

  @override
  String toString() =>
      'BrowserAuthResult(${outcome.name}'
      '${errorCode == null ? '' : ', $errorCode'}'
      '${channel == null ? '' : ', $channel'})';
}

/// No system browser. The default for a host without one, which hides the
/// browser sign-in entry points.
class NullBrowserAuthPort implements BrowserAuthPort {
  const NullBrowserAuthPort();

  @override
  bool get isSupported => false;

  @override
  Uri get defaultRedirectUri => Uri.parse(browserAuthDefaultRedirect);

  @override
  Future<BrowserAuthResult> authorize(
    Uri url, {
    required Uri redirectUri,
    bool preferEphemeral = false,
  }) async =>
      const BrowserAuthResult.unavailable(BrowserAuthErrorCodes.noBrowser);

  @override
  Future<void> cancel() async {}
}
