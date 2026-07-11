import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:conduit/core/utils/debug_logger.dart';
import 'package:conduit/features/workspace/models/workspace_resources.dart';
import 'package:conduit/features/workspace/providers/workspace_providers.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/widgets/conduit_loading.dart';
import 'package:conduit/shared/widgets/themed_dialogs.dart';
import 'package:conduit/shared/widgets/themed_sheets.dart';

/// Paginated version-history panel for a workspace prompt.
///
/// Read access is enough to list versions, view a snapshot, and diff two
/// entries. [canMutate] (write access) gates set-as-production and delete;
/// [canRestore] (an editable form) gates pulling a snapshot's body back into
/// the editor. A restore only ever touches the prompt body — never its command
/// or sharing grants.
class WorkspacePromptHistorySection extends ConsumerStatefulWidget {
  const WorkspacePromptHistorySection({
    super.key,
    required this.promptId,
    required this.productionVersionId,
    required this.canMutate,
    required this.canRestore,
    required this.onRestore,
    required this.onProductionChanged,
  });

  final String promptId;
  final String? productionVersionId;
  final bool canMutate;
  final bool canRestore;
  final void Function(Map<String, dynamic> snapshot) onRestore;
  final void Function(String versionId) onProductionChanged;

  @override
  ConsumerState<WorkspacePromptHistorySection> createState() =>
      _WorkspacePromptHistorySectionState();
}

class _WorkspacePromptHistorySectionState
    extends ConsumerState<WorkspacePromptHistorySection> {
  static const _pageSize = 20;

  final _entries = <WorkspacePromptHistoryEntry>[];
  int _page = 0;
  bool _loading = false;
  bool _loadingMore = false;
  bool _hasError = false;
  bool _hasMore = true;
  bool _busy = false;
  String? _selectedId;
  late String? _productionVersionId;

  @override
  void initState() {
    super.initState();
    _productionVersionId = widget.productionVersionId;
    _loadInitial();
  }

  Future<void> _loadInitial() async {
    setState(() {
      _loading = true;
      _hasError = false;
    });
    try {
      final entries = await ref
          .read(workspacePromptsProvider.notifier)
          .history(widget.promptId, page: 0);
      if (!mounted) return;
      setState(() {
        _entries
          ..clear()
          ..addAll(entries);
        _page = 0;
        _hasMore = entries.length >= _pageSize;
        _loading = false;
        _selectedId = _productionVersionId != null &&
                entries.any((e) => e.id == _productionVersionId)
            ? _productionVersionId
            : (entries.isNotEmpty ? entries.first.id : null);
      });
    } catch (error, stackTrace) {
      DebugLogger.error(
        'prompt history load failed',
        scope: 'workspace/prompts',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        setState(() {
          _loading = false;
          _hasError = true;
        });
      }
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    try {
      final nextPage = _page + 1;
      final entries = await ref
          .read(workspacePromptsProvider.notifier)
          .history(widget.promptId, page: nextPage);
      if (!mounted) return;
      setState(() {
        _entries.addAll(entries);
        _page = nextPage;
        _hasMore = entries.length >= _pageSize;
        _loadingMore = false;
      });
    } catch (error, stackTrace) {
      DebugLogger.error(
        'prompt history page load failed',
        scope: 'workspace/prompts',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<void> _setProduction(WorkspacePromptHistoryEntry entry) async {
    final l10n = AppLocalizations.of(context)!;
    setState(() => _busy = true);
    try {
      await ref
          .read(workspacePromptsProvider.notifier)
          .setProductionVersion(widget.promptId, entry.id);
      if (!mounted) return;
      setState(() => _productionVersionId = entry.id);
      widget.onProductionChanged(entry.id);
      _showSnack(l10n.workspacePromptHistoryProductionSet);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'prompt set production failed',
        scope: 'workspace/prompts',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) _showSnack(l10n.workspacePromptSaveFailed, isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteEntry(WorkspacePromptHistoryEntry entry) async {
    final l10n = AppLocalizations.of(context)!;
    if (entry.id == _productionVersionId) {
      _showSnack(l10n.workspacePromptHistoryDeleteProduction, isError: true);
      return;
    }
    final confirmed = await ThemedDialogs.confirm(
      context,
      title: l10n.workspacePromptHistoryDeleteConfirmTitle,
      message: l10n.workspacePromptHistoryDeleteConfirmMessage,
      confirmText: l10n.delete,
      cancelText: l10n.cancel,
      isDestructive: true,
    );
    if (!confirmed || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(workspacePromptsProvider.notifier)
          .deleteHistoryEntry(widget.promptId, entry.id);
      if (!mounted) return;
      setState(() {
        _entries.removeWhere((e) => e.id == entry.id);
        if (_selectedId == entry.id) {
          _selectedId = _entries.isNotEmpty ? _entries.first.id : null;
        }
      });
      _showSnack(l10n.workspacePromptHistoryDeleted);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'prompt history delete failed',
        scope: 'workspace/prompts',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) _showSnack(l10n.workspacePromptSaveFailed, isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _diff(WorkspacePromptHistoryEntry entry) async {
    final l10n = AppLocalizations.of(context)!;
    final production = _productionVersionId;
    if (production == null || production == entry.id) return;
    setState(() => _busy = true);
    try {
      final diff = await ref
          .read(workspacePromptsProvider.notifier)
          .historyDiff(widget.promptId, fromId: entry.id, toId: production);
      if (!mounted) return;
      await WorkspacePromptDiffSheet.show(context, diff);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'prompt history diff failed',
        scope: 'workspace/prompts',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        _showSnack(l10n.workspacePromptHistoryDiffFailed, isError: true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showSnack(String message, {bool isError = false}) {
    AdaptiveSnackBar.show(
      context,
      message: message,
      type: isError ? AdaptiveSnackBarType.error : AdaptiveSnackBarType.success,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    return Column(
      key: const Key('workspace-prompt-history-panel'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.workspacePromptHistory, style: theme.headingSmall),
        const SizedBox(height: Spacing.sm),
        if (_loading)
          Padding(
            padding: const EdgeInsets.all(Spacing.lg),
            child: Center(
              child: ConduitLoading.inline(context: context),
            ),
          )
        else if (_hasError)
          _errorRow(l10n)
        else if (_entries.isEmpty)
          Padding(
            key: const Key('workspace-prompt-history-empty'),
            padding: const EdgeInsets.symmetric(vertical: Spacing.md),
            child: Text(
              l10n.workspacePromptHistoryEmpty,
              style: theme.bodySmall?.copyWith(color: theme.textSecondary),
            ),
          )
        else
          AbsorbPointer(
            absorbing: _busy,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final entry in _entries) _entryTile(l10n, entry),
                if (_hasMore)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      key: const Key('workspace-prompt-history-load-more'),
                      onPressed: _loadingMore ? null : _loadMore,
                      child: _loadingMore
                          ? ConduitLoading.inline(context: context)
                          : Text(l10n.workspaceLoadMore),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _errorRow(AppLocalizations l10n) {
    final theme = context.conduitTheme;
    return Row(
      key: const Key('workspace-prompt-history-error'),
      children: [
        Icon(Icons.error_outline, size: IconSize.small, color: theme.error),
        const SizedBox(width: Spacing.sm),
        Expanded(
          child: Text(
            l10n.workspacePromptHistoryLoadFailed,
            style: theme.bodySmall?.copyWith(color: theme.error),
          ),
        ),
        TextButton(
          key: const Key('workspace-prompt-history-retry'),
          onPressed: _loadInitial,
          child: Text(l10n.retry),
        ),
      ],
    );
  }

  Widget _entryTile(AppLocalizations l10n, WorkspacePromptHistoryEntry entry) {
    final theme = context.conduitTheme;
    final isProduction = entry.id == _productionVersionId;
    final selected = entry.id == _selectedId;
    final commit = entry.commitMessage?.trim();
    return Column(
      key: Key('prompt-history-${entry.id}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          dense: true,
          selected: selected,
          contentPadding: EdgeInsets.zero,
          title: Row(
            children: [
              Flexible(
                child: Text(
                  commit == null || commit.isEmpty
                      ? l10n.workspacePromptHistoryCommitFallback
                      : commit,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (isProduction) ...[
                const SizedBox(width: Spacing.sm),
                Container(
                  key: Key('prompt-history-live-${entry.id}'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: Spacing.xs,
                    vertical: Spacing.xxs,
                  ),
                  decoration: BoxDecoration(
                    color: theme.success.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(AppBorderRadius.badge),
                  ),
                  child: Text(
                    l10n.workspacePromptHistoryLive,
                    style: theme.caption?.copyWith(color: theme.success),
                  ),
                ),
              ],
            ],
          ),
          subtitle: Text(
            '${entry.id.length >= 7 ? entry.id.substring(0, 7) : entry.id} · '
            '${_formatDate(entry.createdAt)}',
            style: theme.caption?.copyWith(color: theme.textSecondary),
          ),
          onTap: () => setState(
            () => _selectedId = selected ? null : entry.id,
          ),
        ),
        if (selected) _selectedPanel(l10n, entry, isProduction),
      ],
    );
  }

  Widget _selectedPanel(
    AppLocalizations l10n,
    WorkspacePromptHistoryEntry entry,
    bool isProduction,
  ) {
    final theme = context.conduitTheme;
    final content = entry.snapshot['content']?.toString() ?? '';
    return Container(
      key: Key('prompt-history-detail-${entry.id}'),
      margin: const EdgeInsets.only(bottom: Spacing.sm),
      padding: const EdgeInsets.all(Spacing.sm),
      decoration: BoxDecoration(
        color: theme.surfaceContainer,
        borderRadius: BorderRadius.circular(AppBorderRadius.medium),
        border: Border.all(color: theme.dividerColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 200),
            child: SingleChildScrollView(
              child: SelectableText(
                content,
                style: theme.code?.copyWith(color: theme.textPrimary),
              ),
            ),
          ),
          const SizedBox(height: Spacing.sm),
          Wrap(
            spacing: Spacing.sm,
            runSpacing: Spacing.xs,
            children: [
              if (_productionVersionId != null && !isProduction)
                TextButton.icon(
                  key: Key('prompt-history-diff-${entry.id}'),
                  onPressed: () => _diff(entry),
                  icon: const Icon(Icons.difference_outlined, size: IconSize.small),
                  label: Text(l10n.workspacePromptHistoryDiff),
                ),
              if (widget.canRestore)
                TextButton.icon(
                  key: Key('prompt-history-restore-${entry.id}'),
                  onPressed: () => widget.onRestore(entry.snapshot),
                  icon: const Icon(Icons.restore, size: IconSize.small),
                  label: Text(l10n.workspacePromptHistoryRestore),
                ),
              if (widget.canMutate && !isProduction)
                TextButton.icon(
                  key: Key('prompt-history-production-${entry.id}'),
                  onPressed: () => _setProduction(entry),
                  icon: const Icon(Icons.verified_outlined, size: IconSize.small),
                  label: Text(l10n.workspacePromptHistorySetProduction),
                ),
              if (widget.canMutate && !isProduction)
                TextButton.icon(
                  key: Key('prompt-history-delete-${entry.id}'),
                  onPressed: () => _deleteEntry(entry),
                  icon: Icon(
                    Icons.delete_outline,
                    size: IconSize.small,
                    color: theme.error,
                  ),
                  label: Text(
                    l10n.workspacePromptHistoryDelete,
                    style: TextStyle(color: theme.error),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  static String _formatDate(int seconds) {
    if (seconds <= 0) return '';
    final date = DateTime.fromMillisecondsSinceEpoch(
      seconds * 1000,
    ).toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${date.year}-${two(date.month)}-${two(date.day)} '
        '${two(date.hour)}:${two(date.minute)}';
  }
}

/// Bottom sheet rendering the unified diff between two prompt versions.
class WorkspacePromptDiffSheet extends StatelessWidget {
  const WorkspacePromptDiffSheet({super.key, required this.diff});

  final Map<String, dynamic> diff;

  static Future<void> show(BuildContext context, Map<String, dynamic> diff) {
    return ThemedSheets.showCustom<void>(
      context: context,
      builder: (_) => WorkspacePromptDiffSheet(diff: diff),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final lines = (diff['content_diff'] as List?)
            ?.map((line) => line.toString())
            .toList() ??
        const <String>[];
    final nameChanged = diff['name_changed'] == true;
    return ConduitModalSheetSurface(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.workspacePromptHistoryDiffTitle,
                  style: theme.headingSmall,
                ),
              ),
              SheetCloseButton(
                tooltip: l10n.close,
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          const SizedBox(height: Spacing.sm),
          if (nameChanged)
            Padding(
              padding: const EdgeInsets.only(bottom: Spacing.sm),
              child: Text(
                l10n.workspacePromptHistoryDiffNameChanged,
                style: theme.bodySmall?.copyWith(color: theme.textSecondary),
              ),
            ),
          if (lines.isEmpty)
            Padding(
              key: const Key('workspace-prompt-diff-empty'),
              padding: const EdgeInsets.symmetric(vertical: Spacing.md),
              child: Text(
                l10n.workspacePromptHistoryDiffEmpty,
                style: theme.bodyMedium?.copyWith(color: theme.textSecondary),
              ),
            )
          else
            Flexible(
              child: SingleChildScrollView(
                key: const Key('workspace-prompt-diff-content'),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final line in lines)
                      Text(
                        line.isEmpty ? ' ' : line,
                        style: theme.code?.copyWith(
                          color: _diffColor(theme, line) ?? theme.textPrimary,
                        ),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Color? _diffColor(ConduitThemeExtension theme, String line) {
    if (line.startsWith('+') && !line.startsWith('+++')) return theme.success;
    if (line.startsWith('-') && !line.startsWith('---')) return theme.error;
    if (line.startsWith('@@')) return theme.textSecondary;
    return null;
  }
}
