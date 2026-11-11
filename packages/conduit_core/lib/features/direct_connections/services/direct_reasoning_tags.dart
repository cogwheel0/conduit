import 'dart:async';

import 'package:conduit_core/features/direct_connections/models/direct_completion.dart';
import 'package:conduit_markdown/conduit_markdown.dart';

/// Splits raw reasoning tags (`<think>…</think>` and the other pairs Open
/// WebUI recognises) out of a direct run's answer text.
///
/// Many models write their reasoning inline in `content` instead of a
/// separate field. Each adapter passes its event stream through here, so
/// every consumer sees that text as [DirectReasoningDelta]s and the answer
/// as [DirectContentDelta]s, the same split Open WebUI chats get from
/// [StreamingReasoningTagSplitter].
///
/// - A tag split across deltas (`<thi` + `nk>`) is held back until it can
///   be read, as is a partial closing tag inside a block.
/// - A tag inside Markdown code in the answer stays answer text.
/// - Held answer text is released before any other event that renders (a
///   tool call, provider reasoning, an image), so stream order holds. Inside
///   an open block it stays held, since it may be the start of the closing
///   tag. Usage, provider metadata, file annotations and sources are not
///   placed in the answer, so they pass a held fragment without releasing it.
/// - When the run ends (done, error, or the stream closing) everything held
///   is released; a block that never closed keeps the rest as reasoning.
/// - Whitespace right after a closing tag is dropped, as Open WebUI's server
///   strips the text that follows one. A stream without tags passes through
///   with its deltas unchanged.
///
/// A turn has one reasoning section. Provider reasoning deltas
/// (`reasoning_content`, Ollama's `thinking`) and inline tag blocks both feed
/// it, in the order they arrive, as Open WebUI's client merges a reasoning
/// delta into an inline block that is still open. A blank line separates
/// reasoning that follows a closed inline block, so two blocks do not run
/// together.
Stream<DirectStreamEvent> splitInlineReasoningTags(
  Stream<DirectStreamEvent> events,
) {
  final splitter = StreamingReasoningTagSplitter(ignoreTagsInCode: true);
  var separateNextReasoning = false;
  var trimAfterClosingTag = false;

  void addReasoning(EventSink<DirectStreamEvent> sink, String text) {
    if (separateNextReasoning) {
      separateNextReasoning = false;
      text = '\n\n$text';
    }
    sink.add(DirectReasoningDelta(text));
  }

  void addAnswer(EventSink<DirectStreamEvent> sink, String text) {
    if (trimAfterClosingTag) {
      text = text.trimLeft();
      if (text.isEmpty) return;
      trimAfterClosingTag = false;
    }
    sink.add(DirectContentDelta(text));
  }

  void emit(EventSink<DirectStreamEvent> sink, List<RawReasoningTagEvent> raw) {
    for (final event in raw) {
      switch (event) {
        case RawReasoningTagText(:final text):
          addAnswer(sink, text);
        case RawReasoningTagReasoning(:final text):
          addReasoning(sink, text);
        case RawReasoningTagEnd():
          separateNextReasoning = true;
          trimAfterClosingTag = true;
      }
    }
  }

  void releaseHeldAnswerText(EventSink<DirectStreamEvent> sink) {
    if (splitter.isInsideReasoning) return;
    emit(sink, splitter.flush());
  }

  void releaseEverything(EventSink<DirectStreamEvent> sink) {
    emit(sink, splitter.flush());
  }

  return events.transform(
    StreamTransformer<DirectStreamEvent, DirectStreamEvent>.fromHandlers(
      handleData: (event, sink) {
        switch (event) {
          case DirectContentDelta(:final content):
            emit(sink, splitter.feed(content));
          case DirectReasoningDelta(:final content) when content.isNotEmpty:
            releaseHeldAnswerText(sink);
            addReasoning(sink, content);
          case DirectStreamDone() || DirectStreamError():
            releaseEverything(sink);
            sink.add(event);
          case DirectUsageUpdate() ||
              DirectProviderMetadataUpdate() ||
              DirectFileAnnotationsUpdate() ||
              DirectSourceFound():
            // Not placed in the answer, so a held tag fragment stays held
            // for the delta that completes it.
            sink.add(event);
          default:
            releaseHeldAnswerText(sink);
            sink.add(event);
        }
      },
      handleError: (error, stackTrace, sink) {
        releaseEverything(sink);
        sink.addError(error, stackTrace);
      },
      handleDone: (sink) {
        releaseEverything(sink);
        sink.close();
      },
    ),
  );
}
