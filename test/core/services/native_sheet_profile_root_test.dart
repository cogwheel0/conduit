import 'package:checks/checks.dart';
import 'package:conduit/core/services/native_sheet_bridge.dart';
import 'package:conduit/core/utils/native_sheet_utils.dart';
import 'package:conduit/features/navigation/widgets/sidebar_user_pill.dart'
    show nativeProfileSheetFieldsDiffer;
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit_core/auth/openwebui_account_summaries.dart';
import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_connection_profile.dart';
import 'package:conduit_core/models/account_metadata.dart';
import 'package:conduit_core/models/openwebui_registry.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';

final _l10n = lookupAppLocalizations(const Locale('en'));

const _account = NativeProfileRootAccount(
  displayName: 'Ada',
  email: 'ada@example.com',
);

const _card = (title: 'Ada', subtitle: 'Home Lab +1');

const _everything = NativeProfileRootVisibility(
  showCalendar: true,
  canManageWorkspace: true,
  showScheduledTasks: true,
  showPersonalConnections: true,
  showChatDataControls: true,
);

final _home = OpenWebUiServer(
  id: 'home',
  name: 'Home Lab',
  endpoints: [OpenWebUiEndpoint(id: 'home-lan', url: 'http://10.0.0.2:3000')],
);

final _work = OpenWebUiServer(
  id: 'work',
  name: 'Work',
  endpoints: [OpenWebUiEndpoint(id: 'work-1', url: 'https://chat.work')],
);

OpenWebUiAccountEntry _entry(
  String id,
  OpenWebUiServer server, {
  required String name,
  String? email,
  String? profileImage,
  bool isActive = false,
  bool hasSession = true,
}) => OpenWebUiAccountEntry(
  account: OpenWebUiAccount(id: id, serverId: server.id),
  server: server,
  summary: OpenWebUiAccountSummary(
    name: name,
    email: email,
    profileImage: profileImage,
  ),
  isActive: isActive,
  hasSession: hasSession,
);

const _homeAgent = HermesConnectionProfile(
  id: 'hermes-home',
  name: 'Home agent',
  documentTrustPrincipalId: 'p-home',
  baseUrl: 'http://10.0.0.5:8642',
);

const _laptop = HermesConnectionProfile(
  id: 'hermes-laptop',
  name: 'Laptop',
  documentTrustPrincipalId: 'p-laptop',
  baseUrl: 'http://10.0.0.6:9119',
  mode: HermesBackendMode.desktopGateway,
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

List<NativeSheetSectionConfig> _root({
  NativeProfileRootAccount? account = _account,
  NativeProfileRootVisibility visibility = const NativeProfileRootVisibility(),
  int? otherAccountCount = 0,
}) => buildNativeProfileRootSections(
  _l10n,
  account: account,
  visibility: visibility,
  card: _card,
  otherAccountCount: otherAccountCount,
);

void main() {
  group('native Settings root', () {
    test('groups rows in the Flutter Settings order', () {
      final sections = _root(visibility: _everything);

      expect(_ids(sections), [
        [nativeAccountsDetailId, nativeAccountAddActionId],
        [
          NativeSheetRoutes.profile,
          NativeSheetRoutes.notificationSettings,
          NativeSheetRoutes.aiMemory,
          NativeSheetRoutes.dataConnection,
        ],
        [
          NativeSheetRoutes.appearance,
          NativeSheetRoutes.chats,
          NativeSheetRoutes.voice,
        ],
        [NativeSheetRoutes.calendar, NativeSheetRoutes.workspace],
        [
          NativeSheetRoutes.scheduledTasks,
          NativeSheetRoutes.personalConnections,
          NativeSheetRoutes.chatDataControls,
        ],
        [NativeSheetRoutes.helpAbout],
        [nativeSignOutActionId],
        ['buy-me-a-coffee', 'github-sponsors'],
      ]);
      expect(sections[1].title, _l10n.accountSettingsTitle);
      final advanced = sections[4];
      expect(advanced.title, _l10n.advancedFeatures);
      expect(advanced.footer, _l10n.profileAdvancedFooter);
      expect(sections.last.title, _l10n.supportConduit);
    });

    test('the account card leads to Accounts, with Add account under it', () {
      final sections = _root();

      final card = _item(sections, nativeAccountsDetailId);
      expect(card.title, 'Ada');
      expect(card.subtitle, 'Home Lab +1');
      expect(card.usesProfileAvatar, isTrue);
      // Pushed inside the sheet, not a page behind it.
      expect(card.dismissOnSelect, isFalse);
      final add = _item(sections, nativeAccountAddActionId);
      expect(add.title, _l10n.accountsAddAccount);
      expect(add.accent, isTrue);
      expect(add.dismissOnSelect, isTrue);
      // An action, not a page: no chevron.
      expect(add.showsDisclosure, isFalse);
      expect(add.actionId, nativeAccountAddActionId);
    });

    test('Advanced rows use their own symbols and close the sheet', () {
      final sections = _root(visibility: _everything);

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
      final sections = _root();

      expect(
        sections.map((section) => section.title),
        isNot(contains(_l10n.advancedFeatures)),
      );
      final ids = _ids(sections).expand((ids) => ids).toList();
      expect(ids, isNot(contains(NativeSheetRoutes.calendar)));
      expect(ids, isNot(contains(NativeSheetRoutes.workspace)));
      expect(ids, isNot(contains(NativeSheetRoutes.scheduledTasks)));
      // Only the account's and support titles remain as section headings.
      expect(
        sections.where((section) => section.title != null).map((s) => s.title),
        [_l10n.accountSettingsTitle, _l10n.supportConduit],
      );
    });

    test('with several accounts, Sign out leaves only the active one', () {
      final sections = _root(otherAccountCount: 1);

      final signOut = _ids(sections)
          .firstWhere((ids) => ids.contains(nativeAccountSignOutActionId));
      expect(signOut, [nativeAccountSignOutActionId]);
      expect(
        _item(sections, nativeAccountSignOutActionId).title,
        _l10n.signOut,
      );
    });

    // The sheet reads the saved accounts as it opens. When that read failed
    // or ran late, the row said "Sign out" while it signed out of every
    // account.
    test('with the other accounts unknown, signing out says it signs out '
        'of all of them', () {
      final sections = _root(otherAccountCount: null);

      check(_item(sections, nativeSignOutActionId).title)
          .equals(_l10n.accountsSignOutAll);
      final ids = _ids(sections).expand((ids) => ids);
      check(ids.contains(nativeAccountSignOutActionId)).isFalse();
    });

    test('with one account, signing out is what it always was', () {
      final sections = _root();

      final ids = _ids(sections).expand((ids) => ids).toList();
      expect(ids, isNot(contains(nativeAccountSignOutActionId)));
      expect(_item(sections, nativeSignOutActionId).title, _l10n.signOut);
    });

    // Next to a usable Hermes or Direct backend Settings stays open with no
    // Open WebUI account; the card still leads to all of them.
    test('without an Open WebUI account, its rows go and the card stays', () {
      final sections = _root(account: null);

      final ids = _ids(sections).expand((ids) => ids).toList();
      for (final id in [
        NativeSheetRoutes.profile,
        NativeSheetRoutes.notificationSettings,
        NativeSheetRoutes.aiMemory,
        NativeSheetRoutes.dataConnection,
        nativeSignOutActionId,
        // Accounts lists the connections now.
        NativeSheetRoutes.directConnections,
        NativeSheetRoutes.hermes,
        nativeConnectOpenWebUiActionId,
      ]) {
        expect(ids, isNot(contains(id)), reason: id);
      }
      expect(_ids(sections).first, [
        nativeAccountsDetailId,
        nativeAccountAddActionId,
      ]);
    });

    test('without an account, Notifications stays for Hermes and push', () {
      final sections = _root(
        account: null,
        visibility: const NativeProfileRootVisibility(
          showNotificationsWithoutAccount: true,
        ),
      );
      expect(_ids(sections)[1], [
        NativeSheetRoutes.appearance,
        NativeSheetRoutes.chats,
        NativeSheetRoutes.voice,
        NativeSheetRoutes.notificationSettings,
      ]);
      // With an account it stays among the account's rows, listed once.
      final withAccount = _ids(
        _root(
          visibility: const NativeProfileRootVisibility(
            showNotificationsWithoutAccount: true,
          ),
        ),
      ).expand((ids) => ids).where(
        (id) => id == NativeSheetRoutes.notificationSettings,
      );
      expect(withAccount, hasLength(1));
    });
  });

  group('native Accounts page', () {
    NativeSheetDetailConfig accountsPage({
      List<OpenWebUiAccountEntry>? accounts = const [],
      List<HermesConnectionProfile> hermes = const [],
      String? hermesInUseId,
      List<DirectConnectionProfile>? direct = const [],
    }) => buildNativeAccountsDetail(
      _l10n,
      accounts: accounts,
      hermesConnections: hermes,
      hermesInUseId: hermesInUseId,
      directProfiles: direct,
    );

    test('a card for each server, its accounts under it, the active one '
        'checked', () {
      final page = accountsPage(
        accounts: [
          _entry('alex-home', _home, name: 'Alex', isActive: true),
          _entry('sam-home', _home, name: 'Sam', hasSession: false),
          _entry('alex-work', _work, name: 'Alex L.'),
        ],
      );

      expect(page.id, nativeAccountsDetailId);
      expect(page.title, _l10n.accountsTitle);
      expect(page.trailingActionId, nativeAccountAddActionId);
      expect(page.trailingActionSfSymbol, 'plus');
      expect(_ids(page.sections).take(2), [
        [
          '$nativeAccountServerActionId:home',
          '$nativeAccountSwitchActionId:alex-home',
          '$nativeAccountSwitchActionId:sam-home',
        ],
        [
          '$nativeAccountServerActionId:work',
          '$nativeAccountSwitchActionId:alex-work',
        ],
      ]);
      final server = _item(page.sections, '$nativeAccountServerActionId:home');
      expect(server.title, 'Home Lab');
      expect(server.avatarName, 'Home Lab');
      expect(server.actionId, nativeAccountServerActionId);
      expect(server.actionValue, 'home');

      // The one in use stays put.
      final active = _item(
        page.sections,
        '$nativeAccountSwitchActionId:alex-home',
      );
      expect(active.checked, isTrue);
      expect(active.kind, NativeSheetItemKind.info);
      expect(active.actionId, isNull);
      final other = _item(
        page.sections,
        '$nativeAccountSwitchActionId:sam-home',
      );
      expect(other.checked, isFalse);
      expect(other.subtitle, _l10n.accountsSignedOut);
      expect(other.avatarName, 'Sam');
      expect(other.dismissOnSelect, isTrue);
      expect(other.actionId, nativeAccountSwitchActionId);
      expect(other.actionValue, 'sam-home');
    });

    // A switch left the active account signed out: it is switched to again,
    // which opens its sign-in.
    test('the active account, signed out, is switched to', () {
      final page = accountsPage(
        accounts: [
          _entry(
            'alex-home',
            _home,
            name: 'Alex',
            isActive: true,
            hasSession: false,
          ),
        ],
      );

      final active = _item(
        page.sections,
        '$nativeAccountSwitchActionId:alex-home',
      );
      expect(active.checked, isTrue);
      expect(active.actionId, nativeAccountSwitchActionId);
    });

    test('an uploaded picture travels with its account', () {
      final page = accountsPage(
        accounts: [
          _entry(
            'alex-home',
            _home,
            name: 'Alex',
            profileImage: 'data:image/png;base64,AQID',
          ),
        ],
      );

      expect(
        _item(
          page.sections,
          '$nativeAccountSwitchActionId:alex-home',
        ).avatarBytes,
        [1, 2, 3],
      );
    });

    test('Hermes connections, the one in use checked, switch on a tap', () {
      final page = accountsPage(
        hermes: const [_homeAgent, _laptop],
        hermesInUseId: _homeAgent.id,
      );

      final home = _item(page.sections, '$nativeHermesUseActionId:hermes-home');
      expect(home.checked, isTrue);
      expect(home.actionId, isNull);
      final laptop = _item(
        page.sections,
        '$nativeHermesUseActionId:hermes-laptop',
      );
      expect(laptop.checked, isFalse);
      expect(laptop.subtitle, 'Desktop Gateway · 10.0.0.6');
      expect(laptop.sfSymbol, 'desktopcomputer');
      expect(laptop.actionId, nativeHermesUseActionId);
      expect(laptop.actionValue, 'hermes-laptop');
      // Its own row opens the Hermes page.
      expect(
        _item(page.sections, 'accounts-hermes').actionId,
        NativeSheetRoutes.hermes,
      );
    });

    test('Direct providers, none checked, each open their editor', () {
      final page = accountsPage(
        direct: [
          DirectConnectionProfile(
            id: 'desk',
            name: 'Desk',
            adapterKey: kOllamaAdapterKey,
            baseUrl: 'http://10.0.0.7:11434',
            enabled: false,
          ),
        ],
      );

      final desk = _item(page.sections, '$nativeDirectEditActionId:desk');
      expect(desk.subtitle, 'Ollama · Disabled');
      expect(desk.checked, isFalse);
      expect(desk.actionId, nativeDirectEditActionId);
      expect(desk.actionValue, 'desk');
      expect(
        _ids(page.sections).expand((ids) => ids),
        isNot(contains('accounts-direct-add')),
      );
    });

    test('an empty card offers to add its first, on its own tab', () {
      final page = accountsPage();

      for (final (id, kind) in [
        ('accounts-openwebui-add', 'openWebUi'),
        ('accounts-hermes-add', 'hermes'),
        ('accounts-direct-add', 'direct'),
      ]) {
        final add = _item(page.sections, id);
        expect(add.accent, isTrue, reason: id);
        expect(add.actionId, nativeAccountAddActionId, reason: id);
        expect(add.actionValue, kind, reason: id);
      }
    });

    test('unread accounts say so, and unread providers offer no add', () {
      final page = accountsPage(accounts: null, direct: null);

      final ids = _ids(page.sections).expand((ids) => ids).toList();
      expect(ids, contains('accounts-unreadable'));
      expect(ids, isNot(contains('accounts-direct-add')));
    });

    test('signing out of every account is offered with several', () {
      expect(
        _ids(
          accountsPage(accounts: [_entry('alex-home', _home, name: 'Alex')])
              .sections,
        ).expand((ids) => ids),
        isNot(contains(nativeSignOutActionId)),
      );

      final page = accountsPage(
        accounts: [
          _entry('alex-home', _home, name: 'Alex', isActive: true),
          _entry('sam-home', _home, name: 'Sam'),
        ],
      );
      expect(_ids(page.sections).last, [nativeSignOutActionId]);
      expect(
        _item(page.sections, nativeSignOutActionId).title,
        _l10n.accountsSignOutAll,
      );
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
