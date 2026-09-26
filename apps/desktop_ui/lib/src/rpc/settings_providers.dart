import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';

import '../theme_applier.dart';
import 'rpc_providers.dart';

/// Writes the palette to the document, overridden in `main.dart`.
final themeApplierProvider = Provider<ThemeApplierPort>(
  (ref) => RecordingThemeApplier(),
);

/// The app's own preferences, as the daemon has them stored.
final appPreferencesProvider = FutureProvider<AppPreferences>((ref) async {
  ref.watch(coreConnectionProvider);
  final preferences = await ref
      .read(rpcClientProvider)
      .call(ConduitMethods.settingsGetApp, decode: AppPreferences.fromJson);
  // Applied on the way through rather than from a separate listener. The
  // stored palette has to reach the document on the very first read, and a
  // listener that fires afterwards would show the default palette first --
  // which is the flash of wrong colours this whole attribute scheme avoids.
  ref
      .read(themeApplierProvider)
      .apply(
        paletteId: preferences.themePaletteId,
        mode: preferences.themeMode,
        uiFontSize: preferences.uiFontSize,
      );
  return preferences;
});

final settingsActionsProvider = Provider<SettingsActions>(
  (ref) => SettingsActions(ref),
);

class SettingsActions {
  SettingsActions(this._ref);

  final Ref _ref;

  /// Applies the patch locally first, then persists it.
  ///
  /// Optimistic on purpose, and only for this: a palette click should repaint
  /// now, not after a round trip to a local socket. The provider is still
  /// invalidated afterwards, so the daemon remains the source of truth and a
  /// rejected write corrects the document on the next read.
  Future<AppPreferences> update(AppPreferencesPatch patch) async {
    final current = _ref.read(appPreferencesProvider).value;
    if (current != null) {
      _ref
          .read(themeApplierProvider)
          .apply(
            paletteId: patch.themePaletteId ?? current.themePaletteId,
            mode: patch.themeMode ?? current.themeMode,
            uiFontSize: patch.uiFontSize ?? current.uiFontSize,
          );
    }

    final updated = await _ref
        .read(rpcClientProvider)
        .call(
          ConduitMethods.settingsSetApp,
          params: patch.toJson(),
          decode: AppPreferences.fromJson,
        );
    _ref.invalidate(appPreferencesProvider);
    return updated;
  }
}
