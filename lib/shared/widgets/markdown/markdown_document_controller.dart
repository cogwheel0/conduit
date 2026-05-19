import 'dart:async';

import 'compiled_markdown_document.dart';
import 'markdown_compile_service.dart';

typedef MarkdownDocumentControllerListener =
    void Function(
      String compiledPreparedContent,
      CompiledMarkdownDocument? document,
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
  String _compiledPreparedContent = '';
  CompiledMarkdownDocument? _compiledDocument;
  bool _documentInFlight = false;
  String? _queuedPreparedContent;
  int _documentGeneration = 0;
  bool _disposed = false;

  String get compiledPreparedContent => _compiledPreparedContent;

  CompiledMarkdownDocument? get compiledDocument => _compiledDocument;

  void applyDirectDocument(CompiledMarkdownDocument document) {
    _requestedPreparedContent = document.normalizedContent;
    _invalidatePendingAsyncDocument();
    _setState(document.normalizedContent, document);
  }

  void resolvePrepared(
    String preparedContent, {
    bool clearDocumentWhenAsync = false,
  }) {
    final preparedChanged = _requestedPreparedContent != preparedContent;
    _requestedPreparedContent = preparedContent;

    if (preparedContent.trim().isEmpty) {
      _invalidatePendingAsyncDocument();
      _setState('', const CompiledMarkdownDocument.empty());
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

    if (_documentInFlight) {
      _queueLatestPreparedContent(preparedContent);
      return;
    }

    unawaited(_refreshCompiledDocument(preparedContent));
  }

  void invalidatePending() {
    _invalidatePendingAsyncDocument();
  }

  void dispose() {
    _disposed = true;
    _queuedPreparedContent = null;
    _documentGeneration += 1;
  }

  void _invalidatePendingAsyncDocument() {
    _queuedPreparedContent = null;
    _documentGeneration += 1;
  }

  void _queueLatestPreparedContent(String preparedContent) {
    if (_queuedPreparedContent == preparedContent) {
      return;
    }
    _queuedPreparedContent = preparedContent;
    _documentGeneration += 1;
  }

  Future<void> _refreshCompiledDocument(String preparedContent) async {
    if (_documentInFlight) {
      _queueLatestPreparedContent(preparedContent);
      return;
    }

    _documentInFlight = true;
    final generation = ++_documentGeneration;
    try {
      final compiler = _readCompiler();
      final document = await compiler.compilePrepared(preparedContent);
      if (_disposed ||
          generation != _documentGeneration ||
          _requestedPreparedContent != preparedContent) {
        return;
      }
      _setState(preparedContent, document);
    } finally {
      _documentInFlight = false;
      final queuedPreparedContent = _queuedPreparedContent;
      _queuedPreparedContent = null;
      if (queuedPreparedContent != null &&
          (queuedPreparedContent != preparedContent ||
              generation != _documentGeneration) &&
          !_disposed) {
        unawaited(_refreshCompiledDocument(queuedPreparedContent));
      }
    }
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
