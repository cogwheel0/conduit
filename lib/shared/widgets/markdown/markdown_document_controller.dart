import 'dart:async';


import 'package:conduit_markdown/conduit_markdown.dart';
import 'compiled_markdown_document.dart';
import 'markdown_compile_service.dart';
import 'package:meta/meta.dart';
import 'streaming_markdown_preparation.dart';

typedef MarkdownDocumentControllerListener = void Function(
  CompiledMarkdownDocument? document,
);

enum _MarkdownResolveMode { full, streamingIncremental, streamingPatch }

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
  String? _requestedStreamingSessionId;
  int _requestedStreamingRevision = 0;
  String? _compiledStreamingSessionId;
  int _compiledStreamingRevision = 0;
  CompiledMarkdownDocument? _compiledDocument;
  bool _documentInFlight = false;
  _MarkdownResolveRequest? _queuedRequest;
  int _documentGeneration = 0;
  bool _disposed = false;
  _StreamingIncrementalState? _streamingIncrementalState;

  String get compiledPreparedContent => _compiledPreparedContent;
  String? get compiledStreamingSessionId => _compiledStreamingSessionId;
  int get compiledStreamingRevision => _compiledStreamingRevision;

  CompiledMarkdownDocument? get compiledDocument => _compiledDocument;

  void applyDirectDocument(CompiledMarkdownDocument document) {
    _requestedPreparedContent = document.normalizedContent;
    _requestedResolveMode = _MarkdownResolveMode.full;
    _requestedStreamingSessionId = null;
    _requestedStreamingRevision = 0;
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
    _requestedStreamingSessionId = null;
    _requestedStreamingRevision = 0;
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

  void resolveStreamingPreparedPatch(
    PreparedMarkdownText preparedContent,
    MarkdownPreparationPatch patch, {
    bool clearDocumentWhenAsync = false,
  }) {
    if (patch.isStale) return;
    final preparedChanged =
        _requestedResolveMode != _MarkdownResolveMode.streamingPatch ||
        _requestedStreamingSessionId != patch.sessionId ||
        _requestedStreamingRevision != patch.revision;
    _requestedPreparedContent = '';
    _requestedResolveMode = _MarkdownResolveMode.streamingPatch;
    _requestedStreamingSessionId = patch.sessionId;
    _requestedStreamingRevision = patch.revision;

    if (preparedContent.isBlank) {
      _streamingIncrementalState = null;
      _invalidatePendingAsyncDocument();
      _setStreamingState(
        sessionId: patch.sessionId,
        revision: patch.revision,
        document: const CompiledMarkdownDocument.empty(),
      );
      return;
    }

    if (!preparedChanged &&
        _compiledStreamingSessionId == patch.sessionId &&
        _compiledStreamingRevision == patch.revision &&
        _compiledDocument != null) {
      return;
    }

    final compiler = _readCompiler();
    final synchronousCandidate =
        _isWidgetTest() ||
            preparedContent.length <= markdownSynchronousCompileThreshold
        ? preparedContent.materialize()
        : null;
    if (synchronousCandidate != null &&
        compiler.shouldCompileSynchronously(
          synchronousCandidate,
          widgetTest: _isWidgetTest(),
        )) {
      _streamingIncrementalState = null;
      _invalidatePendingAsyncDocument();
      final document = compiler
          .compilePreparedSynchronously(synchronousCandidate)
          .withPreparedContent(preparedContent);
      _setStreamingState(
        sessionId: patch.sessionId,
        revision: patch.revision,
        document: document,
      );
      return;
    }

    if (clearDocumentWhenAsync && preparedChanged) {
      _setStreamingState(
        sessionId: _compiledStreamingSessionId,
        revision: _compiledStreamingRevision,
        document: null,
      );
    }

    final request = _MarkdownResolveRequest.streamingPatch(
      preparedContent: preparedContent,
      patch: patch,
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
      late final CompiledMarkdownDocument document;
      try {
        document = switch (request.mode) {
          _MarkdownResolveMode.full => await _readCompiler().compilePrepared(
            request.preparedContent,
          ),
          _MarkdownResolveMode.streamingIncremental =>
            await _compileStreamingPreparedIncrementally(
              request.preparedContent,
            ),
          _MarkdownResolveMode.streamingPatch =>
            await _compileStreamingPreparedPatch(
              request.preparedText!,
              request.patch!,
            ),
        };
      } catch (error) {
        if (request.mode != _MarkdownResolveMode.streamingPatch ||
            (error is! ArgumentError && error is! StateError)) {
          rethrow;
        }
        _streamingIncrementalState = null;
        final prepared = request.preparedText!;
        document = await _readCompiler()
            .compilePrepared(prepared.materialize(), cacheResult: false)
            .then((value) => value.withPreparedContent(prepared));
      }
      if (_disposed ||
          generation != _documentGeneration ||
          !_matchesRequestedRequest(request)) {
        return;
      }
      if (request.mode == _MarkdownResolveMode.streamingPatch) {
        _setStreamingState(
          sessionId: request.patch!.sessionId,
          revision: request.patch!.revision,
          document: document,
        );
      } else {
        _setState(request.preparedContent, document);
      }
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
    final split = splitStreamingMarkdown(preparedContent);
    final compiler = _readCompiler();
    if (!split.canIncrementallyCompile) {
      _streamingIncrementalState = null;
      return compiler.compilePrepared(preparedContent, cacheResult: false);
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
      return compiler.compilePrepared(preparedContent, cacheResult: false);
    }
  }

  Future<CompiledMarkdownDocument> _compileStreamingPreparedPatch(
    PreparedMarkdownText preparedContent,
    MarkdownPreparationPatch patch,
  ) async {
    final previousState = _streamingIncrementalState;
    final canReuse =
        previousState != null &&
        previousState.sessionId == patch.sessionId &&
        previousState.revision < patch.revision &&
        preparedContent.startsWith(previousState.frozenPreparedText);
    if (!canReuse) {
      return _compileStreamingPatchFromScratch(preparedContent, patch);
    }

    final suffix = preparedContent.substring(
      previousState.frozenPreparedLength,
    );
    final split = splitStreamingMarkdown(suffix);
    if (!split.canIncrementallyCompile) {
      _streamingIncrementalState = null;
      return _readCompiler()
          .compilePrepared(preparedContent.materialize(), cacheResult: false)
          .then((document) => document.withPreparedContent(preparedContent));
    }

    final compiler = _readCompiler();
    final newFrozenDelta = split.frozenPrefix;
    final mutableTail = split.mutableTail;
    final nextFrozenLength =
        previousState.frozenPreparedLength + newFrozenDelta.length;
    final nextFrozenText = preparedContent.slice(0, nextFrozenLength);
    var updatedFrozenDocument = previousState.frozenDocument;

    if (newFrozenDelta.isNotEmpty) {
      if (mutableTail.isEmpty) {
        final deltaDocument = await compiler.compilePrepared(
          newFrozenDelta,
          cacheResult: false,
        );
        updatedFrozenDocument = CompiledMarkdownDocument.composePrepared(
          normalizedContent: nextFrozenText,
          segments: <CompiledMarkdownDocument>[
            if (!previousState.frozenDocument.isEmpty)
              previousState.frozenDocument,
            deltaDocument.rebaseRootIds(
              rootNodeOffset: previousState.frozenDocument.rootNodeCount,
            ),
          ],
        );
      } else {
        final documents = await compiler.compilePreparedBatch(<String>[
          newFrozenDelta,
          mutableTail,
        ], cacheResults: false);
        updatedFrozenDocument = CompiledMarkdownDocument.composePrepared(
          normalizedContent: nextFrozenText,
          segments: <CompiledMarkdownDocument>[
            if (!previousState.frozenDocument.isEmpty)
              previousState.frozenDocument,
            documents[0].rebaseRootIds(
              rootNodeOffset: previousState.frozenDocument.rootNodeCount,
            ),
          ],
        );
        final tailDocument = documents[1].rebaseRootIds(
          rootNodeOffset: updatedFrozenDocument.rootNodeCount,
        );
        final composed = CompiledMarkdownDocument.composePrepared(
          normalizedContent: preparedContent,
          segments: <CompiledMarkdownDocument>[
            if (!updatedFrozenDocument.isEmpty) updatedFrozenDocument,
            if (!tailDocument.isEmpty) tailDocument,
          ],
          mutableBlockStartIndex: tailDocument.isEmpty
              ? -1
              : updatedFrozenDocument.rootBlockCount,
        );
        _streamingIncrementalState = _StreamingIncrementalState.patch(
          sessionId: patch.sessionId,
          revision: patch.revision,
          frozenPreparedText: nextFrozenText,
          frozenDocument: updatedFrozenDocument,
        );
        return composed;
      }
    }

    if (mutableTail.isEmpty) {
      final composed = CompiledMarkdownDocument.composePrepared(
        normalizedContent: preparedContent,
        segments: <CompiledMarkdownDocument>[
          if (!updatedFrozenDocument.isEmpty) updatedFrozenDocument,
        ],
      );
      _streamingIncrementalState = _StreamingIncrementalState.patch(
        sessionId: patch.sessionId,
        revision: patch.revision,
        frozenPreparedText: nextFrozenText,
        frozenDocument: updatedFrozenDocument,
      );
      return composed;
    }

    final tailDocument = await compiler
        .compilePrepared(mutableTail, cacheResult: false)
        .then(
          (document) => document.rebaseRootIds(
            rootNodeOffset: updatedFrozenDocument.rootNodeCount,
          ),
        );
    final composed = CompiledMarkdownDocument.composePrepared(
      normalizedContent: preparedContent,
      segments: <CompiledMarkdownDocument>[
        if (!updatedFrozenDocument.isEmpty) updatedFrozenDocument,
        if (!tailDocument.isEmpty) tailDocument,
      ],
      mutableBlockStartIndex: tailDocument.isEmpty
          ? -1
          : updatedFrozenDocument.rootBlockCount,
    );
    _streamingIncrementalState = _StreamingIncrementalState.patch(
      sessionId: patch.sessionId,
      revision: patch.revision,
      frozenPreparedText: nextFrozenText,
      frozenDocument: updatedFrozenDocument,
    );
    return composed;
  }

  Future<CompiledMarkdownDocument> _compileStreamingPatchFromScratch(
    PreparedMarkdownText preparedContent,
    MarkdownPreparationPatch patch,
  ) async {
    final materialized = preparedContent.materialize();
    final split = splitStreamingMarkdown(materialized);
    if (!split.canIncrementallyCompile) {
      _streamingIncrementalState = null;
      return _readCompiler()
          .compilePrepared(materialized, cacheResult: false)
          .then((document) => document.withPreparedContent(preparedContent));
    }

    final document = await _compileStreamingPreparedFromScratch(
      materialized,
      split,
      _readCompiler(),
    );
    final state = _streamingIncrementalState!;
    _streamingIncrementalState = _StreamingIncrementalState.patch(
      sessionId: patch.sessionId,
      revision: patch.revision,
      frozenPreparedText: preparedContent.slice(0, split.frozenPrefix.length),
      frozenDocument: state.frozenDocument,
    );
    return document.withPreparedContent(preparedContent);
  }

  bool _canReuseStreamingIncrementalState(
    String preparedContent,
    StreamingMarkdownSplit split,
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
    StreamingMarkdownSplit split,
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
      ], cacheResults: false);
      frozenDocument = documents[0];
      tailDocument = documents[1].rebaseRootIds(
        rootNodeOffset: frozenDocument.rootNodeCount,
      );
    } else if (frozenPrefix.isNotEmpty) {
      frozenDocument = await compiler.compilePrepared(
        frozenPrefix,
        cacheResult: false,
      );
    } else if (mutableTail.isNotEmpty) {
      tailDocument = await compiler.compilePrepared(
        mutableTail,
        cacheResult: false,
      );
    }

    final composedDocument = CompiledMarkdownDocument.compose(
      normalizedContent: preparedContent,
      segments: <CompiledMarkdownDocument>[
        if (!frozenDocument.isEmpty) frozenDocument,
        if (tailDocument != null && !tailDocument.isEmpty) tailDocument,
      ],
      mutableBlockStartIndex: tailDocument == null || tailDocument.isEmpty
          ? -1
          : frozenDocument.rootBlockCount,
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
    StreamingMarkdownSplit split,
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
          cacheResult: false,
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
        ], cacheResults: false);
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
          mutableBlockStartIndex: tailDocument.isEmpty
              ? -1
              : updatedFrozenDocument.rootBlockCount,
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
        .compilePrepared(mutableTail, cacheResult: false)
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
      mutableBlockStartIndex: tailDocument.isEmpty
          ? -1
          : updatedFrozenDocument.rootBlockCount,
    );
    _streamingIncrementalState = _StreamingIncrementalState(
      preparedContent: preparedContent,
      frozenPreparedContent: frozenPrefix,
      frozenDocument: updatedFrozenDocument,
    );
    return composedDocument;
  }

  bool _matchesRequestedRequest(_MarkdownResolveRequest request) {
    if (_requestedResolveMode != request.mode) return false;
    if (request.mode == _MarkdownResolveMode.streamingPatch) {
      return _requestedStreamingSessionId == request.patch?.sessionId &&
          _requestedStreamingRevision == request.patch?.revision;
    }
    return _requestedPreparedContent == request.preparedContent;
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
    _compiledStreamingSessionId = null;
    _compiledStreamingRevision = 0;
    _compiledDocument = document;
    _onStateChanged(document);
  }

  void _setStreamingState({
    required String? sessionId,
    required int revision,
    required CompiledMarkdownDocument? document,
  }) {
    final changed =
        _compiledStreamingSessionId != sessionId ||
        _compiledStreamingRevision != revision ||
        _compiledDocument != document;
    if (!changed) return;
    _compiledPreparedContent = '';
    _compiledStreamingSessionId = sessionId;
    _compiledStreamingRevision = revision;
    _compiledDocument = document;
    _onStateChanged(document);
  }
}

@visibleForTesting
Map<String, Object?> debugSplitStreamingPreparedContentForTesting(
  String preparedContent,
) {
  final split = splitStreamingMarkdown(preparedContent);
  return <String, Object?>{
    'frozenPrefix': split.frozenPrefix,
    'mutableTail': split.mutableTail,
    'canIncrementallyCompile': split.canIncrementallyCompile,
    'fallbackReason': split.fallbackReason,
  };
}

@immutable
class _MarkdownResolveRequest {
  const _MarkdownResolveRequest({
    required this.preparedContent,
    required this.mode,
  }) : preparedText = null,
       patch = null;

  const _MarkdownResolveRequest.streamingPatch({
    required PreparedMarkdownText preparedContent,
    required MarkdownPreparationPatch this.patch,
  }) : preparedContent = '',
       preparedText = preparedContent,
       mode = _MarkdownResolveMode.streamingPatch;

  final String preparedContent;
  final PreparedMarkdownText? preparedText;
  final MarkdownPreparationPatch? patch;
  final _MarkdownResolveMode mode;

  @override
  bool operator ==(Object other) {
    if (other is! _MarkdownResolveRequest || other.mode != mode) {
      return false;
    }
    if (mode == _MarkdownResolveMode.streamingPatch) {
      return other.patch?.sessionId == patch?.sessionId &&
          other.patch?.revision == patch?.revision;
    }
    return other.preparedContent == preparedContent;
  }

  @override
  int get hashCode => mode == _MarkdownResolveMode.streamingPatch
      ? Object.hash(mode, patch?.sessionId, patch?.revision)
      : Object.hash(mode, preparedContent);
}

@immutable
class _StreamingIncrementalState {
  _StreamingIncrementalState({
    required this.preparedContent,
    required String frozenPreparedContent,
    required this.frozenDocument,
  }) : sessionId = null,
       revision = 0,
       frozenPreparedText = PreparedMarkdownText.fromString(
         frozenPreparedContent,
       );

  const _StreamingIncrementalState.patch({
    required this.sessionId,
    required this.revision,
    required this.frozenPreparedText,
    required this.frozenDocument,
  }) : preparedContent = '';

  final String preparedContent;
  final PreparedMarkdownText frozenPreparedText;
  final CompiledMarkdownDocument frozenDocument;
  final String? sessionId;
  final int revision;

  String get frozenPreparedContent => frozenPreparedText.materialize();
  int get frozenPreparedLength => frozenPreparedText.length;
}
