import 'package:checks/checks.dart';
import 'package:conduit/features/hermes/services/hermes_dashboard_webview_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final root = Uri.parse('https://hermes.example');
  const headers = {'CF-Access-Client-Secret': 'secret'};

  group('HermesDashboardWebViewPolicy user scripts', () {
    test('install the header script where it runs before the page', () {
      final policy = HermesDashboardWebViewPolicy(
        root: root,
        accessHeaders: headers,
      );
      addTearDown(policy.close);

      check(policy.supported).isTrue();
      check(policy.userScripts).length.equals(1);
      check(policy.userScripts.single.allowedOriginRules)
          .isNotNull()
          .deepEquals({root.origin});
    });

    test('install nothing, and are unsupported, where it could run late', () {
      final policy = HermesDashboardWebViewPolicy(
        root: root,
        accessHeaders: headers,
      )..documentStartScripts = false;
      addTearDown(policy.close);

      check(policy.supported).isFalse();
      check(policy.userScripts).isEmpty();
    });

    test('are not needed without access headers', () {
      final policy = HermesDashboardWebViewPolicy(
        root: root,
        accessHeaders: const {},
      )..documentStartScripts = false;
      addTearDown(policy.close);

      check(policy.supported).isTrue();
      check(policy.userScripts).isEmpty();
    });
  });
}
