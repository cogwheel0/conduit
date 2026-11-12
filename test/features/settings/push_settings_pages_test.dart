import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/core/services/native_sheet_bridge.dart';
import 'package:conduit/core/utils/native_sheet_utils.dart';
import 'package:conduit/features/settings/pages/hermes_page_ids.dart';
import 'package:conduit/features/settings/pages/push_page_ids.dart';
import 'package:conduit/features/settings/pages/push_settings_pages.dart';
import 'package:conduit/features/settings/settings_controller.dart';
import 'package:conduit/features/settings/settings_page_module.dart';
import 'package:conduit/features/settings/settings_pages.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/services/navigation_service.dart';
import 'package:conduit_core/auth/api_auth_interceptor.dart'
    show ApiAuthSnapshot;
import 'package:conduit_core/auth/auth_state_manager.dart';
import 'package:conduit_core/auth/openwebui_account_summaries.dart';
import 'package:conduit_core/features/notifications/providers/notification_target_providers.dart';
import 'package:conduit_core/features/push/models/push_status.dart';
import 'package:conduit_core/features/push/providers/push_providers.dart';
import 'package:conduit_core/features/push/services/hermes_push_backend.dart'
    show kConduitHermesPluginPinned;
import 'package:conduit_core/models/openwebui_registry.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/openwebui_accounts_controller.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart' show MaterialApp;

import '../push/push_test_support.dart';

final AppLocalizations _l10n = lookupAppLocalizations(const Locale('en'));

const _owuiScope = 'owui:acct-1';

PushTargetState _owui(PushStatus status, {PushFailure? failure}) =>
    PushTargetState(target: pushOwuiTarget, status: status, failure: failure);

/// Settings as the pages see it: each question is answered with [answer].
final class _Surface extends SettingsSurface {
  _Surface(super.ref);

  final asked = <String>[];
  String? answer;

  @override
  Future<String?> ask({
    required String title,
    String? message,
    required List<NativeSheetAlertAction> actions,
  }) async {
    asked.add(title);
    return answer;
  }
}

final class _Rig {
  _Rig(this.tester, this.container, this.fake, this.surface);

  final WidgetTester tester;
  final ProviderContainer container;
  final FakePushCoordinator fake;
  final _Surface surface;

  PushSettingsPages get module => container
      .read(settingsPageModulesProvider)
      .whereType<PushSettingsPages>()
      .single;

  NativeSheetDetailConfig? page(String id) =>
      container.read(settingsPagesProvider)[id];

  List<NativeSheetItemConfig> rows(String id) => [
    ...page(id)!.items,
    for (final section in page(id)!.sections) ...section.items,
  ];

  NativeSheetItemConfig row(String pageId, String id) =>
      rows(pageId).singleWhere((row) => row.id == id);

  Iterable<String?> footers(String pageId) =>
      page(pageId)!.sections.map((section) => section.footer);

  List<String> get closed => [
    for (final MapEntry(:key, :value)
        in container.read(settingsPagesProvider).closeRequests.entries)
      for (var i = 0; i < value; i++) key,
  ];

  Future<void> open(String id) async {
    container.read(settingsPagesProvider.notifier).register([
      buildNativeLoadingDetail(l10n: _l10n, id: id, title: ''),
    ]);
    await settle(module.hydrate(id, _l10n));
  }

  Future<void> change(String id, Object? value) =>
      settle(module.handleChange(id, value, _l10n));

  Future<void> settle(Future<Object?> work) async {
    var done = false;
    unawaited(work.whenComplete(() => done = true));
    while (!done) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    await work;
    await idle();
  }

  /// Lets redraws queued by a change, or by push changing, land.
  Future<void> idle() async {
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
  }
}

Future<_Rig> _pump(WidgetTester tester, PushState state) async {
  final fake = FakePushCoordinator(state);
  late final _Surface surface;
  final container = ProviderContainer(
    overrides: [
      pushCoordinatorProvider.overrideWith(() => fake),
      openWebUiAccountsProvider.overrideWith(
        (ref) async => const <OpenWebUiAccountEntry>[],
      ),
      settingsSurfaceProvider.overrideWith((ref) => surface = _Surface(ref)),
    ],
  );
  addTearDown(container.dispose);
  // Push is kept alive from launch in the app.
  container.read(pushCoordinatorProvider);
  container.read(settingsSurfaceProvider);
  return _Rig(tester, container, fake, surface);
}

String _action(String scope) =>
    '$pushTargetActionPrefix${Uri.encodeComponent(scope)}';

List<NativeSheetItemConfig> _rowsOf(NativeSheetDetailConfig page) => [
  for (final section in page.sections) ...section.items,
];

void main() {
  setUp(() => PreferencesStore.debugOverride(InMemoryKeyValueStore()));
  tearDown(PreferencesStore.debugReset);

  group("each status's page shows its fix", () {
    final cases = <String, (PushTargetState, String status, String? action)>{
      'canInstall': (
        _owui(PushStatus.canInstall),
        'Not set up on this server',
        'Set Up',
      ),
      'needsAdminSetup': (
        _owui(PushStatus.needsAdminSetup),
        'Needs your admin to set up',
        'Ask Your Admin',
      ),
      'updateAvailable': (
        _owui(PushStatus.updateAvailable),
        'On · Update available',
        'Update',
      ),
      'pluginsDisabled': (
        _owui(PushStatus.pluginsDisabled),
        'Functions are turned off on this server',
        null,
      ),
      'serverTooOld': (
        _owui(PushStatus.serverTooOld),
        'Needs Open WebUI 0.11 or newer',
        null,
      ),
      'signInNeeded': (
        _owui(PushStatus.signInNeeded),
        'Sign in to use push',
        'Sign In',
      ),
      'failed': (
        _owui(
          PushStatus.failed,
          failure: const PushFailure(PushFailureReason.testTimeout),
        ),
        "The test notification didn't arrive.",
        'Retry',
      ),
      'needsHermesPlugin (dashboard)': (
        const PushTargetState(
          target: pushHermesDesktopTarget,
          status: PushStatus.needsHermesPlugin,
          canInstallHermesPlugin: true,
          hermesInstallCommand: 'hermes plugins install x --enable',
        ),
        'Needs the Conduit plugin in Hermes',
        'Install',
      ),
      'needsHermesPlugin (API key)': (
        const PushTargetState(
          target: pushHermesApiTarget,
          status: PushStatus.needsHermesPlugin,
          hermesInstallCommand: 'hermes plugins install x --enable',
        ),
        'Needs the Conduit plugin in Hermes',
        'Copy Command',
      ),
    };
    for (final MapEntry(key: name, value: (target, status, action))
        in cases.entries) {
      test(name, () {
        final rows = _rowsOf(
          buildPushTargetPage(
            _l10n,
            target: target,
            title: target.target.label,
            pushEnabled: true,
          ),
        );
        check(rows.first.title).equals(status);
        final fix = rows.where((row) => row.accent == true);
        if (action == null) {
          check(fix).isEmpty();
        } else {
          check(fix.single.title).equals(action);
        }
      });
    }
  });

  group('one-tap fixes', () {
    testWidgets('installing asks first, and the page links to the source', (
      tester,
    ) async {
      final rig = await _pump(
        tester,
        pushStateWith([_owui(PushStatus.canInstall)]),
      );
      final pageId = pushTargetPageId(_owuiScope);
      await rig.open(pageId);
      final source = rig
          .rows(pageId)
          .singleWhere((row) => row.title == 'View Source');
      check(source.url).equals(
        'https://github.com/cogwheel0/conduit/blob/main/server-plugins/'
        'openwebui/conduit_push.py',
      );

      await rig.change(_action(_owuiScope), true);
      check(rig.surface.asked).deepEquals(['Install Conduit Push?']);
      check(rig.fake.calls).isEmpty();

      rig.surface.answer = 'install';
      await rig.change(_action(_owuiScope), true);
      check(rig.fake.calls)
          .deepEquals(['installOpenWebUiFunction $_owuiScope']);
    });

    testWidgets('the Hermes plugin installs after a confirmation', (
      tester,
    ) async {
      const target = PushTargetState(
        target: pushHermesDesktopTarget,
        status: PushStatus.needsHermesPlugin,
        canInstallHermesPlugin: true,
      );
      final rig = await _pump(tester, pushStateWith([target]));
      rig.surface.answer = 'install';

      await rig.change(_action(target.scope), true);

      check(rig.surface.asked).deepEquals(['Install the Conduit plugin?']);
      check(rig.fake.calls).deepEquals(['installHermesPlugin ${target.scope}']);
    });

    testWidgets('the Hermes command is copied, and the page says so', (
      tester,
    ) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      const target = PushTargetState(
        target: pushHermesApiTarget,
        status: PushStatus.needsHermesPlugin,
        hermesInstallCommand: 'hermes plugins install x --enable',
      );
      final rig = await _pump(tester, pushStateWith([target]));
      final pageId = pushTargetPageId(target.scope);
      await rig.open(pageId);

      await rig.change(_action(target.scope), true);

      check(copied).equals('hermes plugins install x --enable');
      check(rig.footers(pageId)).contains('Copied to clipboard');
    });

    testWidgets('asking the admin shares the import link and function id', (
      tester,
    ) async {
      final shared = <Object?>[];
      const channel = MethodChannel('dev.fluttercommunity.plus/share');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        shared.add(call.arguments);
        return 'dev.fluttercommunity.plus/share/unavailable';
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      final rig = await _pump(
        tester,
        pushStateWith([_owui(PushStatus.needsAdminSetup)]),
      );

      await rig.change(_action(_owuiScope), true);

      final text = (shared.single! as Map)['text'] as String;
      check(text).contains(
        'https://raw.githubusercontent.com/cogwheel0/conduit/main/'
        'server-plugins/openwebui/conduit_push.py',
      );
      check(text).contains('conduit_push');
      check(text).contains('docs/push/ADMIN_SETUP.md');
    });

    testWidgets('a failure retries', (tester) async {
      final rig = await _pump(
        tester,
        pushStateWith([
          _owui(
            PushStatus.failed,
            failure: const PushFailure(PushFailureReason.serverUnreachable),
          ),
        ]),
      );
      await rig.change(_action(_owuiScope), true);
      check(rig.fake.calls).deepEquals(['retry $_owuiScope']);
    });

    test('signing in closes Settings for an account, and opens a '
        "connection's own page", () {
      NativeSheetItemConfig fix(PushTargetState target) => _rowsOf(
        buildPushTargetPage(
          _l10n,
          target: target,
          title: 'x',
          pushEnabled: true,
        ),
      ).singleWhere((row) => row.accent == true);

      final account = fix(_owui(PushStatus.signInNeeded));
      check(account.dismissOnSelect).equals(true);
      check(account.actionId).equals(pushTargetSignInActionId);
      check(account.actionValue).equals(_owuiScope);

      final connection = fix(
        const PushTargetState(
          target: pushHermesApiTarget,
          status: PushStatus.signInNeeded,
        ),
      );
      check(connection.id).equals(hermesConnectionPageId('conn-api'));
      check(connection.dismissOnSelect).equals(false);
    });
  });

  group("a target's page", () {
    testWidgets('explains, tests, and sets the options', (tester) async {
      final rig = await _pump(tester, pushStateWith([_owui(PushStatus.on)]));
      final pageId = pushTargetPageId(_owuiScope);
      final scope = Uri.encodeComponent(_owuiScope);
      await rig.open(pageId);
      check(rig.page(pageId)!.title).equals('ada@example.com');
      check(rig.rows(pageId).first.subtitle).equals(
        'Notifications for this account reach this device even while '
        'Conduit is closed.',
      );

      await rig.change('$pushTargetTestPrefix$scope', true);
      check(rig.fake.calls).deepEquals(['sendTest $_owuiScope']);
      check(rig.footers(pageId)).contains('The test notification arrived.');
      check(rig.page(pageId)!.announcement)
          .equals('The test notification arrived.');

      await rig.change('$pushTargetOriginPrefix$scope:any', true);
      check(rig.fake.calls.last).equals('setOrigin $_owuiScope any');
      check(rig.row(pageId, '$pushTargetOriginPrefix$scope:any').checked)
          .equals(true);

      await rig.change('$pushTargetUsePrefix$scope', false);
      check(rig.fake.calls.last).equals('setTargetOptedOut $_owuiScope true');
      check(rig.rows(pageId).first.subtitle)
          .equals('Push is turned off for this account on this device.');
    });

    testWidgets('a test that did not arrive says so in its group', (
      tester,
    ) async {
      final rig = await _pump(tester, pushStateWith([_owui(PushStatus.on)]));
      rig.fake.testArrives = false;
      final pageId = pushTargetPageId(_owuiScope);
      await rig.open(pageId);

      await rig.change(
        '$pushTargetTestPrefix${Uri.encodeComponent(_owuiScope)}',
        true,
      );

      final failed = rig
          .rows(pageId)
          .singleWhere(
            (row) => row.title == "The test notification didn't arrive.",
          );
      check(failed.sfSymbol).equals('exclamationmark.triangle');
    });

    testWidgets('a test answered after its page was left is not put on the '
        'page opened since', (tester) async {
      final rig = await _pump(tester, pushStateWith([_owui(PushStatus.on)]));
      final gate = Completer<void>();
      final pageId = pushTargetPageId(_owuiScope);
      await rig.open(pageId);
      rig.fake.testGate = gate;

      final sending = rig.module.handleChange(
        '$pushTargetTestPrefix${Uri.encodeComponent(_owuiScope)}',
        true,
        _l10n,
      );
      await tester.pump();
      // Left, and opened again, while the test is on its way.
      rig.module.pageLeft(pageId);
      await rig.open(pageId);
      gate.complete();
      await rig.settle(sending);

      check(rig.footers(pageId))
          .not((it) => it.contains('The test notification arrived.'));
    });

    test('shows the Hermes command to run, and no reply origin', () {
      const target = PushTargetState(
        target: pushHermesApiTarget,
        status: PushStatus.needsHermesPlugin,
        hermesInstallCommand: 'hermes -p work plugins install x --enable',
      );
      final page = buildPushTargetPage(
        _l10n,
        target: target,
        title: 'Home Hermes',
        pushEnabled: true,
      );
      final rows = _rowsOf(page);
      check(rows.map((row) => row.subtitle))
          .contains('hermes -p work plugins install x --enable');
      // Without a pinned plugin commit the command installs the latest one.
      check(page.sections.first.footer).equals(
        kConduitHermesPluginPinned ? null : _l10n.pushHermesCommandLatest,
      );
      check(rows.map((row) => row.title))
          .not((it) => it.contains('All My Chats'));
    });

    test('a failure says what happens next', () {
      final status = _rowsOf(
        buildPushTargetPage(
          _l10n,
          target: _owui(
            PushStatus.failed,
            failure: const PushFailure(PushFailureReason.relayError),
          ),
          title: 'x',
          pushEnabled: true,
        ),
      ).first;
      check(status.title).equals("The push relay couldn't be reached.");
      check(status.subtitle).equals(
        'Conduit tries again by itself the next time you open it, or you '
        'can try again now.',
      );
    });

    testWidgets('a page whose target is gone closes', (tester) async {
      final rig = await _pump(tester, pushStateWith([_owui(PushStatus.on)]));
      final pageId = pushTargetPageId(_owuiScope);
      await rig.open(pageId);
      check(rig.closed).isEmpty();

      // Signed out of on another screen meanwhile.
      rig.fake.emit(pushStateWith(const []));
      await rig.idle();

      check(rig.closed).deepEquals([pageId]);
    });

    testWidgets('follows push as setup finishes', (tester) async {
      final rig = await _pump(
        tester,
        pushStateWith([_owui(PushStatus.settingUp)]),
      );
      final pageId = pushTargetPageId(_owuiScope);
      await rig.open(pageId);
      check(rig.rows(pageId).first.title).equals('Setting up…');
      // Some time later, as a setup takes.
      for (var i = 0; i < 3; i++) {
        await rig.idle();
      }

      rig.fake.emit(pushStateWith([_owui(PushStatus.on)]));
      await rig.idle();

      check(rig.rows(pageId).first.title).equals('On');
    });
  });

  testWidgets('the targets list opens each target on a page of Settings', (
    tester,
  ) async {
    final rig = await _pump(tester, pushStateWith([_owui(PushStatus.on)]));
    await rig.open(NativeSheetRoutes.pushTargets);

    final row = rig.rows(NativeSheetRoutes.pushTargets).single;
    check(row.id).equals(pushTargetPageId(_owuiScope));
    check(row.dismissOnSelect).equals(false);
    // Known, so the row pushes it.
    check(rig.page(pushTargetPageId(_owuiScope))).isNotNull();
  });

  test('How Push Stays Private is a page of Settings, with the full '
      'details linked', () {
    final page = buildPushPrivacyPage(_l10n);
    check(page.id).equals(pushPrivacyPageId);
    final rows = _rowsOf(page);
    check(rows.first.title).equals(_l10n.pushPrivacyIntro);
    check(page.sections.map((section) => section.title))
        .contains(_l10n.pushPrivacyRelayTitle);
    check(rows.last.title).equals(_l10n.pushPrivacyReadMore);
    check(rows.last.url).isNotNull();
  });

  test('Notifications opens the privacy page inside Settings', () {
    final rows = [
      for (final section in buildNativePushSections(
        _l10n,
        pushStateWith([_owui(PushStatus.on)]),
      ))
        ...section.items,
    ];
    final privacy = rows.singleWhere((row) => row.id == pushPrivacyPageId);
    check(privacy.dismissOnSelect).equals(false);
    check(privacy.actionId).isNull();
  });

  group("an account's row menu", () {
    final entry = OpenWebUiAccountEntry(
      account: OpenWebUiAccount(id: 'acct-1', serverId: 'srv', isActive: true),
      server: OpenWebUiServer(
        id: 'srv',
        name: 'Home',
        endpoints: [OpenWebUiEndpoint(id: 'e', url: 'https://home.example')],
      ),
      summary: const OpenWebUiAccountSummary(name: 'Ada'),
      isActive: true,
      hasSession: true,
    );

    List<NativeSheetRowAction> menu(Set<String> attention) =>
        buildNativeAccountsDetail(
              _l10n,
              accounts: [entry],
              hermesConnections: const [],
              hermesInUseId: null,
              directProfiles: const [],
              pushAttention: attention,
            ).sections
            .expand((section) => section.items)
            .singleWhere(
              (row) => row.id == '$nativeAccountSwitchActionId:acct-1',
            )
            .rowActions;

    test('offers its push page while push needs the user', () {
      final action = menu({_owuiScope}).single;
      check(action.label).equals('Push Settings');
      check(action.detailId).equals(pushTargetPageId(_owuiScope));
    });

    test('offers nothing for push otherwise', () {
      check(menu(const {})).isEmpty();
    });
  });

  group('signing in to the account in use', () {
    Future<(FakePushCoordinator, _SpyAuth)> signIn(
      WidgetTester tester, {
      required _SessionApi api,
    }) async {
      final auth = _SpyAuth();
      final fake = FakePushCoordinator(
        pushStateWith([_owui(PushStatus.signInNeeded)]),
      );
      final container = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWith(
            () => FixedSettings(const AppSettings(notificationsEnabled: true)),
          ),
          pushCoordinatorProvider.overrideWith(() => fake),
          openWebUiAccountsProvider.overrideWith(
            (ref) async => const <OpenWebUiAccountEntry>[],
          ),
          notificationTargetsAvailableProvider.overrideWithValue(false),
          openWebUiAccountsControllerProvider.overrideWith(_AlreadyActive.new),
          apiServiceProvider.overrideWithValue(api),
          authStateManagerProvider.overrideWith(() => auth),
        ],
      );
      addTearDown(container.dispose);
      container.read(pushCoordinatorProvider);
      // As in the app, the session was loaded long before this screen.
      container.read(authStateManagerProvider);
      final router = GoRouter(
        navigatorKey: NavigationService.navigatorKey,
        routes: [
          GoRoute(path: '/', builder: (_, _) => const _App()),
          GoRoute(
            path: Routes.authentication,
            builder: (_, _) => const Text('sign-in page'),
          ),
        ],
      );
      NavigationService.attachRouter(router);
      addTearDown(router.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            routerConfig: router,
            localizationsDelegates: conduitLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
          ),
        ),
      );
      await tester.pumpAndSettle();

      container
          .read(settingsControllerProvider)
          .handle(
            const NativeSheetControlChanged(
              id: pushTargetSignInActionId,
              value: _owuiScope,
            ),
            source: SettingsEventSource.flutter,
          );
      await tester.pumpAndSettle();
      return (fake, auth);
    }

    testWidgets('a session its server refuses goes to sign in again', (
      tester,
    ) async {
      final (fake, auth) = await signIn(tester, api: _SessionApi(status: 401));
      check(auth.invalidations).equals(1);
      check(find.text('sign-in page').evaluate()).isNotEmpty();
      check(fake.calls).isEmpty();
    });

    testWidgets('a session that still works sets push up again', (
      tester,
    ) async {
      final (fake, auth) = await signIn(tester, api: _SessionApi(status: 200));
      check(auth.invalidations).equals(0);
      check(fake.calls).deepEquals(['retry $_owuiScope']);
    });
  });
}

/// The app root as far as Settings needs it: it attaches the controller.
final class _App extends ConsumerStatefulWidget {
  const _App();

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
  Widget build(BuildContext context) => const SizedBox();
}

/// An accounts controller whose account is already the active one.
final class _AlreadyActive extends OpenWebUiAccountsController {
  _AlreadyActive(super.ref);

  @override
  Future<OpenWebUiAccountChangeResult> switchTo(
    String accountId, {
    bool force = false,
  }) async => OpenWebUiAccountChangeResult.alreadyActive;
}

/// The active account's client, whose server answers the session check
/// with [status].
final class _SessionApi extends ApiService {
  _SessionApi({required this.status})
    : super(
        serverConfig: const ServerConfig(
          id: 'acct-1',
          name: 'Home',
          url: 'https://home.test',
        ),
        workerManager: WorkerManager(),
      );

  final int status;

  @override
  String? get authToken => 'opaque-session-token';

  @override
  Future<User> getCurrentUser({
    bool suppressAuthFailureNotification = false,
    String? candidateAuthToken,
    ApiAuthSnapshot? authSnapshot,
  }) async {
    if (status != 200) {
      final request = RequestOptions(path: '/api/v1/auths/');
      throw DioException(
        requestOptions: request,
        response: Response<Object?>(
          requestOptions: request,
          statusCode: status,
        ),
      );
    }
    return const User(
      id: 'u',
      username: 'ada',
      email: 'ada@example.com',
      role: 'user',
    );
  }
}

final class _SpyAuth extends AuthStateManager {
  int invalidations = 0;

  @override
  Future<AuthState> build() async =>
      const AuthState(status: AuthStatus.authenticated, token: 'token');

  @override
  Future<void> onTokenInvalidated() async {
    invalidations++;
    await future;
    state = const AsyncData(AuthState(status: AuthStatus.tokenExpired));
  }
}
