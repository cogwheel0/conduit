import 'dart:convert';
import 'dart:io' show Platform;

import 'package:material_ui/material_ui.dart';

import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit_core/utils/usage_summary.dart';

import '../../../core/services/native_sheet_bridge.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/themed_sheets.dart';

/// Modal bottom sheet displaying usage/performance statistics for a
/// chat response, matching Open WebUI's info button behavior.
class UsageStatsModal {
  UsageStatsModal._();

  /// Shows a bottom sheet with usage/performance statistics for the response.
  static void show(BuildContext context, Map<String, dynamic> usage) async {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;

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
                value: _buildUsageSummaryText(usage),
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
    final stats = <Widget>[];
    // The arithmetic is the core's, shared with the desktop app; this only
    // lays it out.
    final summary = UsageSummary.fromUsage(usage);

    Widget row(String label, String value, {String? detail}) =>
        _UsageStatRow(label: label, value: value, detail: detail, theme: theme);
    String? count(int? tokens) =>
        tokens == null ? null : l10n.usageTokenCount(tokens);

    if (summary.generationPerSecond case final rate?) {
      stats.add(
        row(
          l10n.usageTokenGeneration,
          l10n.usageTokensPerSecond(rate.toStringAsFixed(1)),
          detail: count(summary.generationTokens),
        ),
      );
    } else if (summary.generationTokens case final tokens?) {
      stats.add(row(l10n.usageTokenGeneration, l10n.usageTokenCount(tokens)));
    }

    if (summary.promptPerSecond case final rate?) {
      stats.add(
        row(
          l10n.usagePromptEval,
          l10n.usageTokensPerSecond(rate.toStringAsFixed(1)),
          detail: count(summary.promptTokens),
        ),
      );
    } else if (summary.promptTokens case final tokens?) {
      stats.add(row(l10n.usagePromptEval, l10n.usageTokenCount(tokens)));
    }

    if (summary.reasoningTokens case final tokens?) {
      stats.add(row(l10n.usageReasoningTokens, l10n.usageTokenCount(tokens)));
    }
    if (summary.totalTokens case final tokens?) {
      stats.add(row(l10n.usageTotalTokens, l10n.usageTokenCount(tokens)));
    }
    if (summary.totalSeconds case final seconds?) {
      stats.add(
        row(
          l10n.usageTotalDuration,
          l10n.usageSecondsFormat(seconds.toStringAsFixed(2)),
        ),
      );
    }
    if (summary.queueSeconds case final seconds?) {
      stats.add(
        row(
          l10n.usageQueueTime,
          l10n.usageSecondsFormat(seconds.toStringAsFixed(3)),
        ),
      );
    }
    if (summary.loadSeconds case final seconds?) {
      stats.add(
        row(
          l10n.usageLoadDuration,
          l10n.usageSecondsFormat(seconds.toStringAsFixed(2)),
        ),
      );
    }

    return stats;
  }

  static String _buildUsageSummaryText(Map<String, dynamic> usage) {
    final sortedKeys = usage.keys.toList()..sort();
    return sortedKeys
        .map((key) {
          final value = usage[key];
          final rendered = value is Map || value is List
              ? jsonEncode(value)
              : '$value';
          return '${_humanizeKey(key)}: $rendered';
        })
        .join('\n');
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
