import 'package:checks/checks.dart';
import 'package:conduit_core/providers/host_ports.dart';
import 'package:conduit/shared/theme/theme_providers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod/riverpod.dart';

/// The core resets its own state on a full sign-out, but theme and locale
/// live in the app — they resolve to `ThemeData` and `Locale`, which the
/// sidecar and the desktop renderer cannot name. `app_providers` used to
/// reach up and invalidate them by name, and that single import pulled the
/// whole theme and localisation tree into the core's dependency closure.
///
/// The host registers them instead. What these tests cover is the list and
/// the mechanics: adding a persisted preference without listing it fails
/// here, and the seam is shown to accept something `invalidate` really takes.
///
/// What they do not cover is the single `overrideWithValue` in `main.dart`.
/// Deleting that line would stop theme and locale being cleared on sign-out
/// and nothing here would notice, because the app's container is built
/// during startup and is not reachable from a unit test. That gap is worth
/// knowing about rather than papering over with a source-text assertion.
void main() {
  test('the core registers nothing by default', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    // A daemon has no theme to reset, and that is a coherent answer rather
    // than a missing binding.
    check(container.read(signOutResetTargetsProvider)).isEmpty();
  });

  test('the app registers its persisted preferences', () {
    // main.dart passes exactly this list. If a preference is added to the
    // theme library without being listed, it silently stops being cleared on
    // sign-out, which is why the list is asserted rather than its length.
    check(themePreferenceResetTargets).deepEquals([
      appThemeModeProvider,
      appThemePaletteProvider,
      appLocaleProvider,
    ]);
  });

  test('a registered target is invalidated through the seam', () {
    var builds = 0;
    final counted = Provider<int>((ref) => ++builds);
    final container = ProviderContainer(
      overrides: [
        signOutResetTargetsProvider.overrideWithValue([counted]),
      ],
    );
    addTearDown(container.dispose);

    check(container.read(counted)).equals(1);
    for (final target in container.read(signOutResetTargetsProvider)) {
      container.invalidate(target);
    }

    // Proves the registered provider really is reachable as something
    // `invalidate` accepts, which is the only thing the seam promises.
    check(container.read(counted)).equals(2);
  });
}
