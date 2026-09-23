import 'dart:convert';

import 'package:conduit_protocol/conduit_protocol.dart';

import 'protocol_fixtures.dart';
import 'protocol_goldens.dart';

/// Runs every protocol invariant and returns one string per failure.
///
/// Returning failures instead of throwing lets the same body back two very
/// different runners: `package:test` (which wants individual expectations)
/// and a bare `main()` compiled by `dart compile js` (which has no test
/// framework and must report everything in one pass).
List<String> runProtocolGoldenChecks() {
  final failures = <String>[];

  void check(bool condition, String describe) {
    if (!condition) failures.add(describe);
  }

  // The three maps must describe the same set of DTOs, or a type is being
  // encoded without ever being decoded (or golden-checked) again.
  final fixtureKeys = protocolFixtures.keys.toSet();
  final decoderKeys = protocolDecoders.keys.toSet();
  final goldenKeys = protocolGoldens.keys.toSet();
  check(
    fixtureKeys.difference(decoderKeys).isEmpty,
    'fixtures without a decoder: ${fixtureKeys.difference(decoderKeys)}',
  );
  check(
    decoderKeys.difference(fixtureKeys).isEmpty,
    'decoders without a fixture: ${decoderKeys.difference(fixtureKeys)}',
  );
  check(
    fixtureKeys.difference(goldenKeys).isEmpty,
    'fixtures without a golden (run tool/dump_goldens.dart): '
    '${fixtureKeys.difference(goldenKeys)}',
  );
  check(
    goldenKeys.difference(fixtureKeys).isEmpty,
    'stale goldens (run tool/dump_goldens.dart): '
    '${goldenKeys.difference(fixtureKeys)}',
  );

  for (final name in fixtureKeys.intersection(goldenKeys)) {
    final golden = jsonDecode(protocolGoldens[name]!) as Map<String, dynamic>;
    final encoded = encodeFixture(protocolFixtures[name]!);

    check(
      _deepEquals(encoded, golden),
      '$name: toJson drifted from its golden.\n'
      '  expected: ${jsonEncode(golden)}\n'
      '  actual:   ${jsonEncode(encoded)}',
    );

    // Decoding the golden and re-encoding must land back on the golden. This
    // is what catches a field that serializes but silently fails to parse.
    final decoder = protocolDecoders[name];
    if (decoder != null) {
      final reEncoded = encodeFixture(decoder(golden));
      check(
        _deepEquals(reEncoded, golden),
        '$name: fromJson/toJson is not a round trip.\n'
        '  expected: ${jsonEncode(golden)}\n'
        '  actual:   ${jsonEncode(reEncoded)}',
      );
    }

    // Through a real JSON string, which is where the VM and JS number
    // representations can diverge.
    final viaString = jsonDecode(jsonEncode(encoded)) as Map<String, dynamic>;
    check(
      _deepEquals(viaString, golden),
      '$name: survived toJson but not a jsonEncode/jsonDecode round trip '
      '(number precision?).\n  actual: ${jsonEncode(viaString)}',
    );
  }

  failures.addAll(_checkErrorMapping());
  failures.addAll(_checkSubprotocol());
  failures.addAll(_checkNamespaces());
  return failures;
}

/// [RpcError] must survive a trip through a `json_rpc_2` exception, including
/// the `request` key that `RpcException.serialize` injects into `data`.
List<String> _checkErrorMapping() {
  final failures = <String>[];
  const original = RpcError(
    code: ConduitErrorCodes.sessionExpired,
    args: <String, String>{'server': 'chat.example.com'},
    retryable: true,
  );

  final restored = RpcError.fromException(original.toException());
  if (restored != original) {
    failures.add(
      'RpcError did not survive toException/fromException.\n'
      '  expected: $original\n  actual:   $restored',
    );
  }

  // Simulate the server-side `serialize` step, which adds `request`.
  final withRequest = <String, dynamic>{
    ...original.toJson(),
    'request': <String, dynamic>{'method': 'chats.list', 'id': 7},
  };
  final tolerated = RpcError.fromJson(withRequest);
  if (tolerated != original) {
    failures.add(
      'RpcError.fromJson must ignore the injected `request` key.\n'
      '  actual: $tolerated',
    );
  }

  // A transport-level failure must still produce a usable code.
  final generic = RpcError.fromException(StateError('socket closed'));
  if (generic.code != ConduitErrorCodes.internal) {
    failures.add('non-RPC errors must map to ${ConduitErrorCodes.internal}');
  }
  return failures;
}

List<String> _checkSubprotocol() {
  final failures = <String>[];
  // A token with the characters that make naive base64 handling fail: the
  // padding boundary, and bytes that encode to `-` and `_` in base64url.
  const token = 'aGVsbG8+Pz8/fn5+';
  final offered = buildSubprotocols(token);

  if (!offered.contains(kConduitSubprotocol)) {
    failures.add('buildSubprotocols must advertise $kConduitSubprotocol');
  }
  if (offered.any((p) => p.contains('='))) {
    failures.add('subprotocol tokens must not contain padding: $offered');
  }
  if (extractSessionToken(offered) != token) {
    failures.add(
      'token did not survive buildSubprotocols/extractSessionToken: '
      '${extractSessionToken(offered)}',
    );
  }
  // Every rejection path must return null, never a partial token.
  if (extractSessionToken(null) != null) {
    failures.add('a null protocol list must be rejected');
  }
  if (extractSessionToken(<String>['tk.$token']) != null) {
    failures.add('a token without $kConduitSubprotocol must be rejected');
  }
  if (extractSessionToken(<String>[kConduitSubprotocol]) != null) {
    failures.add('a protocol list with no token entry must be rejected');
  }
  if (extractSessionToken(<String>[kConduitSubprotocol, 'tk.!!!!']) != null) {
    failures.add('a malformed token entry must be rejected');
  }

  if (!isAllowedOrigin(kConduitAppOrigin)) {
    failures.add('$kConduitAppOrigin must be an allowed origin');
  }
  for (final bad in <String?>[
    null,
    '',
    'https://evil.example',
    'app://conduit.evil',
    'http://127.0.0.1:1234',
  ]) {
    if (isAllowedOrigin(bad)) failures.add('origin "$bad" must be rejected');
  }

  if (!constantTimeEquals('abc', 'abc')) {
    failures.add('constantTimeEquals must accept equal strings');
  }
  for (final pair in <List<String>>[
    <String>['abc', 'abd'],
    <String>['abc', 'ab'],
    <String>['ab', 'abc'],
    <String>['', 'a'],
    <String>['a', ''],
  ]) {
    if (constantTimeEquals(pair[0], pair[1])) {
      failures.add('constantTimeEquals must reject ${pair[0]} vs ${pair[1]}');
    }
  }
  if (!constantTimeEquals('', '')) {
    failures.add('constantTimeEquals must accept two empty strings');
  }
  return failures;
}

List<String> _checkNamespaces() {
  final failures = <String>[];
  const systemMethods = <String>[
    ConduitMethods.systemHandshake,
    ConduitMethods.systemPing,
    ConduitMethods.systemCapabilities,
    ConduitMethods.systemShutdown,
    ConduitMethods.systemExportDiagnostics,
    ConduitMethods.eventsSubscribe,
    ConduitMethods.uiRespond,
  ];
  for (final method in systemMethods) {
    if (!ConduitMethods.isReserved(method)) {
      failures.add('$method is not inside a reserved namespace');
    }
  }
  if (ConduitMethods.isReserved('bogus.method')) {
    failures.add('bogus.method must not be treated as reserved');
  }
  for (final event in ConduitEvents.all) {
    if (!event.contains('.')) {
      failures.add('event "$event" must be namespaced');
    }
  }
  if (ConduitEvents.all.length != 17) {
    failures.add(
      'ConduitEvents.all has ${ConduitEvents.all.length} entries; update this '
      'count deliberately when adding an event so nobody forgets to add it to '
      '`all` (the subscription filter reads that set).',
    );
  }
  return failures;
}

bool _deepEquals(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key)) return false;
      if (!_deepEquals(a[key], b[key])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_deepEquals(a[i], b[i])) return false;
    }
    return true;
  }
  // `1` and `1.0` are the same JSON number but different Dart objects, and
  // dart2js blurs the line further. Compare numerically so the JS run does
  // not fail on a distinction the wire cannot express.
  if (a is num && b is num) return a == b;
  return a == b;
}
