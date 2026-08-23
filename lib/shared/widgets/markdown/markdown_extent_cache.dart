import 'dart:collection';

import 'package:flutter/rendering.dart' show RenderProxyBox;
import 'package:material_ui/material_ui.dart';

/// Remembered layout heights for settled markdown bodies.
///
/// A settled chat row must mount at its final extent or the timeline jumps
/// while scrolling through history. That constraint forced every settled
/// mount to prepare and compile markdown synchronously on the UI thread.
/// Once a body has been laid out at a given width and text scale, its height
/// is deterministic, so remounts can show a fixed-extent placeholder and move
/// the prepare/compile work off the frame.
///
/// Keys use the raw content's [String.hashCode] plus length. A hash collision
/// yields a one-frame wrong extent that the timeline's anchor maintenance
/// corrects; it cannot corrupt content.
class MarkdownExtentCache {
  MarkdownExtentCache._();

  static final MarkdownExtentCache instance = MarkdownExtentCache._();

  static const int _maxEntries = 512;

  static const int _maxRecentGeometries = 6;

  final LinkedHashMap<_MarkdownExtentKey, double> _entries =
      LinkedHashMap<_MarkdownExtentKey, double>();
  final LinkedHashSet<int> _recentGeometryKeys = LinkedHashSet<int>();

  static int contentIdentity(String content) =>
      Object.hash(content.hashCode, content.length);

  static int _widthKey(double width) => (width * 2).round();

  static int _scaleKey(double scaledHundred) => scaledHundred.round();

  static int _geometryKey(int widthKey, int scaleKey) =>
      Object.hash(widthKey, scaleKey);

  /// Whether an extent was recorded for [content] at one of the geometries
  /// (slot width + text scale) seen in recent settled markdown layouts.
  ///
  /// A transcript has only a few distinct markdown slot widths (assistant
  /// rows, user bubbles), all present in the recent set, so a row seen this
  /// session at the current geometry defers reliably. After a rotation or
  /// text-size change the new geometry displaces the old ones and stale
  /// entries stop matching, sending those mounts back to the synchronous
  /// path until they re-record.
  bool hasLikelyCurrentExtent(String content) {
    if (_recentGeometryKeys.isEmpty) return false;
    final identity = contentIdentity(content);
    for (final geometryKey in _recentGeometryKeys) {
      if (_entries.containsKey(
        _MarkdownExtentKey(
          contentIdentity: identity,
          geometryKey: geometryKey,
        ),
      )) {
        return true;
      }
    }
    return false;
  }

  /// The recorded height for [content] laid out at exactly [maxWidth] with
  /// the given text scale, or null.
  ///
  /// [textScaledHundred] is `TextScaler.scale(100)` — a stable scalar for
  /// nonlinear text scalers.
  double? heightFor(
    String content, {
    required double maxWidth,
    required double textScaledHundred,
  }) {
    final key = _MarkdownExtentKey(
      contentIdentity: contentIdentity(content),
      geometryKey: _geometryKey(
        _widthKey(maxWidth),
        _scaleKey(textScaledHundred),
      ),
    );
    final height = _entries.remove(key);
    if (height == null) return null;
    _entries[key] = height;
    return height;
  }

  void record(
    String content, {
    required double maxWidth,
    required double textScaledHundred,
    required double height,
  }) {
    if (!height.isFinite || height <= 0 || !maxWidth.isFinite) return;
    final geometryKey = _geometryKey(
      _widthKey(maxWidth),
      _scaleKey(textScaledHundred),
    );
    _recentGeometryKeys.remove(geometryKey);
    _recentGeometryKeys.add(geometryKey);
    while (_recentGeometryKeys.length > _maxRecentGeometries) {
      _recentGeometryKeys.remove(_recentGeometryKeys.first);
    }
    final key = _MarkdownExtentKey(
      contentIdentity: contentIdentity(content),
      geometryKey: geometryKey,
    );
    _entries.remove(key);
    _entries[key] = height;
    while (_entries.length > _maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }

  void clear() {
    _entries.clear();
    _recentGeometryKeys.clear();
  }

  @visibleForTesting
  int get debugLength => _entries.length;
}

@visibleForTesting
void debugResetMarkdownExtentCache() => MarkdownExtentCache.instance.clear();

/// Records the laid-out height of a settled markdown body into
/// [MarkdownExtentCache] keyed by the incoming max-width constraint.
///
/// Recording uses the constraint rather than the child's own size because a
/// short message lays out narrower than its slot; lookups happen against the
/// slot width (from a [LayoutBuilder]) before any content exists.
class MarkdownExtentReporter extends SingleChildRenderObjectWidget {
  const MarkdownExtentReporter({
    required this.content,
    required this.textScaledHundred,
    required this.enabled,
    required super.child,
    super.key,
  });

  final String content;
  final double textScaledHundred;

  /// Recording is gated rather than the wrapper being conditionally mounted:
  /// swapping the wrapper in and out re-inflates the markdown subtree at the
  /// streaming/settled boundary, which this pipeline explicitly avoids.
  final bool enabled;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderMarkdownExtentReporter(
      content: content,
      textScaledHundred: textScaledHundred,
      enabled: enabled,
    );
  }

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderMarkdownExtentReporter)
      ..content = content
      ..textScaledHundred = textScaledHundred
      ..enabled = enabled;
  }
}

class _RenderMarkdownExtentReporter extends RenderProxyBox {
  _RenderMarkdownExtentReporter({
    required String content,
    required double textScaledHundred,
    required bool enabled,
  }) : _content = content,
       _textScaledHundred = textScaledHundred,
       _enabled = enabled;

  String _content;
  set content(String value) {
    if (identical(_content, value) || _content == value) return;
    _content = value;
    markNeedsLayout();
  }

  double _textScaledHundred;
  set textScaledHundred(double value) {
    if (_textScaledHundred == value) return;
    _textScaledHundred = value;
    markNeedsLayout();
  }

  bool _enabled;
  set enabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;
    if (value) markNeedsLayout();
  }

  @override
  void performLayout() {
    super.performLayout();
    if (!_enabled) return;
    MarkdownExtentCache.instance.record(
      _content,
      maxWidth: constraints.maxWidth,
      textScaledHundred: _textScaledHundred,
      height: size.height,
    );
  }
}

@immutable
class _MarkdownExtentKey {
  const _MarkdownExtentKey({
    required this.contentIdentity,
    required this.geometryKey,
  });

  final int contentIdentity;
  final int geometryKey;

  @override
  bool operator ==(Object other) {
    return other is _MarkdownExtentKey &&
        other.contentIdentity == contentIdentity &&
        other.geometryKey == geometryKey;
  }

  @override
  int get hashCode => Object.hash(contentIdentity, geometryKey);
}
