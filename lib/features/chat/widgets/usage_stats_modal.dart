import 'dart:convert';
import 'dart:io' show Platform;

import 'package:material_ui/material_ui.dart';

import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit_core/utils/usage_summary.dart';

import '../../../core/services/native_sheet_bridge.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/platform_ui/platform_ui.dart';
import '../../../shared/widgets/themed_sheets.dart';

/// One figure of a response's usage: what it is, its value and, for a rate,
/// the count it was measured on.
typedef _UsageStat = ({String label, String value, String? detail});

/// Usage/performance statistics for a chat response, behind its Info
/// button as in Open WebUI: a popover on iOS 26 and later, a sheet
/// elsewhere.
class UsageStatsModal {
  UsageStatsModal._();

  /// Shows usage/performance statistics for the response.
  ///
  /// On iOS 26 and later they open in the system popover, pointing at the
  /// widget of [anchorKey] (the button that asked for them). Without an
  /// anchor, elsewhere, or when the usage holds no figure the summary knows,
  /// they open in a sheet.
  static void show(
    BuildContext context,
    Map<String, dynamic> usage, {
    GlobalKey? anchorKey,
  }) async {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;

    if (anchorKey != null) {
      final summary = UsageSummary.fromUsage(usage);
      final shown = await AdaptiveInfoPopover.show(
        context: context,
        anchorKey: anchorKey,
        title: l10n.usageInfoTitle,
        message: summary.incomplete ? l10n.usageIncomplete : null,
        rows: [
          for (final stat in _usageStats(summary, l10n))
            AdaptiveInfoPopoverRow(
              label: stat.label,
              value: stat.value,
              detail: stat.detail,
            ),
        ],
      );
      if (shown || !context.mounted) {
        return;
      }
    }

    if (Platform.isIOS) {
      try {
        await NativeSheetBridge.instance.presentSheet(
          root: NativeSheetDetailConfig(
            id: 'usage-stats',
            title: l10n.usageInfoTitle,
            items: [
              NativeSheetItemConfig(
                id: 'usage-stats-text',
                title: l10n.usageInfoTitle,
                sfSymbol: 'chart.bar',
                kind: NativeSheetItemKind.readOnlyText,
                value: buildUsageSummaryText(usage, l10n),
              ),
            ],
          ),
          rethrowErrors: true,
        );
        return;
      } catch (_) {
        if (!context.mounted) {
          return;
        }
      }
    }

    if (!context.mounted) {
      return;
    }

    ThemedSheets.showSurface<void>(
      context: context,
      showHandle: false,
      padding: const EdgeInsets.all(Spacing.lg),
      builder: (ctx) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Title
            Row(
              children: [
                Icon(
                  Icons.analytics_outlined,
                  size: IconSize.md,
                  color: theme.textPrimary,
                ),
                const SizedBox(width: Spacing.sm),
                Text(
                  l10n.usageInfoTitle,
                  style: AppTypography.bodyLargeStyle.copyWith(
                    fontWeight: FontWeight.w600,
                    color: theme.textPrimary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: Spacing.lg),

            // Stats grid
            ..._buildUsageStats(ctx, usage, l10n, theme),
          ],
        );
      },
    );
  }

  /// Builds the list of usage stat widgets from the usage map.
  static List<Widget> _buildUsageStats(
    BuildContext context,
    Map<String, dynamic> usage,
    AppLocalizations l10n,
    ConduitThemeExtension theme,
  ) {
    final summary = UsageSummary.fromUsage(usage);
    final stats = <Widget>[
      for (final stat in _usageStats(summary, l10n))
        _UsageStatRow(
          label: stat.label,
          value: stat.value,
          detail: stat.detail,
          theme: theme,
        ),
    ];
    // Open WebUI's web client shows the flag with the raw figures; here it is
    // said in words, so partial figures do not pass for the whole reply's.
    if (summary.incomplete && stats.isNotEmpty) {
      stats.add(
        Padding(
          key: const ValueKey<String>('usage-incomplete'),
          padding: const EdgeInsets.only(top: Spacing.sm),
          child: Text(
            l10n.usageIncomplete,
            style: AppTypography.bodySmallStyle.copyWith(
              color: theme.textSecondary,
            ),
          ),
        ),
      );
    }

    return stats;
  }

  /// The figures of [summary], in the order the sheet and the popover list
  /// them. The arithmetic is the core's, shared with the desktop app; this
  /// only words it.
  static List<_UsageStat> _usageStats(
    UsageSummary summary,
    AppLocalizations l10n,
  ) {
    final stats = <_UsageStat>[];
    void add(String label, String value, {String? detail}) =>
        stats.add((label: label, value: value, detail: detail));
    String? count(int? tokens) =>
        tokens == null ? null : l10n.usageTokenCount(tokens);

    if (summary.generationPerSecond case final rate?) {
      add(
        l10n.usageTokenGeneration,
        l10n.usageTokensPerSecond(rate.toStringAsFixed(1)),
        detail: count(summary.generationTokens),
      );
    } else if (summary.generationTokens case final tokens?) {
      add(l10n.usageTokenGeneration, l10n.usageTokenCount(tokens));
    }

    if (summary.promptPerSecond case final rate?) {
      add(
        l10n.usagePromptEval,
        l10n.usageTokensPerSecond(rate.toStringAsFixed(1)),
        detail: count(summary.promptTokens),
      );
    } else if (summary.promptTokens case final tokens?) {
      add(l10n.usagePromptEval, l10n.usageTokenCount(tokens));
    }

    if (summary.reasoningTokens case final tokens?) {
      add(l10n.usageReasoningTokens, l10n.usageTokenCount(tokens));
    }
    if (summary.totalTokens case final tokens?) {
      add(l10n.usageTotalTokens, l10n.usageTokenCount(tokens));
    }
    if (summary.totalSeconds case final seconds?) {
      add(
        l10n.usageTotalDuration,
        l10n.usageSecondsFormat(seconds.toStringAsFixed(2)),
      );
    }
    if (summary.queueSeconds case final seconds?) {
      add(
        l10n.usageQueueTime,
        l10n.usageSecondsFormat(seconds.toStringAsFixed(3)),
      );
    }
    if (summary.loadSeconds case final seconds?) {
      add(
        l10n.usageLoadDuration,
        l10n.usageSecondsFormat(seconds.toStringAsFixed(2)),
      );
    }
    return stats;
  }

  /// The text the native iOS sheet shows: each field of [usage], then, when
  /// Open WebUI marked it incomplete, the same note the other sheet gives.
  @visibleForTesting
  static String buildUsageSummaryText(
    Map<String, dynamic> usage,
    AppLocalizations l10n,
  ) {
    final sortedKeys = usage.keys.toList()..sort();
    final fields = sortedKeys
        .map((key) {
          final value = usage[key];
          final rendered = value is Map || value is List
              ? jsonEncode(value)
              : '$value';
          return '${_humanizeKey(key)}: $rendered';
        })
        .join('\n');
    return UsageSummary.fromUsage(usage).incomplete
        ? '$fields\n\n${l10n.usageIncomplete}'
        : fields;
  }

  static String _humanizeKey(String key) {
    return key
        .split('_')
        .where((part) => part.isNotEmpty)
        .map(
          (part) => part.length == 1
              ? part.toUpperCase()
              : '${part[0].toUpperCase()}${part.substring(1)}',
        )
        .join(' ');
  }
}

/// Row widget for displaying a single usage statistic.
class _UsageStatRow extends StatelessWidget {
  const _UsageStatRow({
    required this.label,
    required this.value,
    this.detail,
    required this.theme,
  });

  final String label;
  final String value;
  final String? detail;
  final ConduitThemeExtension theme;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.sm),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: AppTypography.bodyMediumStyle.copyWith(
              color: theme.textSecondary,
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                value,
                style: AppTypography.bodyMediumStyle.copyWith(
                  fontWeight: FontWeight.w600,
                  fontFamily: AppTypography.monospaceFontFamily,
                  color: theme.textPrimary,
                ),
              ),
              if (detail != null)
                Text(
                  detail!,
                  style: AppTypography.labelSmallStyle.copyWith(
                    color: theme.textTertiary,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
