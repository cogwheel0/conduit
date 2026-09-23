import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../l10n/strings.g.dart';

/// Everything an answer drew on, under it (WP-3.2).
///
/// Collapsed: the chips in the text already say which source backs which
/// sentence, and this is for someone who wants the list. Numbered to match
/// the `[1]`, `[2]` the model wrote.
class SourcesList extends StatelessComponent {
  const SourcesList(this.sources, {super.key});

  final List<ChatSourceDto> sources;

  @override
  Component build(BuildContext context) => details(
    classes: 'mr-auto max-w-[90%] text-ui-sm text-foreground-subtle',
    [
      Component.element(
        tag: 'summary',
        classes: 'cursor-pointer select-none hover:text-foreground',
        children: <Component>[
          Component.text(t.desktop.desktopSourcesCount(count: sources.length)),
        ],
      ),
      ol(classes: 'mt-1 list-decimal space-y-1 pl-5', [
        for (final source in sources)
          li([
            if (_webLink(source.url) case final url?)
              a(
                href: url,
                classes: 'text-primary underline underline-offset-2',
                target: Target.blank,
                attributes: const <String, String>{
                  'rel': 'noopener noreferrer',
                },
                [Component.text(source.label)],
              )
            else
              span(classes: 'text-foreground', [Component.text(source.label)]),
            if (source.snippet case final snippet? when snippet.isNotEmpty)
              p(classes: 'line-clamp-2', [Component.text(snippet)]),
          ]),
      ]),
    ],
  );

  /// Only a web address opens; anything else is shown, not linked.
  static String? _webLink(String? url) {
    final uri = Uri.tryParse(url ?? '');
    return uri != null && (uri.scheme == 'http' || uri.scheme == 'https')
        ? url
        : null;
  }
}
