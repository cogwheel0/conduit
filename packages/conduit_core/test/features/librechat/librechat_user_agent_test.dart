import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/librechat/services/librechat_user_agent.dart';
import 'package:conduit_core/network/conduit_user_agent.dart';
import 'package:conduit_core/testing.dart';
import 'package:test/test.dart';

void main() {
  List<String> pinned() => [
    for (final line in File(
      'test/features/librechat/fixtures/user_agents.txt',
    ).readAsLinesSync())
      if (line.isNotEmpty && !line.startsWith('#')) line,
  ];

  test('every family sends exactly a pinned, ban-checked string', () {
    // The fixture is what tool/librechat_dev/ua_check.sh runs through the
    // server's own ua-parser-js; a new or changed string must be checked
    // there before it is pinned here.
    final sent = [
      for (final family in LibreChatUserAgentFamily.values)
        LibreChatUserAgent.forFamily(family, productToken: 'Conduit/4.2.1'),
    ];
    check(sent).unorderedEquals(pinned());
  });

  test('ends with Conduit\'s own product token', () {
    check(
      LibreChatUserAgent.value,
    ).endsWith(' ${ConduitUserAgent.value}');
    ConduitUserAgent.configure(appVersion: '4.2.1+31');
    addTearDown(() => ConduitUserAgent.configure(appVersion: ''));
    check(LibreChatUserAgent.value).endsWith(' Conduit/4.2.1+31');
  });

  test('the fake server bans what LibreChat bans', () {
    for (final agent in pinned()) {
      check(FakeLibreChatServer.looksLikeBrowser(agent)).isTrue();
    }
    check(FakeLibreChatServer.looksLikeBrowser('Conduit/4.2.1')).isFalse();
    check(
      FakeLibreChatServer.looksLikeBrowser('Dart/3.13 (dart:io)'),
    ).isFalse();
  });
}
