import 'dart:convert';

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

/// A JWT whose `exp` is [expiresAt], unsigned: only its claims are read.
String _jwt(DateTime expiresAt) {
  String part(Map<String, Object> claims) =>
      base64Url.encode(utf8.encode(jsonEncode(claims))).replaceAll('=', '');
  final exp = expiresAt.millisecondsSinceEpoch ~/ 1000;
  return '${part({'alg': 'HS256'})}.${part({'exp': exp})}.signature';
}

/// A new address of a saved server must reach that server before it is
/// saved: every account on it may later send its session there.
void main() {
  Future<OpenWebUiAddressCheckResult> check0({
    required String? activeAccountId,
    String address = 'https://home.example.net',
    String? liveToken,
    Map<String, String> kept = const {},
    Set<String> sessions = const {},
    Map<String, String> usersByToken = const {},
    List<String>? asked,
    bool agrees = true,
    List<Uri>? confirmations,
  }) => checkOpenWebUiAddress(
    registry: _registry,
    serverId: 'home',
    address: address,
    activeAccountId: activeAccountId,
    liveToken: liveToken,
    keptTokenFor: (id) async => kept[id],
    accountsWithSession: sessions,
    confirmSendingSession: (address) async {
      confirmations?.add(address);
      return agrees;
    },
    userAt: (token) async {
      asked?.add(token);
      final user = usersByToken[token];
      if (user == null) throw StateError('401');
      return user;
    },
  );

  test('the active account checks it with its own token', () async {
    final asked = <String>[];

    final found = await check0(
      activeAccountId: 'ada',
      liveToken: 'live-ada',
      kept: {'bob': 'kept-bob'},
      usersByToken: {'live-ada': 'user-ada'},
      asked: asked,
    );

    check(found.result).equals(OpenWebUiAddressCheck.sameServer);
    check(found.provedBy).equals('ada');
    check(asked).deepEquals(['live-ada']);
  });

  test('a server whose accounts are all inactive is checked with a token '
      'kept for one of them', () async {
    final found = await check0(
      activeAccountId: 'cy',
      liveToken: 'live-cy',
      kept: {'bob': 'kept-bob'},
      usersByToken: {'kept-bob': 'user-bob'},
    );

    check(found.result).equals(OpenWebUiAddressCheck.sameServer);
    // Bob's token proved it, so a proxy cookie captured on the way is his.
    check(found.provedBy).equals('bob');
  });

  test('an address that names someone else, or refuses the token, is '
      'another server', () async {
    final namesSomeoneElse = await check0(
      activeAccountId: 'cy',
      kept: {'bob': 'kept-bob'},
      usersByToken: {'kept-bob': 'user-somebody-else'},
    );
    check(namesSomeoneElse.result)
        .equals(OpenWebUiAddressCheck.differentServer);
    check(namesSomeoneElse.provedBy).isNull();
    final refuses = await check0(
      activeAccountId: 'cy',
      kept: {'bob': 'kept-bob'},
    );
    check(refuses.result).equals(OpenWebUiAddressCheck.differentServer);
  });

  test('an expired token is not sent; another account\'s proves it', () async {
    final asked = <String>[];

    final found = await check0(
      activeAccountId: 'ada',
      liveToken: _jwt(DateTime.now().subtract(const Duration(days: 1))),
      kept: {'bob': 'kept-bob'},
      usersByToken: {'kept-bob': 'user-bob'},
      asked: asked,
    );

    check(found.result).equals(OpenWebUiAddressCheck.sameServer);
    check(found.provedBy).equals('bob');
    check(asked).deepEquals(['kept-bob']);
  });

  test('a refused token gives way to the next account\'s', () async {
    final asked = <String>[];

    final found = await check0(
      activeAccountId: 'ada',
      liveToken: 'live-ada',
      kept: {'bob': 'kept-bob'},
      sessions: {'ada', 'bob'},
      usersByToken: {'kept-bob': 'user-bob'},
      asked: asked,
    );

    check(found.result).equals(OpenWebUiAddressCheck.sameServer);
    check(asked).deepEquals(['live-ada', 'kept-bob']);
  });

  test('tokens that are all stale ask to sign in, never accept', () async {
    final found = await check0(
      activeAccountId: 'ada',
      liveToken: _jwt(DateTime.now().subtract(const Duration(days: 1))),
      kept: {'bob': 'kept-bob'},
      sessions: {'ada', 'bob'},
    );

    check(found.result).equals(OpenWebUiAddressCheck.needsSignIn);
  });

  test(
    'a saved sign-in with no token to check with asks to sign in first',
    () async {
      final found = await check0(
        activeAccountId: 'cy',
        sessions: {'bob', 'cy'},
      );
      check(found.result).equals(OpenWebUiAddressCheck.needsSignIn);
    },
  );

  test('a token goes to a new host only once the user agrees', () async {
    final asked = <String>[];
    final confirmations = <Uri>[];

    final found = await check0(
      activeAccountId: 'ada',
      liveToken: 'live-ada',
      usersByToken: {'live-ada': 'user-ada'},
      asked: asked,
      agrees: false,
      confirmations: confirmations,
    );

    check(found.result).equals(OpenWebUiAddressCheck.declined);
    check(asked).isEmpty();
    check(confirmations.single.host).equals('home.example.net');
  });

  test('a host one of the routes already uses is not asked about', () async {
    final confirmations = <Uri>[];

    final found = await check0(
      activeAccountId: 'ada',
      address: 'http://10.0.0.2:3000/owui',
      liveToken: 'live-ada',
      usersByToken: {'live-ada': 'user-ada'},
      agrees: false,
      confirmations: confirmations,
    );

    check(found.result).equals(OpenWebUiAddressCheck.sameServer);
    check(confirmations).isEmpty();
  });

  test(
    'a server with nothing kept for its accounts has nothing to protect',
    () async {
      final found = await check0(activeAccountId: 'cy', sessions: {'cy'});
      check(found.result).equals(OpenWebUiAddressCheck.nothingToProtect);
    },
  );
}
