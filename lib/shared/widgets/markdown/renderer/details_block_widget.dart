import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:html_unescape/html_unescape.dart';

import 'package:conduit/l10n/app_localizations.dart';

import '../../../../core/utils/embed_utils.dart';
import '../../../../core/utils/reasoning_parser.dart';
import '../../assistant_detail_header.dart';
import '../../web_content_embed.dart';
import '../../../theme/theme_extensions.dart';
import '../markdown_config.dart';

final _detailsWidgetUnescape = HtmlUnescape();

/// Upstream-style collapsible renderer for markdown `<details>` blocks.
class MarkdownDetailsBlock extends StatefulWidget {
  const MarkdownDetailsBlock({
    super.key,
    required this.summaryText,
    required this.attributes,
    required this.hasBody,
    this.bodyBuilder,
  });

  final String summaryText;
  final Map<String, String> attributes;
  final bool hasBody;
  final WidgetBuilder? bodyBuilder;

  @override
  State<MarkdownDetailsBlock> createState() => _MarkdownDetailsBlockState();
}

class _MarkdownDetailsBlockState extends State<MarkdownDetailsBlock> {
  static const _resultPreviewLimit = 10000;

  bool get _isToolCall => widget.attributes['type'] == 'tool_calls';

  bool get _isReasoning =>
      widget.attributes['type'] == 'reasoning' ||
      widget.attributes['type'] == 'code_interpreter';

  bool get _isCodeInterpreter =>
      widget.attributes['type'] == 'code_interpreter';

  bool get _isPending {
    final done = widget.attributes['done'];
    return done != null && done != 'true';
  }

  bool get _canExpand {
    if (!_isToolCall) {
      return widget.hasBody;
    }

    if (_toolCallData.hasEmbeds) {
      return false;
    }

    return _toolCallData.hasExpandableContent || widget.hasBody;
  }

  _ToolCallViewData get _toolCallData =>
      _ToolCallViewData.fromAttributes(widget.attributes);

  @override
  Widget build(BuildContext context) {
    final title = _headerTitle(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _canExpand ? () => _showDetailsBottomSheet(context) : null,
            child: AssistantDetailHeader(
              title: title,
              showShimmer: _isPending,
              showChevron: _canExpand,
            ),
          ),
          if (_isToolCall) ..._buildToolCallEmbeds(context),
          if (_isToolCall) ..._buildToolCallImages(context),
        ],
      ),
    );
  }

  void _showDetailsBottomSheet(BuildContext context) {
    final body = _buildBody(context);
    if (body == null) {
      return;
    }

    final theme = context.conduitTheme;
    final title = _modalTitle(context);

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: theme.surfaceBackground,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppBorderRadius.dialog),
        ),
      ),
      builder: (sheetContext) {
        return DraggableScrollableSheet(
          initialChildSize: 0.6,
          minChildSize: 0.3,
          maxChildSize: 0.95,
          expand: false,
          builder: (_, controller) {
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: Spacing.sm),
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: theme.dividerColor.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: Spacing.lg,
                    vertical: Spacing.sm,
                  ),
                  child: Row(
                    children: [
                      _buildLeadingIcon(
                        theme,
                        iconSize: IconSize.md,
                        spinnerSize: IconSize.md,
                      ),
                      const SizedBox(width: Spacing.sm),
                      Expanded(
                        child: Text(
                          title,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: AppTypography.bodyLarge,
                            fontWeight: FontWeight.w600,
                            color: theme.textPrimary,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, size: 20),
                        onPressed: () => Navigator.of(sheetContext).pop(),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        color: theme.textSecondary,
                      ),
                    ],
                  ),
                ),
                Divider(
                  height: 1,
                  color: theme.dividerColor.withValues(alpha: 0.3),
                ),
                Expanded(
                  child: ListView(
                    controller: controller,
                    padding: const EdgeInsets.all(Spacing.lg),
                    children: [body],
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget? _buildBody(BuildContext context) {
    if (_isToolCall) {
      return _buildToolCallBody(context, _toolCallData);
    }
    final builder = widget.bodyBuilder;
    if (builder == null || !widget.hasBody) {
      return null;
    }
    return builder(context);
  }

  Widget _buildLeadingIcon(
    ConduitThemeExtension theme, {
    double iconSize = 16,
    double spinnerSize = 16,
  }) {
    if (_isPending) {
      return SizedBox(
        width: spinnerSize,
        height: spinnerSize,
        child: CircularProgressIndicator(
          strokeWidth: 1.8,
          color: theme.textSecondary,
        ),
      );
    }

    if (_isToolCall) {
      return Icon(
        Icons.check_circle_outline_rounded,
        size: iconSize,
        color: theme.statusPalette.success.base,
      );
    }

    if (_isReasoning) {
      return Icon(
        _isCodeInterpreter ? Icons.terminal_rounded : Icons.psychology_outlined,
        size: iconSize,
        color: theme.textSecondary,
      );
    }

    return Icon(
      Icons.unfold_more_rounded,
      size: iconSize,
      color: theme.textSecondary,
    );
  }

  String _headerTitle(BuildContext context) {
    if (_isToolCall) {
      final name = widget.attributes['name']?.trim();
      final safeName = (name == null || name.isEmpty) ? 'tool' : name;
      if (_toolCallData.hasEmbeds) {
        return safeName;
      }
      return _isPending ? 'Executing $safeName…' : 'View Result from $safeName';
    }

    if (_isReasoning) {
      return _reasoningHeaderText(context);
    }

    final summary = widget.summaryText.trim();
    return summary.isEmpty ? 'Details' : summary;
  }

  String _modalTitle(BuildContext context) {
    if (_isToolCall) {
      final name = widget.attributes['name']?.trim();
      final safeName = (name == null || name.isEmpty) ? 'tool' : name;
      return _isPending ? 'Running $safeName…' : 'Used $safeName';
    }

    return _headerTitle(context);
  }

  String _reasoningHeaderText(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final summary = widget.summaryText.trim();
    final summaryLower = summary.toLowerCase();
    final isDone = widget.attributes['done'] == 'true';
    final duration = int.tryParse(widget.attributes['duration'] ?? '0') ?? 0;

    final isThinkingSummary =
        summaryLower == 'thinking…' ||
        summaryLower == 'thinking...' ||
        summaryLower.startsWith('thinking');

    final hasDurationInSummary = RegExp(
      r'\(\d+s\)|\bfor \d+ seconds?\b',
      caseSensitive: false,
    ).hasMatch(summary);

    if (_isCodeInterpreter) {
      return isDone ? l10n.analyzed : l10n.analyzing;
    }

    if (!isDone) {
      return summary.isNotEmpty && !isThinkingSummary ? summary : l10n.thinking;
    }

    if (duration > 0 || hasDurationInSummary || isThinkingSummary) {
      return l10n.thoughtForDuration(ReasoningParser.formatDuration(duration));
    }

    if (summary.isNotEmpty && !isThinkingSummary) {
      return summary;
    }

    return l10n.thoughts;
  }

  Widget? _buildToolCallBody(BuildContext context, _ToolCallViewData data) {
    final builder = widget.bodyBuilder;
    final hasExtraBody = builder != null && widget.hasBody;
    if (!data.hasExpandableContent && !hasExtraBody) {
      return null;
    }

    final theme = context.conduitTheme;
    var expandedResult = false;

    return StatefulBuilder(
      builder: (context, setModalState) {
        final children = <Widget>[];

        if (data.parsedArguments is Map<String, dynamic>) {
          final arguments = data.parsedArguments as Map<String, dynamic>;
          children.add(_buildSectionTitle('Input', theme));
          children.add(const SizedBox(height: 6));
          children.add(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: arguments.entries
                  .map((entry) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${entry.key}: ',
                            style: TextStyle(
                              color: theme.textSecondary,
                              fontSize: AppTypography.bodySmall,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Expanded(
                            child: SelectableText(
                              _stringifyValue(entry.value),
                              style: TextStyle(
                                color: theme.textPrimary,
                                fontSize: AppTypography.bodySmall,
                                height: 1.35,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  })
                  .toList(growable: false),
            ),
          );
        } else if (data.argumentsText.isNotEmpty) {
          children.add(_buildSectionTitle('Input', theme));
          children.add(const SizedBox(height: 6));
          children.add(
            ConduitMarkdown.buildCodeBlock(
              context: context,
              code: _formatJsonString(data.argumentsText),
              language: 'json',
              theme: theme,
            ),
          );
        }

        if (data.resultText.isNotEmpty) {
          if (children.isNotEmpty) {
            children.add(const SizedBox(height: Spacing.sm));
          }
          children.add(_buildSectionTitle('Output', theme));
          children.add(const SizedBox(height: 6));

          final parsedResult = data.parsedResult;
          if (parsedResult is Map || parsedResult is List) {
            children.add(
              ConduitMarkdown.buildCodeBlock(
                context: context,
                code: const JsonEncoder.withIndent('  ').convert(parsedResult),
                language: 'json',
                theme: theme,
              ),
            );
          } else {
            final resultText = _stringifyValue(parsedResult);
            final isTruncated =
                resultText.length > _resultPreviewLimit && !expandedResult;
            children.add(
              SelectableText(
                isTruncated
                    ? resultText.substring(0, _resultPreviewLimit)
                    : resultText,
                style: TextStyle(
                  color: theme.textPrimary,
                  fontSize: AppTypography.bodySmall,
                  fontFamily: AppTypography.monospaceFontFamily,
                  height: 1.35,
                ),
              ),
            );
            if (isTruncated) {
              children.add(const SizedBox(height: 6));
              children.add(
                TextButton(
                  onPressed: () => setModalState(() {
                    expandedResult = true;
                  }),
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    alignment: Alignment.centerLeft,
                  ),
                  child: Text(
                    'Show all (${resultText.length} characters)',
                    style: TextStyle(
                      color: theme.textSecondary,
                      fontSize: AppTypography.bodySmall,
                    ),
                  ),
                ),
              );
            }
          }
        }

        if (hasExtraBody) {
          if (children.isNotEmpty) {
            children.add(const SizedBox(height: Spacing.sm));
          }
          children.add(builder(context));
        }

        if (children.isEmpty) {
          return const SizedBox.shrink();
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        );
      },
    );
  }

  Widget _buildSectionTitle(String title, ConduitThemeExtension theme) {
    return Text(
      title,
      style: TextStyle(
        color: theme.textSecondary,
        fontSize: AppTypography.labelSmall,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.4,
      ),
    );
  }

  List<Widget> _buildToolCallImages(BuildContext context) {
    final data = _toolCallData;
    final files = data.files;
    if (files.isEmpty) {
      return const [];
    }

    final imageUris = <Uri>[];
    for (final file in files) {
      final uri = _tryImageUri(file);
      if (uri != null) {
        imageUris.add(uri);
      }
    }

    if (imageUris.isEmpty) {
      return const [];
    }

    final theme = context.conduitTheme;
    return [
      const SizedBox(height: Spacing.xs),
      Wrap(
        spacing: Spacing.sm,
        runSpacing: Spacing.sm,
        children: imageUris
            .map((uri) {
              return ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: 220,
                  maxHeight: 220,
                ),
                child: ConduitMarkdown.buildImage(context, uri, theme),
              );
            })
            .toList(growable: false),
      ),
    ];
  }

  List<Widget> _buildToolCallEmbeds(BuildContext context) {
    final data = _toolCallData;
    if (!data.hasEmbeds) {
      return const [];
    }

    return [
      const SizedBox(height: Spacing.xs),
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var index = 0; index < data.embeds.length; index++) ...[
            if (index > 0) const SizedBox(height: Spacing.sm),
            KeyedSubtree(
              key: ValueKey('tool-call-embed-$index'),
              child: WebContentEmbed(
                source: data.embeds[index],
                argsText: data.argumentsText,
              ),
            ),
          ],
        ],
      ),
    ];
  }

  static Uri? _tryImageUri(Object? value) {
    if (value is String) {
      if (!value.startsWith('data:image/') &&
          !value.startsWith('http://') &&
          !value.startsWith('https://')) {
        return null;
      }
      return Uri.tryParse(value);
    }

    if (value is Map) {
      final type = value['type']?.toString();
      final contentType = value['content_type']?.toString() ?? '';
      final url = value['url']?.toString();
      final isImage = type == 'image' || contentType.startsWith('image/');
      if (!isImage || url == null || url.isEmpty) {
        return null;
      }
      return Uri.tryParse(url);
    }

    return null;
  }

  static String _stringifyValue(Object? value) {
    if (value == null) {
      return '';
    }
    if (value is String) {
      return value;
    }
    try {
      return const JsonEncoder.withIndent('  ').convert(value);
    } catch (_) {
      return value.toString();
    }
  }

  static String _formatJsonString(String raw) {
    final parsed = _parseJsonString(raw);
    if (parsed is String) {
      return parsed;
    }
    try {
      return const JsonEncoder.withIndent('  ').convert(parsed);
    } catch (_) {
      return raw;
    }
  }

  static Object? _parseJsonString(String input) {
    if (input.isEmpty) {
      return '';
    }
    try {
      final decoded = json.decode(input);
      if (decoded is String && decoded != input) {
        return _parseJsonString(decoded);
      }
      return decoded;
    } catch (_) {
      return input;
    }
  }
}

class _ToolCallViewData {
  const _ToolCallViewData({
    required this.argumentsText,
    required this.resultText,
    required this.parsedArguments,
    required this.parsedResult,
    required this.files,
    required this.embeds,
  });

  factory _ToolCallViewData.fromAttributes(Map<String, String> attributes) {
    final argumentsText = _decode(attributes['arguments']);
    final resultText = _decode(attributes['result']);
    final parsedArguments = _parseJsonString(argumentsText);
    final parsedResult = _parseJsonString(resultText);
    final rawFiles = _parseJsonString(_decode(attributes['files']));
    final rawEmbeds = _parseJsonString(_decode(attributes['embeds']));

    final files = rawFiles is List
        ? rawFiles.cast<Object?>()
        : const <Object?>[];
    final embeds = normalizeEmbedList(rawEmbeds)
        .map(extractEmbedSource)
        .whereType<String>()
        .where((value) => value.isNotEmpty)
        .toList(growable: false);

    return _ToolCallViewData(
      argumentsText: argumentsText,
      resultText: resultText,
      parsedArguments: parsedArguments,
      parsedResult: parsedResult,
      files: files,
      embeds: embeds,
    );
  }

  final String argumentsText;
  final String resultText;
  final Object? parsedArguments;
  final Object? parsedResult;
  final List<Object?> files;
  final List<String> embeds;

  bool get hasEmbeds => embeds.isNotEmpty;

  bool get hasExpandableContent =>
      argumentsText.trim().isNotEmpty || resultText.trim().isNotEmpty;

  static String _decode(String? input) {
    if (input == null || input.isEmpty) {
      return '';
    }
    return _detailsWidgetUnescape.convert(input);
  }
}

Object? _parseJsonString(String input) {
  if (input.isEmpty) {
    return '';
  }
  try {
    final decoded = json.decode(input);
    if (decoded is String && decoded != input) {
      return _parseJsonString(decoded);
    }
    return decoded;
  } catch (_) {
    return input;
  }
}
