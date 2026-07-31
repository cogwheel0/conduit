import '../../core/persistence/persistence_keys.dart';
import '../../core/persistence/preferences_store.dart';

/// Last public version before automatic release notes first ship in 4.0.1.
///
/// Existing installs have no release-note version marker yet, so this baseline
/// lets the normal semantic-version gate select the bundled 4.0.1 note without
/// making a fresh 4.0.1 install look like an update.
const releaseNotesLegacyBaselineVersion = '3.4.3';

/// Captures install provenance before onboarding can create the same markers.
///
/// This must run once, after legacy preferences have migrated and before
/// [runApp]. An install with no existing configuration is considered fresh;
/// installs with an Open WebUI server or an accountless backend are upgrades.
Future<void> captureReleaseNotesInstallProvenance() async {
  if (PreferencesStore.containsKey(
        PreferenceKeys.releaseNotesExistingInstallAtBootstrap,
      ) ||
      PreferencesStore.containsKey(PreferenceKeys.lastSeenReleaseVersion)) {
    return;
  }

  await PreferencesStore.put(
    PreferenceKeys.releaseNotesExistingInstallAtBootstrap,
    _hasExistingConfiguration(),
  );
}

String? releaseNotesPreviousVersionForEvaluation(String? lastSeenVersion) {
  final normalized = lastSeenVersion?.trim();
  if (normalized != null && normalized.isNotEmpty) {
    return normalized;
  }
  return PreferencesStore.getBool(
            PreferenceKeys.releaseNotesExistingInstallAtBootstrap,
          ) ==
          true
      ? releaseNotesLegacyBaselineVersion
      : null;
}

bool _hasExistingConfiguration() {
  final activeServerId = PreferencesStore.getString(
    PreferenceKeys.activeServerId,
  );
  final preferredBackend = PreferencesStore.getString(
    PreferenceKeys.preferredBackend,
  );
  return (activeServerId != null && activeServerId.trim().isNotEmpty) ||
      preferredBackend == 'owui' ||
      preferredBackend == 'direct' ||
      preferredBackend == 'hermes' ||
      PreferencesStore.getBool(PreferenceKeys.directConnectionsConfigured) ==
          true ||
      PreferencesStore.getBool(PreferenceKeys.hermesEnabled) == true;
}
