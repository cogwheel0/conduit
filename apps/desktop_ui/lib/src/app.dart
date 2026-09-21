import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:jaspr_router/jaspr_router.dart';

import 'pages/diagnostics_page.dart';
import 'pages/onboarding_page.dart';
import 'pages/sign_in_page.dart';
import 'pages/status_page.dart';
import 'rpc/session_providers.dart';

/// The desktop app shell and its routes.
///
/// WP-0.6 had to establish whether `jaspr_router` can carry the Open WebUI
/// information architecture before the chat vertical is built on it. It can:
/// [ShellRoute] gives the persistent sidebar/main split, `redirect` works at
/// both the router and route level, and `RouteState.params` carries path
/// parameters. The 200-line history-API fallback in section 11 is therefore
/// not needed; see docs/desktop/ROUTER-SPIKE.md for what was checked.
class ConduitDesktopApp extends StatelessComponent {
  const ConduitDesktopApp({super.key});

  @override
  Component build(BuildContext context) {
    return Router(
      redirect: (context, state) {
        // A reload, a restored session or a hand-typed URL can land on the
        // file name rather than the clean path. Normalizing here keeps that
        // from rendering the not-found page.
        if (state.location == '/index.html') return '/';
        return _sessionRedirect(context, state.location);
      },
      routes: <RouteBase>[
        ShellRoute(
          builder: (context, state, child) => _Shell(child: child),
          routes: <RouteBase>[
            Route(
              path: '/',
              title: 'Conduit',
              builder: (context, state) => const StatusPage(),
            ),
            Route(
              path: '/diagnostics/:section',
              title: 'Diagnostics',
              builder: (context, state) =>
                  DiagnosticsPage(section: state.params['section'] ?? 'core'),
            ),
            // Proves route-level redirects resolve before a build. The chat
            // vertical relies on this to bounce an unauthenticated window to
            // onboarding without flashing the transcript first.
            Route(
              path: '/diagnostics',
              redirect: (context, state) => '/diagnostics/core',
            ),
            Route(
              path: '/onboarding',
              title: 'Connect to server',
              builder: (context, state) => const OnboardingPage(),
            ),
            Route(
              path: '/sign-in',
              title: 'Sign in',
              builder: (context, state) => const SignInPage(),
            ),
          ],
        ),
      ],
      errorBuilder: (context, state) => _Shell(
        child: div(classes: 'px-8 py-10 text-foreground', [
          h1(classes: 'text-xl font-semibold', [
            Component.text('Page not found'),
          ]),
          p(classes: 'mt-2 text-sm text-muted-foreground', [
            Component.text(state.location),
          ]),
        ]),
      ),
    );
  }
}

/// Sends a window to onboarding or sign-in when it has no session.
String? _sessionRedirect(BuildContext context, String location) =>
    sessionRedirectFor(
      location: location,
      needsOnboarding: context.watch(needsOnboardingProvider),
      auth: context.watch(authStatusProvider),
    );

/// The routing decision, as a pure function of what is currently known.
///
/// Separated from the provider reads so it can be tested as the table of
/// cases it is. Three rules, and the first is the one that matters:
///
///  * **Never redirect on an unknown state.** A redirect is not something a
///    later rebuild can take back, so acting before both queries settle is
///    what makes a signed-in user's window flash onboarding on every launch.
///  * Diagnostics is always reachable. It is where someone goes when the core
///    will not start, and gating it behind a working session would hide it
///    exactly when it is needed.
///  * An error is not an answer. If the daemon cannot say whether a session
///    exists, the banner explains that far better than a login form does.
@visibleForTesting
String? sessionRedirectFor({
  required String location,
  required AsyncValue<bool> needsOnboarding,
  required AsyncValue<AuthSnapshot> auth,
}) {
  if (location.startsWith('/diagnostics')) return null;
  if (needsOnboarding.isLoading || needsOnboarding.hasError) return null;

  if (needsOnboarding.requireValue) {
    return location == '/onboarding' ? null : '/onboarding';
  }
  if (location == '/onboarding') return '/';

  final snapshot = auth.value;
  if (snapshot == null) return null;
  // Reviewer mode is a complete session with no server and no credentials,
  // so it must not be sent to a sign-in form it can never satisfy.
  if (snapshot.isAuthenticated || snapshot.isReviewerMode) {
    return location == '/sign-in' ? '/' : null;
  }
  return location == '/sign-in' ? null : '/sign-in';
}

/// The persistent chrome every route renders inside.
///
/// In M3 this grows the sidebar, model picker and controls pane; keeping it a
/// [ShellRoute] from the start means those never remount on navigation.
class _Shell extends StatelessComponent {
  const _Shell({required this.child});

  final Component child;

  @override
  Component build(BuildContext context) {
    return div(classes: 'min-h-screen bg-background', [child]);
  }
}
