import 'dart:convert';

import '../../shared/widgets/markdown/markdown_preprocessor.dart';

/// Parsed representation of one tool call emitted as a `<details type="tool_calls" ...>` block
class ToolCallEntry {
  final String id;
  final String name;
  final bool done;
  final dynamic arguments; // decoded JSON when possible, else String
  final dynamic result; // decoded JSON when possible, else String
  final List<dynamic>? files; // decoded JSON array when present

  const ToolCallEntry({
    required this.id,
    required this.name,
    required this.done,
    this.arguments,
    this.result,
    this.files,
  });
}

/// Container for extracted tool calls and the remaining main content
class ToolCallsContent {
  final List<ToolCallEntry> toolCalls;
  final String mainContent;
  final String originalContent;

  const ToolCallsContent({
    required this.toolCalls,
    required this.mainContent,
    required this.originalContent,
  });
}

/// Utility to parse `<details type="tool_calls">` blocks from content.
class ToolCallsParser {
  static String _unescapeHtml(String s) {
    return s
        .replaceAll('&quot;', '"')
        .replaceAll('&#34;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&#39;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&#60;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&#62;', '>')
        .replaceAll('&amp;', '&')
        .replaceAll('&#38;', '&');
  }

  /// Represents a mixed stream of text and tool-call entries in original order
  /// as they appeared in the content.
  static List<ToolCallsSegment>? segments(String content) {
    if (content.isEmpty || !content.contains('<details')) return null;

    final segs = <ToolCallsSegment>[];
    int index = 0;

    while (index < content.length) {
      final start = content.indexOf('<details', index);
      if (start == -1) {
        if (index < content.length) {
          segs.add(ToolCallsSegment.text(content.substring(index)));
        }
        break;
      }

      // Text before the block
      if (start > index) {
        segs.add(ToolCallsSegment.text(content.substring(index, start)));
      }

      // Find end of opening tag
      final openEnd = content.indexOf('>', start);
      if (openEnd == -1) {
        // Malformed opening tag; append the rest as text and stop
        segs.add(ToolCallsSegment.text(content.substring(start)));
        break;
      }
      final openTag = content.substring(start, openEnd + 1);

      // Parse attributes from opening tag immediately (to support streaming)
      final attrs = <String, String>{};
      final attrRegex = RegExp(r'(\w+)="(.*?)"');
      for (final m in attrRegex.allMatches(openTag)) {
        attrs[m.group(1)!] = m.group(2) ?? '';
      }

      // Find matching closing tag with nesting support
      int depth = 1;
      int i = openEnd + 1;
      while (i < content.length && depth > 0) {
        final nextOpen = content.indexOf('<details', i);
        final nextClose = content.indexOf('</details>', i);
        if (nextClose == -1 && nextOpen == -1) break;
        if (nextOpen != -1 && (nextClose == -1 || nextOpen < nextClose)) {
          depth++;
          i = nextOpen + 8; // '<details'
        } else {
          depth--;
          i = (nextClose != -1)
              ? nextClose + 10
              : content.length; // '</details>'
        }
      }

      final isToolCalls = (attrs['type'] ?? '') == 'tool_calls';

      if (isToolCalls) {
        // Decode attributes for tool call tile
        dynamic decodeAttribute(String? source) {
          if (source == null || source.isEmpty) return null;
          try {
            final unescaped = _unescapeHtml(source);
            return json.decode(unescaped);
          } catch (_) {
            try {
              return _unescapeHtml(source);
            } catch (_) {
              return source;
            }
          }
        }

        final id = (attrs['id'] ?? '');
        final name = (attrs['name'] ?? 'tool');
        final done = (attrs['done'] == 'true');
        final args = decodeAttribute(attrs['arguments']);
        final result = decodeAttribute(attrs['result']);
        final files = decodeAttribute(attrs['files']);

        segs.add(
          ToolCallsSegment.entry(
            ToolCallEntry(
              id: id.isNotEmpty ? id : '${name}_$start',
              name: name,
              done: done,
              arguments: args,
              result: result,
              files: (files is List) ? files : null,
            ),
          ),
        );

        // If details not closed yet, stop scanning (wait for more stream)
        if (depth != 0) {
          break;
        }

        // If closed, advance index to the end of the block
        index = i;
        continue;
      }

      // Non-tool_calls: keep as text (full block) when closed; if not closed, append remainder and stop
      if (depth != 0) {
        segs.add(ToolCallsSegment.text(content.substring(start)));
        break;
      } else {
        final fullMatch = content.substring(start, i);
        segs.add(ToolCallsSegment.text(fullMatch));
        index = i;
      }
    }

    return segs.isEmpty ? null : segs;
  }

  /// Extracts tool call blocks and returns the remaining content with those blocks removed.
  static ToolCallsContent? parse(String content) {
    if (content.isEmpty || !content.contains('<details')) return null;

    // We need mainContent that excludes tool_calls blocks even if unclosed (streaming)
    final segs = segments(content);
    if (segs == null) return null;

    final calls = <ToolCallEntry>[];
    final buf = StringBuffer();
    for (final seg in segs) {
      if (seg.isToolCall && seg.entry != null) {
        calls.add(seg.entry!);
      } else if (seg.text != null && seg.text!.isNotEmpty) {
        final text = seg.text!;
        // Quick check: only run cleanup regex if tool_calls details might exist
        // (they should already be parsed as segments, but this is a safety net)
        String cleaned = text;
        if (text.contains('<details') && text.contains('tool_calls')) {
          // Remove any embedded tool_calls blocks that may have slipped into text
          cleaned = text.replaceAll(
            RegExp(
              r'<details\s+type=\"tool_calls\"[^>]*>[\s\S]*?<\/details>',
              multiLine: true,
              dotAll: true,
            ),
            '',
          );
        }
        cleaned = cleaned.trim();
        if (cleaned.isNotEmpty) buf.write(cleaned);
      }
    }

    if (calls.isEmpty) return null;
    return ToolCallsContent(
      toolCalls: calls,
      mainContent: buf.toString().trim(),
      originalContent: content,
    );
  }

  /// Legacy helper that summarizes tool blocks to text (kept for fallback)
  static String summarize(String content) {
    final parsed = parse(content);
    if (parsed == null) return content;
    final buf = StringBuffer();
    for (final c in parsed.toolCalls) {
      buf.writeln(
        c.done ? 'Tool Executed: ${c.name}' : 'Running tool: ${c.name}…',
      );
      final args = _prettyMaybe(c.arguments, max: 400);
      final res = _prettyMaybe(c.result, max: 800);
      if (args.isNotEmpty) {
        buf.writeln('\nArguments:\n```json');
        buf.writeln(args);
        buf.writeln('```');
      }
      if (res.isNotEmpty) {
        buf.writeln('\nResult:\n```json');
        buf.writeln(res);
        buf.writeln('```');
      }
      buf.writeln();
    }
    buf.writeln(parsed.mainContent);
    return buf.toString().trim();
  }

  static String _prettyMaybe(dynamic value, {int max = 600}) {
    if (value == null) return '';
    try {
      final pretty = const JsonEncoder.withIndent('  ').convert(value);
      return pretty.length > max ? '${pretty.substring(0, max)}\n…' : pretty;
    } catch (_) {
      final raw = value.toString();
      return raw.length > max ? '${raw.substring(0, max)}…' : raw;
    }
  }

  /// Sanitize assistant/user content before sending to the API, mirroring
  /// the web client's `processDetails` behavior:
  /// - Remove &lt;details type="reasoning"&gt; and &lt;details type="code_interpreter"&gt; blocks
  /// - Replace &lt;details type="tool_calls" ...&gt;...&lt;/details&gt; blocks with the
  ///   JSON-serialized `result` attribute (as a quoted string) when available;
  ///   otherwise replace with an empty string.
  static String sanitizeForApi(String content) {
    if (content.isEmpty) return content;

    // Remove annotations and reasoning blocks
    content = ConduitMarkdownPreprocessor.sanitize(content);

    if (!content.contains('<details')) return content.trim();

    // Replace tool_calls blocks in-order with their results
    final segs = segments(content);
    if (segs == null || segs.isEmpty) return content.trim();

    final buf = StringBuffer();
    for (final seg in segs) {
      if (seg.isToolCall && seg.entry != null) {
        final entry = seg.entry!;
        dynamic res = entry.result;
        String out;
        if (res == null) {
          out = '';
        } else {
          try {
            out = json.encode(res);
          } catch (_) {
            out = res.toString();
          }
        }
        // Match web behavior: wrap in quotes so it's clearly a string payload
        if (out.isNotEmpty && !(out.startsWith('"') && out.endsWith('"'))) {
          out = '"$out"';
        }
        buf.write(out);
      } else {
        final text = seg.text ?? '';
        // Quick check: only run cleanup regex if details tags exist
        String cleaned = text;
        if (text.contains('<details')) {
          // Keep the raw text, but also remove any stray non-tool_calls details blocks
          cleaned = text.replaceAll(
            RegExp(
              r'<details(?!\s+type=\"tool_calls\")[^>]*>[\s\S]*?<\/details>',
              multiLine: true,
              dotAll: true,
            ),
            '',
          );
        }
        if (cleaned.isNotEmpty) buf.write(cleaned);
      }
    }

    return buf.toString().trim();
  }
}

/// Ordered piece of content: either plain text or a tool-call entry
class ToolCallsSegment {
  final String? text;
  final ToolCallEntry? entry;

  const ToolCallsSegment._({this.text, this.entry});
  factory ToolCallsSegment.text(String text) => ToolCallsSegment._(text: text);
  factory ToolCallsSegment.entry(ToolCallEntry entry) =>
      ToolCallsSegment._(entry: entry);

  bool get isToolCall => entry != null;
}
