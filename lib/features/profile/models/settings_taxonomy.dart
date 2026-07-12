import '../../../l10n/app_localizations.dart';

/// Canonical settings categories shared by the native iOS sheet and the
/// Flutter settings page. Platform renderers may expose different leaf-page
/// granularity, but category membership and order must remain identical.
enum SettingsCategory {
  account,
  app,
  ai,
  server,
  support;

  String label(AppLocalizations l10n) => switch (this) {
    SettingsCategory.account => l10n.account,
    SettingsCategory.app => l10n.settingsCategoryApp,
    SettingsCategory.ai => l10n.settingsCategoryAi,
    SettingsCategory.server => l10n.settingsCategoryServer,
    SettingsCategory.support => l10n.settingsCategorySupport,
  };
}

/// Stable destination identities used to keep platform-specific settings
/// renderers in the same information architecture.
enum SettingsDestination {
  profile(SettingsCategory.account),
  appearance(SettingsCategory.app),
  chats(SettingsCategory.app),
  voice(SettingsCategory.app),
  notifications(SettingsCategory.app),
  personalization(SettingsCategory.ai),
  hermes(SettingsCategory.ai),
  workspace(SettingsCategory.server),
  dataConnection(SettingsCategory.server),
  connectOpenWebUi(SettingsCategory.server),
  about(SettingsCategory.support);

  const SettingsDestination(this.category);

  final SettingsCategory category;
}

List<SettingsCategory> settingsCategoriesFor(
  Iterable<SettingsDestination> destinations,
) {
  final populated = destinations
      .map((destination) => destination.category)
      .toSet();
  return [
    for (final category in SettingsCategory.values)
      if (populated.contains(category)) category,
  ];
}
