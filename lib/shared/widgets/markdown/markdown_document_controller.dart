import 'dart:async';

import 'package:flutter/foundation.dart';

import 'compiled_markdown_document.dart';
import 'markdown_compile_service.dart';

typedef MarkdownDocumentControllerListener =
    void Function(
      String compiledPreparedContent,
      CompiledMarkdownDocument? document,
    );

enum _MarkdownResolveMode { full, streamingIncremental }

final RegExp _streamingFenceStartPattern = RegExp(r'^\s*(`{3,}|~{3,})(.*)$');
final RegExp _streamingHeadingPattern = RegExp(r'^\s{0,3}#{1,6}\s+\S');
final RegExp _streamingHorizontalRulePattern = RegExp(
  r'^\s{0,3}(?:\*\s*){3,}$|^\s{0,3}(?:-\s*){3,}$|^\s{0,3}(?:_\s*){3,}$',
);
final RegExp _streamingSetextUnderlinePattern = RegExp(
  r'^\s{0,3}(?:=+|-+)\s*$',
);
final RegExp _streamingUnorderedListPattern = RegExp(r'^\s{0,3}[-+*]\s+');
final RegExp _streamingOrderedListPattern = RegExp(r'^\s{0,3}\d+[.)]\s+');
final RegExp _streamingBlockquotePattern = RegExp(r'^\s{0,3}>');
final RegExp _streamingTableDividerPattern = RegExp(
  r'^\s*\|?(?:\s*:?-{3,}:?\s*\|)+\s*:?-{3,}:?\s*\|?\s*$',
);
final RegExp _streamingDetailsOpenPattern = RegExp(
  r'^<details\b',
  caseSensitive: false,
);
final RegExp _streamingDetailsClosePattern = RegExp(
  r'</details\s*>',
  caseSensitive: false,
);
final RegExp _streamingReferenceDefinitionPattern = RegExp(
  r'^\s{0,3}\[[^\]\n]+\]:',
  multiLine: true,
);

/// Shared controller that resolves prepared markdown into compiled documents.
///
/// Both `ConduitMarkdownWidget` and `StreamingMarkdownWidget` use the same
/// compile state machine, while preserving their different UI policies around
/// whether stale content should remain visible during async recompiles.
class MarkdownDocumentController {
  MarkdownDocumentController({
    required MarkdownCompileService Function() readCompiler,
    required bool Function() isWidgetTest,
    required MarkdownDocumentControllerListener onStateChanged,
  }) : _readCompiler = readCompiler,
       _isWidgetTest = isWidgetTest,
       _onStateChanged = onStateChanged;

  final MarkdownCompileService Function() _readCompiler;
  final bool Function() _isWidgetTest;
  final MarkdownDocumentControllerListener _onStateChanged;

  String _requestedPreparedContent = '';
  _MarkdownResolveMode _requestedResolveMode = _MarkdownResolveMode.full;
  String _compiledPreparedContent = '';
  CompiledMarkdownDocument? _compiledDocument;
  bool _documentInFlight = false;
  _MarkdownResolveRequest? _queuedRequest;
  int _documentGeneration = 0;
  bool _disposed = false;
  _StreamingIncrementalState? _streamingIncrementalState;

  String get compiledPreparedContent => _compiledPreparedContent;

  CompiledMarkdownDocument? get compiledDocument => _compiledDocument;

  void applyDirectDocument(CompiledMarkdownDocument document) {
    _requestedPreparedContent = document.normalizedContent;
    _requestedResolveMode = _MarkdownResolveMode.full;
    _streamingIncrementalState = null;
    _invalidatePendingAsyncDocument();
    _setState(document.normalizedContent, document);
  }

  void resolvePrepared(
    String preparedContent, {
    bool clearDocumentWhenAsync = false,
  }) {
    final preparedChanged =
        _requestedPreparedContent != preparedContent ||
        _requestedResolveMode != _MarkdownResolveMode.full;
    _requestedPreparedContent = preparedContent;
    _requestedResolveMode = _MarkdownResolveMode.full;
    _streamingIncrementalState = null;

    if (preparedContent.trim().isEmpty) {
      _invalidatePendingAsyncDocument();
      _setState('', const CompiledMarkdownDocument.empty());
      return;
    }

    if (!preparedChanged &&
        _compiledPreparedContent == preparedContent &&
        _compiledDocument != null) {
      return;
    }

    final compiler = _readCompiler();
    final cached = compiler.peekPrepared(preparedContent);
    if (cached != null) {
      _invalidatePendingAsyncDocument();
      _setState(preparedContent, cached);
      return;
    }

    if (compiler.shouldCompileSynchronously(
      preparedContent,
      widgetTest: _isWidgetTest(),
    )) {
      _invalidatePendingAsyncDocument();
      final syncDocument = compiler.compilePreparedSynchronously(
        preparedContent,
      );
      _setState(preparedContent, syncDocument);
      return;
    }

    if (clearDocumentWhenAsync && preparedChanged) {
      _setState(_compiledPreparedContent, null);
    }

    final request = _MarkdownResolveRequest(
      preparedContent: preparedContent,
      mode: _MarkdownResolveMode.full,
    );
    if (_documentInFlight) {
      _queueLatestRequest(request);
      return;
    }

    unawaited(_refreshCompiledDocument(request));
  }

  void resolveStreamingPrepared(
    String preparedContent, {
    bool clearDocumentWhenAsync = false,
  }) {
    final preparedChanged =
        _requestedPreparedContent != preparedContent ||
        _requestedResolveMode != _MarkdownResolveMode.streamingIncremental;
    _requestedPreparedContent = preparedContent;
    _requestedResolveMode = _MarkdownResolveMode.streamingIncremental;

    if (preparedContent.trim().isEmpty) {
      _streamingIncrementalState = null;
      _invalidatePendingAsyncDocument();
      _setState('', const CompiledMarkdownDocument.empty());
      return;
    }

    if (!preparedChanged &&
        _compiledPreparedContent == preparedContent &&
        _compiledDocument != null) {
      return;
    }

    final compiler = _readCompiler();
    final cached = compiler.peekPrepared(preparedContent);
    if (cached != null) {
      _streamingIncrementalState = null;
      _invalidatePendingAsyncDocument();
      _setState(preparedContent, cached);
      return;
    }

    if (compiler.shouldCompileSynchronously(
      preparedContent,
      widgetTest: _isWidgetTest(),
    )) {
      _streamingIncrementalState = null;
      _invalidatePendingAsyncDocument();
      final syncDocument = compiler.compilePreparedSynchronously(
        preparedContent,
      );
      _setState(preparedContent, syncDocument);
      return;
    }

    if (clearDocumentWhenAsync && preparedChanged) {
      _setState(_compiledPreparedContent, null);
    }

    final request = _MarkdownResolveRequest(
      preparedContent: preparedContent,
      mode: _MarkdownResolveMode.streamingIncremental,
    );
    if (_documentInFlight) {
      _queueLatestRequest(request);
      return;
    }

    unawaited(_refreshCompiledDocument(request));
  }

  void invalidatePending() {
    _invalidatePendingAsyncDocument();
  }

  /// Immediately drops the rendered document (without re-resolving) so a stale
  /// scope's content stops painting on the very next frame. Used when a scope
  /// change's recompile is deferred: merely arming a pending clear would let the
  /// old document paint for one frame under the new scope before the deferred
  /// refresh lands (#541). The deferred refresh then compiles the new content.
  void clearDocument() {
    // Always cancel any in-flight/queued async resolve first, so a stale compile
    // started under the previous scope can't land after the clear — even when
    // there is no rendered document to drop yet.
    _invalidatePendingAsyncDocument();
    if (_compiledDocument == null) {
      return;
    }
    _setState(_compiledPreparedContent, null);
  }

  void dispose() {
    _disposed = true;
    _queuedRequest = null;
    _documentGeneration += 1;
  }

  void _invalidatePendingAsyncDocument() {
    _queuedRequest = null;
    _documentGeneration += 1;
  }

  void _queueLatestRequest(_MarkdownResolveRequest request) {
    if (_queuedRequest == request) {
      return;
    }
    _queuedRequest = request;
    _documentGeneration += 1;
  }

  Future<void> _refreshCompiledDocument(_MarkdownResolveRequest request) async {
    if (_documentInFlight) {
      _queueLatestRequest(request);
      return;
    }

    _documentInFlight = true;
    final generation = ++_documentGeneration;
    try {
      final document = switch (request.mode) {
        _MarkdownResolveMode.full => await _readCompiler().compilePrepared(
          request.preparedContent,
        ),
        _MarkdownResolveMode.streamingIncremental =>
          await _compileStreamingPreparedIncrementally(request.preparedContent),
      };
      if (_disposed ||
          generation != _documentGeneration ||
          !_matchesRequestedRequest(request)) {
        return;
      }
      _setState(request.preparedContent, document);
    } finally {
      _documentInFlight = false;
      final queuedRequest = _queuedRequest;
      _queuedRequest = null;
      if (queuedRequest != null &&
          (queuedRequest != request || generation != _documentGeneration) &&
          !_disposed) {
        unawaited(_refreshCompiledDocument(queuedRequest));
      }
    }
  }

  Future<CompiledMarkdownDocument> _compileStreamingPreparedIncrementally(
    String preparedContent,
  ) async {
    final split = _splitStreamingPreparedContent(preparedContent);
    final compiler = _readCompiler();
    if (!split.canIncrementallyCompile) {
      _streamingIncrementalState = null;
      return compiler.compilePrepared(preparedContent);
    }

    final previousState =
        _canReuseStreamingIncrementalState(preparedContent, split)
        ? _streamingIncrementalState
        : null;

    try {
      return previousState == null
          ? await _compileStreamingPreparedFromScratch(
              preparedContent,
              split,
              compiler,
            )
          : await _compileStreamingPreparedFromState(
              preparedContent,
              split,
              previousState,
              compiler,
            );
    } on ArgumentError {
      _streamingIncrementalState = null;
      return compiler.compilePrepared(preparedContent);
    }
  }

  bool _canReuseStreamingIncrementalState(
    String preparedContent,
    _StreamingPreparedSplit split,
  ) {
    final state = _streamingIncrementalState;
    if (state == null) {
      return false;
    }
    return preparedContent.startsWith(state.preparedContent) &&
        split.frozenPrefix.startsWith(state.frozenPreparedContent);
  }

  Future<CompiledMarkdownDocument> _compileStreamingPreparedFromScratch(
    String preparedContent,
    _StreamingPreparedSplit split,
    MarkdownCompileService compiler,
  ) async {
    final frozenPrefix = split.frozenPrefix;
    final mutableTail = split.mutableTail;

    CompiledMarkdownDocument frozenDocument =
        const CompiledMarkdownDocument.empty();
    CompiledMarkdownDocument? tailDocument;

    if (frozenPrefix.isNotEmpty && mutableTail.isNotEmpty) {
      final documents = await compiler.compilePreparedBatch(<String>[
        frozenPrefix,
        mutableTail,
      ]);
      frozenDocument = documents[0];
      tailDocument = documents[1].rebaseRootIds(
        rootNodeOffset: frozenDocument.rootNodeCount,
      );
    } else if (frozenPrefix.isNotEmpty) {
      frozenDocument = await compiler.compilePrepared(frozenPrefix);
    } else if (mutableTail.isNotEmpty) {
      tailDocument = await compiler.compilePrepared(mutableTail);
    }

    final composedDocument = CompiledMarkdownDocument.compose(
      normalizedContent: preparedContent,
      segments: <CompiledMarkdownDocument>[
        if (!frozenDocument.isEmpty) frozenDocument,
        if (tailDocument != null && !tailDocument.isEmpty) tailDocument,
      ],
    );
    _streamingIncrementalState = _StreamingIncrementalState(
      preparedContent: preparedContent,
      frozenPreparedContent: frozenPrefix,
      frozenDocument: frozenDocument,
    );
    return composedDocument;
  }

  Future<CompiledMarkdownDocument> _compileStreamingPreparedFromState(
    String preparedContent,
    _StreamingPreparedSplit split,
    _StreamingIncrementalState previousState,
    MarkdownCompileService compiler,
  ) async {
    final frozenPrefix = split.frozenPrefix;
    final mutableTail = split.mutableTail;
    final newFrozenDelta = frozenPrefix.substring(
      previousState.frozenPreparedContent.length,
    );

    var updatedFrozenDocument = previousState.frozenDocument;
    if (newFrozenDelta.isNotEmpty) {
      if (mutableTail.isEmpty) {
        final newFrozenDocument = await compiler.compilePrepared(
          newFrozenDelta,
        );
        updatedFrozenDocument = CompiledMarkdownDocument.compose(
          normalizedContent: frozenPrefix,
          segments: <CompiledMarkdownDocument>[
            if (!previousState.frozenDocument.isEmpty)
              previousState.frozenDocument,
            newFrozenDocument.rebaseRootIds(
              rootNodeOffset: previousState.frozenDocument.rootNodeCount,
            ),
          ],
        );
      } else {
        final documents = await compiler.compilePreparedBatch(<String>[
          newFrozenDelta,
          mutableTail,
        ]);
        final rebasedFrozenDelta = documents[0].rebaseRootIds(
          rootNodeOffset: previousState.frozenDocument.rootNodeCount,
        );
        updatedFrozenDocument = CompiledMarkdownDocument.compose(
          normalizedContent: frozenPrefix,
          segments: <CompiledMarkdownDocument>[
            if (!previousState.frozenDocument.isEmpty)
              previousState.frozenDocument,
            rebasedFrozenDelta,
          ],
        );
        final tailDocument = documents[1].rebaseRootIds(
          rootNodeOffset: updatedFrozenDocument.rootNodeCount,
        );
        final composedDocument = CompiledMarkdownDocument.compose(
          normalizedContent: preparedContent,
          segments: <CompiledMarkdownDocument>[
            if (!updatedFrozenDocument.isEmpty) updatedFrozenDocument,
            if (!tailDocument.isEmpty) tailDocument,
          ],
        );
        _streamingIncrementalState = _StreamingIncrementalState(
          preparedContent: preparedContent,
          frozenPreparedContent: frozenPrefix,
          frozenDocument: updatedFrozenDocument,
        );
        return composedDocument;
      }
    }

    if (mutableTail.isEmpty) {
      final composedDocument = CompiledMarkdownDocument.compose(
        normalizedContent: preparedContent,
        segments: <CompiledMarkdownDocument>[
          if (!updatedFrozenDocument.isEmpty) updatedFrozenDocument,
        ],
      );
      _streamingIncrementalState = _StreamingIncrementalState(
        preparedContent: preparedContent,
        frozenPreparedContent: frozenPrefix,
        frozenDocument: updatedFrozenDocument,
      );
      return composedDocument;
    }

    final tailDocument = await compiler
        .compilePrepared(mutableTail)
        .then(
          (document) => document.rebaseRootIds(
            rootNodeOffset: updatedFrozenDocument.rootNodeCount,
          ),
        );
    final composedDocument = CompiledMarkdownDocument.compose(
      normalizedContent: preparedContent,
      segments: <CompiledMarkdownDocument>[
        if (!updatedFrozenDocument.isEmpty) updatedFrozenDocument,
        if (!tailDocument.isEmpty) tailDocument,
      ],
    );
    _streamingIncrementalState = _StreamingIncrementalState(
      preparedContent: preparedContent,
      frozenPreparedContent: frozenPrefix,
      frozenDocument: updatedFrozenDocument,
    );
    return composedDocument;
  }

  bool _matchesRequestedRequest(_MarkdownResolveRequest request) {
    return _requestedPreparedContent == request.preparedContent &&
        _requestedResolveMode == request.mode;
  }

  void _setState(
    String compiledPreparedContent,
    CompiledMarkdownDocument? document,
  ) {
    final changed =
        _compiledPreparedContent != compiledPreparedContent ||
        _compiledDocument != document;
    if (!changed) {
      return;
    }

    _compiledPreparedContent = compiledPreparedContent;
    _compiledDocument = document;
    _onStateChanged(compiledPreparedContent, document);
  }
}

@visibleForTesting
Map<String, Object?> debugSplitStreamingPreparedContentForTesting(
  String preparedContent,
) {
  final split = _splitStreamingPreparedContent(preparedContent);
  return <String, Object?>{
    'frozenPrefix': split.frozenPrefix,
    'mutableTail': split.mutableTail,
    'canIncrementallyCompile': split.canIncrementallyCompile,
    'fallbackReason': split.fallbackReason,
  };
}

_StreamingPreparedSplit _splitStreamingPreparedContent(String preparedContent) {
  if (preparedContent.isEmpty) {
    return const _StreamingPreparedSplit(frozenPrefix: '', mutableTail: '');
  }

  // Reference definitions can retroactively change earlier blocks, so keep
  // the full document mutable while they are present.
  if (_streamingReferenceDefinitionPattern.hasMatch(preparedContent)) {
    return _StreamingPreparedSplit(
      frozenPrefix: '',
      mutableTail: preparedContent,
      fallbackReason: 'referenceDefinitions',
    );
  }

  final lines = _splitStreamingPreparedLines(preparedContent);
  var index = 0;
  var safeBoundary = 0;

  while (index < lines.length) {
    if (lines[index].isBlank) {
      index += 1;
      continue;
    }

    final result = _scanStreamingPreparedBlock(
      lines,
      index,
      preparedContent.length,
    );
    if (result == null) {
      break;
    }

    safeBoundary = result.safeBoundary;
    index = result.nextIndex;
  }

  return _StreamingPreparedSplit(
    frozenPrefix: preparedContent.substring(0, safeBoundary),
    mutableTail: preparedContent.substring(safeBoundary),
  );
}

List<_StreamingPreparedLine> _splitStreamingPreparedLines(String content) {
  if (content.isEmpty) {
    return const <_StreamingPreparedLine>[];
  }

  final lines = <_StreamingPreparedLine>[];
  var start = 0;
  while (start < content.length) {
    final newlineIndex = content.indexOf('\n', start);
    if (newlineIndex == -1) {
      lines.add(
        _StreamingPreparedLine(
          text: content.substring(start),
          start: start,
          end: content.length,
          endsWithNewline: false,
        ),
      );
      break;
    }

    lines.add(
      _StreamingPreparedLine(
        text: content.substring(start, newlineIndex),
        start: start,
        end: newlineIndex + 1,
        endsWithNewline: true,
      ),
    );
    start = newlineIndex + 1;
  }
  return lines;
}

_StreamingBlockScanResult? _scanStreamingPreparedBlock(
  List<_StreamingPreparedLine> lines,
  int index,
  int contentLength,
) {
  final line = lines[index];
  final starterCandidate = _streamingBlockStarterCandidate(line.text);

  final fenceMatch = starterCandidate == null
      ? null
      : _streamingFenceStartPattern.firstMatch(starterCandidate);
  if (fenceMatch != null) {
    final fence = fenceMatch.group(1)!;
    final closingPattern = RegExp(
      '^\\s*${RegExp.escape(fence[0])}{${fence.length},}\\s*\$',
    );
    for (var lineIndex = index + 1; lineIndex < lines.length; lineIndex += 1) {
      final closingCandidate = _streamingBlockStarterCandidate(
        lines[lineIndex].text,
      );
      if (closingCandidate == null ||
          !closingPattern.hasMatch(closingCandidate)) {
        continue;
      }
      final nextIndex = _skipBlankStreamingLines(lines, lineIndex + 1);
      return _StreamingBlockScanResult(
        safeBoundary: _safeBoundaryOffset(lines, nextIndex, contentLength),
        nextIndex: nextIndex,
      );
    }
    return null;
  }

  if (_startsStreamingDetailsBlock(line.text)) {
    var depth = 0;
    for (var lineIndex = index; lineIndex < lines.length; lineIndex += 1) {
      final currentLine = lines[lineIndex];
      final currentCandidate = _streamingBlockStarterCandidate(
        currentLine.text,
      );
      if (currentCandidate != null) {
        depth += _streamingDetailsOpenPattern
            .allMatches(currentCandidate)
            .length;
        depth -= _streamingDetailsClosePattern
            .allMatches(currentCandidate)
            .length;
      }
      if (depth > 0) {
        continue;
      }
      if (lineIndex == lines.length - 1 && !currentLine.endsWithNewline) {
        return null;
      }
      final nextIndex = _skipBlankStreamingLines(lines, lineIndex + 1);
      return _StreamingBlockScanResult(
        safeBoundary: _safeBoundaryOffset(lines, nextIndex, contentLength),
        nextIndex: nextIndex,
      );
    }
    return null;
  }

  if (starterCandidate != null &&
      (_streamingHeadingPattern.hasMatch(starterCandidate) ||
          _streamingHorizontalRulePattern.hasMatch(starterCandidate))) {
    if (!line.endsWithNewline && index == lines.length - 1) {
      return null;
    }
    final nextIndex = _skipBlankStreamingLines(lines, index + 1);
    return _StreamingBlockScanResult(
      safeBoundary: _safeBoundaryOffset(lines, nextIndex, contentLength),
      nextIndex: nextIndex,
    );
  }

  if (_looksLikeStreamingTable(lines, index)) {
    var lineIndex = index + 2;
    while (lineIndex < lines.length &&
        _looksLikeStreamingTableRow(lines[lineIndex].text)) {
      lineIndex += 1;
    }
    if (lineIndex == lines.length) {
      return null;
    }
    final nextIndex = _skipBlankStreamingLines(lines, lineIndex);
    return _StreamingBlockScanResult(
      safeBoundary: _safeBoundaryOffset(lines, nextIndex, contentLength),
      nextIndex: nextIndex,
    );
  }

  if (starterCandidate != null &&
      _looksLikeStreamingListItem(starterCandidate)) {
    var lineIndex = index + 1;
    while (true) {
      while (lineIndex < lines.length && !lines[lineIndex].isBlank) {
        lineIndex += 1;
      }
      if (lineIndex == lines.length) {
        return null;
      }
      final nextIndex = _skipBlankStreamingLines(lines, lineIndex);
      if (nextIndex < lines.length) {
        final nextCandidate = _streamingBlockStarterCandidate(
          lines[nextIndex].text,
        );
        if (_looksLikeStreamingIndentedContinuation(lines[nextIndex].text) ||
            (nextCandidate != null &&
                _looksLikeStreamingListItem(nextCandidate))) {
          lineIndex = nextIndex + 1;
          continue;
        }
      }
      return _StreamingBlockScanResult(
        safeBoundary: _safeBoundaryOffset(lines, nextIndex, contentLength),
        nextIndex: nextIndex,
      );
    }
  }

  if (starterCandidate != null &&
      _streamingBlockquotePattern.hasMatch(starterCandidate)) {
    var lineIndex = index + 1;
    while (lineIndex < lines.length) {
      final nextLine = lines[lineIndex];
      final nextCandidate = _streamingBlockStarterCandidate(nextLine.text);
      if (nextCandidate != null &&
          _streamingBlockquotePattern.hasMatch(nextCandidate)) {
        lineIndex += 1;
        continue;
      }
      if (nextLine.isBlank ||
          _startsStandaloneStreamingBlock(lines, lineIndex)) {
        break;
      }
      // CommonMark/GFM allow paragraph continuations inside blockquotes
      // without a leading `>` marker until a new block boundary appears.
      lineIndex += 1;
    }
    if (lineIndex == lines.length) {
      return null;
    }
    final nextIndex = _skipBlankStreamingLines(lines, lineIndex);
    return _StreamingBlockScanResult(
      safeBoundary: _safeBoundaryOffset(lines, nextIndex, contentLength),
      nextIndex: nextIndex,
    );
  }

  var lineIndex = index;
  while (true) {
    final nextIndex = lineIndex + 1;
    if (nextIndex >= lines.length) {
      return null;
    }
    if (_looksLikeStreamingSetextUnderline(lines[nextIndex].text) &&
        lines[lineIndex].text.trim().isNotEmpty) {
      lineIndex = nextIndex;
      continue;
    }
    if (lines[nextIndex].isBlank) {
      final blockEndIndex = _skipBlankStreamingLines(lines, nextIndex);
      return _StreamingBlockScanResult(
        safeBoundary: _safeBoundaryOffset(lines, blockEndIndex, contentLength),
        nextIndex: blockEndIndex,
      );
    }
    if (_startsStandaloneStreamingBlock(lines, nextIndex)) {
      return _StreamingBlockScanResult(
        safeBoundary: lines[nextIndex].start,
        nextIndex: nextIndex,
      );
    }
    lineIndex = nextIndex;
  }
}

bool _startsStandaloneStreamingBlock(
  List<_StreamingPreparedLine> lines,
  int index,
) {
  final starterCandidate = _streamingBlockStarterCandidate(lines[index].text);
  if (starterCandidate == null) {
    return false;
  }
  return _streamingFenceStartPattern.hasMatch(starterCandidate) ||
      _streamingHeadingPattern.hasMatch(starterCandidate) ||
      _streamingHorizontalRulePattern.hasMatch(starterCandidate) ||
      _startsStandaloneStreamingListItem(starterCandidate) ||
      _streamingBlockquotePattern.hasMatch(starterCandidate) ||
      _streamingDetailsOpenPattern.hasMatch(starterCandidate) ||
      _looksLikeStreamingTable(lines, index);
}

bool _looksLikeStreamingTable(List<_StreamingPreparedLine> lines, int index) {
  if (index + 1 >= lines.length) {
    return false;
  }
  final dividerCandidate = _streamingBlockStarterCandidate(
    lines[index + 1].text,
  );
  return _looksLikeStreamingTableRow(lines[index].text) &&
      dividerCandidate != null &&
      _streamingTableDividerPattern.hasMatch(dividerCandidate);
}

bool _looksLikeStreamingTableRow(String line) {
  final starterCandidate = _streamingBlockStarterCandidate(line);
  if (starterCandidate == null) {
    return false;
  }
  final trimmed = starterCandidate.trim();
  if (trimmed.isEmpty || !_hasUnescapedPipe(trimmed)) {
    return false;
  }
  return trimmed.startsWith('|') || trimmed.endsWith('|');
}

bool _hasUnescapedPipe(String text) {
  for (var index = 0; index < text.length; index += 1) {
    if (text[index] != '|') {
      continue;
    }
    if (index == 0 || text[index - 1] != r'\') {
      return true;
    }
  }
  return false;
}

bool _looksLikeStreamingListItem(String line) {
  return _streamingUnorderedListPattern.hasMatch(line) ||
      _streamingOrderedListPattern.hasMatch(line);
}

bool _startsStandaloneStreamingListItem(String line) {
  if (_streamingUnorderedListPattern.hasMatch(line)) {
    return true;
  }
  final match = RegExp(r'^(\d+)[.)]\s+').firstMatch(line);
  if (match == null) {
    return false;
  }
  return match.group(1) == '1';
}

bool _looksLikeStreamingIndentedContinuation(String line) {
  if (line.startsWith('\t')) {
    return true;
  }
  var leadingSpaces = 0;
  while (leadingSpaces < line.length &&
      line.codeUnitAt(leadingSpaces) == 0x20) {
    leadingSpaces += 1;
  }
  return leadingSpaces >= 2;
}

bool _looksLikeStreamingSetextUnderline(String line) {
  final starterCandidate = _streamingBlockStarterCandidate(line);
  return starterCandidate != null &&
      _streamingSetextUnderlinePattern.hasMatch(starterCandidate);
}

bool _startsStreamingDetailsBlock(String line) {
  final starterCandidate = _streamingBlockStarterCandidate(line);
  return starterCandidate != null &&
      _streamingDetailsOpenPattern.hasMatch(starterCandidate);
}

String? _streamingBlockStarterCandidate(String line) {
  var index = 0;
  var indentColumns = 0;
  while (index < line.length) {
    final codeUnit = line.codeUnitAt(index);
    if (codeUnit == 0x20) {
      indentColumns += 1;
    } else if (codeUnit == 0x09) {
      indentColumns += 4 - (indentColumns % 4);
    } else {
      break;
    }
    if (indentColumns > 3) {
      return null;
    }
    index += 1;
  }
  return line.substring(index);
}

int _skipBlankStreamingLines(List<_StreamingPreparedLine> lines, int index) {
  var nextIndex = index;
  while (nextIndex < lines.length && lines[nextIndex].isBlank) {
    nextIndex += 1;
  }
  return nextIndex;
}

int _safeBoundaryOffset(
  List<_StreamingPreparedLine> lines,
  int nextIndex,
  int contentLength,
) {
  if (nextIndex >= lines.length) {
    return contentLength;
  }
  return lines[nextIndex].start;
}

@immutable
class _MarkdownResolveRequest {
  const _MarkdownResolveRequest({
    required this.preparedContent,
    required this.mode,
  });

  final String preparedContent;
  final _MarkdownResolveMode mode;

  @override
  bool operator ==(Object other) {
    return other is _MarkdownResolveRequest &&
        other.preparedContent == preparedContent &&
        other.mode == mode;
  }

  @override
  int get hashCode => Object.hash(preparedContent, mode);
}

@immutable
class _StreamingIncrementalState {
  const _StreamingIncrementalState({
    required this.preparedContent,
    required this.frozenPreparedContent,
    required this.frozenDocument,
  });

  final String preparedContent;
  final String frozenPreparedContent;
  final CompiledMarkdownDocument frozenDocument;
}

@immutable
class _StreamingPreparedSplit {
  const _StreamingPreparedSplit({
    required this.frozenPrefix,
    required this.mutableTail,
    this.fallbackReason,
  });

  final String frozenPrefix;
  final String mutableTail;
  final String? fallbackReason;

  bool get canIncrementallyCompile => fallbackReason == null;
}

@immutable
class _StreamingPreparedLine {
  const _StreamingPreparedLine({
    required this.text,
    required this.start,
    required this.end,
    required this.endsWithNewline,
  });

  final String text;
  final int start;
  final int end;
  final bool endsWithNewline;

  bool get isBlank => text.trim().isEmpty;
}

@immutable
class _StreamingBlockScanResult {
  const _StreamingBlockScanResult({
    required this.safeBoundary,
    required this.nextIndex,
  });

  final int safeBoundary;
  final int nextIndex;
}
