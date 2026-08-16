import '../models/hermes_config.dart';
import 'hermes_desktop_api_service.dart';

HermesDesktopAuthKind hermesRecommendedDesktopAuth(
  Map<String, dynamic> status, {
  required bool hasAccessHeaders,
}) {
  if (status['auth_required'] == false) {
    return HermesDesktopAuthKind.legacyToken;
  }
  final flows = status['auth_flows'];
  final native =
      flows is List &&
      flows.any(
        (flow) =>
            flow == 'native_pkce' ||
            flow is Map &&
                (flow['id'] == 'native_pkce' || flow['type'] == 'native_pkce'),
      );
  return native && !hasAccessHeaders
      ? HermesDesktopAuthKind.nativePkce
      : HermesDesktopAuthKind.dashboardCookie;
}

bool hermesDesktopConnectionMatches(HermesConfig left, HermesConfig right) {
  if (HermesConfig.connectionEndpoint(left.baseUrl) !=
          HermesConfig.connectionEndpoint(right.baseUrl) ||
      left.desktopAuthKind != right.desktopAuthKind ||
      left.desktopProfile != right.desktopProfile ||
      (left.desktopAuthKind == HermesDesktopAuthKind.legacyToken &&
          left.desktopCredentials?.legacyToken !=
              right.desktopCredentials?.legacyToken) ||
      left.accessHeaders.length != right.accessHeaders.length) {
    return false;
  }
  final rightHeaders = {
    for (final entry in right.accessHeaders.entries)
      entry.key.toLowerCase(): entry.value,
  };
  return left.accessHeaders.entries.every(
    (entry) => rightHeaders[entry.key.toLowerCase()] == entry.value,
  );
}

final class HermesDesktopConnectionCoordinator {
  const HermesDesktopConnectionCoordinator();

  Future<List<String>> profiles(
    HermesConfig config, {
    HermesDesktopApiService? service,
    HermesDesktopCredentialsWriter? onCredentialsChanged,
  }) {
    if (service != null) return service.listProfiles();
    if (config.desktopCredentials?.nativeTokens != null &&
        onCredentialsChanged == null) {
      throw StateError('Save the Hermes server before loading profiles.');
    }
    return _using(
      config,
      (temporary) => temporary.listProfiles(),
      onCredentialsChanged: onCredentialsChanged,
    );
  }

  Future<void> signInNative(
    HermesConfig config, {
    required HermesDesktopCredentialsWriter onCredentialsChanged,
    HermesDesktopApiService? service,
  }) =>
      service?.signInNative() ??
      _using(
        config,
        (temporary) => temporary.signInNative(),
        onCredentialsChanged: onCredentialsChanged,
      );

  Future<HermesDesktopAuthKind> recommendedAuth(HermesConfig config) =>
      _using(config, (service) async {
        final status = await service.statusProbe(refresh: true);
        return hermesRecommendedDesktopAuth(
          status,
          hasAccessHeaders: config.accessHeaders.isNotEmpty,
        );
      });

  Future<T> _using<T>(
    HermesConfig config,
    Future<T> Function(HermesDesktopApiService service) operation, {
    HermesDesktopCredentialsWriter? onCredentialsChanged,
  }) async {
    final service = HermesDesktopApiService(
      config: config,
      onCredentialsChanged: onCredentialsChanged,
    );
    try {
      return await operation(service);
    } finally {
      service.close();
    }
  }
}
