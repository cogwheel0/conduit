import 'dart:async';

import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/services/optimized_storage_service.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:riverpod/riverpod.dart';

/// Implements the app half of `settings.*`.
///
/// Reads and writes the same `PreferencesStore` keys the mobile app uses, so
/// the two front-ends agree on what a stored value means rather than each
/// inventing its own spelling of "dark".
final class SettingsService {
  SettingsService(this._container);

  final ProviderContainer _container;

  OptimizedStorageService get _storage =>
      _container.read(optimizedStorageServiceProvider);

  AppPreferences read() => AppPreferences(
    themeMode: _parseThemeMode(_storage.getThemeMode()),
    // The protocol's own default rather than a literal, so changing the
    // default is one edit in one place.
    themePaletteId:
        _storage.getThemePaletteId() ?? const AppPreferences().themePaletteId,
    uiFontSize: (PreferencesStore.getInt(_uiFontSizeKey) ?? kDefaultUiFontSize)
        .clamp(kMinUiFontSize, kMaxUiFontSize),
    localeCode: _storage.getLocaleCode(),
  );

  Future<AppPreferences> write(AppPreferencesPatch patch) async {
    if (patch.themeMode case final mode?) {
      await _storage.setThemeMode(mode.name);
    }
    if (patch.themePaletteId case final palette?) {
      await _storage.setThemePaletteId(palette);
    }
    if (patch.uiFontSize case final size?) {
      await PreferencesStore.put(
        _uiFontSizeKey,
        size.clamp(kMinUiFontSize, kMaxUiFontSize),
      );
    }
    // Order matters only here: clearing wins over setting, so a caller that
    // sends both gets "follow the system" rather than a silent coin toss.
    if (patch.clearLocaleCode) {
      await _storage.setLocaleCode(null);
    } else if (patch.localeCode case final locale?) {
      await _storage.setLocaleCode(locale);
    }
    return read();
  }

  /// Mobile persists `ThemeMode.name`, so the stored strings are already
  /// `light`, `dark` and `system`. An unrecognised value -- a newer build's
  /// mode, or a corrupted preference -- falls back rather than throwing: a
  /// bad theme preference must not stop the app from starting.
  static AppThemeMode _parseThemeMode(String? raw) => switch (raw) {
    'light' => AppThemeMode.light,
    'dark' => AppThemeMode.dark,
    _ => AppThemeMode.system,
  };

  /// Desktop only: the phone app has its own text scaling.
  static const String _uiFontSizeKey = 'desktop.uiFontSize';
}
