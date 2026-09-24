/// The `variables` Open WebUI substitutes into a model's system prompt:
/// `{{USER_NAME}}`, `{{CURRENT_DATE}}` and the rest, with the same
/// fallbacks and formats its own web client sends.
library;

String _two(int value) => value.toString().padLeft(2, '0');

/// `YYYY-MM-DD`.
String formatOpenWebUiDate(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-${_two(value.month)}-'
    '${_two(value.day)}';

/// `HH:MM:SS`, 24-hour.
String formatOpenWebUiTime(DateTime value) =>
    '${_two(value.hour)}:${_two(value.minute)}:${_two(value.second)}';

String openWebUiWeekday(DateTime value) => const <String>[
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
][value.weekday - 1];

/// The map sent as a completion request's `variables`.
Map<String, dynamic> buildOpenWebUiPromptVariables({
  required DateTime now,
  required String userName,
  required String userEmail,
  required String userLanguage,
  String? userLocation,
}) {
  String or(String? value, String fallback) =>
      value != null && value.trim().isNotEmpty ? value.trim() : fallback;
  final date = formatOpenWebUiDate(now);
  final time = formatOpenWebUiTime(now);
  return <String, dynamic>{
    '{{USER_NAME}}': or(userName, 'User'),
    '{{USER_EMAIL}}': or(userEmail, 'Unknown'),
    '{{USER_LOCATION}}': or(userLocation, 'Unknown'),
    '{{CURRENT_DATETIME}}': '$date $time',
    '{{CURRENT_DATE}}': date,
    '{{CURRENT_TIME}}': time,
    '{{CURRENT_WEEKDAY}}': openWebUiWeekday(now),
    '{{CURRENT_TIMEZONE}}': now.timeZoneName,
    '{{USER_LANGUAGE}}': or(userLanguage, 'en-US'),
  };
}

/// What the account's `userLocation` setting asks for.
class UserLocationSetting {
  const UserLocationSetting({
    this.autoRefreshEnabled = false,
    this.legacyLocation,
  });

  /// Look the location up from the device, and keep the account's copy of
  /// it current.
  final bool autoRefreshEnabled;

  /// A fixed location the user typed, from before the toggle existed.
  final String? legacyLocation;
}

/// Reads `userLocation` from Open WebUI user settings, at the root or under
/// `ui`: a flag, one of the words Open WebUI has used for on and off, or a
/// place the user typed.
UserLocationSetting extractUserLocationSetting(
  Map<String, dynamic>? userSettings,
) {
  final ui = userSettings?['ui'];
  final raw = (userSettings?.containsKey('userLocation') ?? false)
      ? userSettings!['userLocation']
      : (ui is Map ? ui['userLocation'] : null);
  if (raw is bool) return UserLocationSetting(autoRefreshEnabled: raw);
  if (raw is num) return UserLocationSetting(autoRefreshEnabled: raw != 0);
  final text = raw is String ? raw.trim() : null;
  if (text == null || text.isEmpty) return const UserLocationSetting();
  return switch (text.toLowerCase()) {
    'always' ||
    'enabled' ||
    'on' ||
    'true' ||
    '1' ||
    'yes' => const UserLocationSetting(autoRefreshEnabled: true),
    'disabled' || 'off' || 'false' || '0' || 'no' => const UserLocationSetting(),
    _ => UserLocationSetting(legacyLocation: text),
  };
}

/// Coordinates as Open WebUI's client writes them into the account.
String formatUserLocationCoordinates({
  required double latitude,
  required double longitude,
}) =>
    '${latitude.toStringAsFixed(3)}, ${longitude.toStringAsFixed(3)} '
    '(lat, long)';
