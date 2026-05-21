import 'package:flutter/material.dart';

import 'package:conduit/l10n/app_localizations.dart';

import '../../../theme/theme_extensions.dart';
import '../../assistant_detail_header.dart';

class MarkdownDetailsGroupItem {
  const MarkdownDetailsGroupItem({
    required this.type,
    required this.childBuilder,
    this.name = '',
    this.isDone = true,
  });

  final String type;
  final String name;
  final bool isDone;
  final WidgetBuilder childBuilder;
}

class MarkdownDetailsGroup extends StatefulWidget {
  const MarkdownDetailsGroup({super.key, required this.items, this.stateId});

  final List<MarkdownDetailsGroupItem> items;
  final String? stateId;

  @override
  State<MarkdownDetailsGroup> createState() => _MarkdownDetailsGroupState();
}

class _MarkdownDetailsGroupState extends State<MarkdownDetailsGroup> {
  var _isExpanded = false;
  String? _restoredStateId;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _restoreExpansionStateIfNeeded();
  }

  @override
  void didUpdateWidget(covariant MarkdownDetailsGroup oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.stateId != widget.stateId) {
      _restoredStateId = null;
      _restoreExpansionStateIfNeeded();
    }
  }

  bool get _hasPending => widget.items.any((item) => !item.isDone);

  void _restoreExpansionStateIfNeeded() {
    final stateId = widget.stateId;
    if (stateId == null || _restoredStateId == stateId) {
      return;
    }

    final restored = PageStorage.maybeOf(
      context,
    )?.readState(context, identifier: stateId);
    if (restored is bool) {
      _isExpanded = restored;
    }
    _restoredStateId = stateId;
  }

  void _persistExpansionState() {
    final stateId = widget.stateId;
    if (stateId == null) {
      return;
    }
    PageStorage.maybeOf(
      context,
    )?.writeState(context, _isExpanded, identifier: stateId);
  }

  String _buildSummaryText() {
    final l10n = AppLocalizations.of(context)!;
    final toolNameCounts = <String, int>{};

    for (final item in widget.items) {
      final name = item.name.trim().isEmpty
          ? l10n.markdownDetailsGroupUnnamedTool
          : item.name.trim();
      toolNameCounts[name] = (toolNameCounts[name] ?? 0) + 1;
    }

    final parts = toolNameCounts.entries
        .map(
          (entry) =>
              entry.value > 1 ? '${entry.key} (${entry.value})' : entry.key,
        )
        .toList(growable: false);

    return parts.join(', ');
  }

  String _buildTitle() {
    final l10n = AppLocalizations.of(context)!;
    final summary = _buildSummaryText();
    final title = _hasPending
        ? l10n.markdownDetailsGroupPendingTitle(summary)
        : l10n.markdownDetailsGroupCompleteTitle(summary);
    return title.trim();
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;

    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              setState(() {
                _isExpanded = !_isExpanded;
              });
              _persistExpansionState();
            },
            child: AssistantDetailHeader(
              title: _buildTitle(),
              showShimmer: _hasPending,
              showChevron: true,
              allowWrap: true,
              useInlineChevron: true,
              isExpanded: _isExpanded,
            ),
          ),
          if (_isExpanded)
            Padding(
              padding: const EdgeInsets.only(top: Spacing.xs, left: Spacing.sm),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border(
                    left: BorderSide(
                      color: theme.dividerColor.withValues(alpha: 0.28),
                    ),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.only(left: Spacing.sm),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: widget.items
                        .map((item) => Builder(builder: item.childBuilder))
                        .toList(growable: false),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
