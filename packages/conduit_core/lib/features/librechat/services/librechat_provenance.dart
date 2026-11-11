import 'package:conduit_core/features/librechat/models/librechat_transport.dart';
import 'package:conduit_core/models/conversation.dart';

/// [conversation], loaded from a LibreChat account's own database, marked as
/// LibreChat's: the conversation's `backend` and each reply's `transport`.
///
/// These markers route Stop, regenerate and approvals, so they are written
/// only here, by code that read the chat from the LibreChat database. Stored
/// payload metadata is never trusted for them: Open WebUI parsing strips any
/// LibreChat claim, and a LibreChat record keeps its own data outside
/// metadata.
Conversation stampLibreChatProvenance(Conversation conversation) =>
    conversation.copyWith(
      metadata: <String, dynamic>{
        ...conversation.metadata,
        'backend': kLibreChatTransport,
      },
      messages: [
        for (final message in conversation.messages)
          message.role == 'assistant'
              ? message.copyWith(
                  metadata: <String, dynamic>{
                    ...?message.metadata,
                    'transport': kLibreChatTransport,
                  },
                )
              : message,
      ],
    );
