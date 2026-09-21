/// Running an external sign-in, as the renderer sees it.
///
/// A port rather than a direct `window.conduit` call, for the same reason the
/// core has ports: this file is plain Dart, so the sign-in page and its tests
/// run on the VM without a browser or an Electron shell. The interop lives in
/// `bridge.dart`, which is browser-only.
abstract interface class ExternalSignInPort {
  /// Opens a browser window at [startUrl] and resolves once it returns to
  /// [serverUrl]'s origin, or when the user closes it.
  Future<ExternalSignIn> run({
    required String startUrl,
    required String serverUrl,
    String? title,
  });
}

/// What an external sign-in left behind.
sealed class ExternalSignIn {
  const ExternalSignIn();
}

final class ExternalSignInCaptured extends ExternalSignIn {
  const ExternalSignInCaptured({
    required this.origin,
    required this.cookies,
    this.token,
  });

  final String origin;
  final Map<String, String> cookies;

  /// Present when a trusted-header proxy already authenticated the user, so
  /// Open WebUI issued a session and the sign-in form can be skipped. Absent
  /// is not a failure: the proxy let us through and the server still wants
  /// credentials.
  final String? token;
}

/// The user closed the window, or it ran past its budget.
///
/// One case, not two, because there is nothing different to do: both mean no
/// session was established and the form stays where it is. They are told
/// apart in the message only.
final class ExternalSignInAbandoned extends ExternalSignIn {
  const ExternalSignInAbandoned({required this.timedOut});

  final bool timedOut;
}

/// The port with no shell behind it.
///
/// Development in a plain browser has no Electron to open a window, and a
/// sign-in button that silently did nothing would look like a bug in the
/// server. This says so instead.
final class UnavailableExternalSignIn implements ExternalSignInPort {
  const UnavailableExternalSignIn();

  @override
  Future<ExternalSignIn> run({
    required String startUrl,
    required String serverUrl,
    String? title,
  }) async => throw UnsupportedError(
    'external sign-in needs the Electron shell; run the app rather than the '
    'dev browser',
  );
}
