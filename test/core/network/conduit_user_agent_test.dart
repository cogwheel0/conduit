import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit/core/network/conduit_user_agent.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ConduitUserAgent', () {
    test('builds a product and app-version token', () {
      check(
        ConduitUserAgent.build(appVersion: ' 3.4.3 '),
      ).equals('Conduit/3.4.3');
    });

    test('sanitizes characters that are invalid in a product token', () {
      check(
        ConduitUserAgent.build(appVersion: '3.4 beta/1'),
      ).equals('Conduit/3.4-beta-1');
    });

    test('falls back to the product name when the version is empty', () {
      check(ConduitUserAgent.build(appVersion: '   ')).equals('Conduit');
    });

    test('configure updates the process-wide identity', () {
      addTearDown(() => ConduitUserAgent.configure(appVersion: ''));

      ConduitUserAgent.configure(appVersion: '9.8.7');

      check(ConduitUserAgent.value).equals('Conduit/9.8.7');
    });

    test('runtime fallback matches dart:io', () {
      final client = HttpClient();
      addTearDown(() => client.close(force: true));

      check(ConduitUserAgent.runtimeDefaultValue).equals(client.userAgent);
    });

    test('replaces case variants with one canonical header', () {
      final original = <String, String>{
        'user-agent': 'spoofed',
        'X-Custom': 'value',
      };

      final merged = ConduitUserAgent.mergeHeaders(original);

      check(merged[ConduitUserAgent.headerName]).equals(ConduitUserAgent.value);
      check(
        merged.keys.where(ConduitUserAgent.isHeaderName),
      ).deepEquals([ConduitUserAgent.headerName]);
      check(merged['X-Custom']).equals('value');
      check(original['user-agent']).equals('spoofed');
    });
  });
}
