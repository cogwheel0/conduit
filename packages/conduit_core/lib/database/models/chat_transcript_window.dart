import '../app_database.dart';

import 'package:meta/meta.dart';

const int kChatTranscriptPageSize = 50;
const int kChatTranscriptMaxTraversalRows = 10000;

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

/// An in-session viewport anchor.
///
/// Anchors live only in ChatPage's bounded in-memory LRU. They are never
/// serialized to Drift, shared preferences, or secure storage, so changing
/// their coordinate representation does not require a persisted-data
/// migration and cannot reinterpret legacy item-edge fractions.
@immutable
final class ChatScrollAnchor {
  const ChatScrollAnchor({
    required this.messageId,
    required this.offsetWithinMessage,
  });

  final String messageId;

  /// Logical pixels from the viewport's top content inset to the top edge of
  /// [messageId]'s row. Negative means the row begins above that inset;
  /// positive means it begins below it.
  final double offsetWithinMessage;
}
