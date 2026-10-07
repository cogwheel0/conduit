import 'package:checks/checks.dart';
import 'package:conduit_core/auth/openwebui_address_check.dart';
import 'package:conduit_core/models/openwebui_registry.dart';
import 'package:test/test.dart';

final _registry = OpenWebUiRegistry(
  servers: [
    OpenWebUiServer(
      id: 'home',
      name: 'Home',
      endpoints: [OpenWebUiEndpoint(id: 'lan', url: 'http://10.0.0.2:3000')],
    ),
    OpenWebUiServer(
      id: 'work',
      name: 'Work',
      endpoints: [OpenWebUiEndpoint(id: 'www', url: 'https://work.example')],
    ),
  ],
  accounts: [
    OpenWebUiAccount(id: 'ada', serverId: 'home', userId: 'user-ada'),
    OpenWebUiAccount(id: 'bob', serverId: 'home', userId: 'user-bob'),
    OpenWebUiAccount(id: 'cy', serverId: 'work', userId: 'user-cy'),
  ],
);

/// A new address of a saved server must reach that server before it is
/// saved: every account on it may later send its session there.
void main() {
  Future<OpenWebUiAddressCheck> check0({
    required String? activeAccountId,
    String? liveToken,
    Map<String, String> kept = const {},
    Set<String> sessions = const {},
    Map<String, String> usersByToken = const {},
    List<String>? asked,
  }) => checkOpenWebUiAddress(
    registry: _registry,
    serverId: 'home',
    activeAccountId: activeAccountId,
    liveToken: liveToken,
    keptTokenFor: (id) async => kept[id],
    accountsWithSession: sessions,
    userAt: (token) async {
      asked?.add(token);
      final user = usersByToken[token];
      if (user == null) throw StateError('401');
      return user;
    },
  );

  test('the active account checks it with its own token', () async {
    final asked = <String>[];

    final result = await check0(
      activeAccountId: 'ada',
      liveToken: 'live-ada',
      kept: {'bob': 'kept-bob'},
      usersByToken: {'live-ada': 'user-ada'},
      asked: asked,
    );

    check(result).equals(OpenWebUiAddressCheck.sameServer);
    check(asked).deepEquals(['live-ada']);
  });

  test('a server whose accounts are all inactive is checked with a token '
      'kept for one of them', () async {
    final result = await check0(
      activeAccountId: 'cy',
      liveToken: 'live-cy',
      kept: {'bob': 'kept-bob'},
      usersByToken: {'kept-bob': 'user-bob'},
    );

    check(result).equals(OpenWebUiAddressCheck.sameServer);
  });

  test('an address that names someone else, or refuses the token, is '
      'another server', () async {
    check(
      await check0(
        activeAccountId: 'cy',
        kept: {'bob': 'kept-bob'},
        usersByToken: {'kept-bob': 'user-somebody-else'},
      ),
    ).equals(OpenWebUiAddressCheck.differentServer);
    check(await check0(activeAccountId: 'cy', kept: {'bob': 'kept-bob'}))
        .equals(OpenWebUiAddressCheck.differentServer);
  });

  test(
    'a saved sign-in with no token to check with asks to sign in first',
    () async {
      check(await check0(activeAccountId: 'cy', sessions: {'bob', 'cy'}))
          .equals(OpenWebUiAddressCheck.needsSignIn);
    },
  );

  test(
    'a server with nothing kept for its accounts has nothing to protect',
    () async {
      check(await check0(activeAccountId: 'cy', sessions: {'cy'}))
          .equals(OpenWebUiAddressCheck.nothingToProtect);
    },
  );
}
