import 'package:conduit_core/utils/recency_sections.dart';
import 'package:flutter/foundation.dart' show immutable;
import 'package:intl/intl.dart';

import '../../../l10n/app_localizations.dart';
import 'recency_section_label.dart' show capitalizeFirstLetter;

/// What a sidebar row shows after its title, and what VoiceOver says for it.
@immutable
class RecencyStamp {
  const RecencyStamp({required this.text, required this.spoken});

  /// The stamp as drawn: "9:41 AM", "Yesterday", "Tuesday" or "11/2/26".
  final String text;

  /// The stamp as read aloud. A short numeric date is spelled out
  /// ("November 2, 2026") so VoiceOver does not read its slashes.
  final String spoken;

  @override
  bool operator ==(Object other) =>
      other is RecencyStamp && other.text == text && other.spoken == spoken;

  @override
  int get hashCode => Object.hash(text, spoken);

  @override
  String toString() => 'RecencyStamp($text, $spoken)';
}

/// The stamp a chat or note row shows for [timestamp] when it is [now], as
/// Mail dates its messages: the time for today, in the 12 or 24 hour style
/// of [use24HourTime]; "Yesterday"; the weekday within the last week; else
/// the short date of [locale].
RecencyStamp recencyStampLabel(
  DateTime timestamp,
  AppLocalizations l10n, {
  required String locale,
  required DateTime now,
  required bool use24HourTime,
}) {
  final verified = Intl.verifiedLocale(
    locale,
    DateFormat.localeExists,
    onFailure: (_) => 'en',
  );
  final zoned = now.isUtc ? timestamp.toUtc() : timestamp.toLocal();
  switch (recencyStampKindFor(timestamp, now: now)) {
    case RecencyStampKind.time:
      final text =
          (use24HourTime ? DateFormat.Hm(verified) : DateFormat.jm(verified))
              .format(zoned);
      return RecencyStamp(text: text, spoken: text);
    case RecencyStampKind.yesterday:
      return RecencyStamp(text: l10n.yesterday, spoken: l10n.yesterday);
    case RecencyStampKind.weekday:
      // Stand-alone weekday, capitalised as a list item starts in every
      // language ("Mardi", not "mardi").
      final text = capitalizeFirstLetter(
        DateFormat('cccc', verified).format(zoned),
      );
      return RecencyStamp(text: text, spoken: text);
    case RecencyStampKind.date:
      // The locale's short date style ("11/2/26", "02.11.26"), which is what
      // iOS lists use; the skeleton forms always spell the year in full.
      final shortPattern = DateFormat(
        null,
        verified,
      ).dateSymbols.DATEFORMATS[3];
      return RecencyStamp(
        text: DateFormat(shortPattern, verified).format(zoned),
        spoken: DateFormat.yMMMMd(verified).format(zoned),
      );
  }
}
