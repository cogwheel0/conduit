import 'package:checks/checks.dart';
import 'package:conduit/core/services/native_sheet_bridge.dart';
import 'package:conduit/core/services/native_sheet_hydration_service.dart';
import 'package:conduit/core/utils/native_sheet_utils.dart';
import 'package:conduit/features/settings/settings_controller.dart';
import 'package:conduit/features/settings/settings_pages.dart';
import 'package:conduit/features/settings/views/settings_page_view.dart';
import 'package:conduit/features/settings/views/settings_profile_editors.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/services/navigation_service.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';

import 'dart:async';

import 'package:conduit_core/models/account_metadata.dart';
import 'package:conduit_core/models/server_about_info.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' show MaterialApp, Scaffold;
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit/platform/flutter_key_value_store.dart';
import 'package:conduit_core/services/settings_service.dart';

final AppLocalizations _l10n = lookupAppLocalizations(const Locale('en'));

User _user(String id) =>
    User(id: id, username: id, email: '$id@example.com', role: 'user');

AccountMetadata _profile(String bio, {String name = 'Ada'}) => AccountMetadata(
  id: 'a',
  email: 'a@example.com',
  name: name,
  role: 'user',
  isActive: true,
  bio: bio,
);

/// The API of the one server signed in to; only its identity is read.
final class _Api extends Mock implements ApiService {
  _Api() {
    when(() => serverConfig).thenReturn(
      const ServerConfig(
        id: 'server',
        name: 'Server',
        url: 'https://example.com',
      ),
    );
  }
}

/// The signed-in Open WebUI user, swapped by a test.
final class _SignedIn extends Notifier<User?> {
  _SignedIn(this.initial);

  final User? initial;

  @override
  User? build() => initial;

  void use(User? user) => state = user;
}

/// The account's profile: [cached] until a refresh, which reads [fresh], or
/// fails when there is none.
final class _Profile extends AccountProfile {
  _Profile({required this.cached, this.fresh});

  final AccountMetadata? cached;
  final AccountMetadata? fresh;
  final List<({String password, String newPassword})> passwordChanges = [];
  final List<String> savedNames = [];

  /// Holds a password change back until completed, when set.
  Completer<void>? passwordGate;

  /// Holds a profile save back until completed, when set.
  Completer<void>? saveGate;

  @override
  Future<AccountMetadata?> build() async => cached;

  @override
  Future<void> refresh() async {
    final fresh = this.fresh;
    state = fresh == null
        ? AsyncError(StateError('offline'), StackTrace.empty)
        : AsyncData(fresh);
  }

  @override
  Future<void> updatePassword({
    required String password,
    required String newPassword,
  }) async {
    passwordChanges.add((password: password, newPassword: newPassword));
    await passwordGate?.future;
  }

  @override
  Future<AccountMetadata> save({
    required String name,
    required String profileImageUrl,
    String? bio,
    String? gender,
    String? dateOfBirth,
    String? timezone,
  }) async {
    savedNames.add(name);
    await saveGate?.future;
    return _profile(bio ?? '', name: name);
  }
}

/// The app root as far as Settings needs it: it attaches the controller.
final class _App extends ConsumerStatefulWidget {
  const _App(this.child);

  final Widget child;

  @override
  ConsumerState<_App> createState() => _AppState();
}

final class _AppState extends ConsumerState<_App> {
  @override
  void initState() {
    super.initState();
    ref.read(settingsControllerProvider).attach(ref);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

final class _Rig {
  _Rig(this.tester, this.container, this.signedIn, this.profile);

  final WidgetTester tester;
  final ProviderContainer container;
  final NotifierProvider<_SignedIn, User?> signedIn;
  final _Profile profile;

  SettingsPages get pages => container.read(settingsPagesProvider.notifier);

  NativeSheetDetailConfig? page(String id) =>
      container.read(settingsPagesProvider)[id];

  List<NativeSheetItemConfig> rows(String id) => [
    ...page(id)!.items,
    for (final section in page(id)!.sections) ...section.items,
  ];

  void signIn(User? user) => container.read(signedIn.notifier).use(user);

  /// A row change from a Settings page, waited on until it is handled.
  Future<void> change(String id, Object? value) async {
    container
        .read(settingsControllerProvider)
        .handle(
          NativeSheetControlChanged(id: id, value: value),
          source: SettingsEventSource.flutter,
        );
    await tester.pumpAndSettle();
  }
}

Future<_Rig> _pump(
  WidgetTester tester, {
  Widget home = const SizedBox(),
  User? user,
  AccountMetadata? cached,
  AccountMetadata? fresh,
  Future<ServerAboutInfo?> Function()? serverAbout,
}) async {
  final signedIn = NotifierProvider<_SignedIn, User?>(
    () => _SignedIn(user ?? _user('a')),
  );
  final profile = _Profile(cached: cached, fresh: fresh);
  final container = ProviderContainer(
    overrides: [
      currentUserProvider2.overrideWith((ref) => ref.watch(signedIn)),
      apiServiceProvider.overrideWithValue(_Api()),
      accountProfileProvider.overrideWith(() => profile),
      // The server allows a password change.
      // By default the server allows a password change.
      serverAboutInfoProvider.overrideWith(
        (ref) => (serverAbout ?? () async => null)(),
      ),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        navigatorKey: NavigationService.navigatorKey,
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: _App(home),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _Rig(tester, container, signedIn, profile);
}

NativeSheetDetailConfig _chats(String title) => NativeSheetDetailConfig(
  id: NativeSheetRoutes.chats,
  title: title,
  items: [NativeSheetItemConfig(id: 'chats-row', title: title)],
);

void main() {
  testWidgets('another account forgets the pages described for the last one', (
    tester,
  ) async {
    final rig = await _pump(tester);
    rig.pages.register([_chats('Chats of a')]);

    rig.signIn(_user('b'));
    await tester.pumpAndSettle();

    check(rig.page(NativeSheetRoutes.chats)).isNull();
  });

  testWidgets('a page left open as another account takes over describes '
      'itself again', (tester) async {
    final rig = await _pump(
      tester,
      home: const SettingsDetailPage(detailId: NativeSheetRoutes.chats),
    );
    rig.pages.register([_chats('Chats of a')]);
    await tester.pumpAndSettle();
    check(find.text('Chats of a').evaluate()).isNotEmpty();

    rig.signIn(_user('b'));
    await tester.pumpAndSettle();

    // Back on its loading row, until it is filled in for the new account.
    check(find.text('Chats of a').evaluate()).isEmpty();
    check(rig.page(NativeSheetRoutes.chats)).isNotNull();
  });

  group('Profile opened by itself', () {
    Future<_Rig> open(
      WidgetTester tester, {
      User? user,
      AccountMetadata? cached,
      AccountMetadata? fresh,
    }) async {
      final rig = await _pump(tester, user: user, cached: cached, fresh: fresh);
      // Loaded once already, as the app does on sign-in.
      await rig.container.read(accountProfileProvider.future);
      rig.pages.register([
        buildNativeLoadingDetail(
          l10n: _l10n,
          id: NativeSheetRoutes.profile,
          title: '',
        ),
      ]);
      await rig.container
          .read(nativeSheetHydrationServiceProvider)
          .hydrateFlutterProfileDetail(_l10n);
      return rig;
    }

    String? about(_Rig rig) => rig
        .rows(NativeSheetRoutes.profile)
        .singleWhere((row) => row.id == 'profile-about')
        .subtitle;

    testWidgets('fills in from the profile the server has now', (tester) async {
      final rig = await open(
        tester,
        cached: _profile('Old'),
        fresh: _profile('New'),
      );

      check(about(rig)).equals('New');
    });

    testWidgets('shows the copy the app holds when the refresh fails', (
      tester,
    ) async {
      final rig = await open(tester, cached: _profile('Old'));

      check(about(rig)).equals('Old');
    });

    testWidgets('names the account as its profile does', (tester) async {
      final rig = await open(
        tester,
        user: User(
          id: 'a',
          username: 'ada',
          email: 'a@example.com',
          role: 'user',
        ),
        cached: _profile('Old'),
        fresh: _profile('New', name: 'Ada Lovelace'),
      );

      check(
        rig
            .rows(NativeSheetRoutes.profile)
            .singleWhere((row) => row.id == 'profile-name')
            .subtitle,
      ).equals('Ada Lovelace');
    });

    testWidgets('says it cannot be loaded with no profile at all', (
      tester,
    ) async {
      final rig = await open(tester);

      check(rig.rows(NativeSheetRoutes.profile).single.title)
          .equals(_l10n.unableToLoadProfile);
    });
  });

  testWidgets("Chat's model-name switch sets whether the message box names "
      'its model', (tester) async {
    await tester.runAsync(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      PreferencesStore.debugOverride(await FlutterKeyValueStore.load());
    });
    addTearDown(PreferencesStore.debugReset);
    final rig = await _pump(tester);
    check(rig.container.read(appSettingsProvider).showModelNameInComposer)
        .isFalse();

    await rig.change('composer-model-name', true);

    check(rig.container.read(appSettingsProvider).showModelNameInComposer)
        .isTrue();
  });

  testWidgets("a model's prompt read for the last account is not put on "
      "the next one's page", (tester) async {
    final rig = await _pump(tester);
    final api = rig.container.read(apiServiceProvider)! as _Api;
    final answer = Completer<Map<String, dynamic>?>();
    when(() => api.getModelDetails(any())).thenAnswer((_) => answer.future);
    const page = 'model-prompt:m1';
    final loading = buildNativeLoadingDetail(l10n: _l10n, id: page, title: '');
    rig.pages.register([loading]);
    final reading = rig.container
        .read(nativeSheetHydrationServiceProvider)
        .hydrateDetail(page);
    await tester.pump();

    // Another account signs in, and opens the same page, before the first
    // one's server answers.
    rig.signIn(_user('b'));
    await tester.pump();
    final next = buildNativeLoadingDetail(l10n: _l10n, id: page, title: '');
    rig.pages.register([next]);
    answer.complete({
      'write_access': true,
      'params': {'system': 'Private prompt'},
    });
    await reading;
    await tester.pumpAndSettle();

    check(rig.page(page)).identicalTo(next);
  });

  group('Change Password', () {
    testWidgets('nothing is sent until Done, and Done sends it once', (
      tester,
    ) async {
      final rig = await _pump(tester);
      rig.pages.register([
        buildNativePasswordDetail(_l10n, passwordChangeEnabled: true),
      ]);
      check(rig.page('password')!.confirmActionId)
          .equals(nativePasswordSaveActionId);
      await rig.change('current-password', 'old');
      await rig.change('new-password', 'next');
      await rig.change('confirm-password', 'next');
      check(rig.profile.passwordChanges).isEmpty();

      // Left with all three filled, as Back leaves it: nothing goes.
      rig.container.read(settingsControllerProvider).pageClosed('password');
      await tester.pumpAndSettle();
      check(rig.profile.passwordChanges).isEmpty();

      await rig.change('current-password', 'old');
      await rig.change('new-password', 'next');
      await rig.change('confirm-password', 'next');
      await rig.change(nativePasswordSaveActionId, true);
      await rig.change(nativePasswordSaveActionId, true);

      check(rig.profile.passwordChanges)
          .deepEquals([(password: 'old', newPassword: 'next')]);
      // The second Done found nothing typed: the outcome stays.
      check(rig.page('password')!.subtitle).equals(_l10n.passwordUpdated);
    });

    testWidgets('a Done with nothing typed leaves what the page says', (
      tester,
    ) async {
      final rig = await _pump(tester);
      rig.pages.register([
        buildNativePasswordDetail(_l10n, passwordChangeEnabled: true),
      ]);
      await rig.change('current-password', 'old');
      await rig.change('new-password', 'first');
      await rig.change('confirm-password', 'second');
      await rig.change(nativePasswordSaveActionId, true);
      check(rig.page('password')!.subtitle).equals(_l10n.passwordsDoNotMatch);

      // Tapped again, with nothing typed since.
      await rig.change(nativePasswordSaveActionId, true);

      check(rig.page('password')!.subtitle).equals(_l10n.passwordsDoNotMatch);
      check(rig.profile.passwordChanges).isEmpty();
    });

    testWidgets('a page opened from a link gets its Done; a server that '
        'refuses changes shows none, and its Done brings no form back', (
      tester,
    ) async {
      final rig = await _pump(
        tester,
        serverAbout: () async => const ServerAboutInfo(
          name: 'Server',
          version: '1.0',
          enablePasswordChangeForm: true,
        ),
      );
      rig.pages.register([
        buildNativeLoadingDetail(l10n: _l10n, id: 'password', title: ''),
      ]);
      await rig.container
          .read(nativeSheetHydrationServiceProvider)
          .hydrateDetail('password');
      await tester.pumpAndSettle();
      check(rig.page('password')!.confirmActionId)
          .equals(nativePasswordSaveActionId);

      final refusing = await _pump(
        tester,
        serverAbout: () async => const ServerAboutInfo(
          name: 'Server',
          version: '1.0',
          enablePasswordChangeForm: false,
        ),
      );
      refusing.pages.register([
        buildNativePasswordDetail(_l10n, passwordChangeEnabled: true),
      ]);
      await refusing.container
          .read(nativeSheetHydrationServiceProvider)
          .hydrateDetail('password');
      await tester.pumpAndSettle();
      check(refusing.page('password')!.confirmActionId).isNull();

      await refusing.change(nativePasswordSaveActionId, true);
      check(refusing.rows('password').map((row) => row.id))
          .not((ids) => ids.contains('current-password'));
    });

    testWidgets('Settings forgets the pages it drew once the sheet closes, '
        'as the sheet does', (tester) async {
      final rig = await _pump(tester);
      rig.pages.register([
        buildNativePasswordDetail(_l10n, passwordChangeEnabled: true),
      ]);

      rig.container
          .read(settingsControllerProvider)
          .handle(const NativeSheetDismissed());

      check(rig.page('password')).isNull();
    });

    testWidgets('new passwords that differ say so, and nothing is sent', (
      tester,
    ) async {
      final rig = await _pump(tester);
      rig.pages.register([
        buildNativePasswordDetail(_l10n, passwordChangeEnabled: true),
      ]);

      await rig.change('current-password', 'old');
      await rig.change('new-password', 'first');
      await rig.change('confirm-password', 'second');
      await rig.change(nativePasswordSaveActionId, true);

      check(rig.profile.passwordChanges).isEmpty();
      check(rig.page('password')!.subtitle).equals(_l10n.passwordsDoNotMatch);
    });

    testWidgets('a password typed on an earlier visit is not used', (
      tester,
    ) async {
      final rig = await _pump(tester);
      rig.pages.register([
        buildNativePasswordDetail(_l10n, passwordChangeEnabled: true),
      ]);
      await rig.change('current-password', 'left behind');

      // Opened again.
      rig.container
          .read(settingsControllerProvider)
          .handle(
            const NativeSheetDetailAppeared(detailId: 'password'),
            source: SettingsEventSource.flutter,
          );
      await rig.change('new-password', 'next');
      await rig.change('confirm-password', 'next');
      await rig.change(nativePasswordSaveActionId, true);
      check(rig.profile.passwordChanges).isEmpty();

      await rig.change('current-password', 'old');
      await rig.change('new-password', 'next');
      await rig.change('confirm-password', 'next');
      await rig.change(nativePasswordSaveActionId, true);
      check(rig.profile.passwordChanges)
          .deepEquals([(password: 'old', newPassword: 'next')]);
      check(rig.page('password')!.subtitle).equals(_l10n.passwordUpdated);
    });

    testWidgets('a change sent on a visit since left does not report on the '
        'next', (tester) async {
      final rig = await _pump(tester);
      rig.pages.register([
        buildNativePasswordDetail(_l10n, passwordChangeEnabled: true),
      ]);
      final gate = rig.profile.passwordGate = Completer<void>();
      await rig.change('current-password', 'old');
      await rig.change('new-password', 'next');
      await rig.change('confirm-password', 'next');
      await rig.change(nativePasswordSaveActionId, true);
      check(rig.profile.passwordChanges).length.equals(1);

      // Left and opened again while the change is still on its way.
      rig.container.read(settingsControllerProvider).pageClosed('password');
      rig.container
          .read(settingsControllerProvider)
          .handle(
            const NativeSheetDetailAppeared(detailId: 'password'),
            source: SettingsEventSource.flutter,
          );
      gate.complete();
      await tester.pumpAndSettle();

      check(rig.page('password')!.subtitle).isNull();
    });

    testWidgets("the last account's answer about password changes is not "
        "put on the next one's page", (tester) async {
      final answer = Completer<ServerAboutInfo?>();
      final rig = await _pump(tester, serverAbout: () => answer.future);
      final form = buildNativePasswordDetail(
        _l10n,
        passwordChangeEnabled: true,
      );
      rig.pages.register([form]);
      final asking = rig.container
          .read(nativeSheetHydrationServiceProvider)
          .hydrateDetail('password');
      await tester.pump();

      // Another account signs in and its page is described before the
      // last account's server answers.
      rig.signIn(_user('b'));
      await tester.pump();
      rig.pages.register([form]);
      answer.complete(
        const ServerAboutInfo(
          name: 'Server',
          version: '1.0',
          enablePasswordChangeForm: false,
        ),
      );
      await asking;
      await tester.pumpAndSettle();

      check(rig.rows('password').map((row) => row.id))
          .contains('current-password');
    });

    testWidgets("a change typed on the last account's page is not sent once "
        'another takes over', (tester) async {
      final rig = await _pump(tester);
      rig.pages.register([
        buildNativePasswordDetail(_l10n, passwordChangeEnabled: true),
      ]);
      final gate = rig.profile.passwordGate = Completer<void>();
      await rig.change('current-password', 'old');
      await rig.change('new-password', 'next');
      await rig.change('confirm-password', 'next');
      await rig.change(nativePasswordSaveActionId, true);

      // Typed again and Done while the first change is on its way, then
      // another account signs in before those wait their turn.
      for (final (id, value) in [
        ('current-password', 'next'),
        ('new-password', 'later'),
        ('confirm-password', 'later'),
        (nativePasswordSaveActionId, true),
      ]) {
        rig.container
            .read(settingsControllerProvider)
            .handle(
              NativeSheetControlChanged(id: id, value: value),
              source: SettingsEventSource.flutter,
            );
      }
      rig.signIn(_user('b'));
      gate.complete();
      await tester.pumpAndSettle();

      check(rig.profile.passwordChanges)
          .deepEquals([(password: 'old', newPassword: 'next')]);
    });

    testWidgets('a page left open as another account takes over gets its '
        'form back', (tester) async {
      final rig = await _pump(
        tester,
        home: const SettingsDetailPage(detailId: 'password'),
      );
      rig.pages.register([
        buildNativePasswordDetail(_l10n, passwordChangeEnabled: true),
      ]);
      await tester.pumpAndSettle();

      rig.signIn(_user('b'));
      await tester.pumpAndSettle();

      check(rig.rows('password').map((row) => row.id))
          .contains('current-password');
    });
  });

  group('Profile editors', () {
    /// A Profile page whose Name row opens its editor.
    Future<_Rig> open(WidgetTester tester, {AccountMetadata? fresh}) async {
      final rig = await _pump(
        tester,
        cached: _profile('Old'),
        fresh: fresh,
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => GestureDetector(
              onTap: () =>
                  editSettingsProfileField(context, ref, 'profile-name'),
              child: const Text('Name'),
            ),
          ),
        ),
      );
      await rig.container.read(accountProfileProvider.future);
      return rig;
    }

    Future<void> rename(WidgetTester tester, String name) async {
      await tester.tap(find.text('Name'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(EditableText), name);
    }

    Future<void> save(WidgetTester tester) async {
      await tester.tap(find.text(_l10n.save));
      await tester.pumpAndSettle();
      // The message the edit ends with goes away by itself.
      await tester.pump(const Duration(seconds: 5));
    }

    testWidgets('edit the copy kept while its refresh failed', (tester) async {
      final rig = await open(tester);
      await rig.container.read(accountProfileProvider.notifier).refresh();
      check(rig.container.read(accountProfileProvider).hasError).isTrue();

      await rename(tester, 'Grace');
      await save(tester);

      check(rig.profile.savedNames).deepEquals(['Grace']);
    });

    testWidgets("a save that lands after another account took over is not "
        "put on that account's page", (tester) async {
      final rig = await open(tester);
      final gate = rig.profile.saveGate = Completer<void>();
      await rename(tester, 'Grace');
      await tester.tap(find.text(_l10n.save));
      await tester.pumpAndSettle();
      check(rig.profile.savedNames).deepEquals(['Grace']);

      rig.signIn(_user('b'));
      await tester.pump();
      rig.pages.register([
        buildNativeLoadingDetail(
          l10n: _l10n,
          id: NativeSheetRoutes.profile,
          title: '',
        ),
      ]);
      gate.complete();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 5));

      check(rig.rows(NativeSheetRoutes.profile).map((row) => row.id))
          .not((ids) => ids.contains('profile-name'));
    });

    testWidgets('save nothing once another account took over', (tester) async {
      final rig = await open(tester);

      await rename(tester, 'Grace');
      rig.signIn(_user('b'));
      await tester.pump();
      await save(tester);

      check(rig.profile.savedNames).isEmpty();
    });
  });
}
