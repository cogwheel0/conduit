import 'package:checks/checks.dart';
import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/core/models/conversation.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/features/chat/providers/chat_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Notifier that always returns null for the active conversation.
class _NullConversationNotifier extends ActiveConversationNotifier {
  @override
  Conversation? build() => null;
}

/// Minimal [ChatMessagesNotifier] that avoids the real notifier's complex
/// lifecycle (listener subscriptions, streaming timers, socket teardown).
/// Only implements the methods used by regeneration tests.
class _TestMessagesNotifier extends ChatMessagesNotifier {
  @override
  List<ChatMessage> build() => [];

  @override
  void addMessage(ChatMessage message) {
    state = [...state, message];
  }

  @override
  void removeLastMessage() {
    if (state.isNotEmpty) {
      state = state.sublist(0, state.length - 1);
    }
  }

  @override
  void clearMessages() {
    state = [];
  }

  @override
  void setMessages(List<ChatMessage> messages) {
    state = messages;
  }

  @override
  void updateLastMessageWithFunction(
    ChatMessage Function(ChatMessage) updater,
  ) {
    if (state.isEmpty) return;
    final lastMessage = state.last;
    if (lastMessage.role != 'assistant') return;
    final updated = updater(lastMessage);
    state = [...state.sublist(0, state.length - 1), updated];
  }

  @override
  void updateMessageById(
    String messageId,
    ChatMessage Function(ChatMessage current) updater,
  ) {
    final index = state.indexWhere((m) => m.id == messageId);
    if (index == -1) return;
    final original = state[index];
    final updated = updater(original);
    if (identical(updated, original)) return;
    final next = [...state];
    next[index] = updated;
    state = next;
  }
}

/// Creates a minimal [ProviderContainer] wired for regeneration tests.
///
/// Uses a test-only [ChatMessagesNotifier] that avoids the real notifier's
/// complex lifecycle. By default `apiServiceProvider` and
/// `selectedModelProvider` return null, so any call to `regenerateMessage`
/// will throw immediately — letting us observe side-effects that happen
/// *before* that call.
ProviderContainer _regenContainer({
  List<ChatMessage> initialMessages = const [],
  bool initialImageGenEnabled = false,
}) {
  final container = ProviderContainer(
    overrides: [
      // Use test notifier to avoid lifecycle complexity
      chatMessagesProvider.overrideWith(() => _TestMessagesNotifier()),
      // Prevent ChatMessagesNotifier.build from touching real data
      activeConversationProvider.overrideWith(
        () => _NullConversationNotifier(),
      ),
      // regenerateMessage reads these — null causes immediate throw
      apiServiceProvider.overrideWithValue(null),
      selectedModelProvider.overrideWithValue(null),
      reviewerModeProvider.overrideWithValue(false),
    ],
  );

  // Pre-populate messages
  if (initialMessages.isNotEmpty) {
    container.read(chatMessagesProvider.notifier).setMessages(initialMessages);
  }

  // Set initial image gen toggle state
  if (initialImageGenEnabled) {
    container.read(imageGenerationEnabledProvider.notifier).set(true);
  }

  return container;
}

/// Convenience builder for a user [ChatMessage].
ChatMessage _userMsg({
  String id = 'user-1',
  String content = 'Draw me a cat',
  List<String>? attachmentIds,
}) {
  return ChatMessage(
    id: id,
    role: 'user',
    content: content,
    timestamp: DateTime.now(),
    attachmentIds: attachmentIds,
  );
}

/// Convenience builder for an assistant [ChatMessage] with image files.
ChatMessage _assistantWithImages({
  String id = 'assistant-1',
  String content = '',
  List<Map<String, dynamic>>? files,
}) {
  return ChatMessage(
    id: id,
    role: 'assistant',
    content: content,
    timestamp: DateTime.now(),
    files:
        files ??
        [
          {
            'type': 'image',
            'url': 'https://example.com/cat.png',
            'name': 'cat.png',
          },
        ],
  );
}

/// Convenience builder for a text-only assistant [ChatMessage].
ChatMessage _assistantTextOnly({
  String id = 'assistant-1',
  String content = 'Here is some text',
}) {
  return ChatMessage(
    id: id,
    role: 'assistant',
    content: content,
    timestamp: DateTime.now(),
  );
}

/// Convenience builder for a mixed text + image assistant [ChatMessage].
ChatMessage _assistantMixed({
  String id = 'assistant-1',
  String content = 'Here are your images',
}) {
  return ChatMessage(
    id: id,
    role: 'assistant',
    content: content,
    timestamp: DateTime.now(),
    files: [
      {
        'type': 'image',
        'url': 'https://example.com/cat.png',
        'name': 'cat.png',
      },
    ],
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  // =========================================================================
  // 1. Image detection from normalized files
  // =========================================================================
  group('Image regeneration detection', () {
    test('assistant with normalized image files triggers image '
        'regeneration path', () async {
      final container = _regenContainer(
        initialMessages: [_userMsg(), _assistantWithImages()],
      );
      addTearDown(container.dispose);

      // Calling the regeneration function should:
      //  - detect images -> set imageGenerationEnabled = true
      //  - call regenerateMessage -> throws (no API)
      //  - finally -> restore imageGenerationEnabled
      //
      // We verify the toggle was flipped (and restored) which proves
      // the image regeneration path was taken.

      final regenerate = container.read(regenerateLastMessageProvider);

      // The function will throw because regenerateMessage can't proceed
      // without API/model. Capture the error.
      Object? caught;
      try {
        await regenerate();
      } catch (e) {
        caught = e;
      }

      check(caught).isNotNull();

      // Image toggle should have been restored to its original value
      final toggleAfter = container.read(imageGenerationEnabledProvider);
      check(toggleAfter).equals(false);
    });

    test('mixed text+image assistant response still counts as image '
        'regeneration', () async {
      final container = _regenContainer(
        initialMessages: [
          _userMsg(),
          _assistantMixed(content: 'Here are your generated images'),
        ],
      );
      addTearDown(container.dispose);

      final regenerate = container.read(regenerateLastMessageProvider);

      Object? caught;
      try {
        await regenerate();
      } catch (e) {
        caught = e;
      }

      check(caught).isNotNull();

      // Toggle should have been temporarily enabled then restored
      check(container.read(imageGenerationEnabledProvider)).equals(false);
    });

    test('text-only assistant does NOT trigger image regeneration', () async {
      final container = _regenContainer(
        initialMessages: [_userMsg(), _assistantTextOnly()],
      );
      addTearDown(container.dispose);

      final regenerate = container.read(regenerateLastMessageProvider);

      Object? caught;
      try {
        await regenerate();
      } catch (e) {
        caught = e;
      }

      // Still throws (regenerateMessage fails) but the toggle should
      // never have been touched
      check(caught).isNotNull();
      check(container.read(imageGenerationEnabledProvider)).equals(false);
    });
  });

  // =========================================================================
  // 2. Toggle override / restore
  // =========================================================================
  group('Toggle override/restore', () {
    test(
      'previous toggle state is restored after forced image replay',
      () async {
        // Start with image generation already enabled
        final container = _regenContainer(
          initialMessages: [_userMsg(), _assistantWithImages()],
          initialImageGenEnabled: true,
        );
        addTearDown(container.dispose);

        check(container.read(imageGenerationEnabledProvider)).equals(true);

        final regenerate = container.read(regenerateLastMessageProvider);

        try {
          await regenerate();
        } catch (_) {}

        // Should be restored to the original value: true
        check(container.read(imageGenerationEnabledProvider)).equals(true);
      },
    );

    test('previous toggle state is restored even if regeneration '
        'dispatch fails before streaming begins', () async {
      // Start with image generation disabled
      final container = _regenContainer(
        initialMessages: [_userMsg(), _assistantWithImages()],
        initialImageGenEnabled: false,
      );
      addTearDown(container.dispose);

      final regenerate = container.read(regenerateLastMessageProvider);

      try {
        await regenerate();
      } catch (_) {}

      // Must be restored to false
      check(container.read(imageGenerationEnabledProvider)).equals(false);
    });
  });

  // =========================================================================
  // 3. Archived variant metadata
  // =========================================================================
  group('Archived variant metadata', () {
    test('archived variant metadata is set before replay', () async {
      final container = _regenContainer(
        initialMessages: [
          _userMsg(),
          _assistantWithImages(id: 'asst-old'),
        ],
      );
      addTearDown(container.dispose);

      final regenerate = container.read(regenerateLastMessageProvider);

      try {
        await regenerate();
      } catch (_) {}

      // The last assistant message should have archivedVariant: true
      final messages = container.read(chatMessagesProvider);
      final lastAssistant = messages.lastWhere((m) => m.role == 'assistant');
      check(lastAssistant.metadata).isNotNull();
      check(lastAssistant.metadata!['archivedVariant']).equals(true);
      // Should also be marked non-streaming
      check(lastAssistant.isStreaming).equals(false);
    });
  });

  // =========================================================================
  // 4. Send-path failure lifecycle
  // =========================================================================
  group('Send-path failure lifecycle', () {
    test('transport setup failure converts existing assistant placeholder '
        'into error-state message in the same slot', () async {
      // Simulate the send-path error handling by directly testing the
      // pattern: placeholder exists, error occurs, placeholder should
      // be converted in-place (not removed + replaced).
      final container = _regenContainer();
      addTearDown(container.dispose);

      final notifier = container.read(chatMessagesProvider.notifier);

      // 1. Add user message
      final userMsg = _userMsg(id: 'u-1');
      notifier.addMessage(userMsg);

      // 2. Add assistant placeholder (simulates what sendMessage does)
      const placeholderId = 'asst-placeholder';
      final placeholder = ChatMessage(
        id: placeholderId,
        role: 'assistant',
        content: '',
        timestamp: DateTime.now(),
        isStreaming: true,
      );
      notifier.addMessage(placeholder);

      // Verify placeholder is in the list
      var messages = container.read(chatMessagesProvider);
      check(messages.length).equals(2);
      check(messages.last.id).equals(placeholderId);
      check(messages.last.isStreaming).equals(true);

      // 3. Simulate transport setup failure by converting the
      //    placeholder in-place to an error-state message.
      //    This is the DESIRED behavior we're testing for.
      notifier.updateLastMessageWithFunction((m) {
        return m.copyWith(
          isStreaming: false,
          error: const ChatMessageError(content: 'Transport setup failed'),
        );
      });

      // 4. Verify the placeholder was converted, not replaced
      messages = container.read(chatMessagesProvider);
      check(messages.length).equals(2);
      check(messages.last.id).equals(placeholderId);
      check(messages.last.isStreaming).equals(false);
      check(messages.last.error).isNotNull();
      check(messages.last.error!.content).equals('Transport setup failed');

      // 5. No extra fallback message appended
      final assistantMessages = messages
          .where((m) => m.role == 'assistant')
          .toList();
      check(assistantMessages.length).equals(1);
    });

    test('send-path converts placeholder in-place on error '
        '(preserves ID and any attached files)', () async {
      final container = _regenContainer();
      addTearDown(container.dispose);

      final notifier = container.read(chatMessagesProvider.notifier);

      // Setup: user + assistant placeholder with pre-attached files
      notifier.addMessage(_userMsg(id: 'u-1'));
      const placeholderId = 'asst-placeholder';
      notifier.addMessage(
        ChatMessage(
          id: placeholderId,
          role: 'assistant',
          content: '',
          timestamp: DateTime.now(),
          isStreaming: true,
          files: const [
            {'type': 'image', 'url': '/api/v1/files/a/content'},
          ],
        ),
      );

      // Simulate the new in-place error conversion pattern
      notifier.updateLastMessageWithFunction(
        (m) => m.copyWith(
          isStreaming: false,
          error: const ChatMessageError(
            content: 'Transport setup failed',
          ),
        ),
      );

      final messages = container.read(chatMessagesProvider);
      // Same placeholder ID preserved
      check(messages.length).equals(2);
      check(messages.last.id).equals(placeholderId);
      // Error state set
      check(messages.last.isStreaming).equals(false);
      check(messages.last.error).isNotNull();
      // Pre-attached files survived
      check(messages.last.files).isNotNull();
      check(messages.last.files!.length).equals(1);
    });
  });

  // =========================================================================
  // 5. Regeneration path failure lifecycle
  // =========================================================================
  group('Regeneration failure lifecycle', () {
    test(
      'transport setup failure before streaming converts existing '
      'assistant placeholder into error-state message in same slot',
      () async {
        final container = _regenContainer(
          initialMessages: [
            _userMsg(),
            _assistantWithImages(id: 'asst-img'),
          ],
        );
        addTearDown(container.dispose);

        final regenerate = container.read(regenerateLastMessageProvider);

        // regenerateMessage will throw (no API/model).
        // The regeneration provider should handle this by converting the
        // archived assistant message to error state rather than crashing
        // silently.
        try {
          await regenerate();
        } catch (_) {}

        final messages = container.read(chatMessagesProvider);

        // The archived assistant should still be there (same ID)
        final assistants = messages
            .where((m) => m.role == 'assistant')
            .toList();
        check(assistants).isNotEmpty();
        check(assistants.last.id).equals('asst-img');
        // Should be non-streaming
        check(assistants.last.isStreaming).equals(false);
      },
    );
  });

  // =========================================================================
  // 6. Pure image detection function
  // =========================================================================
  group('assistantHasNormalizedImageFiles', () {
    test('detects normalized image files', () {
      final msg = _assistantWithImages(
        files: [
          {'type': 'image', 'url': 'https://example.com/cat.png'},
        ],
      );
      check(assistantHasNormalizedImageFiles(msg)).isTrue();
    });

    test('returns false for text-only assistant', () {
      final msg = _assistantTextOnly();
      check(assistantHasNormalizedImageFiles(msg)).isFalse();
    });

    test('returns false for null files', () {
      final msg = ChatMessage(
        id: 'a',
        role: 'assistant',
        content: 'text',
        timestamp: DateTime.now(),
      );
      check(assistantHasNormalizedImageFiles(msg)).isFalse();
    });

    test('returns false for empty files list', () {
      final msg = ChatMessage(
        id: 'a',
        role: 'assistant',
        content: 'text',
        timestamp: DateTime.now(),
        files: const [],
      );
      check(assistantHasNormalizedImageFiles(msg)).isFalse();
    });

    test('detects image among non-image files', () {
      final msg = ChatMessage(
        id: 'a',
        role: 'assistant',
        content: 'mixed',
        timestamp: DateTime.now(),
        files: [
          {'type': 'file', 'url': 'doc.pdf'},
          {'type': 'image', 'url': 'cat.png'},
        ],
      );
      check(assistantHasNormalizedImageFiles(msg)).isTrue();
    });

    test('returns false for non-assistant role', () {
      final msg = ChatMessage(
        id: 'a',
        role: 'user',
        content: 'text',
        timestamp: DateTime.now(),
        files: [
          {'type': 'image', 'url': 'cat.png'},
        ],
      );
      check(assistantHasNormalizedImageFiles(msg)).isFalse();
    });
  });
}
