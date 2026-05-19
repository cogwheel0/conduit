import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:html_unescape/html_unescape.dart';

import 'package:conduit/l10n/app_localizations.dart';

import '../../../../core/utils/embed_utils.dart';
import '../../../../core/utils/reasoning_parser.dart';
import '../../assistant_detail_header.dart';
import '../../themed_sheets.dart';
import '../../web_content_embed.dart';
import '../../../theme/theme_extensions.dart';
import '../compiled_markdown_document.dart';
import '../markdown_config.dart';
import 'markdown_style.dart';

final _detailsWidgetUnescape = HtmlUnescape();

/// Upstream-style collapsible renderer for markdown `<details>` blocks.
class MarkdownDetailsBlock extends StatefulWidget {
  const MarkdownDetailsBlock({
    super.key,
    required this.summaryText,
    required this.attributes,
    required this.hasBody,
    this.detailsData,
    this.bodyBuilder,
    this.inlineExpansionStateId,
  });

  final String summaryText;
  final Map<String, String> attributes;
  final bool hasBody;
  final CompiledMarkdownDetailsData? detailsData;
  final WidgetBuilder? bodyBuilder;
  final String? inlineExpansionStateId;

  @override
  State<MarkdownDetailsBlock> createState() => _MarkdownDetailsBlockState();
}

class _MarkdownDetailsBlockState extends State<MarkdownDetailsBlock> {
  static const _resultPreviewLimit = 10000;
  final ValueNotifier<int> _sheetRevision = ValueNotifier<int>(0);
  var _isSheetOpen = false;
  var _hasPendingSheetRefresh = false;
  var _isInlineExpanded = false;
  String? _restoredInlineExpansionStateId;

  CompiledMarkdownDetailsData? get _detailsData => widget.detailsData;

  bool get _isToolCall =>
      _detailsData?.kind == CompiledMarkdownDetailsKind.toolCall ||
      widget.attributes['type'] == 'tool_calls';

  bool get _isReasoning =>
      _detailsData?.kind == CompiledMarkdownDetailsKind.reasoning ||
      _detailsData?.kind == CompiledMarkdownDetailsKind.codeInterpreter ||
      widget.attributes['type'] == 'reasoning' ||
      widget.attributes['type'] == 'code_interpreter';

  bool get _isCodeInterpreter =>
      _detailsData?.kind == CompiledMarkdownDetailsKind.codeInterpreter ||
      widget.attributes['type'] == 'code_interpreter';

  bool get _isPending {
    final compiled = _detailsData;
    if (compiled != null) {
      return compiled.isPending;
    }
    final done = widget.attributes['done'];
    return done != null && done != 'true';
  }

  bool get _supportsInlineExpansion =>
      _detailsData?.supportsInlineExpansion ?? _isReasoning;

  bool get _usesInlineExpansion => _supportsInlineExpansion && _isPending;

  bool get _canExpand {
    final compiled = _detailsData;
    if (compiled != null) {
      return compiled.canExpand;
    }
    if (!_isToolCall) {
      return widget.hasBody;
    }

    if (_toolCallData.hasEmbeds) {
      return false;
    }

    return _toolCallData.hasExpandableContent || widget.hasBody;
  }

  CompiledMarkdownToolCallData get _toolCallData =>
      _detailsData?.toolCallData ??
      _compileLegacyToolCallData(widget.attributes);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _restoreInlineExpansionStateIfNeeded();
  }

  @override
  void didUpdateWidget(covariant MarkdownDetailsBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.inlineExpansionStateId != widget.inlineExpansionStateId) {
      _restoredInlineExpansionStateId = null;
      _restoreInlineExpansionStateIfNeeded();
    }
    if (_isInlineExpanded && !_usesInlineExpansion) {
      _isInlineExpanded = false;
      _persistInlineExpansionState();
    }
    _scheduleSheetRefresh();
  }

  @override
  void dispose() {
    _sheetRevision.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final title = _headerTitle(context);
    final showInlineChevron = _usesInlineExpansion && _canExpand;
    final inlineBody = showInlineChevron && _isInlineExpanded
        ? _buildBody(context)
        : null;

    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _canExpand ? () => _handleHeaderTap(context) : null,
            child: AssistantDetailHeader(
              title: title,
              showShimmer: _isPending,
              showChevron: _canExpand,
              useInlineChevron: showInlineChevron,
              isExpanded: showInlineChevron && _isInlineExpanded,
            ),
          ),
          if (inlineBody != null) _buildInlineBody(context, inlineBody),
          if (_isToolCall) ..._buildToolCallEmbeds(context),
          if (_isToolCall) ..._buildToolCallImages(context),
        ],
      ),
    );
  }

  void _handleHeaderTap(BuildContext context) {
    if (!_canExpand) {
      return;
    }

    if (_usesInlineExpansion) {
      setState(() {
        _isInlineExpanded = !_isInlineExpanded;
      });
      _persistInlineExpansionState();
      return;
    }

    _showDetailsBottomSheet(context);
  }

  void _restoreInlineExpansionStateIfNeeded() {
    final stateId = widget.inlineExpansionStateId;
    if (stateId == null || _restoredInlineExpansionStateId == stateId) {
      return;
    }

    final restored = PageStorage.maybeOf(
      context,
    )?.readState(context, identifier: stateId);
    if (_usesInlineExpansion && restored is bool) {
      _isInlineExpanded = restored;
    } else if (!_usesInlineExpansion) {
      _isInlineExpanded = false;
    }
    _restoredInlineExpansionStateId = stateId;
  }

  void _persistInlineExpansionState() {
    final stateId = widget.inlineExpansionStateId;
    if (stateId == null) {
      return;
    }

    PageStorage.maybeOf(
      context,
    )?.writeState(context, _isInlineExpanded, identifier: stateId);
  }

  Widget _buildInlineBody(BuildContext context, Widget body) {
    final theme = context.conduitTheme;
    return Padding(
      padding: const EdgeInsets.only(top: Spacing.xs, left: Spacing.sm),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(color: theme.dividerColor.withValues(alpha: 0.28)),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.only(left: Spacing.sm),
          child: body,
        ),
      ),
    );
  }

  void _scheduleSheetRefresh() {
    if (!_isSheetOpen || _hasPendingSheetRefresh) {
      return;
    }

    _hasPendingSheetRefresh = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _hasPendingSheetRefresh = false;
      if (!mounted || !_isSheetOpen) {
        return;
      }
      _sheetRevision.value++;
    });
  }

  void _showDetailsBottomSheet(BuildContext context) {
    final body = _buildBody(context);
    if (body == null) {
      return;
    }

    _isSheetOpen = true;

    ThemedSheets.showSurface<void>(
      context: context,
      isScrollControlled: true,
      showHandle: false,
      padding: EdgeInsets.zero,
      builder: (sheetContext) {
        return ValueListenableBuilder<int>(
          valueListenable: _sheetRevision,
          builder: (context, value, child) {
            final liveTheme = sheetContext.conduitTheme;
            final markdownStyle = ConduitMarkdownStyle.fromTheme(sheetContext);
            final title = _modalTitle(sheetContext);
            final liveBody = _buildBody(sheetContext);
            if (liveBody == null) {
              return const SizedBox.shrink();
            }

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
                          color: liveTheme.dividerColor.withValues(alpha: 0.4),
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
                            liveTheme,
                            iconSize: IconSize.md,
                            spinnerSize: IconSize.md,
                          ),
                          const SizedBox(width: Spacing.sm),
                          Expanded(
                            child: Text(
                              title,
                              overflow: TextOverflow.ellipsis,
                              style: markdownStyle.sheetTitle,
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.close, size: 20),
                            onPressed: () => Navigator.of(sheetContext).pop(),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            color: liveTheme.textSecondary,
                          ),
                        ],
                      ),
                    ),
                    Divider(
                      height: 1,
                      color: liveTheme.dividerColor.withValues(alpha: 0.3),
                    ),
                    Expanded(
                      child: ListView(
                        controller: controller,
                        padding: const EdgeInsets.all(Spacing.lg),
                        children: [liveBody],
                      ),
                    ),
                  ],
                );
              },
            );
          },
        );
      },
    ).whenComplete(() {
      _isSheetOpen = false;
    });
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
      final name =
          _detailsData?.name.trim() ?? widget.attributes['name']?.trim();
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
      final name =
          _detailsData?.name.trim() ?? widget.attributes['name']?.trim();
      final safeName = (name == null || name.isEmpty) ? 'tool' : name;
      return _isPending ? 'Running $safeName…' : 'Used $safeName';
    }

    return _headerTitle(context);
  }

  String _reasoningHeaderText(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final summary = (_detailsData?.summaryText ?? widget.summaryText).trim();
    final summaryLower = summary.toLowerCase();
    final isDone =
        _detailsData?.isDone ?? (widget.attributes['done'] == 'true');
    final duration =
        _detailsData?.durationSeconds ??
        (int.tryParse(widget.attributes['duration'] ?? '0') ?? 0);

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

  Widget? _buildToolCallBody(
    BuildContext context,
    CompiledMarkdownToolCallData data,
  ) {
    final builder = widget.bodyBuilder;
    final hasExtraBody = builder != null && widget.hasBody;
    if (!data.hasExpandableContent && !hasExtraBody) {
      return null;
    }

    final theme = context.conduitTheme;
    final markdownStyle = ConduitMarkdownStyle.fromTheme(context);
    var expandedResult = false;

    return StatefulBuilder(
      builder: (context, setModalState) {
        final children = <Widget>[];

        if (data.argumentEntries.isNotEmpty) {
          children.add(_buildSectionTitle('Input', markdownStyle));
          children.add(const SizedBox(height: 6));
          children.add(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: data.argumentEntries
                  .map((entry) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${entry.label}: ',
                            style: markdownStyle.detailLabel,
                          ),
                          Expanded(
                            child: SelectableText(
                              entry.value,
                              style: markdownStyle.detailValue,
                            ),
                          ),
                        ],
                      ),
                    );
                  })
                  .toList(growable: false),
            ),
          );
        } else if (data.argumentsCode.isNotEmpty) {
          children.add(_buildSectionTitle('Input', markdownStyle));
          children.add(const SizedBox(height: 6));
          children.add(
            ConduitMarkdown.buildCodeBlock(
              context: context,
              code: data.argumentsCode,
              language: 'json',
              theme: theme,
            ),
          );
        }

        if (data.resultText.isNotEmpty) {
          if (children.isNotEmpty) {
            children.add(const SizedBox(height: Spacing.sm));
          }
          children.add(_buildSectionTitle('Output', markdownStyle));
          children.add(const SizedBox(height: 6));

          if (data.resultCode.isNotEmpty) {
            children.add(
              ConduitMarkdown.buildCodeBlock(
                context: context,
                code: data.resultCode,
                language: 'json',
                theme: theme,
              ),
            );
          } else {
            final resultText = data.resultDisplayText;
            final isTruncated =
                resultText.length > _resultPreviewLimit && !expandedResult;
            children.add(
              SelectableText(
                isTruncated
                    ? resultText.substring(0, _resultPreviewLimit)
                    : resultText,
                style: markdownStyle.detailCode,
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
                    style: markdownStyle.detailAction,
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

  Widget _buildSectionTitle(String title, ConduitMarkdownStyle markdownStyle) {
    return Text(title, style: markdownStyle.detailLabel);
  }

  List<Widget> _buildToolCallImages(BuildContext context) {
    final data = _toolCallData;
    if (data.imageUrls.isEmpty) {
      return const [];
    }

    final imageUris = data.imageUrls
        .map(Uri.tryParse)
        .whereType<Uri>()
        .toList(growable: false);
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
          for (var index = 0; index < data.embedSources.length; index++) ...[
            if (index > 0) const SizedBox(height: Spacing.sm),
            KeyedSubtree(
              key: ValueKey('tool-call-embed-$index'),
              child: WebContentEmbed(
                source: data.embedSources[index],
                argsText: data.argumentsText,
                previewTitle: 'Embedded Output',
                previewDescription:
                    'Load the embedded output preview on demand.',
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

CompiledMarkdownToolCallData _compileLegacyToolCallData(
  Map<String, String> attributes,
) {
  final argumentsText = _decodeToolCallAttribute(attributes['arguments']);
  final resultText = _decodeToolCallAttribute(attributes['result']);
  final parsedArguments = _parseJsonString(argumentsText);
  final parsedResult = _parseJsonString(resultText);
  final rawFiles = _parseJsonString(
    _decodeToolCallAttribute(attributes['files']),
  );
  final rawEmbeds = _parseJsonString(
    _decodeToolCallAttribute(attributes['embeds']),
  );

  final argumentEntries = parsedArguments is Map
      ? parsedArguments.entries
            .map(
              (entry) => CompiledMarkdownToolCallArgumentEntry(
                label: entry.key.toString(),
                value: _MarkdownDetailsBlockState._stringifyValue(entry.value),
              ),
            )
            .toList(growable: false)
      : const <CompiledMarkdownToolCallArgumentEntry>[];

  final argumentsCode = argumentsText.isEmpty || parsedArguments is Map
      ? ''
      : _MarkdownDetailsBlockState._formatJsonString(argumentsText);

  final resultCode = parsedResult is Map || parsedResult is List
      ? const JsonEncoder.withIndent('  ').convert(parsedResult)
      : '';
  final resultDisplayText = resultText.isEmpty || resultCode.isNotEmpty
      ? ''
      : _MarkdownDetailsBlockState._stringifyValue(parsedResult);

  final embeds = normalizeEmbedList(rawEmbeds)
      .map(extractEmbedSource)
      .whereType<String>()
      .where((value) => value.isNotEmpty)
      .toList(growable: false);

  final imageUrls = rawFiles is List
      ? rawFiles
            .cast<Object?>()
            .map(_MarkdownDetailsBlockState._tryImageUri)
            .whereType<Uri>()
            .map((uri) => uri.toString())
            .toList(growable: false)
      : const <String>[];

  return CompiledMarkdownToolCallData(
    argumentsText: argumentsText,
    resultText: resultText,
    argumentEntries: argumentEntries,
    argumentsCode: argumentsCode,
    resultCode: resultCode,
    resultDisplayText: resultDisplayText,
    embedSources: embeds,
    imageUrls: imageUrls,
  );
}

String _decodeToolCallAttribute(String? input) {
  if (input == null || input.isEmpty) {
    return '';
  }
  return _detailsWidgetUnescape.convert(input);
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
