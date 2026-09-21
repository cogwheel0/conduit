import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:jaspr_router/jaspr_router.dart';

import '../rpc/rpc_providers.dart';

/// Exercises the router features WP-0.6 had to verify: a path parameter, and
/// a page rendered inside the shell layout rather than replacing it.
///
/// It doubles as a real diagnostics view — the section id comes from the URL,
/// which is what `conduit://` deep links will push in WP-9.3.
class DiagnosticsPage extends StatelessComponent {
  const DiagnosticsPage({required this.section, super.key});

  final String section;

  @override
  Component build(BuildContext context) {
    final connection = context.watch(coreConnectionProvider);
    return div(classes: 'mx-auto max-w-2xl px-8 py-10 text-foreground', [
      h1(classes: 'text-xl font-semibold', [
        Component.text('Diagnostics: $section'),
      ]),
      p(classes: 'mt-2 text-sm text-muted-foreground', [
        Component.text(
          connection.hasValue
              ? 'Last event sequence: '
                    '${context.read(rpcClientProvider).lastSeq}'
              : 'Not connected.',
        ),
      ]),
      Link(
        to: '/',
        classes: 'mt-6 inline-block text-sm text-primary underline',
        child: Component.text('Back to status'),
      ),
    ]);
  }
}
