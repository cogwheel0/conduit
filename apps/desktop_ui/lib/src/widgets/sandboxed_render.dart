import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';

import '../rpc/rpc_providers.dart';
import '../sandbox_port.dart';

/// Draws [payload] inside the render sandbox.
///
/// The frame is `app://conduit/sandbox.html` with `sandbox="allow-scripts"`
/// and nothing else, which gives it an opaque origin: it cannot read this
/// document, the app's storage or the session, and it cannot navigate this
/// window. The payload crosses as a `postMessage` *value*, so the model's
/// text reaches a library as a string and is turned into nodes there --
/// never parsed as markup here.
///
/// Sized by the frame rather than guessed: an iframe does not grow to its
/// content, and a fixed height would clip a long formula or leave a band of
/// whitespace under a short one.
class SandboxedRender extends StatefulComponent {
  const SandboxedRender({
    required this.id,
    required this.payload,
    this.title,
    super.key,
  });

  /// Stable across rebuilds, and unique on the page. It identifies the frame
  /// to the port, which is how a height report finds its way back.
  final String id;
  final SandboxPayload payload;
  final String? title;

  @override
  State<SandboxedRender> createState() => _SandboxedRenderState();
}

class _SandboxedRenderState extends State<SandboxedRender> {
  static const int _initialHeight = 24;

  int _height = _initialHeight;
  StreamSubscription<({String frameId, int height})>? _sizes;

  SandboxPort get _sandbox => context.read(sandboxProvider);

  @override
  void initState() {
    super.initState();
    _sizes = _sandbox.heights.listen((size) {
      if (size.frameId != component.id || !mounted) return;
      if (size.height == _height) return;
      setState(() => _height = size.height);
    });
    _sandbox.render(component.id, component.payload);
  }

  @override
  void didUpdateComponent(SandboxedRender oldComponent) {
    super.didUpdateComponent(oldComponent);
    // A streaming formula changes under us on every delta.
    if (oldComponent.payload.source != component.payload.source ||
        oldComponent.payload.kind != component.payload.kind) {
      _sandbox.render(component.id, component.payload);
    }
  }

  @override
  void dispose() {
    unawaited(_sizes?.cancel());
    _sandbox.release(component.id);
    super.dispose();
  }

  @override
  Component build(BuildContext context) => Component.element(
    tag: 'iframe',
    id: component.id,
    classes: 'w-full border-0',
    styles: Styles(raw: <String, String>{'height': '${_height}px'}),
    attributes: <String, String>{
      // Scripts, and nothing else. Never together with
      // `allow-same-origin`, which would let the frame reach through
      // `parent` and remove its own sandbox attribute.
      'sandbox': 'allow-scripts',
      'src': '/sandbox.html',
      'title': ?component.title,
      'referrerpolicy': 'no-referrer',
      'scrolling': 'no',
    },
  );
}
