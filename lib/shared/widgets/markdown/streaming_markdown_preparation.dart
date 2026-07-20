import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'markdown_preprocessor.dart';

String prepareMarkdownContentCanonical(
  String content, {
  required bool streaming,
}) {
  final normalized = ConduitMarkdownPreprocessor.normalize(content);
  return streaming
      ? stripTrailingIncompleteToolCallDetailsCanonical(normalized)
      : normalized;
}

final _detailsOpenPattern = RegExp(r'<details\b', caseSensitive: false);
final _toolCallDetailsOpenPattern = RegExp(
  r'<details\b[^>]*type="tool_calls"[^>]*>',
  caseSensitive: false,
);

String stripTrailingIncompleteToolCallDetailsCanonical(String input) {
  if (input.isEmpty || !_detailsOpenPattern.hasMatch(input)) {
    return input;
  }

  final matches = _toolCallDetailsOpenPattern
      .allMatches(input)
      .toList(growable: false);
  if (matches.isEmpty) {
    return input;
  }

  final lastOpen = matches.last;
  final trailing = input.substring(lastOpen.start).toLowerCase();
  if (trailing.contains('</details>')) {
    return input;
  }

  return input.substring(0, lastOpen.start).trimRight();
}

enum MarkdownPreparationMode {
  full,
  incremental,
  resetFull,
  stale,
  fallbackFull,
  webSync,
}

@immutable
class MarkdownPreparationRequest {
  const MarkdownPreparationRequest({
    required this.sessionId,
    required this.revision,
    required this.expectedBaseRevision,
    required this.content,
    required this.streaming,
    required this.collectMetrics,
    this.verifyParity = false,
  });

  final String sessionId;
  final int revision;
  final int expectedBaseRevision;
  final String content;
  final bool streaming;
  final bool collectMetrics;
  final bool verifyParity;

  Map<String, Object?> toMap() => <String, Object?>{
    'sessionId': sessionId,
    'revision': revision,
    'expectedBaseRevision': expectedBaseRevision,
    'content': content,
    'streaming': streaming,
    'collectMetrics': collectMetrics,
    'verifyParity': verifyParity,
  };

  factory MarkdownPreparationRequest.fromMap(Map<Object?, Object?> map) {
    return MarkdownPreparationRequest(
      sessionId: (map['sessionId'] ?? '').toString(),
      revision: (map['revision'] as num?)?.toInt() ?? 0,
      expectedBaseRevision: (map['expectedBaseRevision'] as num?)?.toInt() ?? 0,
      content: (map['content'] ?? '').toString(),
      streaming: map['streaming'] == true,
      collectMetrics: map['collectMetrics'] == true,
      verifyParity: map['verifyParity'] == true,
    );
  }
}

@immutable
class MarkdownPreparationMetrics {
  const MarkdownPreparationMetrics({
    required this.callCount,
    required this.inputCharacters,
    required this.inputUtf8Bytes,
    required this.processedCharacters,
    required this.processedUtf8Bytes,
    required this.retainedRawCharacters,
    required this.retainedPreparedCharacters,
    required this.replacementCharacters,
    required this.replacementUtf8Bytes,
    required this.outputCharacters,
    required this.outputUtf8Bytes,
  });

  const MarkdownPreparationMetrics.empty()
    : callCount = 0,
      inputCharacters = 0,
      inputUtf8Bytes = 0,
      processedCharacters = 0,
      processedUtf8Bytes = 0,
      retainedRawCharacters = 0,
      retainedPreparedCharacters = 0,
      replacementCharacters = 0,
      replacementUtf8Bytes = 0,
      outputCharacters = 0,
      outputUtf8Bytes = 0;

  final int callCount;
  final int inputCharacters;
  final int inputUtf8Bytes;
  final int processedCharacters;
  final int processedUtf8Bytes;
  final int retainedRawCharacters;
  final int retainedPreparedCharacters;
  final int replacementCharacters;
  final int replacementUtf8Bytes;
  final int outputCharacters;
  final int outputUtf8Bytes;

  Map<String, Object?> toMap() => <String, Object?>{
    'callCount': callCount,
    'inputCharacters': inputCharacters,
    'inputUtf8Bytes': inputUtf8Bytes,
    'processedCharacters': processedCharacters,
    'processedUtf8Bytes': processedUtf8Bytes,
    'retainedRawCharacters': retainedRawCharacters,
    'retainedPreparedCharacters': retainedPreparedCharacters,
    'replacementCharacters': replacementCharacters,
    'replacementUtf8Bytes': replacementUtf8Bytes,
    'outputCharacters': outputCharacters,
    'outputUtf8Bytes': outputUtf8Bytes,
  };

  factory MarkdownPreparationMetrics.fromMap(Map<Object?, Object?> map) {
    int value(String key) => (map[key] as num?)?.toInt() ?? 0;
    return MarkdownPreparationMetrics(
      callCount: value('callCount'),
      inputCharacters: value('inputCharacters'),
      inputUtf8Bytes: value('inputUtf8Bytes'),
      processedCharacters: value('processedCharacters'),
      processedUtf8Bytes: value('processedUtf8Bytes'),
      retainedRawCharacters: value('retainedRawCharacters'),
      retainedPreparedCharacters: value('retainedPreparedCharacters'),
      replacementCharacters: value('replacementCharacters'),
      replacementUtf8Bytes: value('replacementUtf8Bytes'),
      outputCharacters: value('outputCharacters'),
      outputUtf8Bytes: value('outputUtf8Bytes'),
    );
  }
}

@immutable
class MarkdownPreparationPatch {
  const MarkdownPreparationPatch({
    required this.sessionId,
    required this.revision,
    required this.baseRevision,
    required this.rawRetainLength,
    required this.preparedRetainLength,
    required this.replacementTail,
    required this.logicalPreparedLength,
    required this.mode,
    required this.metrics,
    this.fallbackReason,
  });

  final String sessionId;
  final int revision;
  final int baseRevision;
  final int rawRetainLength;
  final int preparedRetainLength;
  final String replacementTail;
  final int logicalPreparedLength;
  final MarkdownPreparationMode mode;
  final MarkdownPreparationMetrics metrics;
  final String? fallbackReason;

  bool get isIncremental => mode == MarkdownPreparationMode.incremental;
  bool get isStale => mode == MarkdownPreparationMode.stale;

  Map<String, Object?> toMap() => <String, Object?>{
    'sessionId': sessionId,
    'revision': revision,
    'baseRevision': baseRevision,
    'rawRetainLength': rawRetainLength,
    'preparedRetainLength': preparedRetainLength,
    'replacementTail': replacementTail,
    'logicalPreparedLength': logicalPreparedLength,
    'mode': mode.name,
    'metrics': metrics.toMap(),
    if (fallbackReason != null) 'fallbackReason': fallbackReason,
  };

  factory MarkdownPreparationPatch.fromMap(Map<Object?, Object?> map) {
    final modeName = (map['mode'] ?? '').toString();
    return MarkdownPreparationPatch(
      sessionId: (map['sessionId'] ?? '').toString(),
      revision: (map['revision'] as num?)?.toInt() ?? 0,
      baseRevision: (map['baseRevision'] as num?)?.toInt() ?? 0,
      rawRetainLength: (map['rawRetainLength'] as num?)?.toInt() ?? 0,
      preparedRetainLength: (map['preparedRetainLength'] as num?)?.toInt() ?? 0,
      replacementTail: (map['replacementTail'] ?? '').toString(),
      logicalPreparedLength:
          (map['logicalPreparedLength'] as num?)?.toInt() ?? 0,
      mode: MarkdownPreparationMode.values.firstWhere(
        (value) => value.name == modeName,
        orElse: () => MarkdownPreparationMode.fallbackFull,
      ),
      metrics: MarkdownPreparationMetrics.fromMap(
        (map['metrics'] as Map<Object?, Object?>?) ??
            const <Object?, Object?>{},
      ),
      fallbackReason: map['fallbackReason']?.toString(),
    );
  }
}

@immutable
class PreparedMarkdownText {
  PreparedMarkdownText._(List<String> segments)
    : _segments = List<String>.unmodifiable(
        segments.where((segment) => segment.isNotEmpty),
      ),
      length = segments.fold<int>(0, (sum, segment) => sum + segment.length);

  const PreparedMarkdownText.empty() : _segments = const <String>[], length = 0;

  factory PreparedMarkdownText.fromString(String value) => value.isEmpty
      ? const PreparedMarkdownText.empty()
      : PreparedMarkdownText._(<String>[value]);

  static const int _maxSegments = 16;

  final List<String> _segments;
  final int length;

  bool get isEmpty => length == 0;
  bool get isBlank => _segments.every((segment) => segment.trim().isEmpty);
  int get segmentCount => _segments.length;

  String materialize() {
    if (_segments.isEmpty) return '';
    if (_segments.length == 1) return _segments.single;
    return _segments.join();
  }

  PreparedMarkdownText slice(int start, [int? end]) {
    final resolvedEnd = end ?? length;
    RangeError.checkValidRange(start, resolvedEnd, length);
    if (start == resolvedEnd) return const PreparedMarkdownText.empty();
    if (start == 0 && resolvedEnd == length) return this;

    final segments = <String>[];
    var segmentStart = 0;
    for (final segment in _segments) {
      final segmentEnd = segmentStart + segment.length;
      if (segmentEnd <= start) {
        segmentStart = segmentEnd;
        continue;
      }
      if (segmentStart >= resolvedEnd) break;
      final localStart = start > segmentStart ? start - segmentStart : 0;
      final localEnd = resolvedEnd < segmentEnd
          ? resolvedEnd - segmentStart
          : segment.length;
      segments.add(segment.substring(localStart, localEnd));
      segmentStart = segmentEnd;
    }
    return PreparedMarkdownText._(segments);
  }

  int utf8Length([int? end]) {
    final resolvedEnd = end ?? length;
    RangeError.checkValueInInterval(resolvedEnd, 0, length, 'end');
    var remaining = resolvedEnd;
    var byteLength = 0;
    for (final segment in _segments) {
      if (remaining <= 0) break;
      if (remaining >= segment.length) {
        byteLength += utf8.encode(segment).length;
        remaining -= segment.length;
      } else {
        byteLength += utf8.encode(segment.substring(0, remaining)).length;
        break;
      }
    }
    return byteLength;
  }

  bool startsWith(PreparedMarkdownText prefix) {
    if (prefix.length > length) return false;
    if (prefix.isEmpty || identical(this, prefix)) return true;

    var currentSegmentIndex = 0;
    var prefixSegmentIndex = 0;
    var currentOffset = 0;
    var prefixOffset = 0;
    var compared = 0;

    while (compared < prefix.length) {
      final currentSegment = _segments[currentSegmentIndex];
      final prefixSegment = prefix._segments[prefixSegmentIndex];
      final currentRemaining = currentSegment.length - currentOffset;
      final prefixRemaining = prefixSegment.length - prefixOffset;
      final count = currentRemaining < prefixRemaining
          ? currentRemaining
          : prefixRemaining;

      if (currentOffset == 0 &&
          prefixOffset == 0 &&
          count == currentSegment.length &&
          count == prefixSegment.length) {
        if (currentSegment != prefixSegment) return false;
      } else {
        for (var index = 0; index < count; index += 1) {
          if (currentSegment.codeUnitAt(currentOffset + index) !=
              prefixSegment.codeUnitAt(prefixOffset + index)) {
            return false;
          }
        }
      }

      compared += count;
      currentOffset += count;
      prefixOffset += count;
      if (currentOffset == currentSegment.length) {
        currentSegmentIndex += 1;
        currentOffset = 0;
      }
      if (prefixOffset == prefixSegment.length) {
        prefixSegmentIndex += 1;
        prefixOffset = 0;
      }
    }
    return true;
  }

  String substring(int start, [int? end]) {
    final resolvedEnd = end ?? length;
    RangeError.checkValidRange(start, resolvedEnd, length);
    if (start == resolvedEnd) return '';
    if (start == 0 && resolvedEnd == length) return materialize();

    final buffer = StringBuffer();
    var segmentStart = 0;
    for (final segment in _segments) {
      final segmentEnd = segmentStart + segment.length;
      if (segmentEnd <= start) {
        segmentStart = segmentEnd;
        continue;
      }
      if (segmentStart >= resolvedEnd) break;
      final localStart = start > segmentStart ? start - segmentStart : 0;
      final localEnd = resolvedEnd < segmentEnd
          ? resolvedEnd - segmentStart
          : segment.length;
      buffer.write(segment.substring(localStart, localEnd));
      segmentStart = segmentEnd;
    }
    return buffer.toString();
  }

  PreparedMarkdownText applyPatch(MarkdownPreparationPatch patch) {
    if (patch.isStale) {
      throw StateError('Cannot apply a stale markdown preparation patch');
    }
    final retainLength = patch.preparedRetainLength;
    RangeError.checkValueInInterval(
      retainLength,
      0,
      length,
      'preparedRetainLength',
    );
    if (!_isCodePointBoundary(retainLength)) {
      throw ArgumentError.value(
        retainLength,
        'preparedRetainLength',
        'must not split a UTF-16 surrogate pair',
      );
    }

    final nextSegments = <String>[];
    var remaining = retainLength;
    for (final segment in _segments) {
      if (remaining <= 0) break;
      if (remaining >= segment.length) {
        nextSegments.add(segment);
        remaining -= segment.length;
        continue;
      }
      nextSegments.add(segment.substring(0, remaining));
      remaining = 0;
      break;
    }
    if (patch.replacementTail.isNotEmpty) {
      nextSegments.add(patch.replacementTail);
    }

    var result = PreparedMarkdownText._(nextSegments);
    if (result.length != patch.logicalPreparedLength) {
      throw StateError(
        'Markdown patch produced ${result.length} characters; '
        'expected ${patch.logicalPreparedLength}.',
      );
    }
    if (result.segmentCount > _maxSegments) {
      result = PreparedMarkdownText.fromString(result.materialize());
    }
    return result;
  }

  bool _isCodePointBoundary(int offset) {
    if (offset <= 0 || offset >= length) return true;
    final previous = codeUnitAt(offset - 1);
    final next = codeUnitAt(offset);
    return !(previous >= 0xD800 &&
        previous <= 0xDBFF &&
        next >= 0xDC00 &&
        next <= 0xDFFF);
  }

  int codeUnitAt(int index) {
    RangeError.checkValidIndex(index, this, 'index', length);
    var segmentStart = 0;
    for (final segment in _segments) {
      final segmentEnd = segmentStart + segment.length;
      if (index < segmentEnd) {
        return segment.codeUnitAt(index - segmentStart);
      }
      segmentStart = segmentEnd;
    }
    throw RangeError.index(index, this, 'index', null, length);
  }

  @override
  bool operator ==(Object other) =>
      other is PreparedMarkdownText &&
      length == other.length &&
      materialize() == other.materialize();

  @override
  int get hashCode => Object.hash(length, materialize());
}

class StreamingMarkdownPreparationEngine {
  StreamingMarkdownPreparationEngine({this.maxSessions = 32});

  final int maxSessions;
  final LinkedHashMap<String, _MarkdownPreparationSession> _sessions =
      LinkedHashMap<String, _MarkdownPreparationSession>();

  int get sessionCount => _sessions.length;

  MarkdownPreparationPatch prepare(MarkdownPreparationRequest request) {
    if (request.sessionId.isEmpty) {
      throw ArgumentError.value(request.sessionId, 'sessionId');
    }
    if (request.revision <= 0) {
      throw ArgumentError.value(request.revision, 'revision');
    }

    final existing = _sessions.remove(request.sessionId);
    if (existing != null) {
      _sessions[request.sessionId] = existing;
    }

    if (existing != null && request.revision <= existing.revision) {
      return _stalePatch(request, existing);
    }

    if (existing == null) {
      return _prepareFull(
        request,
        mode: request.expectedBaseRevision == 0
            ? MarkdownPreparationMode.full
            : MarkdownPreparationMode.resetFull,
        fallbackReason: request.expectedBaseRevision == 0
            ? null
            : 'missingSession',
      );
    }

    if (request.expectedBaseRevision != existing.revision ||
        request.streaming != existing.streaming) {
      return _prepareFull(
        request,
        mode: MarkdownPreparationMode.resetFull,
        fallbackReason: request.streaming != existing.streaming
            ? 'streamingModeChanged'
            : 'baseRevisionMismatch',
        previousCallCount: existing.callCount,
      );
    }

    final incremental = _tryPrepareIncrementally(request, existing);
    if (incremental != null) {
      return incremental;
    }
    return _prepareFull(
      request,
      mode: MarkdownPreparationMode.resetFull,
      fallbackReason: 'unsafeMutation',
      previousCallCount: existing.callCount,
      previousPrepared: existing.prepared,
    );
  }

  bool release(String sessionId) => _sessions.remove(sessionId) != null;

  MarkdownPreparationPatch? _tryPrepareIncrementally(
    MarkdownPreparationRequest request,
    _MarkdownPreparationSession state,
  ) {
    final commonRawPrefix =
        request.content.length >= state.rawContent.length &&
            request.content.startsWith(state.rawContent)
        ? state.rawContent.length
        : _commonPrefixLength(state.rawContent, request.content);
    final checkpoint = state.checkpoint;
    if (commonRawPrefix < checkpoint.rawOffset ||
        checkpoint.rawOffset == 0 ||
        state.hasReferenceDefinitions ||
        request.content.contains(']:')) {
      return null;
    }

    var rawRetainLength = checkpoint.rawOffset;
    var rawTail = request.content.substring(rawRetainLength);
    var replacementTail = prepareMarkdownContentCanonical(
      rawTail,
      streaming: request.streaming,
    );
    var preparedRetainLength = checkpoint.preparedOffset;
    if (replacementTail.isEmpty) {
      preparedRetainLength = state.prepared
          .substring(0, checkpoint.preparedOffset)
          .trimRight()
          .length;
      if (preparedRetainLength < checkpoint.preparedOffset) {
        rawRetainLength = request.content
            .substring(0, checkpoint.rawOffset)
            .trimRight()
            .length;
        rawTail = request.content.substring(rawRetainLength);
        replacementTail = prepareMarkdownContentCanonical(
          rawTail,
          streaming: request.streaming,
        );
      }
    }
    final patch = _buildPatch(
      request: request,
      baseRevision: state.revision,
      rawRetainLength: rawRetainLength,
      preparedRetainLength: preparedRetainLength,
      replacementTail: replacementTail,
      mode: MarkdownPreparationMode.incremental,
      callCount: state.callCount + 1,
      retainedPreparedUtf8Bytes: request.collectMetrics
          ? state.prepared.utf8Length(preparedRetainLength)
          : 0,
    );

    PreparedMarkdownText prepared;
    try {
      prepared = state.prepared.applyPatch(patch);
    } catch (_) {
      return null;
    }

    if (request.verifyParity) {
      final canonical = prepareMarkdownContentCanonical(
        request.content,
        streaming: request.streaming,
      );
      if (prepared.materialize() != canonical) {
        return _prepareFull(
          request,
          mode: MarkdownPreparationMode.fallbackFull,
          fallbackReason: 'parityMismatch',
          previousCallCount: state.callCount,
          preparedOverride: canonical,
          previousPrepared: state.prepared,
        );
      }
    }

    final nextCheckpoint = _advanceCheckpoint(
      request.content,
      prepared,
      baseRawOffset: rawRetainLength,
      basePreparedOffset: preparedRetainLength,
      rawTail: rawTail,
      preparedTail: replacementTail,
      streaming: request.streaming,
    );
    _storeSession(
      request.sessionId,
      _MarkdownPreparationSession(
        revision: request.revision,
        rawContent: request.content,
        prepared: prepared,
        checkpoint: nextCheckpoint,
        streaming: request.streaming,
        hasReferenceDefinitions: false,
        callCount: state.callCount + 1,
      ),
    );
    return patch;
  }

  MarkdownPreparationPatch _prepareFull(
    MarkdownPreparationRequest request, {
    required MarkdownPreparationMode mode,
    String? fallbackReason,
    int previousCallCount = 0,
    String? preparedOverride,
    PreparedMarkdownText? previousPrepared,
  }) {
    final preparedValue =
        preparedOverride ??
        prepareMarkdownContentCanonical(
          request.content,
          streaming: request.streaming,
        );
    final prepared = PreparedMarkdownText.fromString(preparedValue);
    final previousValue = previousPrepared?.materialize();
    final preparedRetainLength = previousValue == null
        ? 0
        : _commonPrefixLength(previousValue, preparedValue);
    final replacementTail = preparedValue.substring(preparedRetainLength);
    final patch = _buildPatch(
      request: request,
      baseRevision: request.expectedBaseRevision,
      rawRetainLength: 0,
      preparedRetainLength: preparedRetainLength,
      replacementTail: replacementTail,
      mode: mode,
      fallbackReason: fallbackReason,
      callCount: previousCallCount + 1,
      retainedPreparedUtf8Bytes:
          request.collectMetrics && previousPrepared != null
          ? previousPrepared.utf8Length(preparedRetainLength)
          : 0,
    );
    final hasReferences = request.content.contains(']:');
    final checkpoint = hasReferences
        ? const _MarkdownPreparationCheckpoint.empty()
        : _advanceCheckpoint(
            request.content,
            prepared,
            baseRawOffset: 0,
            basePreparedOffset: 0,
            rawTail: request.content,
            preparedTail: preparedValue,
            streaming: request.streaming,
          );
    _storeSession(
      request.sessionId,
      _MarkdownPreparationSession(
        revision: request.revision,
        rawContent: request.content,
        prepared: prepared,
        checkpoint: checkpoint,
        streaming: request.streaming,
        hasReferenceDefinitions: hasReferences,
        callCount: previousCallCount + 1,
      ),
    );
    return patch;
  }

  MarkdownPreparationPatch _stalePatch(
    MarkdownPreparationRequest request,
    _MarkdownPreparationSession state,
  ) {
    return MarkdownPreparationPatch(
      sessionId: request.sessionId,
      revision: request.revision,
      baseRevision: state.revision,
      rawRetainLength: 0,
      preparedRetainLength: 0,
      replacementTail: '',
      logicalPreparedLength: state.prepared.length,
      mode: MarkdownPreparationMode.stale,
      fallbackReason: 'staleRevision',
      metrics: const MarkdownPreparationMetrics.empty(),
    );
  }

  MarkdownPreparationPatch _buildPatch({
    required MarkdownPreparationRequest request,
    required int baseRevision,
    required int rawRetainLength,
    required int preparedRetainLength,
    required String replacementTail,
    required MarkdownPreparationMode mode,
    required int callCount,
    int retainedPreparedUtf8Bytes = 0,
    String? fallbackReason,
  }) {
    final logicalLength = preparedRetainLength + replacementTail.length;
    final processed = request.content.substring(rawRetainLength);
    final collect = request.collectMetrics;
    return MarkdownPreparationPatch(
      sessionId: request.sessionId,
      revision: request.revision,
      baseRevision: baseRevision,
      rawRetainLength: rawRetainLength,
      preparedRetainLength: preparedRetainLength,
      replacementTail: replacementTail,
      logicalPreparedLength: logicalLength,
      mode: mode,
      fallbackReason: fallbackReason,
      metrics: MarkdownPreparationMetrics(
        callCount: callCount,
        inputCharacters: request.content.length,
        inputUtf8Bytes: collect ? utf8.encode(request.content).length : 0,
        processedCharacters: processed.length,
        processedUtf8Bytes: collect ? utf8.encode(processed).length : 0,
        retainedRawCharacters: rawRetainLength,
        retainedPreparedCharacters: preparedRetainLength,
        replacementCharacters: replacementTail.length,
        replacementUtf8Bytes: collect ? utf8.encode(replacementTail).length : 0,
        outputCharacters: logicalLength,
        outputUtf8Bytes: collect
            ? retainedPreparedUtf8Bytes + utf8.encode(replacementTail).length
            : 0,
      ),
    );
  }

  _MarkdownPreparationCheckpoint _advanceCheckpoint(
    String rawContent,
    PreparedMarkdownText prepared, {
    required int baseRawOffset,
    required int basePreparedOffset,
    required String rawTail,
    required String preparedTail,
    required bool streaming,
  }) {
    final localRawBoundary = _lastSafeRawBoundary(rawTail);
    if (localRawBoundary <= 0 || localRawBoundary >= rawTail.length) {
      return _MarkdownPreparationCheckpoint(
        rawOffset: baseRawOffset,
        preparedOffset: basePreparedOffset,
      );
    }

    final rawPrefixTail = rawTail.substring(0, localRawBoundary);
    if (rawPrefixTail.contains(']:')) {
      return _MarkdownPreparationCheckpoint(
        rawOffset: baseRawOffset,
        preparedOffset: basePreparedOffset,
      );
    }
    final preparedPrefixTail = prepareMarkdownContentCanonical(
      rawPrefixTail,
      streaming: streaming,
    );
    if (preparedPrefixTail.isEmpty && rawPrefixTail.trim().isEmpty) {
      return _MarkdownPreparationCheckpoint(
        rawOffset: baseRawOffset,
        preparedOffset: basePreparedOffset,
      );
    }
    if (!preparedTail.startsWith(preparedPrefixTail)) {
      return _MarkdownPreparationCheckpoint(
        rawOffset: baseRawOffset,
        preparedOffset: basePreparedOffset,
      );
    }

    final rawOffset = baseRawOffset + localRawBoundary;
    final preparedOffset = basePreparedOffset + preparedPrefixTail.length;
    if (rawOffset > rawContent.length || preparedOffset > prepared.length) {
      return _MarkdownPreparationCheckpoint(
        rawOffset: baseRawOffset,
        preparedOffset: basePreparedOffset,
      );
    }
    return _MarkdownPreparationCheckpoint(
      rawOffset: rawOffset,
      preparedOffset: preparedOffset,
    );
  }

  void _storeSession(String sessionId, _MarkdownPreparationSession session) {
    _sessions.remove(sessionId);
    _sessions[sessionId] = session;
    while (_sessions.length > maxSessions) {
      _sessions.remove(_sessions.keys.first);
    }
  }
}

int _commonPrefixLength(String left, String right) {
  final limit = left.length < right.length ? left.length : right.length;
  var index = 0;
  while (index < limit && left.codeUnitAt(index) == right.codeUnitAt(index)) {
    index += 1;
  }
  if (index > 0 &&
      index < left.length &&
      index < right.length &&
      _isHighSurrogate(left.codeUnitAt(index - 1))) {
    index -= 1;
  }
  return index;
}

int _lastSafeRawBoundary(String input) {
  if (input.isEmpty || input.contains(']:')) return 0;

  var openTicks = 0;
  var detailsDepth = 0;
  var lastBoundary = 0;
  var lineStart = 0;

  while (lineStart < input.length) {
    final newline = input.indexOf('\n', lineStart);
    final lineEnd = newline == -1 ? input.length : newline;
    final line = input.substring(lineStart, lineEnd);
    final lower = line.toLowerCase();

    detailsDepth += RegExp(
      r'<details\b',
      caseSensitive: false,
    ).allMatches(line).length;
    detailsDepth -= RegExp(
      r'</details\s*>',
      caseSensitive: false,
    ).allMatches(line).length;
    if (detailsDepth < 0) detailsDepth = 0;

    var index = 0;
    while (index < line.length) {
      if (line.codeUnitAt(index) != 0x60) {
        index += 1;
        continue;
      }
      var end = index + 1;
      while (end < line.length && line.codeUnitAt(end) == 0x60) {
        end += 1;
      }
      final runLength = end - index;
      if (openTicks == 0) {
        openTicks = runLength;
      } else if (runLength == openTicks) {
        openTicks = 0;
      }
      index = end;
    }

    final endsWithNewline = newline != -1;
    if (endsWithNewline &&
        line.trim().isEmpty &&
        openTicks == 0 &&
        detailsDepth == 0 &&
        !lower.contains('<details')) {
      lastBoundary = newline + 1;
    }
    if (!endsWithNewline) break;
    lineStart = newline + 1;
  }

  if (lastBoundary > 0 &&
      lastBoundary < input.length &&
      _isLowSurrogate(input.codeUnitAt(lastBoundary))) {
    return lastBoundary - 1;
  }
  return lastBoundary;
}

bool _isHighSurrogate(int value) => value >= 0xD800 && value <= 0xDBFF;
bool _isLowSurrogate(int value) => value >= 0xDC00 && value <= 0xDFFF;

@immutable
class _MarkdownPreparationCheckpoint {
  const _MarkdownPreparationCheckpoint({
    required this.rawOffset,
    required this.preparedOffset,
  });

  const _MarkdownPreparationCheckpoint.empty()
    : rawOffset = 0,
      preparedOffset = 0;

  final int rawOffset;
  final int preparedOffset;
}

@immutable
class _MarkdownPreparationSession {
  const _MarkdownPreparationSession({
    required this.revision,
    required this.rawContent,
    required this.prepared,
    required this.checkpoint,
    required this.streaming,
    required this.hasReferenceDefinitions,
    required this.callCount,
  });

  final int revision;
  final String rawContent;
  final PreparedMarkdownText prepared;
  final _MarkdownPreparationCheckpoint checkpoint;
  final bool streaming;
  final bool hasReferenceDefinitions;
  final int callCount;
}
