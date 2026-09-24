/// The embedder's half of the render sandbox.
///
/// A port, like every other browser capability in this package, so the
/// components that use it stay testable on the VM -- and so a test can
/// assert what was *sent* to the sandbox without a frame existing.
abstract interface class SandboxPort {
  /// Hands [payload] to the frame registered under [frameId].
  ///
  /// Buffered until that frame reports itself ready: it is created and
  /// posted to in the same rebuild, and a message sent before its scripts
  /// have run is simply lost.
  void render(String frameId, SandboxPayload payload);

  /// Stops tracking [frameId], which is being removed from the tree.
  void release(String frameId);

  /// Heights the sandbox has reported, so the embedder can size the frame.
  Stream<({String frameId, int height})> get heights;
}

/// What a sandbox is asked to draw.
///
/// [source] is model output and stays a string the whole way: it crosses as
/// a `postMessage` value, and the frame hands it to a library that builds
/// nodes from it. It is never markup, so it is never script.
class SandboxPayload {
  const SandboxPayload({
    required this.kind,
    required this.source,
    this.display = false,
  });

  /// Which renderer inside the frame handles it. `math` today.
  final String kind;
  final String source;

  /// Block-level rather than inline, for the renderers that distinguish.
  final bool display;

  Map<String, Object?> toJson() => <String, Object?>{
    'conduit': 'render',
    'kind': kind,
    'source': source,
    'display': display,
  };
}

/// Records what it was asked to draw. The default outside a browser.
final class RecordingSandbox implements SandboxPort {
  final List<({String frameId, SandboxPayload payload})> rendered =
      <({String frameId, SandboxPayload payload})>[];
  final List<String> released = <String>[];

  @override
  void render(String frameId, SandboxPayload payload) =>
      rendered.add((frameId: frameId, payload: payload));

  @override
  void release(String frameId) => released.add(frameId);

  @override
  Stream<({String frameId, int height})> get heights =>
      const Stream<({String frameId, int height})>.empty();
}
