import 'package:checks/checks.dart';
import 'package:conduit/core/services/native_sheet_bridge.dart';
import 'package:conduit/core/services/native_sheet_hydration_service.dart';
import 'package:conduit/core/utils/native_sheet_utils.dart';
import 'package:conduit/features/settings/settings_controller.dart';
import 'package:conduit/features/settings/settings_pages.dart';
import 'package:conduit/features/settings/views/settings_page_view.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/models/account_metadata.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' show MaterialApp;

final AppLocalizations _l10n = lookupAppLocalizations(const Locale('en'));

User _user(String id) =>
    User(id: id, username: id, email: '$id@example.com', role: 'user');

AccountMetadata _profile(String bio) => AccountMetadata(
  id: 'a',
  email: 'a@example.com',
  name: 'Ada',
  role: 'user',
  isActive: true,
  bio: bio,
);

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
}) async {
  final signedIn = NotifierProvider<_SignedIn, User?>(
    () => _SignedIn(user ?? _user('a')),
  );
  final profile = _Profile(cached: cached, fresh: fresh);
  final container = ProviderContainer(
    overrides: [
      currentUserProvider2.overrideWith((ref) => ref.watch(signedIn)),
      apiServiceProvider.overrideWithValue(null),
      accountProfileProvider.overrideWith(() => profile),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
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

    testWidgets('says it cannot be loaded with no profile at all', (
      tester,
    ) async {
      final rig = await open(tester);

      check(rig.rows(NativeSheetRoutes.profile).single.title)
          .equals(_l10n.unableToLoadProfile);
    });
  });

  group('Change Password', () {
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
      check(rig.profile.passwordChanges).isEmpty();

      await rig.change('current-password', 'old');
      check(rig.profile.passwordChanges)
          .deepEquals([(password: 'old', newPassword: 'next')]);
      check(rig.page('password')!.subtitle).equals(_l10n.passwordUpdated);
    });
  });
}
