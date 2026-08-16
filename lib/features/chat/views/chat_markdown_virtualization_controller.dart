import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/models/chat_message.dart';
import '../../../core/utils/debug_logger.dart';
import '../../../shared/widgets/markdown/compiled_markdown_document.dart';
import '../../../shared/widgets/markdown/markdown_compile_service.dart';
import '../../../shared/widgets/markdown/markdown_display_part.dart';
import '../../../shared/widgets/markdown/markdown_preprocessor.dart';

typedef _MarkdownSignature = ({
  int versionIndex,
  String? versionId,
  String content,
});

class _MarkdownEntry {
  const _MarkdownEntry({required this.signature, required this.parts});

  final _MarkdownSignature signature;
  final List<MarkdownDisplayPart> parts;
}

class ChatMarkdownVirtualizationView {
  const ChatMarkdownVirtualizationView({
    required this.partsByMessageId,
    required this.pendingMessageIds,
  });

  final Map<String, List<MarkdownDisplayPart>> partsByMessageId;
  final Set<String> pendingMessageIds;
}

/// Owns the cache and compilation lifecycle for settled assistant block rows.
class ChatMarkdownVirtualizationController {
  ChatMarkdownVirtualizationController({
    required MarkdownCompileService compiler,
    required VoidCallback onChanged,
  }) : _compiler = compiler,
       _onChanged = onChanged;

  static const int blockThreshold = 24;
  static const int characterThreshold = 12000;

  final MarkdownCompileService _compiler;
  final VoidCallback _onChanged;
  final Map<String, _MarkdownEntry> _entries = {};
  final Map<String, _MarkdownEntry> _streamingCandidates = {};
  final Map<String, _MarkdownSignature> _compileSignatures = {};
  final Map<String, _MarkdownSignature> _failedSignatures = {};
  final Set<String> _runningCompilations = {};
  final Map<String, int> _versionIndexByMessageId = {};
  int _generation = 0;
  bool _disposed = false;

  int activeVersionIndex(ChatMessage message) {
    final index = _versionIndexByMessageId[message.id] ?? -1;
    return index >= 0 && index < message.versions.length ? index : -1;
  }

  int displayedVersionIndex(ChatMessage message) {
    final signature = _entries[message.id]?.signature;
    return signature != null && _versionExists(message, signature)
        ? signature.versionIndex
        : activeVersionIndex(message);
  }

  void selectVersion(String messageId, int versionIndex) {
    _versionIndexByMessageId[messageId] = versionIndex;
  }

  bool isPending(String messageId, int versionIndex, String content) =>
      _compileSignatures[messageId]?.versionIndex == versionIndex &&
      _compileSignatures[messageId]?.content == content;

  _MarkdownSignature _signature(
    ChatMessage message,
    int versionIndex,
    String content,
  ) => (
    versionIndex: versionIndex,
    versionId: versionIndex < 0 ? null : message.versions[versionIndex].id,
    content: content,
  );

  bool _versionExists(ChatMessage message, _MarkdownSignature signature) =>
      signature.versionIndex < 0 ||
      (signature.versionIndex < message.versions.length &&
          message.versions[signature.versionIndex].id == signature.versionId);

  String preparedContent(ChatMessage message, int versionIndex) {
    final content = versionIndex < 0
        ? message.content
        : message.versions[versionIndex].content;
    return ConduitMarkdownPreprocessor.prepareAssistantContent(content);
  }

  ChatMarkdownVirtualizationView reconcile(
    List<ChatMessage> messages, {
    required bool customResponseBuilderActive,
  }) {
    final loadedIds = <String>{};
    final duplicateIds = <String>{};
    for (final message in messages) {
      if (!loadedIds.add(message.id)) duplicateIds.add(message.id);
    }
    _entries.removeWhere((id, _) => !loadedIds.contains(id));
    _streamingCandidates.removeWhere((id, _) => !loadedIds.contains(id));
    _compileSignatures.removeWhere((id, _) => !loadedIds.contains(id));
    _failedSignatures.removeWhere((id, _) => !loadedIds.contains(id));
    _versionIndexByMessageId.removeWhere((id, _) => !loadedIds.contains(id));
    for (final id in duplicateIds) {
      _entries.remove(id);
      _streamingCandidates.remove(id);
      _compileSignatures.remove(id);
      _failedSignatures.remove(id);
      _versionIndexByMessageId.remove(id);
    }
    if (customResponseBuilderActive) {
      _compileSignatures.clear();
      return const ChatMarkdownVirtualizationView(
        partsByMessageId: {},
        pendingMessageIds: {},
      );
    }

    final partsByMessageId = <String, List<MarkdownDisplayPart>>{};
    for (final message in messages) {
      if (duplicateIds.contains(message.id)) continue;
      if (message.role != 'assistant' || message.error != null) {
        _entries.remove(message.id);
        _streamingCandidates.remove(message.id);
        _compileSignatures.remove(message.id);
        _failedSignatures.remove(message.id);
        continue;
      }
      if (message.isStreaming) {
        _entries.remove(message.id);
        _compileSignatures.remove(message.id);
        continue;
      }

      final versionIndex = activeVersionIndex(message);
      final signature = _signature(
        message,
        versionIndex,
        preparedContent(message, versionIndex),
      );
      final candidate = _streamingCandidates.remove(message.id);
      if (candidate?.signature.versionIndex == versionIndex) {
        _entries[message.id] = candidate!;
      }

      final entry = _entries[message.id];
      if (entry != null && _versionExists(message, entry.signature)) {
        partsByMessageId[message.id] = entry.parts;
      }
      final needsCompile =
          _failedSignatures[message.id] != signature &&
          ((entry == null && signature.content.length > characterThreshold) ||
              (entry != null && entry.signature != signature));
      if (needsCompile) {
        _compileSignatures[message.id] = signature;
      } else if (_compileSignatures[message.id] != signature) {
        _compileSignatures.remove(message.id);
      }
    }

    return ChatMarkdownVirtualizationView(
      partsByMessageId: Map.unmodifiable(partsByMessageId),
      pendingMessageIds: Set.unmodifiable(_compileSignatures.keys),
    );
  }

  void startPendingCompilations() {
    for (final entry in _compileSignatures.entries.toList(growable: false)) {
      if (_runningCompilations.add(entry.key)) {
        unawaited(_compile(entry.key, entry.value));
      }
    }
  }

  Future<void> _compile(String messageId, _MarkdownSignature signature) async {
    final generation = _generation;
    try {
      final prepared = await _compiler.prepareContent(
        signature.content,
        streaming: false,
      );
      final document = await _compiler.compilePrepared(prepared);
      if (!_accepts(messageId, signature, generation)) return;
      final parts = buildMarkdownDisplayParts(document, isStreaming: false);
      if (_eligible(signature.content, parts) && parts.isNotEmpty) {
        _entries[messageId] = _MarkdownEntry(
          signature: signature,
          parts: parts,
        );
        _failedSignatures.remove(messageId);
      } else {
        _entries.remove(messageId);
        _failedSignatures[messageId] = signature;
      }
    } catch (error, stackTrace) {
      if (_accepts(messageId, signature, generation)) {
        _failedSignatures[messageId] = signature;
        if (_entries[messageId]?.signature != signature) {
          _entries.remove(messageId);
        }
      }
      DebugLogger.error(
        'markdown-virtualization-compile-failed',
        scope: 'chat/layout',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      _runningCompilations.remove(messageId);
      if (_compileSignatures[messageId] == signature) {
        _compileSignatures.remove(messageId);
      }
      if (!_disposed && generation == _generation) _onChanged();
    }
  }

  bool _accepts(
    String messageId,
    _MarkdownSignature signature,
    int generation,
  ) =>
      !_disposed &&
      generation == _generation &&
      _compileSignatures[messageId] == signature;

  void cacheStreamingDocument({
    required ChatMessage message,
    required int versionIndex,
    required String content,
    required CompiledMarkdownDocument document,
  }) {
    if (_disposed || !message.isStreaming || message.error != null) return;
    final parts = buildMarkdownDisplayParts(document, isStreaming: false);
    if (parts.isNotEmpty && _eligible(content, parts)) {
      _failedSignatures.remove(message.id);
      _streamingCandidates[message.id] = _MarkdownEntry(
        signature: _signature(message, versionIndex, content),
        parts: parts,
      );
    } else {
      _streamingCandidates.remove(message.id);
    }
  }

  void acceptSettledDocument({
    required ChatMessage message,
    required int versionIndex,
    required String content,
    required CompiledMarkdownDocument document,
  }) {
    if (_disposed || message.isStreaming || message.error != null) return;
    final parts = buildMarkdownDisplayParts(document, isStreaming: false);
    if (parts.isEmpty || !_eligible(content, parts)) return;
    final signature = _signature(message, versionIndex, content);
    final current = _entries[message.id];
    if (current?.signature == signature) return;
    _failedSignatures.remove(message.id);
    _entries[message.id] = _MarkdownEntry(signature: signature, parts: parts);
    _onChanged();
  }

  bool _eligible(String content, List<MarkdownDisplayPart> parts) =>
      content.length > characterThreshold || parts.length > blockThreshold;

  void clear() {
    _generation += 1;
    _entries.clear();
    _streamingCandidates.clear();
    _compileSignatures.clear();
    _failedSignatures.clear();
    _runningCompilations.clear();
    _versionIndexByMessageId.clear();
  }

  void dispose() {
    _disposed = true;
    clear();
  }
}
