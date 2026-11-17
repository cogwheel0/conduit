@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:conduit_core/auth/auth_state_manager.dart';
import 'package:conduit_core/features/librechat/models/librechat_account.dart'
    show LibreChatRegistry;
import 'package:conduit_core/features/librechat/models/librechat_server.dart';
import 'package:conduit_core/features/librechat/providers/librechat_providers.dart';
import 'package:conduit_core/features/librechat/services/librechat_auth_service.dart'
    show LibreChatAuthService, LibreChatSignedIn;
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/persistence/hive_boxes.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:conduit_core/ports/secure_key_value_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/backend_mode_providers.dart';
import 'package:conduit_core/providers/openwebui_accounts_controller.dart';
import 'package:conduit_core/providers/primary_account_providers.dart';
import 'package:conduit_core/providers/primary_account_switcher.dart';
import 'package:conduit_core/services/optimized_storage_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/testing.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:hive_ce/hive.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

/// A LibreChat sign-in step puts its account in charge only while it is the
/// sign-in under way, under the account in charge when it began: through
/// the core's real account storage and switch, against the core's fake
/// LibreChat server (an in-process Dio adapter). No network.
void main() {
  late _Bench bench;

  setUp(() async => bench = await _Bench.start());
  tearDown(() => bench.close());

  test('a sign-in overtaken while Open WebUI parks for it puts no account in '
      'charge', () async {
    LibreChatSignInResult? newer;
    // A newer sign-in begins (and is refused) while the first one's switch
    // parks Open WebUI.
    bench.auth.duringPark = () async {
      newer = await bench.service.signIn(
        LibreChatSignIn(url: bench.fake.baseUrl, email: _blake, password: 'x'),
      );
    };

    final first = await bench.service.signIn(
      LibreChatSignIn(
        url: bench.fake.baseUrl,
        email: _avery,
        password: 'pw-avery',
      ),
    );

    expect(newer?.outcome, LibreChatSignInOutcome.rejected);
    expect(first.outcome, LibreChatSignInOutcome.expired);
    expect(bench.preferred(), PreferredBackend.owui);
    expect(await bench.activeLibreChat(), isNull);
    expect(bench.owuiSwitches, contains('owui'), reason: 'Open WebUI back');
  });

  test(
    'a code sent for a flow that is gone leaves the sign-in under way alone',
    () async {
      final asked = Completer<void>();
      final release = Completer<void>();
      bench.fake.beforeAnswer = (request) async {
        if (request.path.endsWith('/api/auth/login') && !release.isCompleted) {
          if (!asked.isCompleted) asked.complete();
          await release.future;
        }
      };
      final signingIn = bench.service.signIn(
        LibreChatSignIn(
          url: bench.fake.baseUrl,
          email: _avery,
          password: 'pw-avery',
        ),
      );
      await asked.future;

      // A late code from a form that is long gone.
      final stale = await bench.service.verify(
        const LibreChatVerify(flowId: 'flow-from-before', code: '135790'),
      );
      expect(stale.outcome, LibreChatSignInOutcome.expired);

      release.complete();
      final done = await signingIn;
      expect(done.outcome, LibreChatSignInOutcome.signedIn);
      expect(bench.preferred(), PreferredBackend.libreChat);
    },
  );

  test('a code the server takes signs in although a wrong one was tried '
      'meanwhile', () async {
    bench.fake.addUser(email: _casey, password: 'pw-casey', totpCode: '246810');
    final flow = await bench.service.signIn(
      LibreChatSignIn(
        url: bench.fake.baseUrl,
        email: _casey,
        password: 'pw-casey',
      ),
    );
    expect(flow.outcome, LibreChatSignInOutcome.twoFactorRequired);

    final asked = Completer<void>();
    final release = Completer<void>();
    var verifies = 0;
    bench.fake.beforeAnswer = (request) async {
      if (request.path.endsWith('/api/auth/2fa/verify-temp') &&
          ++verifies == 1) {
        asked.complete();
        await release.future;
      }
    };
    final right = bench.service.verify(
      LibreChatVerify(flowId: flow.flowId!, code: '246810'),
    );
    await asked.future;
    final wrong = await bench.service.verify(
      LibreChatVerify(flowId: flow.flowId!, code: '111111'),
    );
    expect(wrong.outcome, LibreChatSignInOutcome.invalidCode);

    release.complete();
    expect((await right).outcome, LibreChatSignInOutcome.signedIn);
  });

  test(
    'a two-step flow begun under one account takes no code under another',
    () async {
      bench.fake.addUser(
        email: _casey,
        password: 'pw-casey',
        totpCode: '246810',
      );
      final flow = await bench.service.signIn(
        LibreChatSignIn(
          url: bench.fake.baseUrl,
          email: _casey,
          password: 'pw-casey',
        ),
      );
      expect(flow.outcome, LibreChatSignInOutcome.twoFactorRequired);

      // Another account is put in charge before the code is sent.
      await bench.useOtherOpenWebUi();

      final late = await bench.service.verify(
        LibreChatVerify(flowId: flow.flowId!, code: '246810'),
      );
      expect(late.outcome, LibreChatSignInOutcome.expired);
      expect(bench.preferred(), PreferredBackend.owui);
      expect((await bench.registry()).accounts, isEmpty);
    },
  );

  test('a single sign-on started under one account completes under no '
      'other', () async {
    bench.fake.startupConfig
      ..['socialLoginEnabled'] = true
      ..['openidLoginEnabled'] = true;
    final user = bench.fake.addUser(email: _casey, password: 'pw-casey');
    bench.fake.refreshTokens['refresh-from-the-browser'] = user.id;
    final plan = await bench.service.ssoStart(
      LibreChatSsoStart(url: bench.fake.baseUrl, provider: 'openid'),
    );

    await bench.useOtherOpenWebUi();

    final done = await bench.service.completeSso(
      LibreChatSsoCompletion(
        url: bench.fake.baseUrl,
        cookies: const {'refreshToken': 'refresh-from-the-browser'},
        startId: plan.startId,
      ),
    );
    expect(done.outcome, LibreChatSignInOutcome.expired);
    expect(bench.preferred(), PreferredBackend.owui);
    expect((await bench.registry()).accounts, isEmpty);
  });

  test('a Switch Anyway asked over one account switches nothing once '
      'another is in charge', () async {
    final avery = await bench.saveLibreChatAccount();
    // Asked over owui; owui-2 takes charge before the answer arrives.
    await bench.useOtherOpenWebUi();
    bench.owuiSwitches.clear();

    for (final target in <String>['owui-3', avery]) {
      await expectLater(
        bench.accounts.switchTo(
          AccountRef(accountId: target, force: true, askedOver: 'owui'),
        ),
        throwsA(
          isA<RpcError>().having(
            (e) => e.code,
            'code',
            ConduitErrorCodes.sessionExpired,
          ),
        ),
      );
    }
    expect(bench.owuiSwitches, isEmpty);
    expect(bench.preferred(), PreferredBackend.owui);
    expect(await bench.activeLibreChat(), isNull);
    expect(
      bench.container.read(primaryAccountProvider),
      const PrimaryAccountRef(PrimaryAccountKind.openWebUi, 'owui-2'),
    );

    // Asked over the account in charge, it goes ahead.
    await bench.accounts.switchTo(
      const AccountRef(accountId: 'owui-3', force: true, askedOver: 'owui-2'),
    );
    expect(bench.owuiSwitches, <String>['owui-3']);
  });

  test('cookies from an older single sign-on window put no account in '
      'charge', () async {
    bench.fake.startupConfig
      ..['socialLoginEnabled'] = true
      ..['openidLoginEnabled'] = true;
    final user = bench.fake.addUser(email: _casey, password: 'pw-casey');
    bench.fake.refreshTokens['refresh-from-the-first-window'] = user.id;
    bench.fake.refreshTokens['refresh-from-the-second-window'] = user.id;
    const start = LibreChatSsoStart(
      url: 'https://chat.example.com',
      provider: 'openid',
    );
    final first = await bench.service.ssoStart(start);
    final second = await bench.service.ssoStart(start);
    expect(first.startId, isNotNull);
    expect(second.startId, isNot(first.startId));

    // The first window finishes last: its cookies are not the newer start's.
    final stale = await bench.service.completeSso(
      LibreChatSsoCompletion(
        url: bench.fake.baseUrl,
        cookies: const {'refreshToken': 'refresh-from-the-first-window'},
        startId: first.startId,
      ),
    );
    expect(stale.outcome, LibreChatSignInOutcome.expired);
    expect((await bench.registry()).accounts, isEmpty);
    expect(bench.preferred(), PreferredBackend.owui);

    final done = await bench.service.completeSso(
      LibreChatSsoCompletion(
        url: bench.fake.baseUrl,
        cookies: const {'refreshToken': 'refresh-from-the-second-window'},
        startId: second.startId,
      ),
    );
    expect(done.outcome, LibreChatSignInOutcome.signedIn);
  });

  test('a forced switch that names no account it was asked over is '
      'refused', () async {
    await expectLater(
      bench.accounts.switchTo(
        const AccountRef(accountId: 'owui-3', force: true),
      ),
      throwsA(
        isA<RpcError>().having(
          (e) => e.code,
          'code',
          ConduitErrorCodes.invalidParams,
        ),
      ),
    );
    expect(bench.owuiSwitches, isEmpty);
    expect(bench.stops, 0);
  });

  test('a forced switch whose account left charge while it waited its turn '
      'is refused at its turn, and stops nothing', () async {
    final signedIn = await bench.service.signIn(
      LibreChatSignIn(
        url: bench.fake.baseUrl,
        email: _avery,
        password: 'pw-avery',
      ),
    );
    expect(signedIn.outcome, LibreChatSignInOutcome.signedIn);
    final avery = signedIn.accountId!;
    bench.owuiSwitches.clear();
    final stopsBefore = bench.stops;

    // Another switch holds the queue while both are asked for, over avery.
    final release = Completer<void>();
    var holding = true;
    final queued = bench.container
        .read(primaryAccountSwitcherProvider)
        .handOverUnclaimedTab(
          unclaimed: () => holding,
          candidates: () async {
            await release.future;
            holding = false;
            return (libreChatId: null, openWebUiId: null);
          },
        );
    final first = bench.accounts.switchTo(
      AccountRef(accountId: 'owui-2', force: true, askedOver: avery),
    );
    final second = bench.accounts.switchTo(
      AccountRef(accountId: 'owui-3', force: true, askedOver: avery),
    );
    final refusedLater = expectLater(
      second,
      throwsA(
        isA<RpcError>().having(
          (e) => e.code,
          'code',
          ConduitErrorCodes.sessionExpired,
        ),
      ),
    );
    await pumpEventQueue();
    expect(bench.owuiSwitches, isEmpty, reason: 'both wait their turn');
    release.complete();
    expect(await queued, isFalse);

    await first;
    await refusedLater;
    expect(bench.owuiSwitches, <String>['owui-2']);
    expect(bench.stops - stopsBefore, 1, reason: 'the second stopped answers');
  });

  test('a sign-in overtaken while its backend choice is written leaves '
      'neither the choice nor its account in charge', () async {
    final release = bench.preferences.hold('libreChat');
    final first = bench.service.signIn(
      LibreChatSignIn(
        url: bench.fake.baseUrl,
        email: _avery,
        password: 'pw-avery',
      ),
    );
    await bench.preferences.asked;
    // A newer sign-in begins (and is refused) while the choice is written.
    final newer = await bench.service.signIn(
      LibreChatSignIn(url: bench.fake.baseUrl, email: _blake, password: 'x'),
    );
    expect(newer.outcome, LibreChatSignInOutcome.rejected);
    release.complete();

    expect((await first).outcome, LibreChatSignInOutcome.expired);
    expect(bench.preferred(), PreferredBackend.owui);
    expect(
      PreferencesStore.getString('preferred_backend_v1'),
      PreferredBackend.owui.name,
    );
    expect(await bench.activeLibreChat(), isNull);
    expect(bench.owuiSwitches, contains('owui'), reason: 'Open WebUI back');
  });

  // The saved backend choice is put back exactly as it was stored: Open
  // WebUI, Direct, Hermes or none at all.
  for (final prior in <String?>['owui', 'direct', 'hermes', null]) {
    test('a superseded sign-in leaves the saved backend choice '
        '${prior ?? 'unset'} as it was', () async {
      await PreferencesStore.put('preferred_backend_v1', prior);
      bench.container.invalidate(preferredBackendProvider);
      final before = bench.preferred();
      final release = bench.preferences.hold('libreChat');
      final first = bench.service.signIn(
        LibreChatSignIn(
          url: bench.fake.baseUrl,
          email: _avery,
          password: 'pw-avery',
        ),
      );
      await bench.preferences.asked;
      // A newer sign-in begins (and is refused) while the choice is written.
      await bench.service.signIn(
        LibreChatSignIn(url: bench.fake.baseUrl, email: _blake, password: 'x'),
      );
      release.complete();

      expect((await first).outcome, LibreChatSignInOutcome.expired);
      expect(PreferencesStore.getString('preferred_backend_v1'), prior);
      expect(bench.preferred(), before);
      expect(await bench.activeLibreChat(), isNull);
    });
  }
}

const _avery = 'avery@example.com';
const _blake = 'blake@example.com';
const _casey = 'casey@example.com';

/// Parks through storage alone, as the core's switch tests do.
final class _Auth extends AuthStateManager {
  _Auth(this.storage);

  final OptimizedStorageService storage;

  /// Runs while Open WebUI parks, as another step of the user's may.
  Future<void> Function()? duringPark;

  @override
  Future<AuthState> build() async =>
      const AuthState(status: AuthStatus.authenticated, token: 'owui');

  @override
  Future<void> parkActiveAccount() async {
    await duringPark?.call();
    await storage.parkActiveServer(
      fromServerId: await storage.getEffectiveActiveServerId(),
    );
  }
}

final class _OpenWebUiAccounts extends OpenWebUiAccountsController {
  _OpenWebUiAccounts(super.ref, this.storage, this.switches);

  final OptimizedStorageService storage;
  final List<String> switches;

  @override
  Future<OpenWebUiAccountChangeResult> switchTo(
    String accountId, {
    bool force = false,
    bool Function()? stillFrom,
  }) async {
    switches.add(accountId);
    await storage.switchActiveServer(
      fromServerId: await storage.getEffectiveActiveServerId(),
      toServerId: accountId,
    );
    return OpenWebUiAccountChangeResult.done;
  }
}

/// Two saved Open WebUI accounts, the first in charge; avery and blake on a
/// fake LibreChat server; the daemon's LibreChat service over the core's
/// real account storage.
final class _Bench {
  _Bench._(
    this._tempDir,
    this._workers,
    this.fake,
    this.container,
    this.auth,
    this.accounts,
    this.service,
    this.owuiSwitches,
    this._stops,
    this.preferences,
  );

  final Directory _tempDir;
  final WorkerManager _workers;
  final FakeLibreChatServer fake;
  final ProviderContainer container;
  final _Auth auth;
  final AccountsService accounts;
  final LibreChatService service;
  final List<String> owuiSwitches;

  /// Times a switch stopped the answers being written.
  int get stops => _stops.value;
  final _Count _stops;

  /// The preferences store, whose next backend choice can be held.
  final _HeldPreferences preferences;

  PreferredBackend preferred() => container.read(preferredBackendProvider);

  Future<LibreChatRegistry> registry() =>
      container.read(libreChatRegistryProvider.future);

  Future<String?> activeLibreChat() async => (await registry()).activeId;

  /// Saves avery's LibreChat account (signed in, not in charge); its id.
  Future<String> saveLibreChatAccount() async {
    const server = LibreChatServer(baseUrl: 'https://chat.example.com');
    final auth = LibreChatAuthService(server, adapter: fake);
    addTearDown(auth.close);
    final signedIn = await auth.signIn(
      email: _avery,
      password: 'pw-avery',
    ) as LibreChatSignedIn;
    final account = await container
        .read(libreChatAccountsProvider)
        .saveSignedIn(
          server: server,
          session: signedIn.session,
          activate: false,
        );
    return account.id;
  }

  /// The user puts the other Open WebUI account in charge.
  Future<void> useOtherOpenWebUi() async {
    await container
        .read(primaryAccountSwitcherProvider)
        .useOpenWebUi('owui-2', force: true);
    container
      ..read(settledActiveAccountIdProvider)
      ..invalidate(activeServerProvider);
    await container.read(activeServerProvider.future);
    expect(
      container.read(primaryAccountProvider),
      const PrimaryAccountRef(PrimaryAccountKind.openWebUi, 'owui-2'),
    );
  }

  static Future<_Bench> start() async {
    final tempDir = await Directory.systemTemp.createTemp('lc-sign-in-test');
    Hive.init(tempDir.path);
    final boxes = HiveBoxes(
      preferences: await Hive.openBox<dynamic>(HiveBoxNames.preferences),
      caches: await Hive.openBox<dynamic>(HiveBoxNames.caches),
      attachmentQueue: await Hive.openBox<dynamic>(
        HiveBoxNames.attachmentQueue,
      ),
      metadata: await Hive.openBox<dynamic>(HiveBoxNames.metadata),
    );
    final preferences = _HeldPreferences();
    PreferencesStore.installLoader(() async => preferences);
    await PreferencesStore.ensureInitialized();
    final workers = WorkerManager(maxConcurrentTasks: 1);
    final storage = OptimizedStorageService(
      secureStorage: InMemorySecureKeyValueStore(),
      boxes: boxes,
      workerManager: workers,
    );
    await storage.saveServerConfigs(const [
      ServerConfig(id: 'owui', name: 'owui', url: 'https://owui.example.com'),
      ServerConfig(
        id: 'owui-2',
        name: 'owui-2',
        url: 'https://owui-2.example.com',
      ),
      ServerConfig(
        id: 'owui-3',
        name: 'owui-3',
        url: 'https://owui-3.example.com',
      ),
    ]);
    await storage.setActiveServerId('owui');
    await storage.saveAuthToken('owui-token');
    await PreferencesStore.put(
      'preferred_backend_v1',
      PreferredBackend.owui.name,
    );
    final fake = FakeLibreChatServer()
      ..addUser(email: _avery, password: 'pw-avery')
      ..addUser(email: _blake, password: 'pw-blake');
    final switches = <String>[];
    final stops = _Count();
    late _Auth auth;
    final container = ProviderContainer(
      overrides: [
        secureStorageProvider.overrideWithValue(InMemorySecureKeyValueStore()),
        optimizedStorageServiceProvider.overrideWithValue(storage),
        workerManagerProvider.overrideWithValue(workers),
        authStateManagerProvider.overrideWith(() => auth = _Auth(storage)),
        openWebUiAccountsControllerProvider.overrideWith(
          (ref) => _OpenWebUiAccounts(ref, storage, switches),
        ),
        accountChangeReplyGuardProvider.overrideWithValue(() => false),
        accountChangeStopRepliesProvider.overrideWithValue(() => stops.value++),
        libreChatHttpAdapterProvider.overrideWithValue(fake),
      ],
      retry: (_, _) => null,
    );
    await container.read(authStateManagerProvider.future);
    container.read(openWebUiAccountsControllerProvider);
    final accounts = AccountsService(container, events: EventBus());
    final service = LibreChatService(
      container,
      events: EventBus(),
      accounts: accounts,
    );
    return _Bench._(
      tempDir,
      workers,
      fake,
      container,
      auth,
      accounts,
      service,
      switches,
      stops,
      preferences,
    );
  }

  Future<void> close() async {
    container.dispose();
    _workers.dispose();
    PreferencesStore.debugReset();
    await Hive.close();
    if (_tempDir.existsSync()) _tempDir.deleteSync(recursive: true);
  }
}

final class _Count {
  int value = 0;
}

/// Preferences whose next write of the chosen backend waits once [hold] is
/// called: [asked] completes as it arrives.
final class _HeldPreferences extends InMemoryKeyValueStore {
  Completer<void>? _release;
  Completer<void> _asked = Completer<void>();
  String? _value;

  Future<void> get asked => _asked.future;

  /// Holds the next write of [value] as the chosen backend.
  Completer<void> hold(String value) {
    _value = value;
    _asked = Completer<void>();
    return _release = Completer<void>();
  }

  @override
  Future<bool> setString(String key, String value) async {
    final release = _release;
    if (release != null && key == 'preferred_backend_v1' && value == _value) {
      _release = null;
      _asked.complete();
      await release.future;
    }
    return super.setString(key, value);
  }
}
