part of 'chat_providers.dart';

@immutable
class _ChatMessageListStructure {
  const _ChatMessageListStructure({required this.ids, required this.signature});

  // ChatMessage is immutable and unchanged messages keep their identity
  // across chatMessagesProvider emissions, so per-message signature fragments
  // are cached by identity. This factory runs on every message-list emission;
  // without the cache it re-derived O(messages × versions) string work each
  // time even when nothing changed.
  static final Expando<String> _messageSignatureCache = Expando<String>();

  factory _ChatMessageListStructure.fromMessages(List<ChatMessage> messages) {
    final ids = List<String>.unmodifiable(
      messages.map((message) => message.id).toList(growable: false),
    );
    final buffer = StringBuffer();
    for (final message in messages) {
      buffer.write(
        _messageSignatureCache[message] ??= _buildMessageSignature(message),
      );
    }
    return _ChatMessageListStructure(ids: ids, signature: buffer.toString());
  }

  static String _buildMessageSignature(ChatMessage message) {
    final buffer = StringBuffer();
    buffer
      ..write(message.id)
      ..write('\u0000')
      ..write(message.role)
      ..write('\u0000')
      ..write(message.model ?? '')
      ..write('\u0000')
      ..write(message.attachmentIds?.length ?? 0)
      ..write('\u0000')
      ..write(message.files?.length ?? 0)
      ..write('\u0000')
      ..write(message.embeds?.length ?? 0)
      ..write('\u0000')
      ..write(message.output?.length ?? 0)
      ..write('\u0000')
      ..write(message.statusHistory.length)
      ..write('\u0000')
      ..write(message.followUps.length)
      ..write('\u0000')
      ..write(message.sources.length)
      ..write('\u0000')
      ..write(message.codeExecutions.length)
      ..write('\u0000')
      ..write(message.error == null ? 0 : 1)
      ..write('\u0000')
      ..write(message.metadata?['archivedVariant'] == true ? 1 : 0)
      ..write('\u0000')
      // responseDone flips the rendered turn phase (running footer host /
      // pin-to-top) while isStreaming is still set, so the list shell must
      // rebuild on this transition to recompute the timeline.
      ..write(message.metadata?['responseDone'] == true ? 1 : 0)
      ..write('\u0000')
      // Include the displayed model-name fallback so the structure signature
      // changes whenever the label changes, keeping the list-shell rebuild
      // trigger in agreement with chat_page's layout signature. Use the
      // normalized extractor so trim/empty handling matches the displayed name.
      ..write(_messageModelName(message) ?? '')
      ..write('\u0000')
      ..write(message.versions.length);
    for (final version in message.versions) {
      buffer
        ..write('\u0000')
        ..write(version.model ?? '');
    }
    buffer.writeln();
    return buffer.toString();
  }

  final List<String> ids;
  final String signature;

  bool get hasMessages => ids.isNotEmpty;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _ChatMessageListStructure && other.signature == signature;

  @override
  int get hashCode => signature.hashCode;
}

final _chatMessageListStructureProvider = Provider<_ChatMessageListStructure>((
  ref,
) {
  return ref.watch(
    chatMessagesProvider.select(_ChatMessageListStructure.fromMessages),
  );
});

final _chatMessageMapProvider = Provider<Map<String, ChatMessage>>((ref) {
  return ref.watch(
    chatMessagesProvider.select((messages) {
      final byId = <String, ChatMessage>{};
      for (final message in messages) {
        byId[message.id] = message;
      }
      return Map<String, ChatMessage>.unmodifiable(byId);
    }),
  );
});

final chatMessageStructureSignatureProvider = Provider<String>((ref) {
  return ref.watch(
    _chatMessageListStructureProvider.select(
      (structure) => structure.signature,
    ),
  );
});

final chatMessageIdsProvider = Provider<List<String>>((ref) {
  return ref.watch(
    _chatMessageListStructureProvider.select((structure) => structure.ids),
  );
});

final hasChatMessagesProvider = Provider<bool>((ref) {
  return ref.watch(
    _chatMessageListStructureProvider.select(
      (structure) => structure.hasMessages,
    ),
  );
});

final chatMessageByIdProvider = Provider.autoDispose
    .family<ChatMessage?, String>((ref, messageId) {
      return ref.watch(
        _chatMessageMapProvider.select(
          (messagesById) => messagesById[messageId],
        ),
      );
    });

bool _messagesAreStreaming(List<ChatMessage> messages) {
  if (messages.isEmpty) return false;
  final last = messages.last;
  return last.role == 'assistant' && last.isStreaming;
}

/// Whether chat is currently streaming a response.
/// Used by router to avoid showing connection issues during active streaming.
/// Uses select() to only rebuild when the streaming state actually changes,
/// not on every content update to the message list.
final isChatStreamingProvider = Provider<bool>((ref) {
  return ref.watch(chatMessagesProvider.select(_messagesAreStreaming));
});

/// Platform hook used by [chatWakelockCoordinatorProvider]; tests swap it to
/// observe toggles without a platform channel.
typedef ChatWakelockToggle = Future<void> Function({required bool enable});

final chatWakelockToggleProvider = Provider<ChatWakelockToggle>(
  (ref) => WakelockPlus.toggle,
);

final _localChatGenerationCountProvider =
    NotifierProvider<_LocalChatGenerationCount, int>(
      _LocalChatGenerationCount.new,
    );

/// True while any Direct, Hermes, or outbox generation owned by this process
/// is still running, regardless of which chat is visible.
final localChatGenerationActiveProvider = Provider<bool>(
  (ref) => ref.watch(_localChatGenerationCountProvider) > 0,
);

/// Marks a process-owned generation as running until the returned callback
/// runs. Releasing twice is a no-op. A run that keeps going after the user
/// switches chats is otherwise invisible to [isChatStreamingProvider].
void Function() holdLocalChatGeneration(dynamic ref) {
  final counter = ref.read(
    _localChatGenerationCountProvider.notifier,
  ) as _LocalChatGenerationCount;
  counter.hold();
  var released = false;
  return () {
    if (released) return;
    released = true;
    counter.release();
  };
}

class _LocalChatGenerationCount extends Notifier<int> {
  @override
  int build() => 0;

  void hold() {
    if (ref.mounted) state++;
  }

  void release() {
    if (ref.mounted && state > 0) state--;
  }
}

/// Keeps the screen awake only while an assistant response is thinking or
/// streaming (#681). Direct and Hermes generations live in this process, so
/// letting the device lock mid-response drops the transport and loses the
/// reply. The hold follows both the visible chat's streaming message and the
/// process-owned generation count, so switching chats mid-response keeps the
/// lock until that run finishes. Toggles are serialized so a fast
/// enable/disable pair cannot land out of order on the platform side.
final chatWakelockCoordinatorProvider = Provider<void>((ref) {
  final toggle = ref.watch(chatWakelockToggleProvider);
  var queue = Future<void>.value();
  // The platform idle timer starts enabled, so the first idle observation
  // must not issue a redundant disable.
  var applied = false;
  var visibleStreaming = false;
  var ownedGenerationActive = false;

  void apply(bool enable) {
    if (applied == enable) return;
    applied = enable;
    queue = queue.then((_) async {
      try {
        await toggle(enable: enable);
      } catch (error, stackTrace) {
        DebugLogger.error(
          'toggle-failed',
          scope: 'chat/wakelock',
          error: error,
          stackTrace: stackTrace,
          data: {'enable': enable},
        );
      }
    });
  }

  void sync() => apply(visibleStreaming || ownedGenerationActive);

  ref.listen<bool>(chatMessagesProvider.select(_messagesAreStreaming), (
    _,
    streaming,
  ) {
    visibleStreaming = streaming;
    sync();
  }, fireImmediately: true);
  // Listen to the counter itself: notifier state changes notify
  // synchronously, whereas a derived provider rebuild waits for the scheduler.
  ref.listen<int>(_localChatGenerationCountProvider, (_, count) {
    ownedGenerationActive = count > 0;
    sync();
  }, fireImmediately: true);
  ref.onDispose(() => apply(false));
});

final shouldProtectLocalStreamingStateProvider = Provider<bool>((ref) {
  final isStreaming = ref.watch(isChatStreamingProvider);
  if (isStreaming) {
    return true;
  }

  return ref.watch(
    streamingContentProvider.select(
      (content) => content != null && content.isNotEmpty,
    ),
  );
});

String? _connectedSocketSessionId(SocketService? socketService) {
  if (socketService?.isConnected != true) {
    return null;
  }

  final sessionId = socketService!.sessionId;
  if (sessionId == null || sessionId.isEmpty) {
    return null;
  }

  return sessionId;
}

const Duration _headlessStreamDrainTimeout = Duration(minutes: 5);

Future<String?> _ensureConnectedSocketSessionId(
  SocketService? socketService, {
  Duration timeout = const Duration(milliseconds: 1200),
}) async {
  if (socketService == null) {
    return null;
  }

  if (!socketService.isConnected) {
    try {
      await socketService.ensureConnected(timeout: timeout);
    } catch (e) {
      DebugLogger.log(
        'Socket reconnect before chat send failed: $e',
        scope: 'chat/providers',
      );
    }
  }

  return _connectedSocketSessionId(socketService);
}
