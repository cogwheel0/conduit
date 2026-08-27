import 'package:material_ui/material_ui.dart';

import '../markdown_render_gate.dart';

/// Region count above which settled markdown regions (root blocks or display
/// parts) inflate across frames instead of in one.
const int markdownChunkedPartInflationThreshold = 128;

/// A column of markdown block widgets that inflates in bounded batches.
///
/// Attribution profiling of the multi-second freeze when opening a
/// conversation with a very large settled message showed the time was NOT
/// markdown parsing (moved off-thread earlier) but element inflation + first
/// layout of thousands of block widgets in a single frame (~6–8 s for ~2.4k
/// blocks; a same-size single block laid out in ~150 ms). Splitting the
/// mount across frames keeps every frame bounded while the transcript's
/// initial-position settlement (which is already frame-polled) tracks the
/// growing height.
///
/// The widgets are prebuilt by the caller — building them is cheap; only
/// their inflation is chunked. While unrevealed blocks remain, the region is
/// registered as incomplete on the enclosing [MarkdownRenderGate] so
/// SelectionArea wrapping is held off until the tree stops mutating.
class ChunkedBlockColumn extends StatefulWidget {
  const ChunkedBlockColumn({
    required this.children,
    this.revealImmediately = false,
    this.initialChunk = 48,
    this.chunkSize = 96,
    super.key,
  });

  /// Prebuilt block widgets in document order. The list may be a fresh
  /// object on every ancestor rebuild; reveal progress is keyed on count,
  /// not list identity.
  final List<Widget> children;

  /// While true, every child is revealed synchronously — no chunking. Used
  /// during streaming, where blocks arrive one at a time (so no single frame
  /// inflates a large batch) and the live tail must never trail a frame
  /// behind the pin/extent math. Progress is monotonic: children revealed
  /// under this mode stay revealed when it turns off, so the
  /// streaming→settled flip never re-inflates or collapses the body.
  final bool revealImmediately;

  /// Blocks inflated synchronously on the first frame — enough to overfill
  /// a phone viewport so the reveal is invisible at the reading edge.
  final int initialChunk;

  /// Blocks appended per subsequent frame.
  final int chunkSize;

  @override
  State<ChunkedBlockColumn> createState() => _ChunkedBlockColumnState();
}

class _ChunkedBlockColumnState extends State<ChunkedBlockColumn> {
  late int _revealed;
  bool _revealScheduled = false;
  MarkdownRenderGate? _gate;
  bool _holdingGate = false;

  @override
  void initState() {
    super.initState();
    _revealed =
        widget.revealImmediately ||
            widget.children.length <= widget.initialChunk
        ? widget.children.length
        : widget.initialChunk;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final gate = MarkdownRenderGateScope.maybeOf(context);
    if (!identical(gate, _gate)) {
      if (_holdingGate) {
        _gate?.markRegionComplete();
        _holdingGate = false;
      }
      _gate = gate;
    }
    _syncGate();
    _scheduleRevealIfNeeded();
  }

  @override
  void didUpdateWidget(covariant ChunkedBlockColumn oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Content updates never reset progress: a message that grows (the
    // responseDone gap keeps appending after isStreaming flips false) keeps
    // everything already revealed and streams the appended blocks in;
    // resetting to the initial chunk would visibly collapse the body.
    // Shrinking documents clamp.
    if (widget.revealImmediately) {
      _revealed = widget.children.length;
    } else if (_revealed > widget.children.length) {
      _revealed = widget.children.length;
    }
    _syncGate();
    _scheduleRevealIfNeeded();
  }

  @override
  void dispose() {
    if (_holdingGate) {
      _gate?.markRegionComplete();
      _holdingGate = false;
    }
    super.dispose();
  }

  bool get _isComplete => _revealed >= widget.children.length;

  void _syncGate() {
    final shouldHold = !_isComplete;
    if (shouldHold == _holdingGate) return;
    _holdingGate = shouldHold;
    if (shouldHold) {
      _gate?.markRegionIncomplete();
    } else {
      _gate?.markRegionComplete();
    }
  }

  void _scheduleRevealIfNeeded() {
    if (widget.revealImmediately || _isComplete || _revealScheduled) return;
    _revealScheduled = true;
    final binding = WidgetsBinding.instance;
    binding.addPostFrameCallback((_) {
      _revealScheduled = false;
      if (!mounted || _isComplete) return;
      setState(() {
        _revealed = (_revealed + widget.chunkSize).clamp(
          0,
          widget.children.length,
        );
      });
      _syncGate();
      _scheduleRevealIfNeeded();
    });
    binding.scheduleFrame();
  }

  @override
  Widget build(BuildContext context) {
    final children = _isComplete
        ? widget.children
        : widget.children.sublist(0, _revealed);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }
}
