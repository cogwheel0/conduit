import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';

import '../../l10n/app_localizations.dart';

/// Locale-aware formatting for changing values shown throughout the app.
abstract final class LocaleDisplayFormatters {
  static String _locale(BuildContext context) =>
      Localizations.localeOf(context).toLanguageTag();

  static String integer(BuildContext context, num value) =>
      NumberFormat.decimalPattern(_locale(context)).format(value);

  static String compact(BuildContext context, num value) =>
      NumberFormat.compact(locale: _locale(context)).format(value);

  static String percentage(
    BuildContext context,
    num value, {
    int decimalDigits = 0,
  }) {
    final formatter = NumberFormat.percentPattern(_locale(context))
      ..minimumFractionDigits = decimalDigits
      ..maximumFractionDigits = decimalDigits;
    return formatter.format(value);
  }

  static String bytes(BuildContext context, int value) {
    const units = <String>['B', 'KB', 'MB', 'GB', 'TB'];
    var amount = value.toDouble();
    var unit = 0;
    while (amount.abs() >= 1024 && unit < units.length - 1) {
      amount /= 1024;
      unit++;
    }
    final formatter = NumberFormat.decimalPatternDigits(
      locale: _locale(context),
      decimalDigits: unit == 0 || amount.abs() >= 10 ? 0 : 1,
    );
    return '${formatter.format(amount)} ${units[unit]}';
  }

  static String shortDate(BuildContext context, DateTime value) =>
      DateFormat.MMMd(_locale(context)).format(value);

  static String compactRelativeTime(BuildContext context, DateTime value) {
    final l10n = AppLocalizations.of(context)!;
    final difference = DateTime.now().difference(value);
    if (difference.isNegative || difference.inSeconds < 10) {
      return l10n.timeJustNow;
    }
    if (difference.inMinutes < 1) {
      return l10n.timeSecondsAgo(difference.inSeconds);
    }
    if (difference.inHours < 1) {
      return l10n.timeMinutesAgo(difference.inMinutes);
    }
    if (difference.inHours < 24) {
      return l10n.timeHoursAgo(difference.inHours);
    }
    return shortDate(context, value);
  }
}
