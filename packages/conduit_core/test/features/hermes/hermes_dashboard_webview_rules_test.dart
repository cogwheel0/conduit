import 'package:checks/checks.dart';
import 'package:conduit_core/features/hermes/services/hermes_dashboard_access.dart';
import 'package:conduit_core/features/hermes/services/hermes_dashboard_webview_rules.dart';
import 'package:test/test.dart';

void main() {
  final root = Uri.parse('https://hermes.example');

  test('fails closed for dashboard access headers on iOS', () {
    check(
      hermesDashboardHeadersSupported(
        isIOS: true,
        accessHeaders: const {'CF-Access-Client-Secret': 'secret'},
      ),
    ).isFalse();
    check(
      hermesDashboardHeadersSupported(
        isIOS: false,
        accessHeaders: const {'CF-Access-Client-Secret': 'secret'},
      ),
    ).isTrue();
    check(hermesDashboardHeadersSupported(isIOS: true, accessHeaders: const {}))
        .isTrue();
  });

  test('derives the dashboard pages from the configured base URL', () {
    final nested = hermesDashboardRoot(' https://hermes.example/agent/v1/ ');
    check(nested.toString()).equals('https://hermes.example/agent');
    check(hermesDashboardLoginUrl(nested).toString())
        .equals('https://hermes.example/agent/login');
    check(hermesDashboardAuthCheckUrl(nested).toString())
        .equals('https://hermes.example/agent/api/auth/me');

    final bare = hermesDashboardRoot('http://127.0.0.1:18171/v1');
    check(hermesDashboardLoginUrl(bare).toString())
        .equals('http://127.0.0.1:18171/login');
    check(
      hermesDashboardLoginUrl(Uri.parse('https://hermes.example/')).toString(),
    ).equals('https://hermes.example/login');
  });

  test('allows HTTPS identity providers only until dashboard return', () {
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

  test('refuses non-HTTPS targets off the dashboard', () {
    for (final target in [
      'http://identity.example/authorize',
      'http://hermes.example/login',
      'javascript:alert(1)',
    ]) {
      final transition = hermesDashboardNavigationTransition(
        target: Uri.parse(target),
        dashboardRoot: root,
        leftDashboard: false,
        returnedToDashboard: false,
      );
      check(because: target, transition.allowed).isFalse();
      check(because: target, transition.leftDashboard).isFalse();
    }
    // An explicit default port is the same origin.
    check(
      hermesDashboardNavigationTransition(
        target: Uri.parse('https://HERMES.example:443/login'),
        dashboardRoot: root,
        leftDashboard: false,
        returnedToDashboard: false,
      ).allowed,
    ).isTrue();
  });

  test('removes access credentials before an identity-provider request', () {
    check(
      hermesHeadersWithoutAccessCredentials(
        const {'CF-Secret': 'secret', 'Accept': 'text/html'},
        const {'cf-secret': 'secret'},
      ),
    ).deepEquals({'Accept': 'text/html'});
  });

  test('adds access credentials to dashboard requests', () {
    check(
      hermesDashboardSameOriginHeaders(
        const {'Accept': 'text/html', 'CF-Secret': 'page-set', 'X-Count': 2},
        const {'CF-Secret': 'secret'},
      ),
    ).deepEquals({
      'Accept': 'text/html',
      'CF-Secret': 'secret',
      'X-Count': '2',
    });
    check(hermesDashboardSameOriginHeaders(null, const {'CF-Secret': 'secret'}))
        .deepEquals({'CF-Secret': 'secret'});
  });

  test('intercepts only dashboard GET subresources', () {
    bool intercepts(String url, {String? method = 'GET', bool main = false}) =>
        hermesDashboardInterceptsSubresource(
          method: method,
          isMainFrame: main,
          target: Uri.parse(url),
          root: root,
        );

    check(intercepts('https://hermes.example/assets/app.js')).isTrue();
    check(intercepts('https://hermes.example/api/x', method: 'get')).isTrue();
    check(intercepts('https://hermes.example/', main: true)).isFalse();
    check(intercepts('https://hermes.example/api/x', method: 'POST')).isFalse();
    check(intercepts('https://hermes.example/api/x', method: null)).isFalse();
    check(intercepts('https://cdn.example/app.js')).isFalse();
    check(intercepts('http://hermes.example/app.js')).isFalse();
  });

  test('checks sign-in only on finished dashboard pages', () {
    bool checks(String? url, {bool checking = false}) =>
        hermesDashboardShouldCheckSignIn(
          loaded: url == null ? null : Uri.parse(url),
          root: root,
          checking: checking,
        );

    check(checks('https://hermes.example/')).isTrue();
    check(checks('https://hermes.example/auth/callback')).isTrue();
    check(checks('https://hermes.example/login')).isFalse();
    check(checks('https://hermes.example/agent/login')).isFalse();
    check(checks('https://hermes.example/', checking: true)).isFalse();
    check(checks('https://identity.example/done')).isFalse();
    check(checks(null)).isFalse();
  });
}
