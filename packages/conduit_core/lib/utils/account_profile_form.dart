/// Form rules of the account settings page (profile gender and birth date).
library;

/// The gender choices the account page offers. `''` is "prefer not to say";
/// [kProfileGenderCustom] reveals a free-text field.
const String kProfileGenderMale = 'male';
const String kProfileGenderFemale = 'female';
const String kProfileGenderCustom = 'custom';
const List<String> kProfileGenderChoices = <String>[
  '',
  kProfileGenderMale,
  kProfileGenderFemale,
  kProfileGenderCustom,
];

/// Splits a stored gender into the picker's choice and the custom text.
/// Anything other than empty, `male` or `female` is a custom gender.
({String choice, String custom}) splitProfileGender(String? value) {
  final normalized = value?.trim();
  if (normalized == null || normalized.isEmpty) {
    return (choice: '', custom: '');
  }
  if (normalized == kProfileGenderMale || normalized == kProfileGenderFemale) {
    return (choice: normalized, custom: '');
  }
  return (choice: kProfileGenderCustom, custom: normalized);
}

/// The gender to save for a picker [choice] and its [custom] text.
String resolveProfileGender(String choice, String custom) {
  return switch (choice) {
    kProfileGenderMale || kProfileGenderFemale => choice,
    kProfileGenderCustom => custom.trim(),
    _ => '',
  };
}

/// The earliest birth date the page accepts.
final DateTime kEarliestProfileBirthDate = DateTime(1900, 1, 1);

/// Parses a stored `YYYY-MM-DD` birth date; null when empty or invalid.
DateTime? parseProfileBirthDate(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  return DateTime.tryParse(trimmed);
}

/// Formats a birth date the way Open WebUI stores it (`YYYY-MM-DD`).
String formatProfileBirthDate(DateTime value) {
  final date = DateTime(value.year, value.month, value.day);
  return date.toIso8601String().split('T').first;
}

/// Keeps a birth date between [kEarliestProfileBirthDate] and [now]
/// (defaults to the current time).
DateTime clampProfileBirthDate(DateTime value, {DateTime? now}) {
  final maximum = now ?? DateTime.now();
  if (value.isBefore(kEarliestProfileBirthDate)) {
    return kEarliestProfileBirthDate;
  }
  if (value.isAfter(maximum)) return maximum;
  return value;
}
