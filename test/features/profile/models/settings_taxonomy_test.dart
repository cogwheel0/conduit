import 'package:checks/checks.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conduit/features/profile/models/settings_taxonomy.dart';

void main() {
  test('settings destinations retain the shared category contract', () {
    check(
      SettingsDestination.profile.category,
    ).equals(SettingsCategory.account);
    check(SettingsDestination.appearance.category).equals(SettingsCategory.app);
    check(
      SettingsDestination.personalization.category,
    ).equals(SettingsCategory.ai);
    check(
      SettingsDestination.workspace.category,
    ).equals(SettingsCategory.server);
    check(SettingsDestination.about.category).equals(SettingsCategory.support);
  });

  test('populated categories follow canonical order and omit empty groups', () {
    final categories = settingsCategoriesFor([
      SettingsDestination.about,
      SettingsDestination.workspace,
      SettingsDestination.voice,
      SettingsDestination.profile,
      SettingsDestination.hermes,
    ]);

    check(categories).deepEquals(SettingsCategory.values);
    check(
      settingsCategoriesFor([SettingsDestination.hermes]),
    ).deepEquals([SettingsCategory.ai]);
  });
}
