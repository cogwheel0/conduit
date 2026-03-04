import 'package:flutter/widgets.dart';

/// Intent to send the current chat message.
class SendMessageIntent extends Intent {
  const SendMessageIntent();
}

/// Intent to insert a newline in the chat input.
class InsertNewlineIntent extends Intent {
  const InsertNewlineIntent();
}

/// Intent to select the next prompt suggestion.
class SelectNextPromptIntent extends Intent {
  const SelectNextPromptIntent();
}

/// Intent to select the previous prompt suggestion.
class SelectPreviousPromptIntent extends Intent {
  const SelectPreviousPromptIntent();
}

/// Intent to dismiss the prompt suggestions overlay.
class DismissPromptIntent extends Intent {
  const DismissPromptIntent();
}

/// Represents a matched slash-command in the chat input text.
class PromptCommandMatch {
  const PromptCommandMatch({
    required this.command,
    required this.start,
    required this.end,
  });

  final String command;
  final int start;
  final int end;
}
