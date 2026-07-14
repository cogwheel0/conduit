import 'conduit_user_agent_platform.dart' as platform;

/// Public identity for requests initiated against the configured Open WebUI
/// server.
///
/// Native clients retain User-Agent headers across redirects so server
/// allowlists remain stable. A redirect can cross origins, therefore this value
/// must stay product-specific and never contain device or account data.
abstract final class ConduitUserAgent {
  static const String productName = 'Conduit';
  static const String headerName = 'User-Agent';

  static String _value = productName;

  /// The process-wide User-Agent, falling back to [productName] until startup
  /// supplies the installed package version.
  static String get value => _value;

  /// The runtime's original identity, used when an Open WebUI-scoped client is
  /// deliberately reused for an absolute request to another origin.
  static String? get runtimeDefaultValue => platform.runtimeDefaultUserAgent;

  /// Initializes the process-wide value from public package metadata.
  static void configure({required String appVersion}) {
    _value = build(appVersion: appVersion);
  }

  /// Builds an RFC-compatible product token from an app version.
  static String build({required String appVersion}) {
    final sanitizedVersion = appVersion.trim().replaceAll(
      RegExp(r'[^A-Za-z0-9._+\-]'),
      '-',
    );
    if (sanitizedVersion.isEmpty) {
      return productName;
    }
    return '$productName/$sanitizedVersion';
  }

  /// Returns [headers] with exactly one canonical Conduit User-Agent.
  static Map<String, String> mergeHeaders([
    Map<String, String> headers = const {},
  ]) {
    final merged = Map<String, String>.from(headers)
      ..removeWhere((name, _) => isHeaderName(name));
    merged[headerName] = value;
    return merged;
  }

  /// Replaces any case variant in a mutable request-header map.
  static void applyTo(Map<String, dynamic> headers) {
    headers.removeWhere((name, _) => isHeaderName(name));
    headers[headerName] = value;
  }

  static bool isHeaderName(String name) =>
      name.toLowerCase() == headerName.toLowerCase();
}
