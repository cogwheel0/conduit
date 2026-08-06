import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/app_localizations_pl.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Focused tests for the Polish (pl) localization added for
/// https://github.com/cogwheel0/conduit/issues/616.
void main() {
  group('Polish locale registration', () {
    test('pl is listed in the supported locales', () {
      final supported = AppLocalizations.supportedLocales;
      check(supported.map((loc) => loc.languageCode)).contains('pl');
    });

    test('device locales pl and pl_PL resolve to Polish without fallback', () {
      final delegate = AppLocalizations.delegate;
      check(delegate.isSupported(const Locale('pl'))).isTrue();
      check(delegate.isSupported(const Locale('pl', 'PL'))).isTrue();

      // The generated delegate maps both the bare language and the
      // language+country pair to the Polish bundle.
      check(lookupAppLocalizations(const Locale('pl')))
          .isA<AppLocalizationsPl>();
      check(lookupAppLocalizations(const Locale('pl', 'PL')))
          .isA<AppLocalizationsPl>();
    });

    test('the language selector label is the Polish endonym', () {
      final l10n = AppLocalizationsPl();
      check(l10n.polish).equals('Polski');
    });
  });

  group('Polish resource completeness', () {
    test('app_pl.arb mirrors every key from app_en.arb', () {
      final en = _readArbKeys('lib/l10n/app_en.arb');
      final pl = _readArbKeys('lib/l10n/app_pl.arb');
      check(pl.difference(en)).isEmpty();
      check(en.difference(pl)).isEmpty();
    });

    test('Polish placeholders match the template metadata', () {
      final en = _readArb('lib/l10n/app_en.arb');
      final pl = _readArb('lib/l10n/app_pl.arb');
      final enMeta = _placeholdersByKey(en);
      final plMeta = _placeholdersByKey(pl);
      for (final entry in enMeta.entries) {
        final plPlaceholders = plMeta[entry.key];
        check(plPlaceholders).isNotNull();
        // Normalize to a sorted, comma-joined string: Dart List/Set equality
        // is identity-based, and package:checks does not deep-compare here.
        final plJoined = (plPlaceholders!.toList()..sort()).join(',');
        final enJoined = (entry.value.toList()..sort()).join(',');
        check(plJoined).equals(enJoined);
      }
    });
  });

  group('Polish plural categories (one / few / many / other)', () {
    final l10n = AppLocalizationsPl();

    test('quickActionsSelectedCount follows CLDR Polish rules', () {
      check(l10n.quickActionsSelectedCount(0)).equals('Nie wybrano żadnych akcji');
      check(l10n.quickActionsSelectedCount(1)).equals('Wybrano 1 akcję');
      check(l10n.quickActionsSelectedCount(2)).equals('Wybrano 2 akcje');
      check(l10n.quickActionsSelectedCount(4)).equals('Wybrano 4 akcje');
      check(l10n.quickActionsSelectedCount(5)).equals('Wybrano 5 akcji');
      check(l10n.quickActionsSelectedCount(12)).equals('Wybrano 12 akcji');
      check(l10n.quickActionsSelectedCount(14)).equals('Wybrano 14 akcji');
      check(l10n.quickActionsSelectedCount(21)).equals('Wybrano 21 akcji');
      check(l10n.quickActionsSelectedCount(22)).equals('Wybrano 22 akcje');
      check(l10n.quickActionsSelectedCount(24)).equals('Wybrano 24 akcje');
      check(l10n.quickActionsSelectedCount(25)).equals('Wybrano 25 akcji');
      check(l10n.quickActionsSelectedCount(101)).equals('Wybrano 101 akcji');
      check(l10n.quickActionsSelectedCount(102)).equals('Wybrano 102 akcje');
      check(l10n.quickActionsSelectedCount(112)).equals('Wybrano 112 akcji');
    });

    test('usageTokenCount pluralizes the noun', () {
      check(l10n.usageTokenCount(1)).equals('1 token');
      check(l10n.usageTokenCount(2)).equals('2 tokeny');
      check(l10n.usageTokenCount(5)).equals('5 tokenów');
      check(l10n.usageTokenCount(22)).equals('22 tokeny');
    });

    test('wordCount pluralizes the noun', () {
      check(l10n.wordCount(1)).equals('1 słowo');
      check(l10n.wordCount(2)).equals('2 słowa');
      check(l10n.wordCount(5)).equals('5 słów');
    });

    test('deleteMessagesMessage agrees with the count', () {
      check(l10n.deleteMessagesMessage(1)).equals('Usunąć 1 wiadomość?');
      check(l10n.deleteMessagesMessage(2)).equals('Usunąć 2 wiadomości?');
      check(l10n.deleteMessagesMessage(5)).equals('Usunąć 5 wiadomości?');
      check(l10n.deleteMessagesMessage(22)).equals('Usunąć 22 wiadomości?');
      check(l10n.deleteMessagesMessage(112)).equals('Usunąć 112 wiadomości?');
    });

    test('channelMembers uses one/few/many', () {
      check(l10n.channelMembers(1)).equals('1 członek');
      check(l10n.channelMembers(2)).equals('2 członków');
      check(l10n.channelMembers(5)).equals('5 członków');
      check(l10n.channelMembers(22)).equals('22 członków');
    });

    test('accessibleModelsCount agrees with the count', () {
      check(l10n.accessibleModelsCount(1)).equals('1 dostępny model');
      check(l10n.accessibleModelsCount(2)).equals('2 dostępne modele');
      check(l10n.accessibleModelsCount(5)).equals('5 dostępnych modeli');
      check(l10n.accessibleModelsCount(22)).equals('22 dostępne modele');
    });

    test('savedMemoriesCount agrees with the count', () {
      check(l10n.savedMemoriesCount(1)).equals('1 zapisane wspomnienie');
      check(l10n.savedMemoriesCount(2)).equals('2 zapisane wspomnienia');
      check(l10n.savedMemoriesCount(5)).equals('5 zapisanych wspomnień');
    });

    test('hermesSchedulesSummary and direct probes stay grammatical', () {
      // active itself is a pluralized count: 1 aktywny / 2 aktywne / 5 aktywnych.
      check(l10n.hermesSchedulesSummary(1, 1)).equals('1 aktywny · 1 harmonogram');
      check(l10n.hermesSchedulesSummary(1, 5)).equals('1 aktywny · 5 harmonogramów');
      check(l10n.hermesSchedulesSummary(2, 3)).equals('2 aktywne · 3 harmonogramy');
      check(l10n.hermesSchedulesSummary(5, 22)).equals('5 aktywnych · 22 harmonogramy');
      check(l10n.directConnectionProbeConnectedModels(1))
          .contains('1 model');
      check(l10n.directConnectionProbeConnectedModels(3))
          .contains('3 modele');
      check(l10n.directConnectionProbeConnectedModels(5))
          .contains('5 modeli');
    });
  });
}

Map<String, dynamic> _readArb(String path) {
  return json.decode(File(path).readAsStringSync()) as Map<String, dynamic>;
}

Set<String> _readArbKeys(String path) {
  return _readArb(path)
      .keys
      .where((k) => !k.startsWith('@'))
      .toSet();
}

Map<String, Set<String>> _placeholdersByKey(Map<String, dynamic> arb) {
  final result = <String, Set<String>>{};
  for (final entry in arb.entries) {
    if (!entry.key.startsWith('@')) continue;
    final meta = entry.value;
    if (meta is! Map<String, dynamic>) continue;
    final placeholders = meta['placeholders'];
    if (placeholders is! Map<String, dynamic>) continue;
    result[entry.key.substring(1)] = placeholders.keys.toSet();
  }
  return result;
}
