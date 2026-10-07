import 'package:conduit/core/router/app_router.dart'
    show usesNoTransitionForNativeSheet;
import 'package:conduit/core/services/native_sheet_bridge.dart';
import 'package:conduit/core/utils/native_sheet_utils.dart';
import 'package:conduit/features/navigation/widgets/sidebar_user_pill.dart'
    show nativeProfileSheetFieldsDiffer;
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/services/navigation_service.dart'
    show RouteNames, accountsNativeSheetNavigationRequest;
import 'package:conduit_core/models/account_metadata.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';

final _l10n = lookupAppLocalizations(const Locale('en'));

const _account = NativeProfileRootAccount(
  displayName: 'Ada',
  email: 'ada@example.com',
);

const _everything = NativeProfileRootVisibility(
  showCalendar: true,
  canManageWorkspace: true,
  showScheduledTasks: true,
  showPersonalConnections: true,
  showChatDataControls: true,
);

List<List<String>> _ids(List<NativeSheetSectionConfig> sections) => [
  for (final section in sections) [for (final item in section.items) item.id],
];

NativeSheetItemConfig _item(
  List<NativeSheetSectionConfig> sections,
  String id,
) => sections
    .expand((section) => section.items)
    .singleWhere((item) => item.id == id);

void main() {
  group('native Settings root', () {
    test('groups rows in the Flutter Settings order', () {
      final sections = buildNativeProfileRootSections(
        _l10n,
        account: _account,
        visibility: _everything,
      );

      expect(_ids(sections), [
        [NativeSheetRoutes.profile],
        [nativeAccountAddActionId],
        [
          NativeSheetRoutes.appearance,
          NativeSheetRoutes.chats,
          NativeSheetRoutes.voice,
          NativeSheetRoutes.notificationSettings,
          NativeSheetRoutes.aiMemory,
        ],
        [NativeSheetRoutes.calendar, NativeSheetRoutes.workspace],
        [
          NativeSheetRoutes.dataConnection,
          NativeSheetRoutes.directConnections,
          NativeSheetRoutes.hermes,
        ],
        [
          NativeSheetRoutes.scheduledTasks,
          NativeSheetRoutes.personalConnections,
          NativeSheetRoutes.chatDataControls,
        ],
        [NativeSheetRoutes.helpAbout],
        [nativeSignOutActionId],
        ['buy-me-a-coffee', 'github-sponsors'],
      ]);
      final advanced = sections[5];
      expect(advanced.title, _l10n.advancedFeatures);
      expect(advanced.footer, _l10n.profileAdvancedFooter);
      expect(sections.last.title, _l10n.supportConduit);
    });

    test('Advanced rows use their own symbols and close the sheet', () {
      final sections = buildNativeProfileRootSections(
        _l10n,
        account: _account,
        visibility: _everything,
      );

      final expected = {
        NativeSheetRoutes.scheduledTasks: 'clock.arrow.circlepath',
        NativeSheetRoutes.personalConnections: 'server.rack',
        NativeSheetRoutes.chatDataControls: 'externaldrive',
      };
      for (final MapEntry(:key, :value) in expected.entries) {
        final item = _item(sections, key);
        expect(item.sfSymbol, value, reason: key);
        expect(item.dismissOnSelect, isTrue, reason: key);
        expect(item.actionId, key, reason: key);
      }
    });

    test('the Advanced and places groups go with their last row', () {
      final sections = buildNativeProfileRootSections(
        _l10n,
        account: _account,
        visibility: const NativeProfileRootVisibility(),
      );

      expect(
        sections.map((section) => section.title),
        isNot(contains(_l10n.advancedFeatures)),
      );
      final ids = _ids(sections).expand((ids) => ids).toList();
      expect(ids, isNot(contains(NativeSheetRoutes.calendar)));
      expect(ids, isNot(contains(NativeSheetRoutes.workspace)));
      expect(ids, isNot(contains(NativeSheetRoutes.scheduledTasks)));
      // Only the accounts and support titles remain as section headings.
      expect(
        sections.where((section) => section.title != null).map((s) => s.title),
        [_l10n.accountsTitle, _l10n.supportConduit],
      );
    });

    test('other saved accounts are a tap away, with one sign-out each', () {
      final sections = buildNativeProfileRootSections(
        _l10n,
        account: _account,
        visibility: const NativeProfileRootVisibility(),
        otherAccounts: const [
          NativeProfileRootSavedAccount(
            id: 'work',
            displayName: 'Ada at work',
            detail: 'ada@work.example · Work',
          ),
        ],
      );

      final accounts = sections[1];
      expect(accounts.title, _l10n.accountsTitle);
      expect(
        [for (final item in accounts.items) item.actionId],
        [
          nativeAccountSwitchActionId,
          nativeAccountAddActionId,
          nativeAccountManageActionId,
        ],
      );
      final work = accounts.items.first;
      expect(work.title, 'Ada at work');
      expect(work.subtitle, 'ada@work.example · Work');
      expect(work.actionValue, 'work');
      expect(work.dismissOnSelect, isTrue);

      final signOut = _ids(sections)
          .firstWhere((ids) => ids.contains(nativeSignOutActionId));
      expect(signOut, [nativeAccountSignOutActionId, nativeSignOutActionId]);
      expect(
        _item(sections, nativeAccountSignOutActionId).title,
        _l10n.accountsSignOutOf('Ada'),
      );
      expect(
        _item(sections, nativeSignOutActionId).title,
        _l10n.accountsSignOutAll,
      );
    });

    // Pushed without the native-sheet origin, the page played its own
    // transition under the sheet as that slid away.
    test('Manage accounts opens without a second transition', () {
      final sections = buildNativeProfileRootSections(
        _l10n,
        account: _account,
        visibility: const NativeProfileRootVisibility(),
        otherAccounts: const [
          NativeProfileRootSavedAccount(
            id: 'work',
            displayName: 'Ada at work',
            detail: 'ada@work.example · Work',
          ),
        ],
      );
      final request = accountsNativeSheetNavigationRequest;

      expect(
        _item(sections, nativeAccountManageActionId).dismissOnSelect,
        isTrue,
      );
      expect(request.routeName, RouteNames.accounts);
      expect(usesNoTransitionForNativeSheet(request.extra), isTrue);
    });

    test('with one account, signing out is what it always was', () {
      final sections = buildNativeProfileRootSections(
        _l10n,
        account: _account,
        visibility: const NativeProfileRootVisibility(),
      );

      final ids = _ids(sections).expand((ids) => ids).toList();
      expect(ids, isNot(contains(nativeAccountSignOutActionId)));
      expect(ids, isNot(contains(nativeAccountManageActionId)));
      expect(_item(sections, nativeSignOutActionId).title, _l10n.signOut);
    });

    test('without an Open WebUI account the account rows give way to '
        'Connect to Open WebUI', () {
      final sections = buildNativeProfileRootSections(
        _l10n,
        account: null,
        visibility: const NativeProfileRootVisibility(),
      );

      final ids = _ids(sections).expand((ids) => ids).toList();
      for (final id in [
        NativeSheetRoutes.profile,
        NativeSheetRoutes.notificationSettings,
        NativeSheetRoutes.aiMemory,
        NativeSheetRoutes.dataConnection,
        nativeSignOutActionId,
      ]) {
        expect(ids, isNot(contains(id)), reason: id);
      }
      expect(_ids(sections)[1], [
        NativeSheetRoutes.directConnections,
        NativeSheetRoutes.hermes,
        nativeConnectOpenWebUiActionId,
      ]);
    });
  });

  test('About rows that open Flutter pages close the sheet with a chevron', () {
    final items = buildNativeAboutItems(_l10n, appVersion: '1.0');

    for (final id in [
      NativeSheetRoutes.releaseNotesManual,
      NativeSheetRoutes.openSourceLicenses,
    ]) {
      final item = items.singleWhere((item) => item.id == id);
      expect(item.dismissOnSelect, isTrue, reason: id);
      expect(item.showsDisclosure, isTrue, reason: id);
    }
  });

  group('Webhook destinations row', () {
    test('counts the destinations', () {
      String? subtitle(int? count) =>
          buildNativeNotificationTargetsItem(_l10n, count: count).subtitle;

      expect(subtitle(0), 'None');
      expect(subtitle(1), '1 destination');
      expect(subtitle(3), '3 destinations');
      expect(subtitle(null), isNull);
    });

    test('explains destinations in its group footer', () {
      final section = buildNativeNotificationTargetsSection(_l10n, count: 2);

      expect(section.footer, _l10n.notificationTargetsDescription);
      final item = section.items.single;
      expect(item.sfSymbol, 'bell.and.waves.left.and.right');
      expect(item.dismissOnSelect, isTrue);
      expect(item.actionId, nativeNotificationTargetsActionId);
    });
  });

  test('profile page rows show the About text, or Not set', () {
    AccountMetadata profile(String? bio) => AccountMetadata(
      id: 'user-1',
      email: 'ada@example.com',
      name: 'Ada',
      role: 'user',
      isActive: true,
      bio: bio,
    );
    NativeSheetItemConfig row(AccountMetadata? profile, String id) => _item(
      buildNativeProfileDetailSections(
        _l10n,
        displayName: 'Ada',
        accountProfile: profile,
      ),
      id,
    );

    expect(row(profile(' Hello '), 'profile-name').subtitle, 'Ada · Hello');
    expect(row(profile(' Hello '), 'profile-about').subtitle, 'Hello');
    expect(row(profile(''), 'profile-name').subtitle, 'Ada');
    expect(row(null, 'profile-about').subtitle, _l10n.notSet);
  });

  test('a refreshed profile reaches the sheet only when an edited field '
      'changed', () {
    const shown = AccountMetadata(
      id: 'user-1',
      email: 'ada@example.com',
      name: 'Ada',
      role: 'user',
      isActive: true,
      bio: 'Hello',
      gender: 'female',
      dateOfBirth: '1990-01-01',
      profileImageUrl: '/avatar.png',
    );
    AccountMetadata copy({
      String? bio = 'Hello',
      String? gender = 'female',
      String? dateOfBirth = '1990-01-01',
      String? profileImageUrl = '/avatar.png',
      String timezone = 'UTC',
    }) => AccountMetadata(
      id: 'user-1',
      email: 'ada@example.com',
      name: 'Ada',
      role: 'user',
      isActive: true,
      bio: bio,
      gender: gender,
      dateOfBirth: dateOfBirth,
      profileImageUrl: profileImageUrl,
      timezone: timezone,
    );

    expect(nativeProfileSheetFieldsDiffer(shown, copy()), isFalse);
    expect(nativeProfileSheetFieldsDiffer(shown, copy(timezone: 'CET')), isFalse);
    expect(nativeProfileSheetFieldsDiffer(shown, copy(bio: 'New')), isTrue);
    expect(nativeProfileSheetFieldsDiffer(shown, copy(gender: null)), isTrue);
    expect(
      nativeProfileSheetFieldsDiffer(shown, copy(dateOfBirth: '1991-01-01')),
      isTrue,
    );
    expect(
      nativeProfileSheetFieldsDiffer(shown, copy(profileImageUrl: '/new.png')),
      isTrue,
    );
  });
}
