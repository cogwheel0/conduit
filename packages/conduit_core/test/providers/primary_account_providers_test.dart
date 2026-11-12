import 'package:checks/checks.dart';
import 'package:conduit_core/auth/auth_state_manager.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/librechat/providers/librechat_providers.dart';
import 'package:conduit_core/features/workspace/models/workspace_capabilities.dart';
import 'package:conduit_core/features/workspace/providers/workspace_capabilities_provider.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/backend_mode_providers.dart';
import 'package:conduit_core/providers/chat_entry_readiness_providers.dart';
import 'package:conduit_core/providers/primary_account_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

const _admin = User(
  id: 'owui-admin',
  username: 'root',
  email: 'root@owui.example',
  name: 'Root',
  role: 'admin',
);

const _server = ServerConfig(
  id: 'owui',
  name: 'Open WebUI',
  url: 'https://owui.example',
);

final class _SignedInAuth extends AuthStateManager {
  @override
  Future<AuthState> build() async => const AuthState(
    status: AuthStatus.authenticated,
    token: 'owui-token',
    user: _admin,
  );
}

final class _Preferred extends PreferredBackendController {
  _Preferred(this.value);

  final PreferredBackend value;

  @override
  PreferredBackend build() => value;
}

void main() {
  late WorkerManager workers;

  setUp(() async {
    PreferencesStore.installLoader(() async => InMemoryKeyValueStore());
    await PreferencesStore.ensureInitialized();
    workers = WorkerManager(maxConcurrentTasks: 1);
  });

  tearDown(() {
    workers.dispose();
    PreferencesStore.debugReset();
  });

  /// An Open WebUI admin still signed in -- as a switch that crashed
  /// part-way could leave one -- with [preferred] in charge.
  Future<ProviderContainer> signedInAdmin(PreferredBackend preferred) async {
    final api = ApiService(serverConfig: _server, workerManager: workers);
    final container = ProviderContainer(
      overrides: [
        reviewerModeProvider.overrideWithValue(false),
        preferredBackendProvider.overrideWith(() => _Preferred(preferred)),
        authStateManagerProvider.overrideWith(_SignedInAuth.new),
        activeServerProvider.overrideWith((ref) async => _server),
        apiServiceProvider.overrideWithValue(api),
        currentUserProvider.overrideWith((ref) async => _admin),
      ],
    );
    addTearDown(container.dispose);
    await container.read(authStateManagerProvider.future);
    await container.read(currentUserProvider.future);
    return container;
  }

  group('with LibreChat in charge', () {
    test('no Open WebUI role opens the workspace', () async {
      final container = await signedInAdmin(PreferredBackend.libreChat);

      check(
        await container.read(workspaceCapabilitiesProvider.future),
      ).equals(WorkspaceCapabilities.none);
      check(container.read(openWebUiAccountAvailableProvider)).isFalse();
    });

    test('the Open WebUI user is never the primary user', () async {
      final container = await signedInAdmin(PreferredBackend.libreChat);

      check(container.read(primaryAccountKindProvider))
          .equals(PrimaryAccountKind.libreChat);
      check(container.read(primaryUserProvider)).isNull();
      // No LibreChat account is saved: once that is read, it needs sign-in.
      await container.read(libreChatSessionProvider.future);
      check(container.read(primaryAuthNavigationStateProvider))
          .equals(AuthNavigationState.needsLogin);
      // Chat waits for the LibreChat sign-in, not Open WebUI's.
      check(container.read(chatEntryReadyProvider)).isFalse();
    });

    test('the primary account is LibreChat\'s', () async {
      final container = await signedInAdmin(PreferredBackend.libreChat);
      check(container.read(primaryAccountProvider))
          .equals(const PrimaryAccountRef(PrimaryAccountKind.libreChat, null));
    });
  });

  group('with Open WebUI in charge', () {
    test('everything reads as before', () async {
      final container = await signedInAdmin(PreferredBackend.owui);

      check(
        await container.read(workspaceCapabilitiesProvider.future),
      ).equals(WorkspaceCapabilities.all);
      check(container.read(openWebUiAccountAvailableProvider)).isTrue();
      check(container.read(primaryAuthNavigationStateProvider)).equals(
        container.read(authNavigationStateProvider),
      );
      check(container.read(chatEntryReadyProvider)).isTrue();
      check(container.read(primaryUserProvider)).equals(
        const PrimaryUserSummary(
          kind: PrimaryAccountKind.openWebUi,
          id: 'owui-admin',
          displayName: 'Root',
          email: 'root@owui.example',
        ),
      );
    });

    test('Hermes and Direct installs keep an Open WebUI account', () async {
      for (final preferred in [
        PreferredBackend.hermes,
        PreferredBackend.direct,
        PreferredBackend.unset,
      ]) {
        final container = await signedInAdmin(preferred);
        check(
          because: preferred.name,
          container.read(primaryAccountKindProvider),
        ).equals(PrimaryAccountKind.openWebUi);
        check(
          because: preferred.name,
          container.read(openWebUiAccountAvailableProvider),
        ).isTrue();
      }
    });
  });

  group('a switch of the primary account', () {
    const owui = PrimaryAccountRef(PrimaryAccountKind.openWebUi, 'owui');
    const libreChat = PrimaryAccountRef(PrimaryAccountKind.libreChat, 'lc');

    test('is recorded until it settles', () async {
      const intent = PrimarySwitchIntent(from: owui, to: libreChat);
      check(PrimarySwitchIntent.read()).isNull();
      await intent.write();
      check(PrimarySwitchIntent.read()).equals(intent);
      await PrimarySwitchIntent.clear();
      check(PrimarySwitchIntent.read()).isNull();

      await PreferencesStore.put(PreferenceKeys.primarySwitchIntent, '{]');
      check(PrimarySwitchIntent.read()).isNull();
    });

    PrimaryBootRecovery decide({
      PrimarySwitchIntent? intent,
      PreferredBackend preferred = PreferredBackend.owui,
      bool parked = false,
      bool openWebUiAccounts = true,
      bool libreChatAccount = false,
    }) => decidePrimaryBootRecovery(
      intent: intent,
      preferredBackend: preferred,
      openWebUiParked: parked,
      hasOpenWebUiAccounts: openWebUiAccounts,
      hasActiveLibreChatAccount: libreChatAccount,
    );

    test('left unfinished is finished when its target can be used', () {
      check(
        decide(
          intent: const PrimarySwitchIntent(from: owui, to: libreChat),
          parked: true,
          libreChatAccount: true,
        ),
      ).equals(PrimaryBootRecovery.completeSwitch);
      check(
        decide(
          intent: const PrimarySwitchIntent(from: libreChat, to: owui),
          preferred: PreferredBackend.libreChat,
          parked: true,
        ),
      ).equals(PrimaryBootRecovery.completeSwitch);
    });

    test('left unfinished is undone when its target cannot be used', () {
      check(
        decide(
          intent: const PrimarySwitchIntent(from: owui, to: libreChat),
          parked: true,
        ),
      ).equals(PrimaryBootRecovery.revertSwitch);
      check(
        decide(
          intent: const PrimarySwitchIntent(from: libreChat, to: owui),
          preferred: PreferredBackend.libreChat,
          openWebUiAccounts: false,
          libreChatAccount: true,
        ),
      ).equals(PrimaryBootRecovery.revertSwitch);
    });

    test('never leaves the app with no account in charge', () {
      // Parked, but LibreChat is not (or no longer) in charge.
      check(decide(parked: true)).equals(PrimaryBootRecovery.unparkOpenWebUi);
      check(
        decide(preferred: PreferredBackend.libreChat, parked: true),
      ).equals(PrimaryBootRecovery.unparkOpenWebUi);
      // A LibreChat account whose session lapsed still owns the tab.
      check(
        decide(
          preferred: PreferredBackend.libreChat,
          parked: true,
          libreChatAccount: true,
        ),
      ).equals(PrimaryBootRecovery.none);
      // Nothing parked, or nothing to take back.
      check(decide()).equals(PrimaryBootRecovery.none);
      check(
        decide(parked: true, openWebUiAccounts: false),
      ).equals(PrimaryBootRecovery.none);
    });

    test('leaves Hermes or Direct in charge when chosen while parked', () {
      for (final preferred in [
        PreferredBackend.hermes,
        PreferredBackend.direct,
      ]) {
        check(
          because: preferred.name,
          decide(preferred: preferred, parked: true),
        ).equals(PrimaryBootRecovery.none);
      }
    });
  });
}
