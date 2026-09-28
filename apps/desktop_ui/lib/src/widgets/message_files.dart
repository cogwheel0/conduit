import 'dart:async';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';

import '../keyboard.dart';
import '../l10n/strings.g.dart';
import '../rpc/chat_providers.dart';
import '../rpc/rpc_providers.dart';
import 'ui.dart';

/// The files on a message: images as thumbnails, anything else by name.
class MessageFiles extends StatelessComponent {
  const MessageFiles(this.files, {this.alignEnd = false, super.key});

  final List<ChatFileDto> files;

  /// Under the user's own bubble, which sits on the right.
  final bool alignEnd;

  @override
  Component build(BuildContext context) {
    final urlFor = context.watch(fileUrlProvider);
    String? srcOf(ChatFileDto file) =>
        file.dataUrl ??
        (file.id != null && urlFor != null ? urlFor(file.id!) : null);

    return div(
      classes:
          'flex max-w-[80%] flex-wrap gap-2 '
          '${alignEnd ? 'ml-auto justify-end' : 'mr-auto'}',
      [
        for (final file in files)
          if (file.image && srcOf(file) != null)
            button(
              [
                img(
                  src: srcOf(file)!,
                  alt: file.name,
                  classes:
                      'max-h-48 max-w-64 rounded-lg border border-border '
                      'object-cover',
                  attributes: const <String, String>{'loading': 'lazy'},
                ),
              ],
              classes: 'cursor-zoom-in rounded-lg',
              type: ButtonType.button,
              attributes: <String, String>{
                'aria-label': t.desktop.desktopOpenImage(name: file.name),
              },
              onClick: () => context
                  .read(lightboxProvider.notifier)
                  .show(srcOf(file)!, file.name),
            )
          // Played where it is: the same daemon route, and the browser's own
          // controls, which are keyboard-operable as they come.
          else if (_media(file) case final kind? when srcOf(file) != null)
            Component.element(
              tag: kind,
              classes: kind == 'video'
                  ? 'max-h-64 max-w-full rounded-lg border border-border'
                  : 'max-w-full',
              attributes: <String, String>{
                'src': srcOf(file)!,
                'controls': '',
                'preload': 'metadata',
                'aria-label': file.name,
              },
            )
          // A PDF opens in a viewer window of the shell's own, which is the
          // only thing a daemon file link opening a window leads to.
          else if (_isPdf(file) && srcOf(file) != null)
            a(
              href: srcOf(file)!,
              target: Target.blank,
              classes:
                  'rounded-lg border border-border px-2 py-1 text-ui-sm '
                  'text-foreground underline-offset-2 hover:underline',
              attributes: const <String, String>{'rel': 'noopener noreferrer'},
              [Component.text(file.name)],
            )
          else
            span(
              classes:
                  'rounded-lg border border-border px-2 py-1 text-ui-sm '
                  'text-foreground-subtle',
              [Component.text(file.name)],
            ),
      ],
    );
  }
}

bool _isPdf(ChatFileDto file) =>
    file.contentType == 'application/pdf' ||
    file.name.toLowerCase().endsWith('.pdf');

/// `audio` or `video` when [file] is one, going by its type.
String? _media(ChatFileDto file) {
  final type = file.contentType ?? '';
  if (type.startsWith('audio/')) return 'audio';
  if (type.startsWith('video/')) return 'video';
  return null;
}

/// An image, full size over the window. A click anywhere or Esc
/// closes it; the close button takes focus so Esc reaches it at once.
class LightboxOverlay extends StatefulComponent {
  const LightboxOverlay({required this.src, required this.name, super.key});

  final String src;
  final String name;

  @override
  State<LightboxOverlay> createState() => _LightboxOverlayState();
}

class _LightboxOverlayState extends State<LightboxOverlay> {
  @override
  void initState() {
    super.initState();
    Future<void>.microtask(() {
      if (mounted) context.read(windowCommandsProvider).focus('lightbox-close');
    });
  }

  @override
  Component build(BuildContext context) {
    void close() => context.read(lightboxProvider.notifier).close();
    return div(
      classes:
          'fixed inset-0 z-50 flex cursor-zoom-out items-center '
          'justify-center bg-black/80 p-8',
      attributes: <String, String>{
        'role': 'dialog',
        'aria-modal': 'true',
        'aria-label': component.name,
      },
      events: <String, EventCallback>{
        'click': (_) => close(),
        'keydown': submitOrCancel(submit: close, cancel: close),
      },
      [
        img(
          src: component.src,
          alt: component.name,
          classes: 'max-h-full max-w-full rounded-lg shadow-lg',
        ),
        button(
          [
            span(
              attributes: const <String, String>{'aria-hidden': 'true'},
              [icon(LucideIcon.x, classes: 'size-4')],
            ),
          ],
          id: 'lightbox-close',
          classes:
              'absolute right-4 top-4 rounded-lg bg-black/50 px-3 py-1.5 '
              'text-ui-base text-white hover:bg-black/70',
          type: ButtonType.button,
          attributes: <String, String>{'aria-label': t.app.close},
          onClick: close,
        ),
      ],
    );
  }
}
