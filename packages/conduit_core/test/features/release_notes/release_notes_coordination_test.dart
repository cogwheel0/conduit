import 'package:checks/checks.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/release_notes/models/release_note.dart';
import 'package:conduit_core/features/release_notes/release_notes_banner_controller.dart';
import 'package:conduit_core/features/release_notes/release_notes_coordination.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:conduit_core/providers/backend_mode_providers.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

ReleaseNote _note(String version) => ReleaseNote(
  version: version,
  title: 'Release $version',
  intro: 'Intro $version',
  bullets: ['Bullet $version'],
);

/// Records what the coordination logic asks the UI to do.
final class _Banner {
  final shown = <ReleaseNotesBannerData>[];
  var cleared = 0;

  void show(ReleaseNotesBannerData data) => shown.add(data);
  void clear() => cleared++;
}

void main() {
  late InMemoryKeyValueStore store;

  setUp(() {
    store = InMemoryKeyValueStore();
    PreferencesStore.debugOverride(store);
  });

  tearDown(PreferencesStore.debugReset);

  group('canPresentReleaseNotes', () {
    test('an authenticated session may always present', () {
      for (final backend in PreferredBackend.values) {
        check(
          canPresentReleaseNotes(AuthNavigationState.authenticated, backend),
        ).isTrue();
      }
    });

    test('Direct needs a configured connection', () async {
      check(
        canPresentReleaseNotes(
          AuthNavigationState.needsLogin,
          PreferredBackend.direct,
        ),
      ).isFalse();
      await store.setBool(PreferenceKeys.directConnectionsConfigured, true);
      check(
        canPresentReleaseNotes(
          AuthNavigationState.needsLogin,
          PreferredBackend.direct,
        ),
      ).isTrue();
    });

    test('Hermes needs the backend enabled', () async {
      check(
        canPresentReleaseNotes(
          AuthNavigationState.needsLogin,
          PreferredBackend.hermes,
        ),
      ).isFalse();
      await store.setBool(PreferenceKeys.hermesEnabled, true);
      check(
        canPresentReleaseNotes(
          AuthNavigationState.needsLogin,
          PreferredBackend.hermes,
        ),
      ).isTrue();
    });

    test('a signed-out Open WebUI or unset backend never presents', () async {
      await store.setBool(PreferenceKeys.directConnectionsConfigured, true);
      await store.setBool(PreferenceKeys.hermesEnabled, true);
      for (final backend in [PreferredBackend.owui, PreferredBackend.unset]) {
        check(canPresentReleaseNotes(AuthNavigationState.needsLogin, backend))
            .isFalse();
      }
    });
  });

  group('readReleaseNotesLastSeenVersion', () {
    test('is the stored version, trimmed', () async {
      await store.setString(PreferenceKeys.lastSeenReleaseVersion, ' 3.3.1 ');
      check(readReleaseNotesLastSeenVersion()).equals('3.3.1');
    });

    test('is null on a fresh install', () async {
      await store.setBool(
        PreferenceKeys.releaseNotesExistingInstallAtBootstrap,
        false,
      );
      check(readReleaseNotesLastSeenVersion()).isNull();
    });

    test(
      'is the legacy baseline for an install that predates the marker',
      () async {
        await store.setBool(
          PreferenceKeys.releaseNotesExistingInstallAtBootstrap,
          true,
        );
        check(readReleaseNotesLastSeenVersion()).equals('3.4.3');
      },
    );
  });

  group('applyReleaseNotesDecision', () {
    test('a fresh install records the version and shows nothing', () async {
      final banner = _Banner();

      await applyReleaseNotesDecision(
        currentVersion: '3.3.2',
        lastSeenVersion: null,
        notes: [_note('3.3.2')],
        isActive: () => true,
        showBanner: banner.show,
        clearBanner: banner.clear,
      );

      check(banner.shown).isEmpty();
      check(banner.cleared).equals(1);
      check(store.getString(PreferenceKeys.lastSeenReleaseVersion))
          .equals('3.3.2');
      check(store.containsKey(PreferenceKeys.releaseNotesBannerPreviousVersion))
          .isFalse();
    });

    test('an update shows the banner and remembers where it began', () async {
      final banner = _Banner();

      await applyReleaseNotesDecision(
        currentVersion: '3.3.2',
        lastSeenVersion: '3.3.1',
        notes: [_note('3.3.2'), _note('3.3.1')],
        isActive: () => true,
        showBanner: banner.show,
        clearBanner: banner.clear,
      );

      check(banner.shown).length.equals(1);
      check(banner.shown.single.currentVersion).equals('3.3.2');
      check(banner.shown.single.notes.map((note) => note.version))
          .deepEquals(['3.3.2']);
      check(store.getString(PreferenceKeys.releaseNotesBannerPreviousVersion))
          .equals('3.3.1');
      check(store.getString(PreferenceKeys.lastSeenReleaseVersion))
          .equals('3.3.2');
    });

    test(
      'an unmounted caller still records the version but not the banner',
      () async {
        final banner = _Banner();

        await applyReleaseNotesDecision(
          currentVersion: '3.3.2',
          lastSeenVersion: '3.3.1',
          notes: [_note('3.3.2')],
          isActive: () => false,
          showBanner: banner.show,
          clearBanner: banner.clear,
        );

        check(banner.shown).isEmpty();
        check(store.getString(PreferenceKeys.lastSeenReleaseVersion))
            .equals('3.3.2');
      },
    );

    test('a relaunch brings the banner back until it is dismissed', () async {
      await store.setString(PreferenceKeys.lastSeenReleaseVersion, '3.3.2');
      await store.setString(
        PreferenceKeys.releaseNotesBannerPreviousVersion,
        '3.3.1',
      );
      final banner = _Banner();

      await applyReleaseNotesDecision(
        currentVersion: '3.3.2',
        lastSeenVersion: '3.3.2',
        notes: [_note('3.3.2')],
        isActive: () => true,
        showBanner: banner.show,
        clearBanner: banner.clear,
      );

      check(banner.shown).length.equals(1);
      check(banner.cleared).equals(0);
      check(store.getString(PreferenceKeys.releaseNotesBannerPreviousVersion))
          .equals('3.3.1');
    });

    test('a relaunch with no pending banner clears any stale one', () async {
      final banner = _Banner();

      await applyReleaseNotesDecision(
        currentVersion: '3.3.2',
        lastSeenVersion: '3.3.2',
        notes: [_note('3.3.2')],
        isActive: () => true,
        showBanner: banner.show,
        clearBanner: banner.clear,
      );

      check(banner.shown).isEmpty();
      check(banner.cleared).equals(1);
    });

    test('a version without a bundled note clears the banner marker', () async {
      await store.setString(
        PreferenceKeys.releaseNotesBannerPreviousVersion,
        '3.3.0',
      );
      final banner = _Banner();

      await applyReleaseNotesDecision(
        currentVersion: '3.3.3',
        lastSeenVersion: '3.3.2',
        notes: [_note('3.3.2')],
        isActive: () => true,
        showBanner: banner.show,
        clearBanner: banner.clear,
      );

      check(banner.shown).isEmpty();
      check(banner.cleared).equals(1);
      check(store.containsKey(PreferenceKeys.releaseNotesBannerPreviousVersion))
          .isFalse();
      check(store.getString(PreferenceKeys.lastSeenReleaseVersion))
          .equals('3.3.3');
    });
  });

  group('releaseNotesBannerProvider', () {
    test('show and clear replace the banner data', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(releaseNotesBannerProvider.notifier);

      check(container.read(releaseNotesBannerProvider)).isNull();
      controller.show(
        ReleaseNotesBannerData(
          currentVersion: '3.3.2',
          notes: [_note('3.3.2')],
        ),
      );
      check(container.read(releaseNotesBannerProvider)).isNotNull();
      controller.clear();
      check(container.read(releaseNotesBannerProvider)).isNull();
    });

    test('dismiss clears the banner and forgets where it began', () async {
      await store.setString(
        PreferenceKeys.releaseNotesBannerPreviousVersion,
        '3.3.1',
      );
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(releaseNotesBannerProvider.notifier)
        ..show(
          ReleaseNotesBannerData(
            currentVersion: '3.3.2',
            notes: [_note('3.3.2')],
          ),
        );

      await controller.dismiss();

      check(container.read(releaseNotesBannerProvider)).isNull();
      check(store.containsKey(PreferenceKeys.releaseNotesBannerPreviousVersion))
          .isFalse();
    });
  });
}
