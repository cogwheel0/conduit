import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';

import '../l10n/strings.g.dart';
import '../rpc/session_providers.dart';

/// The version gate and the connection-issue notice (WP-2.2).
///
/// A banner in the shell rather than a route the guard redirects to. A
/// redirect would eject the user from whatever they were doing the moment a
/// request blipped, and getting back would depend on a second request
/// succeeding -- so a flaky network would feel like the app throwing them
/// out. A banner says the same thing and costs nothing when it is wrong.
///
/// The version case is a warning, not a block: the server reports a version
/// newer than this build was tested against, which usually works. Blocking on
/// it would make every server upgrade an outage.
class ServerIssueBanner extends StatelessComponent {
  const ServerIssueBanner({super.key});

  @override
  Component build(BuildContext context) {
    final status = context.watch(serverStatusProvider).value;
    // Nothing to say while it is loading, and nothing to say when it failed:
    // the core-connection banner already covers "we cannot reach the daemon",
    // and two banners saying the same thing is worse than one.
    if (status == null || status.activeServerId == null) {
      return const _Nothing();
    }

    return switch (status.reachability) {
      ServerReachability.unreachable => _banner(
        tone: 'destructive',
        title: t.app.weCouldntReachServer,
        detail: t.app.pleaseCheckConnection,
      ),
      ServerReachability.notOpenWebUi => _banner(
        tone: 'destructive',
        title: t.app.serverNotOpenWebUI,
        // A different fix from "check your network": the URL points at
        // something real that is not Open WebUI.
        detail: t.app.backToServerSetup,
      ),
      ServerReachability.reachable when !status.isVersionSupported => _banner(
        tone: 'warning',
        title: t.app.serverIncompatibleTitle,
        detail: t.app.serverIncompatibleMessage(
          serverVersion: status.version ?? '?',
          maxVersion: status.maxSupportedVersion,
        ),
      ),
      _ => const _Nothing(),
    };
  }

  Component _banner({
    required String tone,
    required String title,
    required String detail,
  }) => div(
    classes:
        'border-b px-5 py-2 text-sm '
        '${tone == 'destructive' ? 'border-destructive/40 bg-destructive/10 text-destructive' : 'border-warning/40 bg-warning/10 text-warning'}',
    // `status`, not `alert`: this is a condition that persists rather than an
    // event, so it should be announced politely when reached rather than
    // interrupting whatever the user is reading.
    attributes: const <String, String>{'role': 'status'},
    [
      span(classes: 'font-medium', [Component.text(title)]),
      span(classes: 'ml-2 opacity-90', [Component.text(detail)]),
    ],
  );
}

/// Renders nothing, without the caller needing a nullable component.
class _Nothing extends StatelessComponent {
  const _Nothing();

  @override
  Component build(BuildContext context) => const Component.fragment([]);
}
