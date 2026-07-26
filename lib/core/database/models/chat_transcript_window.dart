import 'package:flutter/foundation.dart';

import '../app_database.dart';

const int kChatTranscriptPageSize = 50;
const int kChatTranscriptMaxTraversalRows = 10000;

/// Returns the bounded presentation suffix without changing canonical order.
List<T> latestTranscriptWindow<T>(List<T> complete, int loadedCount) {
  if (complete.isEmpty || loadedCount <= 0) return const [];
  final count = loadedCount.clamp(1, complete.length).toInt();
  return List<T>.unmodifiable(complete.sublist(complete.length - count));
}

@immutable
final class MessageWindowCursor {
  const MessageWindowCursor(this.messageId);

  final String messageId;
}

/// A bounded slice of the active Open WebUI message branch.
///
/// [primaryRows] are the rows that consume page capacity. [rows] additionally
/// contains same-role siblings needed to reconstruct response versions without
/// loading every abandoned branch into memory.
@immutable
final class MessageRowWindow {
  const MessageRowWindow({
    required this.primaryRows,
    required this.rows,
    required this.hasOlder,
    required this.olderCursor,
    this.semanticBoundaryTruncated = false,
  });

  final List<MessageRow> primaryRows;
  final List<MessageRow> rows;
  final bool hasOlder;
  final MessageWindowCursor? olderCursor;
  final bool semanticBoundaryTruncated;
}

@immutable
final class ChatTranscriptPagingState {
  const ChatTranscriptPagingState({
    this.hasOlder = false,
    this.isLoadingOlder = false,
    this.loadedCount = kChatTranscriptPageSize,
    this.oldestMessageId,
    this.generation = 0,
    this.error,
  });

  final bool hasOlder;
  final bool isLoadingOlder;
  final int loadedCount;
  final String? oldestMessageId;
  final int generation;
  final Object? error;

  ChatTranscriptPagingState copyWith({
    bool? hasOlder,
    bool? isLoadingOlder,
    int? loadedCount,
    String? oldestMessageId,
    bool clearOldestMessageId = false,
    int? generation,
    Object? error,
    bool clearError = false,
  }) {
    return ChatTranscriptPagingState(
      hasOlder: hasOlder ?? this.hasOlder,
      isLoadingOlder: isLoadingOlder ?? this.isLoadingOlder,
      loadedCount: loadedCount ?? this.loadedCount,
      oldestMessageId: clearOldestMessageId
          ? null
          : oldestMessageId ?? this.oldestMessageId,
      generation: generation ?? this.generation,
      error: clearError ? null : error ?? this.error,
    );
  }
}

@immutable
final class ChatScrollAnchor {
  const ChatScrollAnchor({
    required this.messageId,
    required this.itemLeadingEdge,
    required this.loadedCount,
  });

  final String messageId;
  final double itemLeadingEdge;
  final int loadedCount;
}
