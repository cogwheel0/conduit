import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_router/jaspr_router.dart';

import 'pages/diagnostics_page.dart';
import 'pages/status_page.dart';

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
      // A reload, a restored session or a hand-typed URL can land on the
      // file name rather than the clean path. Normalizing here keeps that
      // from rendering the not-found page.
      redirect: (context, state) =>
          state.location == '/index.html' ? '/' : null,
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
