import 'package:conduit_core/conduit_core.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// The Flutter app's [OpenExternalUrlPort]: the system browser.
///
/// Always an external application, never an in-app view, and only for
/// web addresses -- what the port's contract asks of every host. MCP and
/// Hermes sign-in go through here; without this binding the core's default
/// refused every URL, and both failed with "could not start".
class UrlLauncherOpenExternalUrlPort implements OpenExternalUrlPort {
  const UrlLauncherOpenExternalUrlPort();

  @override
  Future<bool> open(Uri url) async {
    if (url.scheme != 'https' && url.scheme != 'http') return false;
    try {
      return await launchUrl(url, mode: LaunchMode.externalApplication);
    } on PlatformException {
      return false;
    }
  }
}
