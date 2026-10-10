import 'package:checks/checks.dart';
import 'package:conduit/features/notifications/services/local_notification_service.dart';
import 'package:conduit/features/notifications/services/notification_tap_router.dart';
import 'package:conduit_core/auth/openwebui_account_summaries.dart';
import 'package:conduit_core/features/hermes/models/hermes_connection_profile.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/notifications/models/app_notification.dart';
import 'package:conduit_core/models/openwebui_registry.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/openwebui_accounts_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

OpenWebUiAccountEntry _entry(String id, {bool active = false}) =>
    OpenWebUiAccountEntry(
      account: OpenWebUiAccount(id: id, serverId: '$id-server', userId: 'u'),
      server: OpenWebUiServer(
        id: '$id-server',
        name: id,
        endpoints: [OpenWebUiEndpoint(id: 'lan', url: 'https://$id.example')],
      ),
      summary: const OpenWebUiAccountSummary(name: 'Ada'),
      isActive: active,
      hasSession: true,
    );

const _hermesHome = HermesConnectionProfile(
  id: 'conn-home',
  name: 'Home',
  documentTrustPrincipalId: 'p-home',
);

const _hermesWork = HermesConnectionProfile(
  id: 'conn-work',
  name: 'Work',
  documentTrustPrincipalId: 'p-work',
);

/// The settled active account, which a fake switch moves.
class _SettledAccount extends SettledActiveAccountId {
  _SettledAccount(this.initial);

  final String? initial;

  @override
  String? build() => initial;

  void settle(String? accountId) => state = accountId;
}

/// Answers switches from [results], in order, and records them.
class _FakeAccounts extends Fake implements OpenWebUiAccountsController {
  _FakeAccounts(this.results, {required this.onSwitched});

  final List<OpenWebUiAccountChangeResult> results;
  final void Function(String accountId) onSwitched;
  final List<(String, bool)> switches = [];

  @override
  Future<OpenWebUiAccountChangeResult> switchTo(
    String accountId, {
    bool force = false,
  }) async {
    switches.add((accountId, force));
    final result = results.removeAt(0);
    if (result == OpenWebUiAccountChangeResult.done ||
        result == OpenWebUiAccountChangeResult.needsSignIn) {
      onSwitched(accountId);
    }
    return result;
  }
}

class _ThrowingAccounts extends Fake implements OpenWebUiAccountsController {
  @override
  Future<OpenWebUiAccountChangeResult> switchTo(
    String accountId, {
    bool force = false,
  }) async => throw StateError('storage');
}

/// Records what the router asked the screen to do.
class _RecordingNavigator implements NotificationTapNavigator {
  final List<String> calls = [];
  bool confirmAnswer = true;
  bool hermesSwitchSucceeds = true;

  @override
  Future<bool> confirmSwitchStopsReply() async {
    calls.add('confirm');
    return confirmAnswer;
  }

  @override
  void openSignIn() => calls.add('sign-in');

  @override
  Future<bool> useHermesConnection(String connectionId) async {
    calls.add('use-hermes:$connectionId');
    return hermesSwitchSucceeds;
  }

  @override
  void showTargetUnavailable() => calls.add('unavailable');

  @override
  void showError() => calls.add('error');

  @override
  Future<void> openOpenWebUiChat(String chatId) async =>
      calls.add('chat:$chatId');

  @override
  void openChannel(String channelId) => calls.add('channel:$channelId');

  @override
  Future<void> openHermesSession(
    String sessionId, {
    required String connectionId,
    required String title,
  }) async => calls.add('hermes-session:$connectionId/$sessionId:$title');

  @override
  void openHermesJobs() => calls.add('hermes-jobs');

  @override
  Future<void> openDirectConversation(
    String conversationId, {
    required String title,
  }) async => calls.add('direct:$conversationId');
}

void main() {
  late _RecordingNavigator navigator;
  late _SettledAccount settled;
  late _FakeAccounts accounts;
  late ProviderContainer container;

  String? settledAccount() => container.read(settledActiveAccountIdProvider);

  NotificationTapRouter build({
    String activeAccountId = 'acct-1',
    List<OpenWebUiAccountChangeResult> results = const [],
    OpenWebUiAccountsController? controller,
    String? activeHermesId = 'conn-home',
    bool hermesEnabled = true,
  }) {
    navigator = _RecordingNavigator();
    settled = _SettledAccount(activeAccountId);
    accounts = _FakeAccounts(
      List.of(results),
      onSwitched: (id) => settled.settle(id),
    );
    final routerProvider = Provider<NotificationTapRouter>(
      (ref) => NotificationTapRouter(
        ref,
        navigator,
        settleTimeout: const Duration(milliseconds: 200),
      ),
    );
    container = ProviderContainer(
      overrides: [
        settledActiveAccountIdProvider.overrideWith(() => settled),
        openWebUiAccountsProvider.overrideWith(
          (ref) async => [
            _entry('acct-1', active: activeAccountId == 'acct-1'),
            _entry('acct-2', active: activeAccountId == 'acct-2'),
          ],
        ),
        openWebUiAccountsControllerProvider.overrideWithValue(
          controller ?? accounts,
        ),
        hermesConnectionsProvider.overrideWithValue([_hermesHome, _hermesWork]),
        hermesActiveConnectionIdProvider.overrideWithValue(activeHermesId),
        hermesEnabledProvider.overrideWithValue(hermesEnabled),
      ],
    );
    addTearDown(container.dispose);
    // Built before a fake switch moves it.
    container.read(settledActiveAccountIdProvider);
    return container.read(routerProvider);
  }

  NotificationTap tap(
    NotificationKind kind,
    String sourceId, {
    String? scope,
  }) => NotificationTap(kind: kind, sourceId: sourceId, scope: scope);

  group('Open WebUI', () {
    test('a chat in the active account opens without switching', () async {
      final router = build(
        results: [OpenWebUiAccountChangeResult.alreadyActive],
      );
      await router.openTap(
        tap(NotificationKind.chatCompletion, 'c1', scope: 'owui:acct-1'),
      );
      check(navigator.calls).deepEquals(['chat:c1']);
    });

    test('another account is switched to, then the chat opens', () async {
      final router = build(results: [OpenWebUiAccountChangeResult.done]);
      await router.openTap(
        tap(NotificationKind.replyFailed, 'c2', scope: 'owui:acct-2'),
      );
      check(accounts.switches).deepEquals([('acct-2', false)]);
      check(settledAccount()).equals('acct-2');
      check(navigator.calls).deepEquals(['chat:c2']);
    });

    test('a channel message opens its channel', () async {
      final router = build(results: [OpenWebUiAccountChangeResult.done]);
      await router.openTap(
        tap(NotificationKind.channelMessage, 'ch-9', scope: 'owui:acct-2'),
      );
      check(navigator.calls).deepEquals(['channel:ch-9']);
    });

    test('a reply in the way asks first; keeping it stays put', () async {
      final router = build(
        results: [OpenWebUiAccountChangeResult.blockedByActiveReply],
      );
      navigator.confirmAnswer = false;
      await router.openTap(
        tap(NotificationKind.chatCompletion, 'c2', scope: 'owui:acct-2'),
      );
      check(accounts.switches).deepEquals([('acct-2', false)]);
      check(navigator.calls).deepEquals(['confirm']);
      check(settledAccount()).equals('acct-1');
    });

    test('agreeing to stop the reply switches with force', () async {
      final router = build(
        results: [
          OpenWebUiAccountChangeResult.blockedByActiveReply,
          OpenWebUiAccountChangeResult.done,
        ],
      );
      await router.openTap(
        tap(NotificationKind.chatCompletion, 'c2', scope: 'owui:acct-2'),
      );
      check(
        accounts.switches,
      ).deepEquals([('acct-2', false), ('acct-2', true)]);
      check(navigator.calls).deepEquals(['confirm', 'chat:c2']);
    });

    test('an account that needs a sign-in opens it, not the chat', () async {
      final router = build(results: [OpenWebUiAccountChangeResult.needsSignIn]);
      await router.openTap(
        tap(NotificationKind.chatCompletion, 'c2', scope: 'owui:acct-2'),
      );
      check(navigator.calls).deepEquals(['sign-in']);
    });

    test('a removed account says so and switches nowhere', () async {
      final router = build();
      await router.openTap(
        tap(NotificationKind.chatCompletion, 'c3', scope: 'owui:gone'),
      );
      check(accounts.switches).isEmpty();
      check(navigator.calls).deepEquals(['unavailable']);
    });

    test('a failed switch says so', () async {
      final router = build(controller: _ThrowingAccounts());
      await router.openTap(
        tap(NotificationKind.chatCompletion, 'c2', scope: 'owui:acct-2'),
      );
      check(navigator.calls).deepEquals(['error']);
    });

    test('a switch that never settles opens nothing', () async {
      final router = build(
        controller: _FakeAccounts([
          OpenWebUiAccountChangeResult.done,
        ], onSwitched: (_) {}),
      );
      await router.openTap(
        tap(NotificationKind.chatCompletion, 'c2', scope: 'owui:acct-2'),
      );
      check(navigator.calls).isEmpty();
    });

    test('a tap from before scopes opens in the active account', () async {
      final router = build();
      await router.openTap(tap(NotificationKind.chatCompletion, 'c1'));
      check(accounts.switches).isEmpty();
      check(navigator.calls).deepEquals(['chat:c1']);
    });
  });

  group('Hermes', () {
    test('the connection in use opens the session', () async {
      final router = build();
      await router.openNotification(
        const AppNotification(
          kind: NotificationKind.chatCompletion,
          scope: 'hermes:conn-home',
          title: 'Refactor plan',
          body: 'Done.',
          sourceId: 's-1',
          dedupKey: 'hermes:conn-home|hermes:s-1:t-1',
        ),
      );
      check(
        navigator.calls,
      ).deepEquals(['hermes-session:conn-home/s-1:Refactor plan']);
    });

    test('another connection is used first', () async {
      final router = build();
      await router.openTap(
        tap(NotificationKind.chatCompletion, 's-1', scope: 'hermes:conn-work'),
      );
      check(
        navigator.calls,
      ).deepEquals(['use-hermes:conn-work', 'hermes-session:conn-work/s-1:']);
    });

    test('Hermes switched off is turned on through the same flow', () async {
      final router = build(hermesEnabled: false);
      await router.openTap(
        tap(NotificationKind.chatCompletion, 's-1', scope: 'hermes:conn-home'),
      );
      check(navigator.calls.first).equals('use-hermes:conn-home');
    });

    test('a failed connection switch opens nothing', () async {
      final router = build();
      navigator.hermesSwitchSucceeds = false;
      await router.openTap(
        tap(NotificationKind.chatCompletion, 's-1', scope: 'hermes:conn-work'),
      );
      check(navigator.calls).deepEquals(['use-hermes:conn-work']);
    });

    test('a scheduled task opens the jobs page', () async {
      final router = build();
      await router.openTap(
        tap(NotificationKind.scheduledTask, 'job-1', scope: 'hermes:conn-home'),
      );
      check(navigator.calls).deepEquals(['hermes-jobs']);
    });

    test('a removed connection says so', () async {
      final router = build();
      await router.openTap(
        tap(NotificationKind.chatCompletion, 's-1', scope: 'hermes:gone'),
      );
      check(navigator.calls).deepEquals(['unavailable']);
    });
  });

  group('Direct and push', () {
    test('a Direct reply opens its on-device conversation', () async {
      final router = build();
      await router.openTap(
        tap(NotificationKind.chatCompletion, 'direct-local:1', scope: 'direct'),
      );
      check(navigator.calls).deepEquals(['direct:direct-local:1']);
      check(accounts.switches).isEmpty();
    });

    test('a test push opens nothing', () async {
      final router = build();
      await router.openTap(
        tap(NotificationKind.pushTest, 'nonce', scope: 'owui:acct-1'),
      );
      check(navigator.calls).isEmpty();
    });

    test('a tapped cp/1 push opens in the scope it arrived for', () async {
      final router = build(results: [OpenWebUiAccountChangeResult.done]);
      final opened = await router.openCp1({
        'v': 1,
        'k': 'channel',
        'src': 'owui',
        'ids': {'channel': 'ch-9', 'msg': 'm-42'},
        't': '#general',
        'b': 'hi',
        'ts': 1760000000,
        'dk': 'channel:ch-9:m-42',
      }, scope: 'owui:acct-2');
      check(opened).isTrue();
      check(accounts.switches).deepEquals([('acct-2', false)]);
      check(navigator.calls).deepEquals(['channel:ch-9']);
    });

    test('an invalid cp/1 payload opens nothing', () async {
      final router = build();
      check(
        await router.openCp1({'v': 2}, scope: 'owui:acct-1'),
      ).isFalse();
      check(navigator.calls).isEmpty();
    });
  });

  group('NotificationTap', () {
    const notification = AppNotification(
      kind: NotificationKind.replyFailed,
      scope: 'hermes:conn-home',
      title: 'Plan',
      body: '',
      sourceId: 's-1',
      dedupKey: 'hermes:conn-home|hermes:s-1:t',
      group: 'hermes:s-1',
    );

    test('version 2 round-trips its scope and group', () {
      final payload = NotificationTap.encode(notification);
      check(payload).contains('"v":2');
      check(payload).contains('"kind":"reply_failed"');
      final tap = NotificationTap.tryDecode(payload)!;
      check(tap.kind).equals(NotificationKind.replyFailed);
      check(tap.sourceId).equals('s-1');
      check(tap.scope).equals('hermes:conn-home');
      check(tap.group).equals('hermes:s-1');
    });

    test('version 1 still parses, without a scope', () {
      final tap = NotificationTap.tryDecode(
        '{"kind":"chatCompletion","sourceId":"c1"}',
      )!;
      check(tap.kind).equals(NotificationKind.chatCompletion);
      check(tap.scope).isNull();
    });

    test('version 2 without a valid scope is rejected', () {
      check(
        NotificationTap.tryDecode(
          '{"v":2,"kind":"chat_completion","sourceId":"c1"}',
        ),
      ).isNull();
      check(
        NotificationTap.tryDecode(
          '{"v":2,"kind":"chat_completion","sourceId":"c1","scope":"x"}',
        ),
      ).isNull();
    });

    test('unknown kinds and junk are rejected', () {
      check(
        NotificationTap.tryDecode('{"kind":"poke","sourceId":"c1"}'),
      ).isNull();
      check(NotificationTap.tryDecode('not json')).isNull();
      check(NotificationTap.tryDecode(null)).isNull();
    });
  });
}
