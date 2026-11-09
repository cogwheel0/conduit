import 'package:meta/meta.dart';

/// The kinds of date section a recency-ordered list (chats, notes) groups
/// its items into, newest first.
enum RecencySectionKind { today, yesterday, previous7Days, previous30Days, month }

/// One date section of a recency-ordered list, as Notes groups its list:
/// Today, Yesterday, Previous 7 Days, Previous 30 Days, then each earlier
/// calendar month.
///
/// Sections compare newest first, so sorting them gives list order.
@immutable
final class RecencySection implements Comparable<RecencySection> {
  const RecencySection._(this.kind, [this.year = 0, this.month = 0]);

  /// The current calendar day.
  static const today = RecencySection._(RecencySectionKind.today);

  /// The calendar day before today.
  static const yesterday = RecencySection._(RecencySectionKind.yesterday);

  /// Two to seven calendar days ago.
  static const previous7Days = RecencySection._(
    RecencySectionKind.previous7Days,
  );

  /// Eight to thirty calendar days ago.
  static const previous30Days = RecencySection._(
    RecencySectionKind.previous30Days,
  );

  /// A calendar [month] (1-12) of [year], for anything older than 30 days.
  RecencySection.month(int year, int month)
    : this._(RecencySectionKind.month, year, _checkMonth(month));

  static int _checkMonth(int month) {
    RangeError.checkValueInInterval(month, 1, 12, 'month');
    return month;
  }

  final RecencySectionKind kind;

  /// The year of a [RecencySectionKind.month] section; 0 otherwise.
  final int year;

  /// The month (1-12) of a [RecencySectionKind.month] section; 0 otherwise.
  final int month;

  bool get isMonth => kind == RecencySectionKind.month;

  @override
  int compareTo(RecencySection other) {
    final byKind = kind.index.compareTo(other.kind.index);
    if (byKind != 0) return byKind;
    // Both are months: the later month comes first.
    final byYear = other.year.compareTo(year);
    if (byYear != 0) return byYear;
    return other.month.compareTo(month);
  }

  @override
  bool operator ==(Object other) =>
      other is RecencySection &&
      other.kind == kind &&
      other.year == year &&
      other.month == month;

  @override
  int get hashCode => Object.hash(kind, year, month);

  @override
  String toString() => isMonth
      ? 'RecencySection.month($year, $month)'
      : 'RecencySection.${kind.name}';
}

/// The section [timestamp] falls in when it is [now].
///
/// Days are calendar days in the time zone of [now]: the device's local zone
/// for a local [now], UTC for a UTC one. [timestamp] is converted into that
/// zone first, so a UTC instant from a server lands on the user's local day.
/// Day counts ignore daylight-saving shifts (a 23 or 25 hour day is still one
/// day). A [timestamp] later than [now], from clock skew, counts as today.
RecencySection recencySectionFor(DateTime timestamp, {required DateTime now}) {
  final zoned = now.isUtc ? timestamp.toUtc() : timestamp.toLocal();
  final days = calendarDaysBetween(zoned, now);
  if (days <= 0) return RecencySection.today;
  if (days == 1) return RecencySection.yesterday;
  if (days <= 7) return RecencySection.previous7Days;
  if (days <= 30) return RecencySection.previous30Days;
  return RecencySection.month(zoned.year, zoned.month);
}

/// How a list row dates its item after the title, as Mail dates a message:
/// the time of day for today, "Yesterday", the weekday within the last
/// week, else the date.
enum RecencyStampKind { time, yesterday, weekday, date }

/// The stamp a row shows for [timestamp] when it is [now].
///
/// Days are calendar days in the zone of [now], as [recencySectionFor]
/// counts them. Two to six days ago is a weekday; from seven days the name
/// would repeat today's, so the date is shown instead. A [timestamp] later
/// than [now], from clock skew, counts as today.
RecencyStampKind recencyStampKindFor(
  DateTime timestamp, {
  required DateTime now,
}) {
  final zoned = now.isUtc ? timestamp.toUtc() : timestamp.toLocal();
  final days = calendarDaysBetween(zoned, now);
  if (days <= 0) return RecencyStampKind.time;
  if (days == 1) return RecencyStampKind.yesterday;
  if (days < 7) return RecencyStampKind.weekday;
  return RecencyStampKind.date;
}

/// Whole calendar days from [from]'s date to [to]'s date, each read in its
/// own zone; negative when [from] is later.
@visibleForTesting
int calendarDaysBetween(DateTime from, DateTime to) => DateTime.utc(
  to.year,
  to.month,
  to.day,
).difference(DateTime.utc(from.year, from.month, from.day)).inDays;

/// A date section and the items in it.
typedef RecencyGroup<T> = ({RecencySection section, List<T> items});

/// [items] grouped by [recencySectionFor] their [timestampOf], newest section
/// first. Each section keeps the items in their given order, and sections
/// without items are left out.
List<RecencyGroup<T>> groupByRecency<T>(
  Iterable<T> items, {
  required DateTime Function(T item) timestampOf,
  required DateTime now,
}) {
  final grouped = <RecencySection, List<T>>{};
  for (final item in items) {
    final section = recencySectionFor(timestampOf(item), now: now);
    grouped.putIfAbsent(section, () => <T>[]).add(item);
  }
  final sections = grouped.keys.toList()..sort();
  return [
    for (final section in sections)
      (section: section, items: List<T>.unmodifiable(grouped[section]!)),
  ];
}
