import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Where a request to open Settings goes.
enum SettingsDestination {
  /// The native Settings sheet, as the account button opens it: one column
  /// on iPhone, two on iPad.
  nativeSheet,

  /// The Flutter Settings pages: Android, and iOS when the sheet cannot be
  /// presented.
  flutterPages,
}

/// Where Command-comma opens Settings: the native sheet wherever iOS can
/// present it, as the account button opens it, else the Flutter pages.
SettingsDestination settingsShortcutDestination({
  required bool nativeSheetAvailable,
}) => nativeSheetAvailable
    ? SettingsDestination.nativeSheet
    : SettingsDestination.flutterPages;

/// The app's way of opening Settings, registered at its root, so the account
/// button, Command-comma and any other entry open the very same sheet
/// whatever is on screen.
final class SettingsOpener {
  Future<void> Function()? _open;

  /// How Settings opens, once the app has registered it.
  Future<void> Function()? get open => _open;

  void register(Future<void> Function() open) => _open = open;

  void unregister(Future<void> Function() open) {
    if (identical(_open, open)) _open = null;
  }
}

final settingsOpenerProvider = Provider<SettingsOpener>(
  (_) => SettingsOpener(),
);
