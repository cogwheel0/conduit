import 'package:conduit_core/utils/recency_sections.dart';
import 'package:intl/intl.dart';

import '../../../l10n/app_localizations.dart';

/// The header of a [RecencySection]: "Today", "Yesterday", "Previous 7 Days",
/// "Previous 30 Days", then the month ("September") in the year of [now], or
/// the month and year ("December 2025") before it, in [locale]'s own form.
String recencySectionLabel(
  RecencySection section,
  AppLocalizations l10n, {
  required String locale,
  required DateTime now,
}) {
  switch (section.kind) {
    case RecencySectionKind.today:
      return l10n.today;
    case RecencySectionKind.yesterday:
      return l10n.yesterday;
    case RecencySectionKind.previous7Days:
      return l10n.previous7Days;
    case RecencySectionKind.previous30Days:
      return l10n.previous30Days;
    case RecencySectionKind.month:
      final verified = Intl.verifiedLocale(
        locale,
        DateFormat.localeExists,
        onFailure: (_) => 'en',
      );
      final month = DateTime(section.year, section.month);
      final format = section.year == now.year
          // Stand-alone month, the nominative form languages such as
          // Russian and Polish use for a month on its own.
          ? DateFormat('LLLL', verified)
          : DateFormat.yMMMM(verified);
      return capitalizeFirstLetter(format.format(month));
  }
}

/// Month and weekday names are lowercase in many languages ("septiembre",
/// "mardi"), but a header or a list item starts with a capital, as iOS
/// writes them.
String capitalizeFirstLetter(String text) {
  if (text.isEmpty) return text;
  final first = text.runes.first;
  final head = String.fromCharCode(first);
  return '${head.toUpperCase()}${text.substring(head.length)}';
}
