/// Theme and locale selection for the mobile app.
///
/// These left `app_providers.dart` because they are the one group of
/// providers there that is genuinely presentation: they resolve to
/// `ThemeData`, `CupertinoThemeData` and `Locale`, none of which the
/// `conduitd` sidecar or the desktop renderer can name. Everything else in
/// that file is business logic on its way into `conduit_core`.
///
/// The persisted values still come from the core's storage service; only the
/// decision about what to render is here.
library;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:conduit_core/providers/storage_providers.dart';

import 'package:conduit_core/services/optimized_storage_service.dart';

import 'app_theme.dart';
import 'tweakcn_themes.dart';

part 'theme_providers.g.dart';

// Theme provider
@Riverpod(keepAlive: true)
class AppThemeMode extends _$AppThemeMode {
  // Notifier instances survive invalidation, so build() can run more than once.
  late OptimizedStorageService _storage;

  @override
  ThemeMode build() {
    _storage = ref.watch(optimizedStorageServiceProvider);
    final storedMode = _storage.getThemeMode();
    if (storedMode != null) {
      return ThemeMode.values.firstWhere(
        (e) => e.toString() == storedMode,
        orElse: () => ThemeMode.system,
      );
    }
    return ThemeMode.system;
  }

  void setTheme(ThemeMode mode) {
    state = mode;
    _storage.setThemeMode(mode.toString());
  }
}

@Riverpod(keepAlive: true)
class AppThemePalette extends _$AppThemePalette {
  // Notifier instances survive invalidation, so build() can run more than once.
  late OptimizedStorageService _storage;

  @override
  TweakcnThemeDefinition build() {
    _storage = ref.watch(optimizedStorageServiceProvider);
    final storedId = _storage.getThemePaletteId();
    return TweakcnThemes.byId(storedId);
  }

  Future<void> setPalette(String paletteId) async {
    final palette = TweakcnThemes.byId(paletteId);
    state = palette;
    await _storage.setThemePaletteId(palette.id);
  }
}

@Riverpod(keepAlive: true)
class AppLightTheme extends _$AppLightTheme {
  @override
  ThemeData build() {
    final palette = ref.watch(appThemePaletteProvider);
    return AppTheme.light(palette);
  }
}

@Riverpod(keepAlive: true)
class AppDarkTheme extends _$AppDarkTheme {
  @override
  ThemeData build() {
    final palette = ref.watch(appThemePaletteProvider);
    return AppTheme.dark(palette);
  }
}

@Riverpod(keepAlive: true)
class AppCupertinoLightTheme extends _$AppCupertinoLightTheme {
  @override
  CupertinoThemeData build() {
    final palette = ref.watch(appThemePaletteProvider);
    return AppTheme.cupertinoLight(palette);
  }
}

@Riverpod(keepAlive: true)
class AppCupertinoDarkTheme extends _$AppCupertinoDarkTheme {
  @override
  CupertinoThemeData build() {
    final palette = ref.watch(appThemePaletteProvider);
    return AppTheme.cupertinoDark(palette);
  }
}

// Locale provider
@Riverpod(keepAlive: true)
class AppLocale extends _$AppLocale {
  // Notifier instances survive invalidation, so build() can run more than once.
  late OptimizedStorageService _storage;

  @override
  Locale? build() {
    _storage = ref.watch(optimizedStorageServiceProvider);
    final code = _storage.getLocaleCode();
    if (code != null && code.isNotEmpty) {
      final parsed = _parseLocaleCode(code);
      if (parsed != null) return parsed;
    }
    return null; // system default
  }

  Future<void> setLocale(Locale? locale) async {
    state = locale;
    await _storage.setLocaleCode(locale?.toLanguageTag());
  }

  Locale? _parseLocaleCode(String code) {
    final normalized = code.replaceAll('_', '-');
    final parts = normalized.split('-');
    if (parts.isEmpty || parts.first.isEmpty) return null;

    final language = parts.first;
    String? script;
    String? country;

    for (var i = 1; i < parts.length; i++) {
      final part = parts[i];
      if (part.length == 4) {
        script = '${part[0].toUpperCase()}${part.substring(1).toLowerCase()}';
      } else if (part.length == 2 || part.length == 3) {
        country = part.toUpperCase();
      }
    }

    return Locale.fromSubtags(
      languageCode: language,
      scriptCode: script,
      countryCode: country,
    );
  }
}

/// The preference providers a full sign-out must reset.
///
/// Registered with `signOutResetTargetsProvider` in `main.dart`. They are
/// listed here, beside the providers themselves, so adding a new persisted
/// preference has one obvious place to be remembered.
final List<ProviderOrFamily> themePreferenceResetTargets = <ProviderOrFamily>[
  appThemeModeProvider,
  appThemePaletteProvider,
  appLocaleProvider,
];
