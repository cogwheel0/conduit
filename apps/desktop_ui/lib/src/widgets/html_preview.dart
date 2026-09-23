import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../l10n/strings.g.dart';

/// An opt-in, inert preview of model-written HTML (WP-3.5).
///
/// Two independent things stop it executing, because one of them being
/// wrong is how this kind of feature becomes an exploit:
///
///  * `sandbox` with no tokens at all. Not `allow-scripts`, not
///    `allow-same-origin`, and above all never both -- that pair lets the
///    frame reach out and remove its own sandbox attribute.
///  * `srcdoc`. A `srcdoc` document inherits the embedder's CSP, and the
///    renderer's is `script-src 'self' app:`, so an inline script in the
///    markup is refused even if the sandbox were somehow relaxed. This was
///    measured rather than assumed; the Electron suite pins it.
///
/// Opt-in as well: the frame is only created once the user asks for it, so
/// merely receiving a reply never renders anything but text.
class HtmlPreview extends StatefulComponent {
  const HtmlPreview({required this.html, super.key});

  final String html;

  @override
  State<HtmlPreview> createState() => _HtmlPreviewState();
}

class _HtmlPreviewState extends State<HtmlPreview> {
  bool _showing = false;

  @override
  Component build(BuildContext context) => div(classes: 'mt-2', [
    button(
      [
        Component.text(
          _showing ? t.desktop.desktopHidePreview : t.desktop.desktopPreview,
        ),
      ],
      classes:
          'rounded-lg border border-border px-2 py-0.5 text-ui-sm '
          'text-foreground-subtle hover:bg-hover',
      type: ButtonType.button,
      attributes: <String, String>{
        'aria-expanded': _showing ? 'true' : 'false',
      },
      onClick: () => setState(() => _showing = !_showing),
    ),
    if (_showing)
      Component.element(
        tag: 'iframe',
        classes: 'mt-2 h-64 w-full rounded-lg border border-border bg-white',
        attributes: <String, String>{
          // Empty, not absent. An absent `sandbox` is no sandbox at all;
          // an empty one is every restriction.
          'sandbox': '',
          'srcdoc': component.html,
          'title': t.desktop.desktopPreview,
          // Nothing in the frame may reach the network, and a referrer
          // would leak which conversation is open.
          'referrerpolicy': 'no-referrer',
          'loading': 'lazy',
        },
      ),
  ]);
}
