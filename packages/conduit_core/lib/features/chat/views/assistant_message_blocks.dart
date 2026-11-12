import 'package:conduit_markdown/conduit_markdown.dart';
import 'package:meta/meta.dart';

import '../../../models/chat_message.dart';
import '../../../services/structured_output.dart' show displayedChatFiles;
import '../../web_search/services/direct_web_search_mode.dart'
    show isDirectToolsUnsupportedError;
import '../utils/file_utils.dart'
    show chatFilesWithShown, isImageFile, isVideoFile;
import 'chat_status_display.dart';
import 'chat_turn_render_state.dart';

/// An assistant answer as an ordered list of blocks, for a client that
/// renders only plain markdown: everything the mobile app draws inside an
/// answer, in the order it draws it, with the parsing done here.
///
/// The order is the mobile `AssistantMessageWidget`'s, top to bottom:
///
/// 1. [AssistantFilesBlock]: the answer's files (generated images, files the
///    model showed with `display_file`);
/// 2. [AssistantStatusBlock]: the status timeline (web search, knowledge,
///    Hermes tools);
/// 3. [AssistantMarkdownBlock]s, in content order: text, reasoning, tool
///    calls, code-interpreter runs and other sections, as
///    `segmentAssistantMessage` splits the content, normalised for a plain
///    markdown renderer;
/// 4. [AssistantErrorBlock]: the error banner;
/// 5. [AssistantCodeExecutionBlock]s, one per code execution;
/// 6. [AssistantSourcesBlock]: what `[n]` cites, which the action row shows
///    as a sources pill once the answer is finished;
/// 7. [AssistantFollowUpsBlock]: suggested follow-ups, once finished.
///
/// Not carried: rich embeds and MCP apps (a webview each), a multi-model
/// turn's merged response, a queued send's banner, and the legacy
/// `attachmentIds` of old answers that stored no `files`.
@immutable
sealed class AssistantBlock {
  const AssistantBlock();
}

/// The answer's files, in the order the mobile app shows them: images,
/// then videos, then the rest.
final class AssistantFilesBlock extends AssistantBlock {
  AssistantFilesBlock(List<Map<String, dynamic>> files)
    : files = List<Map<String, dynamic>>.unmodifiable(files);

  /// Open WebUI file entries as stored (`type`, `id`/`file_id`, `url`,
  /// `name`, `content_type`, …), the reply's own first.
  final List<Map<String, dynamic>> files;
}

/// One line of a status timeline, as the mobile app shows it.
@immutable
final class AssistantStatusLine {
  const AssistantStatusLine({
    required this.description,
    required this.action,
    required this.done,
    required this.queries,
    required this.links,
    required this.details,
  });

  factory AssistantStatusLine.of(ChatStatusUpdate update) =>
      AssistantStatusLine(
        description: resolveStatusDescription(update),
        action: update.action,
        done: update.done == true,
        queries: collectStatusQueries(update),
        links: collectStatusLinks(update),
        details: collectStatusDetailItems(update),
      );

  /// What the line reads ([resolveStatusDescription]).
  final String description;

  /// The update's action (`web_search`, `knowledge_search`, …), if any.
  final String? action;

  /// Whether the update reported done.
  final bool done;

  /// Search queries it ran.
  final List<String> queries;

  /// Pages it found.
  final List<StatusLink> links;

  /// Items shown as a snippet under a title.
  final List<ChatStatusItem> details;
}

/// The status timeline: the row shows the last line (or [toolSummary]),
/// and opens to all of them.
final class AssistantStatusBlock extends AssistantBlock {
  AssistantStatusBlock({
    required List<AssistantStatusLine> lines,
    required this.pending,
    this.toolSummary,
  }) : lines = List<AssistantStatusLine>.unmodifiable(lines);

  final List<AssistantStatusLine> lines;

  /// The row shimmers: the turn is running and what it shows is not done.
  final bool pending;

  /// Set when more than one Hermes tool update shows: the tools, for the
  /// row's "Exploring …" / "Explored …" ([hermesToolGroupSummary]).
  final String? toolSummary;
}

/// A piece of the content: text, reasoning, tool calls, a code-interpreter
/// run or another section, normalised for a plain markdown renderer.
final class AssistantMarkdownBlock extends AssistantBlock {
  const AssistantMarkdownBlock(this.block);

  final MessageBlock block;
}

/// The error banner under the content.
final class AssistantErrorBlock extends AssistantBlock {
  const AssistantErrorBlock({
    required this.text,
    required this.toolsUnsupported,
  });

  /// The server's or provider's words; empty when it gave none (hosts then
  /// say that an error occurred).
  final String text;

  /// The model refused tool definitions ([isDirectToolsUnsupportedError]):
  /// hosts show their advice to turn web search off instead of [text].
  final bool toolsUnsupported;
}

/// One code execution, as a header that opens to the code and its result.
final class AssistantCodeExecutionBlock extends AssistantBlock {
  const AssistantCodeExecutionBlock(this.execution);

  final ChatCodeExecution execution;

  /// It has a result: output or an error. Until then it reads "Running …".
  bool get done =>
      execution.result?.error != null || execution.result?.output != null;

  /// It failed.
  bool get isError => execution.result?.error != null;
}

/// What the answer's `[n]` markers cite: marker `n` is `sources[n - 1]`.
final class AssistantSourcesBlock extends AssistantBlock {
  AssistantSourcesBlock(List<ChatSourceReference> sources)
    : sources = List<ChatSourceReference>.unmodifiable(sources);

  final List<ChatSourceReference> sources;
}

/// Suggested follow-ups, at most three ([visibleFollowUps]).
final class AssistantFollowUpsBlock extends AssistantBlock {
  AssistantFollowUpsBlock(List<String> followUps)
    : followUps = List<String>.unmodifiable(followUps);

  final List<String> followUps;
}

/// The follow-ups an answer offers: trimmed, non-empty, at most three.
List<String> visibleFollowUps(List<String> followUps) => followUps
    .map((s) => s.trim())
    .where((s) => s.isNotEmpty)
    .take(3)
    .toList(growable: false);

const String _typingIndicator = '[TYPING_INDICATOR]';
const String _searchBanner = '🔍 Searching the web...';

/// [raw] without the placeholders older streams left at its start.
String stripAssistantContentPlaceholders(String raw) {
  var text = raw;
  if (text.startsWith(_typingIndicator)) {
    text = text.substring(_typingIndicator.length);
  }
  if (text.startsWith(_searchBanner)) {
    text = text.substring(_searchBanner.length);
  }
  return text;
}

final RegExp _standaloneBase64Image = RegExp(
  r'(^|\n)([ \t]*)(data:image/[^;\s]+;base64,[A-Za-z0-9+/=]+)(?=(?:[ \t]*\n|$))',
  multiLine: true,
);

/// [content] with each base64 image that stands alone on its line turned
/// into a markdown image, as image generators sometimes answer.
String markStandaloneBase64Images(String content) {
  if (!content.contains('data:image/')) return content;
  return content.replaceAllMapped(_standaloneBase64Image, (match) {
    final linePrefix = match.group(1) ?? '';
    final indentation = match.group(2) ?? '';
    final imageData = match.group(3)!;
    return '$linePrefix$indentation![Generated Image]($imageData)';
  });
}

/// The answer text the content blocks are made from: [raw] with
/// [stripAssistantContentPlaceholders] and [markStandaloneBase64Images].
String assistantDisplayContent(String raw) =>
    markStandaloneBase64Images(stripAssistantContentPlaceholders(raw));

/// [message]'s blocks (see [AssistantBlock] for the order).
///
/// [content] replaces the message's text: a live turn's newest text, which
/// can be ahead of the transcript's copy. [streaming] says whether the
/// answer is still being written; by default it is whatever the mobile app
/// would decide ([chatTurnPhaseForMessage] is running). While streaming, an
/// unfinished section is held back, follow-ups wait, and the status
/// timeline keeps every update.
///
/// [live] parses a streaming answer incrementally, re-reading only what can
/// still change since the last call; give the same one for every frame of
/// one answer. The result is the same as without it.
///
/// [unnamedTool] names a Hermes tool that reports no name in the status
/// summary; a host passes the word in its user's language, as the mobile app
/// passes its own.
///
/// Empty for anything but an assistant message.
List<AssistantBlock> assistantMessageBlocks(
  ChatMessage message, {
  String? content,
  bool? streaming,
  StreamingContentBlocks? live,
  String unnamedTool = 'tool',
}) {
  if (message.role != 'assistant') return const <AssistantBlock>[];
  final isStreaming =
      streaming ?? chatTurnPhaseForMessage(message) == ChatTurnPhase.running;
  return _assemble(
    content: content ?? message.content,
    streaming: isStreaming,
    live: isStreaming ? live : null,
    files: message.files,
    output: message.output,
    attachmentIds: message.attachmentIds,
    statusHistory: message.statusHistory,
    error: message.error,
    codeExecutions: message.codeExecutions,
    sources: message.sources,
    followUps: message.followUps,
    unnamedTool: unnamedTool,
  );
}

/// The blocks of an earlier answer to the same prompt, as the mobile app
/// shows it when paged to: its own content, files, error, code executions,
/// sources and follow-ups. A version keeps no status timeline.
List<AssistantBlock> assistantVersionBlocks(ChatMessageVersion version) =>
    _assemble(
      content: version.content,
      streaming: false,
      live: null,
      files: version.files,
      output: version.output,
      attachmentIds: null,
      statusHistory: const <ChatStatusUpdate>[],
      error: version.error,
      codeExecutions: version.codeExecutions,
      sources: version.sources,
      followUps: version.followUps,
      // A version keeps no status timeline, so names no tool.
      unnamedTool: 'tool',
    );

List<AssistantBlock> _assemble({
  required String content,
  required bool streaming,
  required StreamingContentBlocks? live,
  required List<Map<String, dynamic>>? files,
  required List<Map<String, dynamic>>? output,
  required List<String>? attachmentIds,
  required List<ChatStatusUpdate> statusHistory,
  required ChatMessageError? error,
  required List<ChatCodeExecution> codeExecutions,
  required List<ChatSourceReference> sources,
  required List<String> followUps,
  required String unnamedTool,
}) {
  final blocks = <AssistantBlock>[];

  final shownFiles = chatFilesWithShown(
    files,
    displayedChatFiles(output),
    attachmentIds: attachmentIds,
  ).whereType<Map<String, dynamic>>().toList(growable: false);
  if (shownFiles.isNotEmpty) {
    // Images first, then videos, then the rest, each in their own order,
    // as the mobile app draws them.
    blocks.add(
      AssistantFilesBlock([
        ...shownFiles.where(isImageFile),
        ...shownFiles.where((file) => !isImageFile(file) && isVideoFile(file)),
        ...shownFiles.where((file) => !isImageFile(file) && !isVideoFile(file)),
      ]),
    );
  }

  final statuses = filterVisibleStatusUpdates(
    statusHistory,
    isStreaming: streaming,
  );
  if (statuses.isNotEmpty) {
    final hermesTools = statuses.where(isHermesToolStatus).toList();
    final grouped = hermesTools.length > 1;
    blocks.add(
      AssistantStatusBlock(
        lines: [for (final update in statuses) AssistantStatusLine.of(update)],
        pending:
            streaming &&
            (grouped
                ? hermesTools.any((update) => update.done != true)
                : statuses.last.done != true),
        toolSummary: grouped
            ? hermesToolGroupSummary(hermesTools, unnamedTool: unnamedTool)
            : null,
      ),
    );
  }

  final text = assistantDisplayContent(content);
  if (text.trim().isNotEmpty) {
    final markdown = live != null
        ? live.blocks(text, sourceCount: sources.length)
        : plainMarkdownContentBlocks(
            text,
            streaming: streaming,
            sourceCount: sources.length,
          );
    blocks.addAll(markdown.map(AssistantMarkdownBlock.new));
  }

  if (error != null) {
    blocks.add(
      AssistantErrorBlock(
        text: error.content ?? '',
        toolsUnsupported: isDirectToolsUnsupportedError(error.content),
      ),
    );
  }

  blocks.addAll(codeExecutions.map(AssistantCodeExecutionBlock.new));

  if (sources.isNotEmpty) blocks.add(AssistantSourcesBlock(sources));

  if (!streaming) {
    final offered = visibleFollowUps(followUps);
    if (offered.isNotEmpty) blocks.add(AssistantFollowUpsBlock(offered));
  }

  return List<AssistantBlock>.unmodifiable(blocks);
}

/// [content] (already through [assistantDisplayContent]) as content blocks
/// for a plain markdown renderer: `segmentAssistantMessage`, then
/// `normalizeBlocksForPlainMarkdown`, where `[n]` becomes a
/// `conduit-cite:n` link when source `n` is among [sourceCount].
List<MessageBlock> plainMarkdownContentBlocks(
  String content, {
  required bool streaming,
  required int sourceCount,
}) => normalizeBlocksForPlainMarkdown(
  segmentAssistantMessage(content, streaming: streaming),
  hasSources: sourceCount > 0,
  sourceCount: sourceCount,
);

/// Content blocks for one streaming answer, frame after frame, without
/// re-reading what can no longer change.
///
/// A streaming answer only grows at its end. Once a stretch of it is closed
/// -- it ends at a blank line outside code, math, HTML blocks and
/// `<details>` sections, and the line after it has arrived -- nothing that
/// arrives later can change how that stretch parses. So that stretch is
/// parsed once and kept, and each frame parses only the open tail after it.
/// Joined, the two are what [plainMarkdownContentBlocks] gives for the whole
/// answer.
///
/// Falls back to a whole parse each frame when the text was replaced rather
/// than extended, when the number of sources changed, and when it holds a
/// link reference definition (whose removal reflows the whole message).
final class StreamingContentBlocks {
  /// The closed stretch: the answer's first [_prefix.length] characters.
  String _prefix = '';
  List<MessageBlock> _prefixBlocks = const <MessageBlock>[];
  int? _sourceCount;
  _CutScanner _scanner = _CutScanner();

  /// Characters of the answer kept from the last frame, for tests and
  /// diagnostics.
  @visibleForTesting
  int get closedLength => _prefix.length;

  /// [content]'s blocks, as [plainMarkdownContentBlocks] gives them while
  /// streaming.
  List<MessageBlock> blocks(String content, {required int sourceCount}) {
    final references =
        ConduitMarkdownPreprocessor.hasLinkReferenceDefinitionLine(content);
    if (sourceCount != _sourceCount ||
        references ||
        !content.startsWith(_prefix)) {
      _reset(sourceCount);
      if (references) return _parse(content);
    }

    final cut = _scanner.advance(content);
    if (cut > _prefix.length) {
      final closed = _parse(content.substring(_prefix.length, cut));
      _prefixBlocks = _join(_prefixBlocks, closed);
      _prefix = content.substring(0, cut);
    }
    final tail = content.substring(_prefix.length);
    return List<MessageBlock>.unmodifiable(_join(_prefixBlocks, _parse(tail)));
  }

  void _reset(int sourceCount) {
    _prefix = '';
    _prefixBlocks = const <MessageBlock>[];
    _sourceCount = sourceCount;
    _scanner = _CutScanner();
  }

  List<MessageBlock> _parse(String content) => plainMarkdownContentBlocks(
    content,
    streaming: true,
    sourceCount: _sourceCount ?? 0,
  );

  /// [before] then [after], as one parse of both would give them: text on
  /// either side of a cut is one block. (A cut never falls right before a
  /// section, so two tool-call groups never meet there.)
  static List<MessageBlock> _join(
    List<MessageBlock> before,
    List<MessageBlock> after,
  ) {
    if (before.isEmpty) return after;
    if (after.isEmpty) return before;
    final last = before.last;
    final first = after.first;
    if (last is TextMessageBlock && first is TextMessageBlock) {
      return <MessageBlock>[
        ...before.take(before.length - 1),
        TextMessageBlock('${last.markdown}\n\n${first.markdown}'),
        ...after.skip(1),
      ];
    }
    return <MessageBlock>[...before, ...after];
  }
}

final RegExp _detailsOpen = RegExp(r'<details\b', caseSensitive: false);
final RegExp _detailsClose = RegExp(r'</details>', caseSensitive: false);
final RegExp _htmlBlockOpen = RegExp(
  r'^[ ]{0,3}<(pre|script|style|textarea)(?=[\s>]|$)|^[ ]{0,3}<!--',
  caseSensitive: false,
);
final RegExp _tildeFence = RegExp(r'^\s*(~{3,})');

// The lines the preprocessor counts as backtick fences when it decides
// whether to close an unclosed one at the end: a line starting with one, a
// closing run at a line's end, and one after a list marker.
final RegExp _fenceAtStart = RegExp(r'^\s*```');
final RegExp _fenceAtEnd = RegExp(r'[^`]```\s*$');
final RegExp _fenceAfterBullet = RegExp(
  r'^\s*(?:[*+-]|\d+\.)\s+```[^\s`]*\s*$',
);

/// Finds the last place a streaming answer can be cut: the start of a line
/// that follows exactly one empty line, where everything before is closed.
///
/// It reads each line once, as the answer grows, keeping what is open at
/// the end of the last line it read. Conservative: an unusual line only
/// keeps the stretch open for longer, which costs time, never correctness.
final class _CutScanner {
  /// Where the next unread line starts.
  int _offset = 0;

  /// The last cut found.
  int _cut = 0;

  // What is open after the last line read.
  /// The backtick run that opened code, or 0.
  int _ticks = 0;

  /// Whether that run began its line (a fence); otherwise it is a code
  /// span, which a blank line ends.
  bool _ticksFence = false;

  /// The tilde fence's length, or 0.
  int _tildes = 0;

  /// Lines the preprocessor counts as fences; it closes an odd count.
  int _fenceLines = 0;

  /// `<details>` sections open outside code. Inside code a tag is text, to
  /// the segmenter as to the mobile renderer.
  int _details = 0;

  /// Whether the last tool-call section opened, in code or not, has no
  /// `</details>` after it. While an answer streams, such a call is dropped
  /// with everything after it, wherever it stands, so nothing after it may
  /// be parsed on its own. An opening tag that does not end on its line
  /// may be one.
  bool _toolCallOpen = false;
  int _doubleDollars = 0;
  int _brackets = 0;
  int _parens = 0;
  String? _htmlEnd;

  // The two lines before the next one.
  String? _previous;
  String? _beforePrevious;

  /// The last safe cut in [content], reading only lines not read before.
  /// Only a line that has its newline counts; the one being written does
  /// not.
  int advance(String content) {
    while (true) {
      final newline = content.indexOf('\n', _offset);
      if (newline < 0) break;
      final line = content.substring(_offset, newline);
      if (_closedBefore(line)) _cut = _offset;
      _read(line);
      _offset = newline + 1;
    }
    return _cut;
  }

  /// Whether the answer can be cut right before [line]: it follows exactly
  /// one empty line, after a line with no trailing whitespace, with nothing
  /// open; and [line] starts fresh (not indented, not a section).
  bool _closedBefore(String line) {
    final previous = _previous;
    final beforePrevious = _beforePrevious;
    if (previous == null || previous.isNotEmpty) return false;
    if (beforePrevious == null ||
        beforePrevious.trim().isEmpty ||
        beforePrevious.trimRight().length != beforePrevious.length) {
      return false;
    }
    if (_ticks != 0 ||
        _tildes != 0 ||
        _fenceLines.isOdd ||
        _details != 0 ||
        _toolCallOpen ||
        _doubleDollars.isOdd ||
        _brackets != 0 ||
        _parens != 0 ||
        _htmlEnd != null) {
      return false;
    }
    if (line.trim().isEmpty) return false;
    final first = line.codeUnitAt(0);
    if (first == 0x20 || first == 0x09) return false;
    // Display math is padded with blank lines of its own; next to a cut
    // they would be lost.
    if (line.startsWith(r'$$') ||
        line.startsWith(r'\[') ||
        beforePrevious.endsWith(r'$$') ||
        beforePrevious.endsWith(r'\]')) {
      return false;
    }
    return !_detailsOpen.hasMatch(line);
  }

  void _read(String line) {
    _beforePrevious = _previous;
    _previous = line;
    _followToolCalls(line);

    if (line.contains('```')) {
      if (_fenceAtStart.hasMatch(line)) _fenceLines++;
      if (_fenceAtEnd.hasMatch(line)) _fenceLines++;
      if (_fenceAfterBullet.hasMatch(line)) _fenceLines++;
    }

    if (line.trim().isEmpty) {
      // A blank line ends a paragraph, and a code span with it.
      if (_ticks != 0 && !_ticksFence) _ticks = 0;
      return;
    }

    // Inside a tilde fence the line is code, sections and all.
    if (_tildes != 0) {
      final close = _tildeFence.firstMatch(line);
      if (close != null &&
          close.group(1)!.length >= _tildes &&
          line.substring(close.end).trim().isEmpty) {
        _tildes = 0;
      }
      return;
    }
    if (_ticks == 0) {
      final open = _tildeFence.firstMatch(line);
      if (open != null) {
        _tildes = open.group(1)!.length;
        return;
      }
    }

    final htmlEnd = _htmlEnd;
    if (htmlEnd != null) {
      if (line.toLowerCase().contains(htmlEnd)) _htmlEnd = null;
    } else if (_ticks == 0) {
      final open = _htmlBlockOpen.firstMatch(line);
      if (open != null) {
        final tag = open.group(1)?.toLowerCase();
        final end = tag == null ? '-->' : '</$tag>';
        if (!line.toLowerCase().substring(open.end).contains(end)) {
          _htmlEnd = end;
        }
      }
    }

    // Backtick runs open and close code (fences and spans alike); math
    // delimiters and sections count only outside them.
    final outside = StringBuffer();
    var index = 0;
    while (index < line.length) {
      final unit = line.codeUnitAt(index);
      if (unit == 0x60) {
        outside.write(' ');
        var end = index + 1;
        while (end < line.length && line.codeUnitAt(end) == 0x60) {
          end++;
        }
        final run = end - index;
        if (_ticks == 0) {
          _ticks = run;
          _ticksFence = run >= 3 && line.substring(0, index).trim().isEmpty;
        } else if (run == _ticks) {
          _ticks = 0;
        }
        index = end;
        continue;
      }
      if (_ticks == 0) {
        outside.writeCharCode(unit);
        if (unit == 0x24 &&
            index + 1 < line.length &&
            line.codeUnitAt(index + 1) == 0x24) {
          _doubleDollars++;
          index += 2;
          continue;
        }
        if (unit == 0x5C && index + 1 < line.length) {
          final next = line.codeUnitAt(index + 1);
          if (next == 0x5B) _brackets++; // \[
          if (next == 0x5D && _brackets > 0) _brackets--; // \]
          if (next == 0x28) _parens++; // \(
          if (next == 0x29 && _parens > 0) _parens--; // \)
          outside.writeCharCode(next);
          index += 2;
          continue;
        }
      }
      index++;
    }

    final text = outside.toString();
    _details += _detailsOpen.allMatches(text).length;
    _details -= _detailsClose.allMatches(text).length;
    if (_details < 0) _details = 0;
  }

  /// Follows tool-call sections as the streaming strip sees them: the last
  /// opener counts, code or not, until a `</details>` follows it.
  void _followToolCalls(String line) {
    final opens = _detailsOpen.allMatches(line).toList(growable: false);
    for (final open in opens.reversed) {
      final end = line.indexOf('>', open.end);
      if (end >= 0 &&
          !line
              .substring(open.start, end)
              .toLowerCase()
              .contains('tool_calls')) {
        continue;
      }
      _toolCallOpen = !_detailsClose.hasMatch(line.substring(open.end));
      return;
    }
    if (_toolCallOpen && _detailsClose.hasMatch(line)) _toolCallOpen = false;
  }
}
