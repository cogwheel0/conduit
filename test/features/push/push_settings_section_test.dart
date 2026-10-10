import 'package:conduit/features/notifications/views/notification_settings_page.dart';
import 'package:conduit/features/profile/widgets/account_actions.dart'
    show ActiveCheckmark;
import 'package:conduit/features/push/views/push_privacy_page.dart';
import 'package:conduit/features/push/widgets/push_target_detail_sheet.dart'
    show PushTargetDetailSheet;
import 'package:conduit/shared/widgets/utility_components.dart'
    show UtilityRow;
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/widgets/conduit_components.dart'
    show ConduitLoadingIndicator;
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart'
    show AdaptiveButton, AdaptiveSwitch;
import 'package:conduit_core/auth/api_auth_interceptor.dart' show ApiAuthSnapshot;
import 'package:conduit_core/auth/auth_state_manager.dart';
import 'package:conduit_core/features/notifications/providers/notification_target_providers.dart';
import 'package:conduit_core/features/push/models/push_status.dart';
import 'package:conduit_core/features/push/providers/push_providers.dart';
import 'package:conduit_core/features/push/services/hermes_push_backend.dart'
    show kConduitHermesPluginPinned;
import 'package:conduit_core/navigation/routes.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:conduit_core/ports/push_platform_port.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/openwebui_accounts_controller.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:dio/dio.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import 'push_test_support.dart';

const _owuiScope = 'owui:acct-1';

Future<FakePushCoordinator> _pump(
  WidgetTester tester,
  PushState state, {
  bool advanced = false,
  List<String> distributors = const [],
  bool settle = true,
  bool hasOpenWebUiAccount = true,
  List<Override> overrides = const [],
}) async {
  tester.view
    ..physicalSize = const Size(900, 3200)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final fake = FakePushCoordinator(state, distributorList: distributors);
  final container = ProviderContainer(
    overrides: [
      appSettingsProvider.overrideWith(
        () => FixedSettings(
          AppSettings(
            notificationsEnabled: true,
            advancedFeaturesEnabled: advanced,
          ),
        ),
      ),
      pushCoordinatorProvider.overrideWith(() => fake),
      openWebUiAccountsProvider.overrideWith(
        (ref) async => const <OpenWebUiAccountEntry>[],
      ),
      // Webhook destinations are a separate feature.
      notificationTargetsAvailableProvider.overrideWithValue(false),
      openWebUiAccountAvailableProvider.overrideWithValue(hasOpenWebUiAccount),
      ...overrides,
    ],
  );
  addTearDown(container.dispose);
  // Push is kept alive from launch in the app.
  container.read(pushCoordinatorProvider);
  final router = GoRouter(
    initialLocation: Routes.notificationSettings,
    routes: [
      GoRoute(
        path: Routes.notificationSettings,
        name: RouteNames.notificationSettings,
        builder: (_, _) => const NotificationSettingsPage(),
      ),
      GoRoute(
        path: Routes.pushPrivacy,
        name: RouteNames.pushPrivacy,
        builder: (_, _) => const PushPrivacyPage(),
      ),
      GoRoute(
        path: Routes.authentication,
        builder: (_, _) => const Text('sign-in page'),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    // A spinner never settles.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }
  return fake;
}

Finder _inRow(String scope, Finder finder) => find.descendant(
  of: find.byKey(Key('push-target-$scope')),
  matching: finder,
);

PushTargetState _owui(PushStatus status, {PushFailure? failure}) =>
    PushTargetState(target: pushOwuiTarget, status: status, failure: failure);

void main() {
  setUp(() => PreferencesStore.debugOverride(InMemoryKeyValueStore()));
  tearDown(PreferencesStore.debugReset);

  group('the switch', () {
    testWidgets('turns push on', (tester) async {
      final fake = await _pump(tester, pushStateWith(const [], enabled: false));

      expect(find.text('Push notifications'), findsWidgets);
      expect(
        find.text(
          'Get notified while Conduit is closed. End-to-end encrypted.',
        ),
        findsOneWidget,
      );
      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('push-enabled')),
          matching: find.byType(AdaptiveSwitch),
        ),
      );
      await tester.pumpAndSettle();
      expect(fake.calls, ['setEnabled true']);
    });

    testWidgets('is off with a reason in an iOS build without a relay', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        final fake = await _pump(
          tester,
          pushStateWith(const [], enabled: false, relayConfigured: false),
        );
        expect(find.text('Not available in this build'), findsOneWidget);
        await tester.tap(find.byKey(const Key('push-enabled')));
        await tester.pumpAndSettle();
        expect(fake.calls, isEmpty);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('points Android without a relay at UnifiedPush', (
      tester,
    ) async {
      await _pump(
        tester,
        pushStateWith(
          const [],
          enabled: false,
          relayConfigured: false,
          transports: const [PushTransport.fcm],
        ),
      );
      expect(
        find.text(
          'Not available in this build without a UnifiedPush distributor',
        ),
        findsOneWidget,
      );
      expect(find.byKey(const Key('push-get-distributor')), findsOneWidget);
    });

    testWidgets('offers system settings when notifications are blocked', (
      tester,
    ) async {
      await _pump(
        tester,
        pushStateWith([
          _owui(PushStatus.permissionDenied),
        ], permissionDenied: true),
      );
      expect(find.byKey(const Key('push-permission-denied')), findsOneWidget);
      expect(
        find.text('Allow notifications for Conduit in system settings.'),
        findsOneWidget,
      );
    });
  });

  group('each status shows its fix', () {
    final cases = <String, (PushTargetState, String status, String? action)>{
      'canInstall': (
        _owui(PushStatus.canInstall),
        'Not set up on this server',
        'Set up',
      ),
      'needsAdminSetup': (
        _owui(PushStatus.needsAdminSetup),
        'Needs your admin to set up',
        'Ask your admin',
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
        'Needs Open WebUI 0.10 or newer',
        null,
      ),
      'signInNeeded': (
        _owui(PushStatus.signInNeeded),
        'Sign in to use push',
        'Sign in',
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
        'Copy command',
      ),
    };
    for (final MapEntry(key: name, value: (target, status, action))
        in cases.entries) {
      testWidgets(name, (tester) async {
        await _pump(tester, pushStateWith([target]));
        expect(_inRow(target.scope, find.text(status)), findsOneWidget);
        final buttons = _inRow(target.scope, find.byType(AdaptiveButton));
        if (action == null) {
          expect(buttons, findsNothing);
        } else {
          expect(
            _inRow(target.scope, find.widgetWithText(AdaptiveButton, action)),
            findsOneWidget,
          );
        }
      });
    }

    for (final (status, text) in [
      (PushStatus.verifying, 'Sending a test notification…'),
      (PushStatus.settingUp, 'Setting up…'),
    ]) {
      testWidgets('${status.name} shows a spinner', (tester) async {
        await _pump(tester, pushStateWith([_owui(status)]), settle: false);
        expect(_inRow(_owuiScope, find.text(text)), findsOneWidget);
        expect(
          _inRow(_owuiScope, find.byType(ConduitLoadingIndicator)),
          findsOneWidget,
        );
      });
    }

    testWidgets('restartHermes shows a spinner and what to do', (tester) async {
      const target = PushTargetState(
        target: pushHermesDesktopTarget,
        status: PushStatus.restartHermes,
      );
      await _pump(tester, pushStateWith([target]), settle: false);
      expect(
        _inRow(target.scope, find.text('Restart Hermes to finish')),
        findsOneWidget,
      );
      expect(
        _inRow(target.scope, find.byType(ConduitLoadingIndicator)),
        findsOneWidget,
      );
    });

    testWidgets('on shows a check mark', (tester) async {
      await _pump(tester, pushStateWith([_owui(PushStatus.on)]));
      expect(_inRow(_owuiScope, find.text('On')), findsOneWidget);
      expect(_inRow(_owuiScope, find.byType(ActiveCheckmark)), findsOneWidget);
    });
  });

  group('one-tap fixes', () {
    testWidgets('installing asks first and links to the source', (
      tester,
    ) async {
      final fake = await _pump(
        tester,
        pushStateWith([_owui(PushStatus.canInstall)]),
      );

      await tester.tap(_inRow(_owuiScope, find.text('Set up')));
      await tester.pumpAndSettle();
      expect(find.text('Install Conduit Push?'), findsOneWidget);
      expect(find.text('View source'), findsOneWidget);
      expect(
        find.text(
          'https://github.com/cogwheel0/conduit/blob/main/server-plugins/'
          'openwebui/conduit_push.py',
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('push-install-cancel')));
      await tester.pumpAndSettle();
      expect(fake.calls, isEmpty);

      await tester.tap(_inRow(_owuiScope, find.text('Set up')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('push-install-confirm')));
      await tester.pumpAndSettle();
      expect(fake.calls, ['installOpenWebUiFunction $_owuiScope']);
    });

    testWidgets('the Hermes plugin installs after a confirmation', (
      tester,
    ) async {
      const target = PushTargetState(
        target: pushHermesDesktopTarget,
        status: PushStatus.needsHermesPlugin,
        canInstallHermesPlugin: true,
      );
      final fake = await _pump(tester, pushStateWith([target]));

      await tester.tap(_inRow(target.scope, find.text('Install')));
      await tester.pumpAndSettle();
      expect(find.text('Install the Conduit plugin?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('push-install-confirm')));
      await tester.pumpAndSettle();
      expect(fake.calls, ['installHermesPlugin ${target.scope}']);
    });

    testWidgets('the Hermes command is copied', (tester) async {
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
      await _pump(tester, pushStateWith([target]));

      await tester.tap(_inRow(target.scope, find.text('Copy command')));
      await tester.pumpAndSettle();
      expect(copied, 'hermes plugins install x --enable');
      expect(find.text('Copied to clipboard'), findsOneWidget);
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
      await _pump(tester, pushStateWith([_owui(PushStatus.needsAdminSetup)]));

      await tester.tap(_inRow(_owuiScope, find.text('Ask your admin')));
      await tester.pumpAndSettle();
      final text = (shared.single! as Map)['text'] as String;
      expect(
        text,
        contains(
          'https://raw.githubusercontent.com/cogwheel0/conduit/main/'
          'server-plugins/openwebui/conduit_push.py',
        ),
      );
      expect(text, contains('conduit_push'));
      expect(text, contains('docs/push/ADMIN_SETUP.md'));
    });

    testWidgets('a failure retries', (tester) async {
      final fake = await _pump(
        tester,
        pushStateWith([
          _owui(
            PushStatus.failed,
            failure: const PushFailure(PushFailureReason.serverUnreachable),
          ),
        ]),
      );
      await tester.tap(_inRow(_owuiScope, find.text('Retry')));
      await tester.pumpAndSettle();
      expect(fake.calls, ['retry $_owuiScope']);
    });
  });

  group('the detail sheet', () {
    testWidgets('explains, tests, and sets the options', (tester) async {
      final fake = await _pump(tester, pushStateWith([_owui(PushStatus.on)]));

      await tester.tap(_inRow(_owuiScope, find.text('ada@example.com')));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Notifications for this account reach this device even while '
          'Conduit is closed.',
        ),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('push-detail-test')));
      await tester.pumpAndSettle();
      expect(fake.calls, ['sendTest $_owuiScope']);
      expect(find.text('The test notification arrived.'), findsOneWidget);

      await tester.tap(find.byKey(const Key('push-origin-any')));
      await tester.pumpAndSettle();
      expect(fake.calls.last, 'setOrigin $_owuiScope any');
      expect(
        find.descendant(
          of: find.byKey(const Key('push-origin-any')),
          matching: find.byType(ActiveCheckmark),
        ),
        findsOneWidget,
      );

      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('push-detail-use')),
          matching: find.byType(AdaptiveSwitch),
        ),
      );
      await tester.pumpAndSettle();
      expect(fake.calls.last, 'setTargetOptedOut $_owuiScope true');
      expect(
        find.text('Push is turned off for this account on this device.'),
        findsOneWidget,
      );
    });

    testWidgets('shows the Hermes command to run', (tester) async {
      const target = PushTargetState(
        target: pushHermesApiTarget,
        status: PushStatus.needsHermesPlugin,
        hermesInstallCommand: 'hermes -p work plugins install x --enable',
      );
      await _pump(tester, pushStateWith([target]));
      await tester.tap(_inRow(target.scope, find.text('Home Hermes')));
      await tester.pumpAndSettle();
      expect(
        find.text('hermes -p work plugins install x --enable'),
        findsWidgets,
      );
      // Without a pinned plugin commit the command installs the latest one.
      expect(
        find.byKey(const Key('push-detail-command-latest')),
        kConduitHermesPluginPinned ? findsNothing : findsOneWidget,
      );
      // Hermes has no reply origin choice.
      expect(find.text('All my chats'), findsNothing);
    });

    testWidgets('a failure says what happens next', (tester) async {
      await _pump(
        tester,
        pushStateWith([
          _owui(
            PushStatus.failed,
            failure: const PushFailure(PushFailureReason.relayError),
          ),
        ]),
      );
      await tester.tap(_inRow(_owuiScope, find.text('ada@example.com')));
      await tester.pumpAndSettle();
      final status = tester.widget<Text>(
        find.byKey(const Key('push-detail-status')),
      );
      expect(status.data, "The push relay couldn't be reached.");
      final explanation = tester.widget<Text>(
        find.byKey(const Key('push-detail-explanation')),
      );
      expect(
        explanation.data,
        'Conduit tries again by itself the next time you open it, or you '
        'can try again now.',
      );
      expect(find.byKey(const Key('push-detail-action')), findsOneWidget);
    });
  });

  group('advanced', () {
    testWidgets('Android picks its delivery service and distributor', (
      tester,
    ) async {
      final fake = await _pump(
        tester,
        pushStateWith(
          [_owui(PushStatus.on)],
          transports: const [PushTransport.fcm, PushTransport.unifiedPush],
        ),
        advanced: true,
        distributors: const ['io.heckel.ntfy', 'org.unifiedpush.distributor'],
      );

      expect(find.text('Push delivery'), findsOneWidget);
      expect(find.byKey(const Key('push-delivery-fcm')), findsOneWidget);
      await tester.tap(find.byKey(const Key('push-delivery-unifiedpush')));
      await tester.pumpAndSettle();
      expect(fake.calls, ['setAndroidTransport unifiedPush io.heckel.ntfy']);

      await tester.tap(
        find.byKey(const Key('push-distributor-org.unifiedpush.distributor')),
      );
      await tester.pumpAndSettle();
      expect(
        fake.calls.last,
        'setAndroidTransport unifiedPush org.unifiedpush.distributor',
      );
    });

    testWidgets('without a distributor it says where to get one', (
      tester,
    ) async {
      await _pump(
        tester,
        pushStateWith(
          [_owui(PushStatus.failed)],
          transports: const [PushTransport.fcm],
          androidTransport: PushAndroidTransport.unifiedPush,
        ),
        advanced: true,
      );
      expect(
        find.text('No UnifiedPush distributor is installed.'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('push-get-distributor')), findsOneWidget);
    });

    testWidgets('resetting keys asks first', (tester) async {
      final fake = await _pump(
        tester,
        pushStateWith([_owui(PushStatus.on)]),
        advanced: true,
      );
      await tester.tap(find.byKey(const Key('push-reset-keys')));
      await tester.pumpAndSettle();
      expect(find.text('Reset push keys?'), findsOneWidget);
      await tester.tap(find.text('Reset').last);
      await tester.pumpAndSettle();
      expect(fake.calls, ['resetKeys']);
    });

    testWidgets('is hidden without Advanced', (tester) async {
      await _pump(tester, pushStateWith([_owui(PushStatus.on)]));
      expect(find.text('Push delivery'), findsNothing);
      expect(find.byKey(const Key('push-reset-keys')), findsNothing);
    });
  });

  testWidgets('the privacy row opens the explainer', (tester) async {
    await _pump(tester, pushStateWith(const [], enabled: false));
    await tester.tap(find.byKey(const Key('push-privacy')));
    await tester.pumpAndSettle();
    expect(find.text('How push stays private'), findsWidgets);
    expect(find.text('The Conduit relay'), findsOneWidget);
    expect(find.byKey(const Key('push-privacy-read-more')), findsOneWidget);
  });

  testWidgets('push that can no longer work here can still be turned off', (
    tester,
  ) async {
    final fake = await _pump(
      tester,
      pushStateWith([_owui(PushStatus.failed)], transports: const []),
    );
    final row = tester.widget<UtilityRow>(
      find.byKey(const Key('push-enabled')),
    );
    expect(row.enabled, isTrue);
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('push-enabled')),
        matching: find.byType(AdaptiveSwitch),
      ),
    );
    await tester.pumpAndSettle();
    expect(fake.calls, ['setEnabled false']);
    // Off, it cannot be turned back on here.
    expect(
      tester.widget<UtilityRow>(find.byKey(const Key('push-enabled'))).enabled,
      isFalse,
    );
  });

  testWidgets('a switch that fails says so', (tester) async {
    final fake = await _pump(tester, pushStateWith(const [], enabled: false));
    fake.setEnabledError = StateError('platform');
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('push-enabled')),
        matching: find.byType(AdaptiveSwitch),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Something went wrong. Please try again.'), findsOneWidget);
  });

  testWidgets('a detail sheet whose target is gone closes', (tester) async {
    final fake = await _pump(tester, pushStateWith([_owui(PushStatus.on)]));
    await tester.tap(_inRow(_owuiScope, find.text('ada@example.com')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('push-detail-status')), findsOneWidget);

    // Signed out of on another screen meanwhile.
    fake.emit(pushStateWith(const []));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('push-detail-diagnostics')), findsNothing);
    expect(find.byType(PushTargetDetailSheet), findsNothing);
  });

  group('signing in to the account in use', () {
    Future<(FakePushCoordinator, _SpyAuth)> signIn(
      WidgetTester tester, {
      required _SessionApi api,
    }) async {
      final auth = _SpyAuth();
      final fake = await _pump(
        tester,
        pushStateWith([_owui(PushStatus.signInNeeded)]),
        overrides: [
          // The app still takes the account for signed in.
          openWebUiAccountsControllerProvider.overrideWith(_AlreadyActive.new),
          apiServiceProvider.overrideWithValue(api),
          authStateManagerProvider.overrideWith(() => auth),
        ],
      );
      await tester.tap(find.byKey(const Key('push-action-$_owuiScope')));
      await tester.pumpAndSettle();
      return (fake, auth);
    }

    testWidgets('a session its server refuses goes to sign in again', (
      tester,
    ) async {
      final (fake, auth) = await signIn(tester, api: _SessionApi(status: 401));
      expect(auth.invalidations, 1);
      expect(find.text('sign-in page'), findsOneWidget);
      expect(fake.calls, isEmpty);
    });

    testWidgets('a session that still works sets push up again', (
      tester,
    ) async {
      final (fake, auth) = await signIn(tester, api: _SessionApi(status: 200));
      expect(auth.invalidations, 0);
      expect(fake.calls, ['retry $_owuiScope']);
    });
  });

  testWidgets('without an Open WebUI account its channels go', (tester) async {
    await _pump(
      tester,
      pushStateWith(const [], enabled: false),
      hasOpenWebUiAccount: false,
    );
    expect(find.text('Channel messages'), findsNothing);
    expect(find.text('Scheduled tasks'), findsOneWidget);
    expect(find.byKey(const Key('push-enabled')), findsOneWidget);

    await _pump(tester, pushStateWith(const [], enabled: false));
    expect(find.text('Channel messages'), findsOneWidget);
  });

  testWidgets('the kinds include scheduled tasks', (tester) async {
    await _pump(tester, pushStateWith(const [], enabled: false));
    expect(find.text('Scheduled tasks'), findsOneWidget);
    expect(
      find.text('Notify when a Hermes scheduled task delivers its result.'),
      findsOneWidget,
    );
  });
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
        response: Response<Object?>(requestOptions: request, statusCode: status),
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
