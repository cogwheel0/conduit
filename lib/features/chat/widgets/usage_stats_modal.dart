import 'dart:convert';
import 'dart:math' as math;

import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit_core/utils/usage_summary.dart';

import '../../../core/services/native_sheet_bridge.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/locale_display_formatters.dart';
import '../../../shared/widgets/platform_ui/platform_ui.dart';
import '../../../shared/widgets/themed_sheets.dart';

/// One figure of a response's usage: what it is, its value, for a rate the
/// count it was measured on, and the SF Symbol the popover draws before it.
typedef _UsageStat = ({
  String label,
  String value,
  String? detail,
  String? symbol,
});

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
  ///
  /// With the [contextLength] of the model that wrote the response, and
  /// usage that gives the prompt and answer of its last call, they include
  /// how full the model's context window was.
  static void show(
    BuildContext context,
    Map<String, dynamic> usage, {
    GlobalKey? anchorKey,
    int? contextLength,
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
          for (final stat in _usageStats(
            context,
            summary,
            contextLength: contextLength,
          ))
            AdaptiveInfoPopoverRow(
              label: stat.label,
              value: stat.value,
              detail: stat.detail,
              symbol: stat.symbol,
            ),
        ],
      );
      if (shown || !context.mounted) {
        return;
      }
    }

    if (PlatformUiCapabilities.isIOS) {
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
                Flexible(
                  child: Text(
                    l10n.usageInfoTitle,
                    style: AppTypography.bodyLargeStyle.copyWith(
                      fontWeight: FontWeight.w600,
                      color: theme.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: Spacing.lg),

            // Stats grid
            ..._buildUsageStats(ctx, usage, l10n, theme, contextLength),
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
    int? contextLength,
  ) {
    final summary = UsageSummary.fromUsage(usage);
    final stats = <Widget>[
      for (final stat in _usageStats(
        context,
        summary,
        contextLength: contextLength,
      ))
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
  ///
  /// How full the context window was leads, when [contextLength] and the
  /// summary's context tokens are both known.
  static List<_UsageStat> _usageStats(
    BuildContext context,
    UsageSummary summary, {
    int? contextLength,
  }) {
    final l10n = AppLocalizations.of(context)!;
    final stats = <_UsageStat>[];
    void add(String label, String value, {String? detail, String? symbol}) =>
        stats.add((label: label, value: value, detail: detail, symbol: symbol));
    String? count(int? tokens) =>
        tokens == null ? null : l10n.usageTokenCount(tokens);

    if ((summary.contextTokens, contextLength)
        case (final tokens?, final length?) when length > 0) {
      final fill = tokens / length;
      add(
        l10n.usageContextWindow,
        l10n.usageContextWindowValue(
          LocaleDisplayFormatters.percentage(context, fill),
          _compactCount(context, tokens),
          // A length of whole 1,024-token blocks that is not a round
          // thousand is named by their number, as models advertise it and
          // the Direct settings show it: 32,768 is 32K, 131,072 is 128K,
          // and 128,000 stays 128K.
          _compactCount(
            context,
            length % 1000 != 0 && length % 1024 == 0
                ? length ~/ 1024 * 1000
                : length,
          ),
        ),
        symbol: _gaugeSymbol(fill),
      );
    }

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

  /// The gauge glyph whose needle is nearest to [fill], a share of the
  /// context window: SF Symbols draws it at 0, 33, 50, 67 and 100 percent.
  static String _gaugeSymbol(double fill) {
    const stops = [0, 33, 50, 67, 100];
    final percent = fill * 100;
    final nearest = stops.reduce(
      (a, b) => (percent - a).abs() <= (percent - b).abs() ? a : b,
    );
    return 'gauge.with.dots.needle.${nearest}percent';
  }

  /// [count] as a short figure in the app's language, rounded as iOS rounds
  /// one (to nearest, ties to even): to one decimal under ten of its unit,
  /// else to whole units. So 9,500 is 9.5K, 9,950 is 10K, 79,123 is 79K and
  /// 999,500 is 1M; 7.9万 in Japanese.
  static String _compactCount(BuildContext context, int count) {
    final format =
        NumberFormat.compact(
            locale: Localizations.localeOf(context).toLanguageTag(),
          )
          ..significantDigitsInUse = false
          ..maximumFractionDigits = 1;
    // How many digits the locale's unit hides at this magnitude (3 for K, 4
    // for 万, none where there is no short form, as for German thousands),
    // read off the magnitude's smallest number, which needs no rounding.
    final digits = '$count'.length;
    final hidden =
        digits -
        _digit.allMatches(format.format(math.pow(10, digits - 1))).length;
    if (hidden <= 0) return format.format(count);
    // Rounded here, in integers: the formatter divides in floating point,
    // where 9.95 is a little less, so 9,950 would read 9.9K.
    final step = math
        .pow(10, digits - hidden == 1 ? hidden - 1 : hidden)
        .toInt();
    final steps = count ~/ step;
    final twiceRest = count % step * 2;
    final roundUp = twiceRest > step || (twiceRest == step && steps.isOdd);
    return format.format((steps + (roundUp ? 1 : 0)) * step);
  }

  static final _digit = RegExp(r'\p{Nd}', unicode: true);

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
      // The value takes the width it needs, up to most of the row, and wraps
      // beyond that; the label wraps in what is left. A long figure (a
      // context window in German at a large text size) then stays on the
      // sheet.
      child: LayoutBuilder(
        builder: (context, constraints) => Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: AppTypography.bodyMediumStyle.copyWith(
                  color: theme.textSecondary,
                ),
              ),
            ),
            const SizedBox(width: Spacing.sm),
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: constraints.maxWidth * 0.6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    value,
                    textAlign: TextAlign.end,
                    style: AppTypography.bodyMediumStyle.copyWith(
                      fontWeight: FontWeight.w600,
                      fontFamily: AppTypography.monospaceFontFamily,
                      color: theme.textPrimary,
                    ),
                  ),
                  if (detail != null)
                    Text(
                      detail!,
                      textAlign: TextAlign.end,
                      style: AppTypography.labelSmallStyle.copyWith(
                        color: theme.textTertiary,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
