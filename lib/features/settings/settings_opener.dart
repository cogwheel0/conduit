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

/// Where Command-comma opens Settings: the same native sheet as the account
/// button wherever that button can present it, else the Flutter pages.
SettingsDestination settingsShortcutDestination({
  required bool nativeSheetAvailable,
}) => nativeSheetAvailable
    ? SettingsDestination.nativeSheet
    : SettingsDestination.flutterPages;

/// The account button's own way of opening Settings, while it is on screen,
/// so a keyboard shortcut opens the very same sheet.
final class SettingsOpener {
  Future<void> Function()? _open;

  /// How Settings opens now, if the account button is on screen.
  Future<void> Function()? get open => _open;

  void register(Future<void> Function() open) => _open = open;

  void unregister(Future<void> Function() open) {
    if (identical(_open, open)) _open = null;
  }
}

final settingsOpenerProvider = Provider<SettingsOpener>(
  (_) => SettingsOpener(),
);
