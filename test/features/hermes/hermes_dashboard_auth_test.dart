import 'package:checks/checks.dart';
import 'package:conduit/features/hermes/services/hermes_dashboard_webview_policy.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('fails closed for dashboard access headers on iOS', () {
    expect(
      hermesDashboardHeadersSupported(
        platform: TargetPlatform.iOS,
        accessHeaders: const {'CF-Access-Client-Secret': 'secret'},
      ),
      isFalse,
    );
    expect(
      hermesDashboardHeadersSupported(
        platform: TargetPlatform.android,
        accessHeaders: const {'CF-Access-Client-Secret': 'secret'},
      ),
      isTrue,
    );
  });

  test('allows HTTPS identity providers only until dashboard return', () {
    final root = Uri.parse('https://hermes.example');
    final outbound = hermesDashboardNavigationTransition(
      target: Uri.parse('https://identity.example/authorize'),
      dashboardRoot: root,
      leftDashboard: false,
      returnedToDashboard: false,
    );
    check(outbound.allowed).isTrue();
    check(outbound.leftDashboard).isTrue();

    final returned = hermesDashboardNavigationTransition(
      target: Uri.parse('https://hermes.example/auth/callback'),
      dashboardRoot: root,
      leftDashboard: outbound.leftDashboard,
      returnedToDashboard: outbound.returnedToDashboard,
    );
    check(returned.allowed).isTrue();
    check(returned.returnedToDashboard).isTrue();

    final escapedAgain = hermesDashboardNavigationTransition(
      target: Uri.parse('https://identity.example/again'),
      dashboardRoot: root,
      leftDashboard: returned.leftDashboard,
      returnedToDashboard: returned.returnedToDashboard,
    );
    check(escapedAgain.allowed).isFalse();
  });

  test('removes access credentials before an identity-provider request', () {
    check(
      hermesHeadersWithoutAccessCredentials(
        const {'CF-Secret': 'secret', 'Accept': 'text/html'},
        const {'cf-secret': 'secret'},
      ),
    ).deepEquals({'Accept': 'text/html'});
  });
}
