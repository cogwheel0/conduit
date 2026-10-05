import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/providers/backend_mode_providers.dart';

import 'models/release_note.dart';
import 'release_notes_banner_controller.dart';
import 'release_notes_bootstrap.dart';
import 'services/release_notes_service.dart';

/// Whether the release-notes flow may run now: a signed-in Open WebUI
/// session, or an accountless backend (Direct, Hermes) the user has set up.
bool canPresentReleaseNotes(
  AuthNavigationState authState,
  PreferredBackend preferredBackend,
) {
  if (authState == AuthNavigationState.authenticated) {
    return true;
  }
  return switch (preferredBackend) {
    PreferredBackend.direct =>
      PreferencesStore.getBool(PreferenceKeys.directConnectionsConfigured) ==
          true,
    PreferredBackend.hermes =>
      PreferencesStore.getBool(PreferenceKeys.hermesEnabled) == true,
    PreferredBackend.unset || PreferredBackend.owui => false,
  };
}

/// The version release notes are evaluated against: the last one the user
/// saw, or the legacy baseline for an install that predates the marker.
String? readReleaseNotesLastSeenVersion() {
  return releaseNotesPreviousVersionForEvaluation(
    PreferencesStore.getString(PreferenceKeys.lastSeenReleaseVersion),
  );
}

/// Decides what to do with the loaded [notes] and applies it: shows or
/// restores the banner, and records [currentVersion] as seen.
///
/// [isActive] reports whether the caller is still mounted; the banner is
/// left alone once it is not, and the preferences are written regardless.
Future<void> applyReleaseNotesDecision({
  required String currentVersion,
  required String? lastSeenVersion,
  required List<ReleaseNote> notes,
  required bool Function() isActive,
  required void Function(ReleaseNotesBannerData data) showBanner,
  required void Function() clearBanner,
  ReleaseNotesService service = const ReleaseNotesService(),
}) async {
  final decision = service.evaluate(
    currentVersion: currentVersion,
    lastSeenVersion: lastSeenVersion,
    notes: notes,
  );

  switch (decision.type) {
    case ReleaseNotesDecisionType.none:
      if (isActive()) {
        _restoreBanner(
          service: service,
          currentVersion: currentVersion,
          notes: notes,
          showBanner: showBanner,
          clearBanner: clearBanner,
        );
      }
    case ReleaseNotesDecisionType.persistOnly:
      await PreferencesStore.remove(
        PreferenceKeys.releaseNotesBannerPreviousVersion,
      );
      if (isActive()) clearBanner();
      await _markVersionSeen(decision.currentVersion);
    case ReleaseNotesDecisionType.show:
      final previousVersion = decision.previousVersion;
      if (previousVersion != null) {
        await PreferencesStore.put(
          PreferenceKeys.releaseNotesBannerPreviousVersion,
          previousVersion,
        );
        if (isActive()) {
          showBanner(
            ReleaseNotesBannerData(
              currentVersion: decision.currentVersion,
              notes: decision.notes,
            ),
          );
        }
      }
      await _markVersionSeen(decision.currentVersion);
  }
}

Future<void> _markVersionSeen(String version) {
  return PreferencesStore.put(PreferenceKeys.lastSeenReleaseVersion, version);
}

/// Brings the banner back after a relaunch, from the version the banner was
/// first shown for.
void _restoreBanner({
  required ReleaseNotesService service,
  required String currentVersion,
  required List<ReleaseNote> notes,
  required void Function(ReleaseNotesBannerData data) showBanner,
  required void Function() clearBanner,
}) {
  final previousVersion = PreferencesStore.getString(
    PreferenceKeys.releaseNotesBannerPreviousVersion,
  );
  final decision = service.evaluate(
    currentVersion: currentVersion,
    lastSeenVersion: previousVersion,
    notes: notes,
  );
  if (decision.type != ReleaseNotesDecisionType.show ||
      decision.previousVersion == null) {
    clearBanner();
    return;
  }
  showBanner(
    ReleaseNotesBannerData(
      currentVersion: decision.currentVersion,
      notes: decision.notes,
    ),
  );
}
