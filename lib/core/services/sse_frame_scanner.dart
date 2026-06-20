/// A single parsed Server-Sent Events frame.
///
/// A frame is the block of lines terminated by a blank line. [data] is the
/// concatenation of all `data:` lines in the frame (joined with `\n`, per the
/// SSE spec), and [event] is the value of the last `event:` line if one was
/// present.
final class SseFrame {
  const SseFrame({this.event, required this.data});

  /// The `event:` field for this frame, or null when none was sent.
  final String? event;

  /// The concatenated `data:` payload for this frame.
  final String data;
}

/// Incrementally scans decoded SSE text and emits complete [SseFrame]s.
///
/// Handles the byte-level concerns shared by every SSE consumer in the app:
/// - Split SSE frames across decoded chunks
/// - CRLF normalization, including a CRLF split across two chunks
/// - Multiple `data:` lines joined with `\n`
/// - The `event:` field, so consumers that key off event type (e.g. the Hermes
///   runs API) can route without re-implementing the scanner
///
/// A frame is only emitted once a blank-line boundary is reached and the frame
/// contained at least one `data:` line. This matches the long-standing
/// OpenWebUI parser behavior (event-only frames are skipped), so existing
/// consumers see no change.
final class SseFrameScanner {
  final StringBuffer _lineBuffer = StringBuffer();
  final StringBuffer _dataBuffer = StringBuffer();
  String? _eventField;
  bool _frameHasDataLine = false;
  bool _skipLeadingLineFeed = false;

  Iterable<SseFrame> addChunk(String chunk) sync* {
    for (var index = 0; index < chunk.length; index++) {
      final codeUnit = chunk.codeUnitAt(index);
      if (_skipLeadingLineFeed) {
        _skipLeadingLineFeed = false;
        if (codeUnit == _lineFeed) {
          continue;
        }
      }

      if (codeUnit == _lineFeed) {
        final frame = _finishLine();
        if (frame != null) {
          yield frame;
        }
        continue;
      }

      if (codeUnit == _carriageReturn) {
        final frame = _finishLine();
        _skipLeadingLineFeed = true;
        if (frame != null) {
          yield frame;
        }
        continue;
      }

      _lineBuffer.writeCharCode(codeUnit);
    }
  }

  Iterable<SseFrame> close() sync* {
    _skipLeadingLineFeed = false;
    if (_lineBuffer.length > 0) {
      _consumeLine(_lineBuffer.toString());
      _lineBuffer.clear();
    }

    final frame = _finishFrame();
    if (frame != null) {
      yield frame;
    }
  }

  SseFrame? _finishLine() {
    if (_lineBuffer.length == 0) {
      return _finishFrame();
    }

    _consumeLine(_lineBuffer.toString());
    _lineBuffer.clear();
    return null;
  }

  void _consumeLine(String line) {
    if (line.startsWith('data:')) {
      if (_frameHasDataLine) {
        _dataBuffer.write('\n');
      }
      _dataBuffer.write(line.substring(5).trimLeft());
      _frameHasDataLine = true;
      return;
    }

    if (line.startsWith('event:')) {
      _eventField = line.substring(6).trim();
    }
  }

  SseFrame? _finishFrame() {
    if (!_frameHasDataLine) {
      // Discard any orphan event field accumulated for a frame without data.
      _eventField = null;
      return null;
    }

    final payload = _dataBuffer.toString();
    final event = _eventField;
    _dataBuffer.clear();
    _eventField = null;
    _frameHasDataLine = false;
    if (payload.isEmpty) {
      return null;
    }
    return SseFrame(event: event, data: payload);
  }
}

const int _lineFeed = 0x0A;
const int _carriageReturn = 0x0D;
