part of 'chat_providers.dart';

// Prefilled input text (e.g., when sharing text from other apps)
@Riverpod(keepAlive: true)
class PrefilledInputText extends _$PrefilledInputText {
  @override
  String? build() => null;

  void set(String? value) => state = value;

  void clear() => state = null;
}

const String chatComposerTextInsertionTargetId = 'chat-composer';

class ComposerTextInsertion {
  const ComposerTextInsertion({
    required this.id,
    required this.targetId,
    required this.text,
    this.separateParagraph = false,
  });

  final int id;
  final String targetId;
  final String text;
  final bool separateParagraph;
}

final composerTextInsertionProvider =
    NotifierProvider<ComposerTextInsertionNotifier, ComposerTextInsertion?>(
      ComposerTextInsertionNotifier.new,
    );

class ComposerTextInsertionNotifier extends Notifier<ComposerTextInsertion?> {
  int _nextId = 0;

  @override
  ComposerTextInsertion? build() => null;

  void insert({
    required String targetId,
    required String text,
    bool separateParagraph = false,
  }) {
    if (text.trim().isEmpty) {
      return;
    }
    state = ComposerTextInsertion(
      id: ++_nextId,
      targetId: targetId,
      text: text,
      separateParagraph: separateParagraph,
    );
  }

  void clear(int id) {
    if (state?.id == id) {
      state = null;
    }
  }
}

// Trigger to request focus on the chat input (increment to signal)
@Riverpod(keepAlive: true)
class InputFocusTrigger extends _$InputFocusTrigger {
  @override
  int build() => 0;

  void set(int value) => state = value;

  int increment() {
    final next = state + 1;
    state = next;
    return next;
  }
}

// Whether the chat composer currently has focus
@Riverpod(keepAlive: true)
class ComposerHasFocus extends _$ComposerHasFocus {
  @override
  bool build() => false;

  void set(bool value) => state = value;
}

// Whether the chat composer is allowed to auto-focus.
// When false, the composer will remain unfocused until the user taps it.
@Riverpod(keepAlive: true)
class ComposerAutofocusEnabled extends _$ComposerAutofocusEnabled {
  @override
  bool build() => true;

  void set(bool value) => state = value;
}
