import 'dart:collection';

import 'semantic_message_builder.dart';
import 'structured_output.dart';

/// A bounded-cost update for projecting cumulative Open WebUI `output`
/// snapshots into the active assistant message.
sealed class StructuredOutputStreamingProjection {
  const StructuredOutputStreamingProjection({
    required this.content,
    required this.plainContent,
  });

  final String content;
  final String plainContent;
}

/// Appends a newly observed plain-text suffix without rebuilding the visible
/// prefix.
final class StructuredOutputStreamingAppend
    extends StructuredOutputStreamingProjection {
  const StructuredOutputStreamingAppend({
    required super.content,
    required super.plainContent,
  });
}

/// Replaces the visible snapshot when its semantic structure changed or an
/// append cannot preserve the authoritative Markdown representation.
final class StructuredOutputStreamingReplace
    extends StructuredOutputStreamingProjection {
  const StructuredOutputStreamingReplace({
    required super.content,
    required super.plainContent,
  });
}

/// Projects cumulative structured-output snapshots with bounded rendering
/// work.
///
/// Open WebUI sends the complete accumulated `output` list on each event. A
/// naive renderer therefore re-parses an ever-growing answer for every token.
/// Plain trailing text is instead appended after fragment-safe HTML escaping.
/// Structure-sensitive updates (reasoning, tools, code, or Markdown code
/// delimiters) receive geometrically spaced authoritative replacements, plus
/// immediate replacements for structural/status transitions. [finish] always
/// performs one final authoritative render so streamed approximations cannot
/// change persisted Markdown semantics.
final class StructuredOutputStreamingProjector {
  List<StructuredOutputBlock> _latestBlocks = const [];
  List<StructuredOutputBlock> _projectedBlocks = const [];
  String? _latestReplacementText;
  String? _projectedReplacementText;
  bool _hasLatestSnapshot = false;
  bool _hasProjection = false;
  bool _appendIsPlain = true;
  bool _finished = false;
  int _nextFullProjectionLength = 1;
  int _fullProjectionCount = 0;
  int _appendProjectionCount = 0;
  int _fullProjectionCharacterCount = 0;

  /// Counts streaming replacements, excluding the final authoritative render.
  int get fullProjectionCount => _fullProjectionCount;

  int get appendProjectionCount => _appendProjectionCount;

  /// Total characters materialized by streaming replacements. This is a
  /// deterministic complexity guard that is more stable than wall-clock tests.
  int get fullProjectionCharacterCount => _fullProjectionCharacterCount;

  StructuredOutputStreamingProjection? project(
    List<StructuredOutputBlock> blocks, {
    String? replacementText,
    bool canAppend = true,
    bool forceReplace = false,
  }) {
    if (_finished) return null;

    final snapshot = List<StructuredOutputBlock>.unmodifiable(blocks);
    _latestBlocks = snapshot;
    _latestReplacementText = replacementText;
    _hasLatestSnapshot = snapshot.isNotEmpty || replacementText != null;
    if (!_hasLatestSnapshot) return null;

    final logicalLength = _logicalLength(snapshot, replacementText);
    if (!_hasProjection) {
      return _replace(snapshot, replacementText, logicalLength);
    }

    final appendDelta = _plainTailAppendDelta(
      _projectedBlocks,
      snapshot,
      previousReplacementText: _projectedReplacementText,
      replacementText: replacementText,
    );
    if (appendDelta != null &&
        appendDelta.isNotEmpty &&
        (appendDelta.contains('`') || appendDelta.contains('~'))) {
      _appendIsPlain = false;
    }

    if (canAppend &&
        _appendIsPlain &&
        appendDelta != null &&
        appendDelta.isNotEmpty &&
        logicalLength < _nextFullProjectionLength) {
      _projectedBlocks = snapshot;
      _projectedReplacementText = replacementText;
      _appendProjectionCount += 1;
      return StructuredOutputStreamingAppend(
        content: renderSemanticPlainTextFragment(appendDelta),
        plainContent: _plainText(snapshot, replacementText),
      );
    }

    if (forceReplace ||
        _requiresImmediateReplacement(
          _projectedBlocks,
          snapshot,
          previousReplacementText: _projectedReplacementText,
          replacementText: replacementText,
        ) ||
        logicalLength >= _nextFullProjectionLength) {
      return _replace(snapshot, replacementText, logicalLength);
    }

    return null;
  }

  /// Produces the exact terminal representation once, regardless of which
  /// bounded streaming projections were visible along the way.
  StructuredOutputStreamingReplace? finish() {
    if (_finished || !_hasLatestSnapshot) return null;
    _finished = true;
    return StructuredOutputStreamingReplace(
      content: _render(_latestBlocks, _latestReplacementText),
      plainContent: _plainText(_latestBlocks, _latestReplacementText),
    );
  }

  StructuredOutputStreamingReplace _replace(
    List<StructuredOutputBlock> blocks,
    String? replacementText,
    int logicalLength,
  ) {
    final content = _render(blocks, replacementText);
    final plainContent = _plainText(blocks, replacementText);
    _projectedBlocks = blocks;
    _projectedReplacementText = replacementText;
    _hasProjection = true;
    _appendIsPlain = !plainContent.contains('`') && !plainContent.contains('~');
    _nextFullProjectionLength = logicalLength == 0 ? 1 : logicalLength * 2;
    _fullProjectionCount += 1;
    _fullProjectionCharacterCount += content.length;
    return StructuredOutputStreamingReplace(
      content: content,
      plainContent: plainContent,
    );
  }
}

String _render(List<StructuredOutputBlock> blocks, String? replacementText) {
  return replacementText == null
      ? renderStructuredOutputBlocks(blocks)
      : renderStructuredOutputBlocksWithContent(blocks, replacementText);
}

String _plainText(List<StructuredOutputBlock> blocks, String? replacementText) {
  return replacementText ?? structuredOutputBlocksPlainText(blocks);
}

int _logicalLength(
  List<StructuredOutputBlock> blocks,
  String? replacementText,
) {
  if (replacementText != null) return replacementText.length;
  var length = 0;
  for (final block in blocks) {
    switch (block) {
      case StructuredOutputTextBlock(:final text):
        length += text.length;
      case StructuredOutputReasoningBlock(:final text):
        length += text.length;
      case StructuredOutputToolCallBlock(
        :final id,
        :final name,
        :final arguments,
        :final result,
        :final files,
        :final embeds,
      ):
        length +=
            id.length +
            name.length +
            _valueLogicalLength(arguments) +
            _valueLogicalLength(result) +
            _valueLogicalLength(files) +
            _valueLogicalLength(embeds) +
            1;
      case StructuredOutputCodeInterpreterBlock(:final code, :final output):
        length += code.length + _valueLogicalLength(output);
    }
  }
  return length;
}

const int _maxStructuredValueDepth = 64;
const int _maxStructuredValueNodes = 100000;
const int _saturatedValueLogicalLength = 1 << 30;

int _valueLogicalLength(Object? value) =>
    _StructuredValueLengthTraversal().measure(value);

/// Measures JSON-like values without allowing untrusted nesting, fan-out, or
/// cycles to make streaming projection traversal unbounded.
///
/// The active-path set, rather than a global visited set, preserves the old
/// behavior for acyclic graphs that reuse the same collection in multiple
/// places: every occurrence still contributes to the logical length.
final class _StructuredValueLengthTraversal {
  final Set<Object> _activeContainers = HashSet<Object>.identity();
  int _nodes = 0;
  bool _saturated = false;

  int measure(Object? value) {
    final length = _measure(value, 0);
    return _saturated ? _saturatedValueLogicalLength : length;
  }

  int _measure(Object? value, int depth) {
    if (value == null || _saturated) return 0;
    if (depth > _maxStructuredValueDepth ||
        ++_nodes > _maxStructuredValueNodes) {
      _saturated = true;
      return 0;
    }

    return switch (value) {
      String() => value.length,
      num() || bool() => value.toString().length,
      List() => _measureList(value, depth),
      Map() => _measureMap(value, depth),
      _ => value.toString().length,
    };
  }

  int _measureList(List<dynamic> value, int depth) {
    if (!_activeContainers.add(value)) {
      _saturated = true;
      return 0;
    }
    var length = 0;
    try {
      for (final item in value) {
        length = _add(length, _measure(item, depth + 1));
        if (_saturated) break;
      }
    } finally {
      _activeContainers.remove(value);
    }
    return length;
  }

  int _measureMap(Map<dynamic, dynamic> value, int depth) {
    if (!_activeContainers.add(value)) {
      _saturated = true;
      return 0;
    }
    var length = 0;
    try {
      for (final entry in value.entries) {
        length = _add(length, entry.key.toString().length);
        length = _add(length, _measure(entry.value, depth + 1));
        if (_saturated) break;
      }
    } finally {
      _activeContainers.remove(value);
    }
    return length;
  }

  int _add(int left, int right) {
    if (_saturated || right >= _saturatedValueLogicalLength - left) {
      _saturated = true;
      return _saturatedValueLogicalLength;
    }
    return left + right;
  }
}

String? _plainTailAppendDelta(
  List<StructuredOutputBlock> previous,
  List<StructuredOutputBlock> current, {
  required String? previousReplacementText,
  required String? replacementText,
}) {
  if (previousReplacementText != null ||
      replacementText != null ||
      previous.length != current.length ||
      previous.isEmpty) {
    return null;
  }

  for (var index = 0; index < previous.length - 1; index += 1) {
    if (!_blocksEquivalent(previous[index], current[index])) return null;
  }

  final previousTail = previous.last;
  final currentTail = current.last;
  if (previousTail is! StructuredOutputTextBlock ||
      currentTail is! StructuredOutputTextBlock ||
      !_hasStableCumulativePrefix(previousTail.text, currentTail.text)) {
    return null;
  }
  return currentTail.text.substring(previousTail.text.length);
}

bool _requiresImmediateReplacement(
  List<StructuredOutputBlock> previous,
  List<StructuredOutputBlock> current, {
  required String? previousReplacementText,
  required String? replacementText,
}) {
  if ((previousReplacementText == null) != (replacementText == null)) {
    return true;
  }
  if (previousReplacementText != null && replacementText != null) {
    if (!_hasStableCumulativePrefix(previousReplacementText, replacementText)) {
      return true;
    }
  }
  if (previous.length != current.length) return true;

  for (var index = 0; index < previous.length; index += 1) {
    final before = previous[index];
    final after = current[index];
    if (before.runtimeType != after.runtimeType) return true;
    switch ((before, after)) {
      case (
        StructuredOutputTextBlock(text: final beforeText),
        StructuredOutputTextBlock(text: final afterText),
      ):
        if (beforeText.length == afterText.length) {
          if (beforeText != afterText) return true;
          continue;
        }
        if (!_hasStableCumulativePrefix(beforeText, afterText)) return true;
      case (
        StructuredOutputReasoningBlock(
          text: final beforeText,
          done: final beforeDone,
          duration: final beforeDuration,
        ),
        StructuredOutputReasoningBlock(
          text: final afterText,
          done: final afterDone,
          duration: final afterDuration,
        ),
      ):
        if (beforeDone != afterDone || beforeDuration != afterDuration) {
          return true;
        }
        if (beforeText.length == afterText.length) {
          if (beforeText != afterText) return true;
          continue;
        }
        if (!_hasStableCumulativePrefix(beforeText, afterText)) return true;
      case (
        StructuredOutputToolCallBlock(
          id: final beforeId,
          name: final beforeName,
          arguments: final beforeArguments,
          done: final beforeDone,
          result: final beforeResult,
          files: final beforeFiles,
          embeds: final beforeEmbeds,
        ),
        StructuredOutputToolCallBlock(
          id: final afterId,
          name: final afterName,
          arguments: final afterArguments,
          done: final afterDone,
          result: final afterResult,
          files: final afterFiles,
          embeds: final afterEmbeds,
        ),
      ):
        if (beforeId != afterId ||
            beforeName != afterName ||
            beforeDone != afterDone ||
            _valueUpdateRequiresImmediateReplacement(
              beforeArguments,
              afterArguments,
            ) ||
            _valueUpdateRequiresImmediateReplacement(
              beforeResult,
              afterResult,
            ) ||
            _valueUpdateRequiresImmediateReplacement(beforeFiles, afterFiles) ||
            _valueUpdateRequiresImmediateReplacement(
              beforeEmbeds,
              afterEmbeds,
            )) {
          return true;
        }
      case (
        StructuredOutputCodeInterpreterBlock(
          code: final beforeCode,
          language: final beforeLanguage,
          done: final beforeDone,
          duration: final beforeDuration,
          output: final beforeOutput,
        ),
        StructuredOutputCodeInterpreterBlock(
          code: final afterCode,
          language: final afterLanguage,
          done: final afterDone,
          duration: final afterDuration,
          output: final afterOutput,
        ),
      ):
        if (beforeLanguage != afterLanguage ||
            beforeDone != afterDone ||
            beforeDuration != afterDuration ||
            _valueUpdateRequiresImmediateReplacement(
              beforeOutput,
              afterOutput,
            )) {
          return true;
        }
        if (beforeCode.length == afterCode.length) {
          if (beforeCode != afterCode) return true;
          continue;
        }
        if (!_hasStableCumulativePrefix(beforeCode, afterCode)) return true;
      default:
        return true;
    }
  }
  return false;
}

bool _valueUpdateRequiresImmediateReplacement(Object? before, Object? after) {
  if (_deepEquals(before, after)) return false;
  if (before is String && after is String) {
    return !_hasStableCumulativePrefix(before, after);
  }
  return _valueLogicalLength(after) <= _valueLogicalLength(before);
}

bool _hasStableCumulativePrefix(String previous, String current) {
  if (identical(previous, current)) return true;
  if (current.length < previous.length) return false;
  if (previous.isEmpty) return true;

  // The protocol defines in-progress message text as cumulative. Validate both
  // ends of the known prefix with bounded work so this guard does not itself
  // recreate the quadratic scan it protects against. Any detected rewrite is
  // replaced immediately, and [StructuredOutputStreamingProjector.finish]
  // remains the authoritative full validation.
  const probeLength = 64;
  if (previous.length <= probeLength * 2) {
    return current.startsWith(previous);
  }
  final leading = previous.substring(0, probeLength);
  final trailingStart = previous.length - probeLength;
  final trailing = previous.substring(trailingStart);
  return current.startsWith(leading) &&
      current.startsWith(trailing, trailingStart);
}

bool _blocksEquivalent(
  StructuredOutputBlock left,
  StructuredOutputBlock right,
) {
  if (identical(left, right)) return true;
  return switch ((left, right)) {
    (
      StructuredOutputTextBlock(text: final a),
      StructuredOutputTextBlock(text: final b),
    ) =>
      _boundedStringEquals(a, b),
    (
      StructuredOutputReasoningBlock(
        text: final aText,
        done: final aDone,
        duration: final aDuration,
      ),
      StructuredOutputReasoningBlock(
        text: final bText,
        done: final bDone,
        duration: final bDuration,
      ),
    ) =>
      aDone == bDone &&
          aDuration == bDuration &&
          _boundedStringEquals(aText, bText),
    (
      StructuredOutputToolCallBlock(
        id: final aId,
        name: final aName,
        arguments: final aArguments,
        done: final aDone,
        result: final aResult,
        files: final aFiles,
        embeds: final aEmbeds,
      ),
      StructuredOutputToolCallBlock(
        id: final bId,
        name: final bName,
        arguments: final bArguments,
        done: final bDone,
        result: final bResult,
        files: final bFiles,
        embeds: final bEmbeds,
      ),
    ) =>
      aId == bId &&
          aName == bName &&
          aDone == bDone &&
          _deepEquals(aArguments, bArguments) &&
          _deepEquals(aResult, bResult) &&
          _deepEquals(aFiles, bFiles) &&
          _deepEquals(aEmbeds, bEmbeds),
    (
      StructuredOutputCodeInterpreterBlock(
        code: final aCode,
        language: final aLanguage,
        done: final aDone,
        duration: final aDuration,
        output: final aOutput,
      ),
      StructuredOutputCodeInterpreterBlock(
        code: final bCode,
        language: final bLanguage,
        done: final bDone,
        duration: final bDuration,
        output: final bOutput,
      ),
    ) =>
      aLanguage == bLanguage &&
          aDone == bDone &&
          aDuration == bDuration &&
          _boundedStringEquals(aCode, bCode) &&
          _deepEquals(aOutput, bOutput),
    _ => false,
  };
}

bool _boundedStringEquals(String left, String right) {
  return left.length == right.length && _hasStableCumulativePrefix(left, right);
}

bool _deepEquals(Object? left, Object? right) =>
    _BoundedStructuredValueEquality().equals(left, right);

/// Fail-closed equality for JSON-like values received from streaming events.
///
/// Returning false when the traversal budget is exhausted may cause one extra
/// authoritative projection, but can never hide a server-side revision. Active
/// identity pairs make equivalent cyclic graphs safe without changing the
/// comparison of ordinary acyclic values.
final class _BoundedStructuredValueEquality {
  final Map<Object, Set<Object>> _activePairs =
      HashMap<Object, Set<Object>>.identity();
  int _nodes = 0;

  bool equals(Object? left, Object? right) => _equals(left, right, 0);

  bool _equals(Object? left, Object? right, int depth) {
    if (identical(left, right) || left == right) return true;
    if (depth > _maxStructuredValueDepth ||
        ++_nodes > _maxStructuredValueNodes) {
      return false;
    }

    if (left is List && right is List) {
      if (left.length != right.length) return false;
      if (!_beginPair(left, right)) return true;
      try {
        for (var index = 0; index < left.length; index += 1) {
          if (!_equals(left[index], right[index], depth + 1)) return false;
        }
        return true;
      } finally {
        _endPair(left, right);
      }
    }
    if (left is Map && right is Map) {
      if (left.length != right.length) return false;
      if (!_beginPair(left, right)) return true;
      try {
        for (final entry in left.entries) {
          if (!right.containsKey(entry.key) ||
              !_equals(entry.value, right[entry.key], depth + 1)) {
            return false;
          }
        }
        return true;
      } finally {
        _endPair(left, right);
      }
    }
    return false;
  }

  bool _beginPair(Object left, Object right) {
    final rights = _activePairs.putIfAbsent(
      left,
      () => HashSet<Object>.identity(),
    );
    return rights.add(right);
  }

  void _endPair(Object left, Object right) {
    final rights = _activePairs[left];
    if (rights == null) return;
    rights.remove(right);
    if (rights.isEmpty) _activePairs.remove(left);
  }
}

String renderStructuredOutputBlocks(List<StructuredOutputBlock> blocks) {
  return renderSemanticMessageBlocks(
    structuredOutputBlocksToSemanticMessage(blocks),
  );
}

String renderStructuredOutputBlocksWithContent(
  List<StructuredOutputBlock> blocks,
  String content,
) {
  return renderSemanticMessageBlocks(
    structuredOutputBlocksToSemanticMessage(blocks, replacementText: content),
  );
}

bool structuredOutputBlocksContainDetails(List<StructuredOutputBlock> blocks) {
  return blocks.any((block) => block is! StructuredOutputTextBlock);
}

String structuredOutputBlocksPlainText(List<StructuredOutputBlock> blocks) {
  return blocks
      .whereType<StructuredOutputTextBlock>()
      .map((block) => block.text)
      .join();
}

List<SemanticMessageBlock> structuredOutputBlocksToSemanticMessage(
  List<StructuredOutputBlock> blocks, {
  String? replacementText,
}) {
  if (blocks.isEmpty && (replacementText == null || replacementText.isEmpty)) {
    return const [];
  }

  final semanticBlocks = <SemanticMessageBlock>[];
  final replacementTextParts = replacementText == null
      ? null
      : _replacementTextParts(blocks, replacementText);
  var replacementTextIndex = 0;

  for (final block in blocks) {
    switch (block) {
      case StructuredOutputTextBlock(:final text):
        if (replacementTextParts != null) {
          final replacementPart = replacementTextParts[replacementTextIndex++];
          if (replacementPart.isNotEmpty) {
            semanticBlocks.add(SemanticTextBlock(replacementPart));
          }
        } else {
          semanticBlocks.add(SemanticTextBlock(text));
        }
      case StructuredOutputReasoningBlock(
        :final text,
        :final done,
        :final duration,
      ):
        semanticBlocks.add(
          SemanticDetailsBlock.reasoning(
            text: text,
            done: done,
            duration: duration,
          ),
        );
      case StructuredOutputToolCallBlock(
        :final id,
        :final name,
        :final arguments,
        :final done,
        :final result,
        :final files,
        :final embeds,
      ):
        semanticBlocks.add(
          SemanticDetailsBlock.toolCall(
            id: id,
            name: name,
            arguments: arguments,
            done: done,
            result: result,
            files: files,
            embeds: embeds,
          ),
        );
      case StructuredOutputCodeInterpreterBlock(
        :final code,
        :final language,
        :final done,
        :final duration,
        :final output,
      ):
        semanticBlocks.add(
          SemanticDetailsBlock.codeInterpreter(
            code: code,
            language: language,
            done: done,
            duration: duration,
            output: output,
          ),
        );
    }
  }

  if (replacementText != null && replacementTextParts == null) {
    semanticBlocks.add(SemanticTextBlock(replacementText));
  }

  return semanticBlocks;
}

List<String>? _replacementTextParts(
  List<StructuredOutputBlock> blocks,
  String replacementText,
) {
  final textBlocks = blocks.whereType<StructuredOutputTextBlock>().toList();
  if (textBlocks.isEmpty) {
    return null;
  }
  if (textBlocks.length == 1) {
    return [replacementText];
  }

  final originalText = textBlocks.map((block) => block.text).join();
  if (originalText == replacementText) {
    return textBlocks.map((block) => block.text).toList(growable: false);
  }

  final parts = <String>[];
  var offset = 0;
  for (var index = 0; index < textBlocks.length; index += 1) {
    if (index == textBlocks.length - 1) {
      parts.add(replacementText.substring(offset));
      break;
    }
    final requestedNextOffset = offset + textBlocks[index].text.length;
    final nextOffset = requestedNextOffset > replacementText.length
        ? replacementText.length
        : requestedNextOffset;
    parts.add(replacementText.substring(offset, nextOffset));
    offset = nextOffset;
  }
  return parts;
}
