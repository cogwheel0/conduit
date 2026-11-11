import 'package:conduit/l10n/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'pages/librechat_memory_settings_pages.dart';
import 'pages/server_address_settings_pages.dart';
import 'pages/webhook_settings_pages.dart';

/// A group of Settings pages kept together: which pages it draws, how it
/// fills them in when they appear, and what their rows do.
///
/// The native sheet and the Flutter Settings pages draw a module's pages
/// alike; the hydration service asks the module to fill in a page it owns,
/// and the controller hands it the changes its rows send.
abstract class SettingsPageModule {
  /// Whether page [detailId] is one of this module's.
  bool ownsPage(String detailId);

  /// Fills in page [detailId] as it appears.
  Future<void> hydrate(String detailId, AppLocalizations l10n);

  /// Acts on a row change from one of this module's pages. Returns whether
  /// [id] was one of its rows.
  Future<bool> handleChange(String id, Object? value, AppLocalizations l10n);
}

final settingsPageModulesProvider = Provider<List<SettingsPageModule>>(
  (ref) => [
    WebhookSettingsPages(ref),
    LibreChatMemorySettingsPages(ref),
    ServerAddressSettingsPages(ref),
  ],
);
