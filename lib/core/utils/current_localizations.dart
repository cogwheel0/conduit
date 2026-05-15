import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:hive_ce/hive.dart';

import 'package:conduit/core/persistence/hive_boxes.dart';
import 'package:conduit/core/persistence/persistence_keys.dart';
import 'package:conduit/l10n/app_localizations.dart';

AppLocalizations currentAppLocalizations() {
  final configuredLocale = _configuredAppLocale();
  if (configuredLocale != null) {
    final resolved = _resolveSupportedLocale([configuredLocale]);
    if (resolved != null) return lookupAppLocalizations(resolved);
  }

  final resolved = _resolveSupportedLocale(
    ui.PlatformDispatcher.instance.locales,
  );
  if (resolved != null) return lookupAppLocalizations(resolved);

  return lookupAppLocalizations(const Locale('en'));
}

Locale? _configuredAppLocale() {
  try {
    if (!Hive.isBoxOpen(HiveBoxNames.preferences)) return null;
    final code =
        Hive.box<dynamic>(
              HiveBoxNames.preferences,
            ).get(PreferenceKeys.localeCode)
            as String?;
    if (code == null || code.isEmpty) return null;
    return _parseLocaleTag(code);
  } catch (_) {
    return null;
  }
}

Locale? _parseLocaleTag(String code) {
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

Locale? _resolveSupportedLocale(List<Locale>? locales) {
  if (locales == null || locales.isEmpty) return null;
  final supported = AppLocalizations.supportedLocales;

  for (final device in locales) {
    final prefersTraditional = _prefersTraditionalChinese(device);
    final deviceLanguage = device.languageCode.toLowerCase();
    final deviceScript = device.scriptCode?.toLowerCase();
    final deviceCountry = device.countryCode?.toUpperCase();

    for (final loc in supported) {
      if (loc.languageCode.toLowerCase() != deviceLanguage) continue;
      final locScript = loc.scriptCode?.toLowerCase();
      final scriptMatches =
          locScript != null &&
          locScript.isNotEmpty &&
          (locScript == deviceScript ||
              (loc.languageCode == 'zh' &&
                  locScript == 'hant' &&
                  prefersTraditional));
      if (!scriptMatches) continue;

      final locCountry = loc.countryCode?.toUpperCase();
      final countryMatches =
          locCountry == null ||
          locCountry.isEmpty ||
          locCountry == deviceCountry;
      if (countryMatches) return loc;
    }

    if (prefersTraditional) {
      for (final loc in supported) {
        if (loc.languageCode == 'zh' && loc.scriptCode == 'Hant') return loc;
      }
    }

    for (final loc in supported) {
      if (loc.languageCode.toLowerCase() == deviceLanguage) return loc;
    }
  }

  return null;
}

bool _prefersTraditionalChinese(Locale locale) {
  final script = locale.scriptCode?.toLowerCase();
  if (script == 'hant') return true;

  final country = locale.countryCode?.toUpperCase();
  return country == 'TW' || country == 'HK' || country == 'MO';
}
