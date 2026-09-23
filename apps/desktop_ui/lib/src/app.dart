import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:jaspr_router/jaspr_router.dart';

import 'pages/chat_page.dart';
import 'pages/diagnostics_page.dart';
import 'pages/channels_page.dart';
import 'pages/hermes_page.dart';
import 'pages/notes_page.dart';
import 'pages/terminal_page.dart';
import 'pages/workspace/workspace_page.dart';
import 'pages/onboarding_page.dart';
import 'pages/quick_ask_page.dart';
import 'pages/settings_page.dart';
import 'pages/sign_in_page.dart';
import 'pages/status_page.dart';
import 'l10n/strings.g.dart';
import 'rpc/rpc_providers.dart';
import 'rpc/session_providers.dart';
import 'widgets/desktop_integration.dart';
import 'widgets/keyboard_layer.dart';
import 'widgets/ui_request_card.dart';
import 'widgets/server_issue_banner.dart';

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
    // The quick-ask panel (WP-9.1) is its own small window, not a route of
    // this one: no sidebar, no session redirects.
    if (context.read(shellBridgeProvider).windowKind == WindowKind.quickAsk) {
      return const QuickAskPage();
    }
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
              builder: (context, state) => const ChatPage(),
            ),
            // The M0 screen that proved the daemon chain works, kept because
            // it is the fastest way to see a handshake, a port and a session
            // id when something is wrong.
            Route(
              path: '/core',
              title: 'Core status',
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
            Route(
              path: '/settings/:tab',
              title: 'Settings',
              builder: (context, state) =>
                  SettingsPage(tab: state.params['tab'] ?? 'appearance'),
            ),
            Route(
              path: '/settings',
              redirect: (context, state) => '/settings/appearance',
            ),
            Route(
              path: '/channels/:id',
              title: 'Channels',
              builder: (context, state) =>
                  ChannelsPage(channelId: state.params['id']),
            ),
            Route(
              path: '/channels',
              title: 'Channels',
              builder: (context, state) => const ChannelsPage(),
            ),
            Route(
              path: '/hermes',
              title: 'Hermes',
              builder: (context, state) => const HermesPage(),
            ),
            Route(
              path: '/terminal',
              title: 'Terminal',
              builder: (context, state) => const TerminalPage(),
            ),
            Route(
              path: '/workspace/:section/new',
              title: 'Workspace',
              builder: (context, state) => WorkspaceScreen(
                section: state.params['section'],
                create: true,
              ),
            ),
            Route(
              path: '/workspace/:section/:id',
              title: 'Workspace',
              builder: (context, state) => WorkspaceScreen(
                section: state.params['section'],
                id: Uri.decodeComponent(state.params['id'] ?? ''),
              ),
            ),
            Route(
              path: '/workspace/:section',
              title: 'Workspace',
              builder: (context, state) =>
                  WorkspaceScreen(section: state.params['section']),
            ),
            Route(
              path: '/workspace',
              title: 'Workspace',
              builder: (context, state) => const WorkspaceScreen(),
            ),
            Route(
              path: '/notes/:id',
              title: 'Notes',
              builder: (context, state) =>
                  NotesPage(noteId: state.params['id']),
            ),
            Route(
              path: '/notes',
              title: 'Notes',
              builder: (context, state) => const NotesPage(),
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

/// Navigates when the session state settles.
///
/// [sessionRedirectFor] is also wired into the router's `redirect`, which
/// catches direct navigations -- but that callback is evaluated once per
/// navigation and is not re-run when a provider it read later resolves. On a
/// cold start both queries are still in flight, the guard correctly declines
/// to redirect on an unknown state, and nothing ever asks again: a fresh
/// install would sit on an empty chat page instead of going to onboarding.
///
/// This component closes that gap by being a *component* -- it rebuilds when
/// the providers it watches change, which is exactly the event the router
/// callback cannot see.
class _SessionGate extends StatelessComponent {
  const _SessionGate();

  @override
  Component build(BuildContext context) {
    final router = Router.of(context);
    final target = sessionRedirectFor(
      location: RouteState.of(context).location,
      needsOnboarding: context.watch(needsOnboardingProvider),
      auth: context.watch(authStatusProvider),
      directOnly: context.watch(directOnlyProvider),
    );
    if (target != null) {
      // Not during build: navigating synchronously here would mutate the
      // tree that is currently being built.
      Future<void>.microtask(() => router.replace(target));
    }
    return const Component.fragment([]);
  }
}

/// The corner escape hatch to settings, for the screens with no chrome.
///
/// Onboarding, sign-in and the error page have no sidebar, so without this
/// the settings modal is reachable only by typing a URL. The chat page has
/// its own entry in the sidebar footer and suppresses this one, and so does
/// settings itself -- a floating pill that sits on top of the dialog it
/// opens reads as a second, broken button.
Component _settingsLink() => a(
  href: '/settings/appearance',
  classes:
      'fixed bottom-4 right-4 rounded-full border border-border bg-card '
      'px-3 py-1.5 text-xs text-muted-foreground shadow hover:bg-accent',
  [Component.text(t.desktop.desktopSettingsTitle)],
);

/// Whether [location] renders its own way into settings.
@visibleForTesting
bool showsFloatingSettingsLink(String location) =>
    location != '/' &&
    location != '/index.html' &&
    !location.startsWith('/settings') &&
    // Notes, channels, the workspace and the terminal lead back to the chat, which has its own way in;
    // the pill would sit on their composers.
    !location.startsWith('/notes') &&
    !location.startsWith('/channels') &&
    !location.startsWith('/workspace') &&
    !location.startsWith('/terminal') &&
    !location.startsWith('/hermes');

/// Sends a window to onboarding or sign-in when it has no session.
String? _sessionRedirect(BuildContext context, String location) =>
    sessionRedirectFor(
      location: location,
      needsOnboarding: context.watch(needsOnboardingProvider),
      auth: context.watch(authStatusProvider),
      directOnly: context.watch(directOnlyProvider),
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
///  * Settings is reachable without a session once a server is configured.
///    Its Connections tab is how a signed-out user adds, removes or switches
///    servers, so sending them to a sign-in form for the server they are
///    trying to leave would be a loop with no exit.
///  * An error is not an answer. If the daemon cannot say whether a session
///    exists, the banner explains that far better than a login form does.
@visibleForTesting
String? sessionRedirectFor({
  required String location,
  required AsyncValue<bool> needsOnboarding,
  required AsyncValue<AuthSnapshot> auth,
  AsyncValue<bool> directOnly = const AsyncValue<bool>.data(false),
}) {
  if (location.startsWith('/diagnostics') || location == '/core') return null;
  if (needsOnboarding.isLoading || needsOnboarding.hasError) return null;

  if (needsOnboarding.requireValue) {
    // Settings too: onboarding's corner link leads there, and language,
    // theme and the desktop's own settings mean something before a server
    // does.
    return location == '/onboarding' || location.startsWith('/settings')
        ? null
        : '/onboarding';
  }
  if (location == '/onboarding') return '/';
  // Direct connections and no server: there is no account to sign in to.
  if (directOnly.value == true) return location == '/sign-in' ? '/' : null;
  if (location.startsWith('/settings')) return null;

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
    return div(classes: 'flex min-h-screen flex-col bg-background', [
      // Above the route, so it is visible wherever the user is rather than
      // only on the screen that happened to notice the problem.
      const ServerIssueBanner(),
      const _SessionGate(),
      const KeyboardLayer(),
      const DesktopIntegration(),
      // Above every route: a tool waiting for approval holds up its reply
      // wherever the person happens to be looking.
      const UiRequestCard(),
      div(classes: 'min-h-0 flex-1', [child]),
      if (showsFloatingSettingsLink(RouteState.of(context).location))
        _settingsLink(),
    ]);
  }
}
