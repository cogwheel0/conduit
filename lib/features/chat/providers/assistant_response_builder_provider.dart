import 'package:flutter/widgets.dart';
import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/models/chat_message.dart';

typedef AssistantResponseBuilder = Widget Function(
  BuildContext context,
  AssistantResponseContext response,
);

class AssistantResponseContext {
  const AssistantResponseContext({
    required this.message,
    required this.markdown,
    required this.isStreaming,
    required this.buildDefault,
  });

  final ChatMessage message;
  final String markdown;
  final bool isStreaming;
  final WidgetBuilder buildDefault;
}

final assistantResponseBuilderProvider = Provider<AssistantResponseBuilder?>(
  (_) => null,
);
