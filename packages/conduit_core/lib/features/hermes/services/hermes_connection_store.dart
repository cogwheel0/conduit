import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_connection_profile.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';

/// Preference-backed storage for saved Hermes connections.
///
/// Reads are synchronous so the router and `HermesConfigController.build` can
/// resolve the active connection without waiting. Writes are checked: a write
/// the platform reports as failed throws instead of leaving an in-memory value
/// that would not survive a restart.
final class HermesConnectionStore {
  HermesConnectionStore._();

  /// Single-connection settings written before saved connections existed.
  static const List<String> _legacyConfigurationKeys = <String>[
    PreferenceKeys.hermesBaseUrl,
    PreferenceKeys.hermesBackendMode,
    PreferenceKeys.hermesDesktopAuthKind,
    PreferenceKeys.hermesDesktopProfile,
    PreferenceKeys.hermesAllowSelfSignedCertificates,
  ];

  /// Every single-connection preference, including the global trust principal
  /// that the first saved connection inherits.
  static const List<String> legacyKeys = <String>[
    ..._legacyConfigurationKeys,
    PreferenceKeys.hermesLocalDocumentTrustPrincipal,
  ];

  static HermesConnectionsDocument? readDocument() =>
      HermesConnectionsDocument.decode(
        PreferencesStore.getString(PreferenceKeys.hermesConnections),
      );

  static String? readActiveId() {
    final value = PreferencesStore.getString(
      PreferenceKeys.hermesActiveConnectionId,
    );
    return value != null && HermesConnectionProfile.isValidId(value)
        ? value
        : null;
  }

  static Future<void> writeDocument(HermesConnectionsDocument document) =>
      PreferencesStore.putChecked(
        PreferenceKeys.hermesConnections,
        document.encode(),
      );

  static Future<void> writeActiveId(String? id) =>
      PreferencesStore.putChecked(PreferenceKeys.hermesActiveConnectionId, id);

  /// Whether a single-connection configuration is still present. A lone trust
  /// principal is not a connection; it is created lazily even when Hermes was
  /// never set up.
  static bool hasLegacyConfiguration() =>
      _legacyConfigurationKeys.any(PreferencesStore.containsKey);

  static bool hasLegacyKeys() => legacyKeys.any(PreferencesStore.containsKey);

  /// Builds the first saved connection from the single-connection preferences.
  ///
  /// The legacy trust principal is carried over unchanged so mixed-chat
  /// session bindings and local document trust recorded before the upgrade
  /// still match this connection.
  static HermesConnectionProfile legacyProfile({required DateTime now}) {
    final baseUrl =
        PreferencesStore.getString(PreferenceKeys.hermesBaseUrl)?.trim() ?? '';
    final desktopProfile = PreferencesStore.getString(
      PreferenceKeys.hermesDesktopProfile,
    )?.trim();
    final principal = PreferencesStore.getString(
      PreferenceKeys.hermesLocalDocumentTrustPrincipal,
    )?.trim();
    return HermesConnectionProfile(
      id: HermesConnectionProfile.newId(),
      // Existing installs keep the name their single connection always had.
      name: kHermesDefaultConnectionName,
      baseUrl: baseUrl,
      mode: HermesBackendMode.values.firstWhere(
        (value) =>
            value.name ==
            PreferencesStore.getString(PreferenceKeys.hermesBackendMode),
        orElse: () => HermesBackendMode.responsesApi,
      ),
      desktopAuthKind: HermesDesktopAuthKind.values.firstWhere(
        (value) =>
            value.name ==
            PreferencesStore.getString(PreferenceKeys.hermesDesktopAuthKind),
        orElse: () => HermesDesktopAuthKind.legacyToken,
      ),
      desktopProfile:
          desktopProfile != null &&
              HermesConfig.isValidDesktopProfile(desktopProfile)
          ? desktopProfile
          : 'default',
      allowSelfSignedCertificates:
          PreferencesStore.getBool(
            PreferenceKeys.hermesAllowSelfSignedCertificates,
          ) ??
          false,
      documentTrustPrincipalId:
          principal != null &&
              HermesConnectionProfile.isValidPrincipalId(principal)
          ? principal
          : HermesConnectionProfile.newId(),
      lastUsedAt: now,
    );
  }

  /// Removes the single-connection preferences. Only called once the saved
  /// connection document that replaces them is durable.
  static Future<void> deleteLegacyKeys() async {
    for (final key in legacyKeys) {
      if (PreferencesStore.containsKey(key)) {
        await PreferencesStore.putChecked(key, null);
      }
    }
  }
}
