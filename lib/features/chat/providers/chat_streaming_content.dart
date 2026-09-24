part of 'chat_providers.dart';

/// The content of the currently streaming assistant message.
/// Only the actively streaming message widget should watch this.
/// This avoids rebuilding all visible messages on every chunk.
@Riverpod(keepAlive: true)
class StreamingContent extends _$StreamingContent {
  @override
  String? build() => null;

  // ignore: use_setters_to_change_properties
  void set(String? value) => state = value;
}

/// Fixed visible-flush cadence for streamed assistant text.
///
/// Earlier builds stretched this interval with response length (up to 750 ms
/// on mobile past 16k characters), which made long replies land in one-second
/// bursts even when the transport delivered tokens smoothly (#688). Markdown
/// preparation is incremental and compiled off the UI isolate for large
/// buffers, so a constant cadence keeps repaint cost bounded without the
/// visible stutter.
const streamingContentUpdateInterval = Duration(milliseconds: 100);

@visibleForTesting
Duration debugStreamingContentUpdateIntervalForBuffer(
  int length, {
  bool isWeb = false,
  TargetPlatform platform = TargetPlatform.android,
}) => streamingContentUpdateInterval;

// Loading state for conversation (used to show chat skeletons during fetch)
@Riverpod(keepAlive: true)
class IsLoadingConversation extends _$IsLoadingConversation {
  @override
  bool build() => false;

  void set(bool value) => state = value;
}

enum _StreamingContentFlushReason {
  firstContent,
  cadence,
  terminal,
  stop,
  comparison,
  replacement,
}
