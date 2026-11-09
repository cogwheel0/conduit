import 'package:conduit_core/conduit_core.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:flutter/services.dart';

import 'conduit_platform_apis.g.dart';

/// The Flutter app's [BrowserAuthPort]: `BrowserAuthBridge` on iOS
/// (`ASWebAuthenticationSession`) and Android (Auth Tab, Custom Tabs or the
/// default browser).
///
/// The bridge matches the redirect exactly; this checks it again, so a
/// result that reaches the core always ended on the redirect it asked for.
/// Nothing here logs a URL: the redirect carries a one-time code.
class PigeonBrowserAuthPort implements BrowserAuthPort {
  PigeonBrowserAuthPort({BrowserAuthHostApi? api})
    : _api = api ?? BrowserAuthHostApi();

  final BrowserAuthHostApi _api;

  @override
  bool get isSupported => true;

  @override
  Future<BrowserAuthResult> authorize(
    Uri url, {
    required Uri redirectUri,
    bool preferEphemeral = false,
  }) async {
    if (!_isBrowsable(url) || !_isAppRedirect(redirectUri)) {
      return const BrowserAuthResult.failed(
        BrowserAuthErrorCodes.invalidRequest,
      );
    }
    final PlatformBrowserAuthResult result;
    try {
      result = await _api.authenticate(
        PlatformBrowserAuthRequest(
          authorizationUrl: url.toString(),
          callbackScheme: redirectUri.scheme,
          callbackHost: redirectUri.host,
          callbackPath: redirectUri.path,
          preferEphemeralSession: preferEphemeral,
        ),
      );
    } on MissingPluginException {
      return const BrowserAuthResult.unavailable(
        BrowserAuthErrorCodes.noBrowser,
      );
    } on PlatformException catch (error) {
      DebugLogger.warning(
        'browser-auth-bridge-failed',
        scope: 'auth/browser',
        data: {'code': error.code},
      );
      return const BrowserAuthResult.failed(BrowserAuthErrorCodes.startFailed);
    }
    return browserAuthResultFromPlatform(result, redirectUri: redirectUri);
  }

  @override
  Future<void> cancel() async {
    try {
      await _api.cancel();
    } on MissingPluginException {
      // No bridge, so nothing to cancel.
    } on PlatformException catch (error) {
      DebugLogger.warning(
        'browser-auth-cancel-failed',
        scope: 'auth/browser',
        data: {'code': error.code},
      );
    }
  }
}

/// The core's view of a bridge [result] for a sign-in that asked for
/// [redirectUri].
///
/// A success whose redirect does not match [redirectUri] exactly is a
/// failure: the bridge should never report one, and the core must never
/// read a code from anywhere else.
BrowserAuthResult browserAuthResultFromPlatform(
  PlatformBrowserAuthResult result, {
  required Uri redirectUri,
}) {
  final channel = result.channel;
  final errorCode = result.errorCode;
  switch (result.outcome) {
    case PlatformBrowserAuthOutcome.success:
      final callback = Uri.tryParse(result.callbackUrl ?? '');
      if (callback == null ||
          !browserAuthRedirectMatches(callback, redirectUri)) {
        DebugLogger.warning(
          'browser-auth-unexpected-callback',
          scope: 'auth/browser',
          data: {'channel': channel},
        );
        return BrowserAuthResult.failed(
          BrowserAuthErrorCodes.unexpectedCallback,
          channel: channel,
        );
      }
      return BrowserAuthResult(
        outcome: BrowserAuthOutcome.success,
        callbackUri: callback,
        channel: channel,
      );
    case PlatformBrowserAuthOutcome.cancelled:
      return BrowserAuthResult.cancelled(channel: channel);
    case PlatformBrowserAuthOutcome.unavailable:
      return BrowserAuthResult.unavailable(
        errorCode ?? BrowserAuthErrorCodes.noBrowser,
        channel: channel,
      );
    case PlatformBrowserAuthOutcome.failed:
      return BrowserAuthResult.failed(
        errorCode ?? BrowserAuthErrorCodes.startFailed,
        channel: channel,
      );
  }
}

/// Whether [callback] is [redirectUri] with only a query added: the same
/// scheme, host and path, and no port, user info or fragment.
bool browserAuthRedirectMatches(Uri callback, Uri redirectUri) {
  return callback.scheme.toLowerCase() == redirectUri.scheme.toLowerCase() &&
      callback.host.toLowerCase() == redirectUri.host.toLowerCase() &&
      callback.path == redirectUri.path &&
      !callback.hasPort &&
      callback.userInfo.isEmpty &&
      !callback.hasFragment;
}

bool _isBrowsable(Uri url) =>
    (url.scheme == 'https' || url.scheme == 'http') && url.host.isNotEmpty;

/// A redirect only the app can receive: a custom scheme, a path, and
/// nothing a browser could confuse with a web page.
bool _isAppRedirect(Uri redirect) {
  final scheme = redirect.scheme.toLowerCase();
  return scheme.isNotEmpty &&
      scheme != 'http' &&
      scheme != 'https' &&
      redirect.path.startsWith('/') &&
      !redirect.hasPort &&
      redirect.userInfo.isEmpty &&
      !redirect.hasQuery &&
      !redirect.hasFragment;
}
