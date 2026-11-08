import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart'
    show isChatStreamingProvider;
import 'package:conduit_core/features/hermes/models/hermes_context_usage.dart';
import 'package:conduit_core/features/hermes/providers/hermes_context_providers.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_transport.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/sheet_handle.dart';
import '../../../shared/widgets/themed_sheets.dart';

/// Opens the Context & usage sheet for the Hermes chat stored as
/// [sessionId].
Future<void> showHermesContextUsageSheet(
  BuildContext context, {
  required String sessionId,
}) => ThemedSheets.showSurface<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  constraints: BoxConstraints(
    maxHeight: MediaQuery.sizeOf(context).height * 0.9,
  ),
  padding: EdgeInsets.zero,
  // The sheet draws its own handle so its list scrolls within its height.
  showHandle: false,
  builder: (_) => HermesContextUsageSheet(sessionId: sessionId),
);

/// [at] as a short local time, with the date when it is not today.
String formatHermesMoment(BuildContext context, DateTime at) {
  final locale = Localizations.localeOf(context).toString();
  final local = at.toLocal();
  final now = DateTime.now();
  final today =
      local.year == now.year &&
      local.month == now.month &&
      local.day == now.day;
  return today
      ? DateFormat.jm(locale).format(local)
      : DateFormat.MMMd(locale).add_jm().format(local);
}

/// How full a Hermes chat's context window is, what fills it, its token
/// and cost totals, the plan's allowances, and Compact now.
class HermesContextUsageSheet extends ConsumerStatefulWidget {
  const HermesContextUsageSheet({super.key, required this.sessionId});

  final String sessionId;

  @override
  ConsumerState<HermesContextUsageSheet> createState() =>
      _HermesContextUsageSheetState();
}

class _HermesContextUsageSheetState
    extends ConsumerState<HermesContextUsageSheet> {
  final _focus = TextEditingController();
  bool _compacting = false;
  HermesCompactResult? _result;
  String? _compactError;

  /// Whether the last build showed a compaction still running.
  bool _shownPending = false;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  /// A compaction Hermes is still finishing in the background: another
  /// would replace its result, and its completion would no longer refresh
  /// the report. The service knows of it after the sheet was closed and
  /// opened again.
  bool get _compactionPending {
    if (_result?.outcome == HermesCompactOutcome.pending) return true;
    final service = ref.read(hermesApiServiceProvider);
    return service is HermesDesktopApiService &&
        service.compactionPending(widget.sessionId);
  }

  Future<void> _compact() async {
    if (_compactionPending) return;
    final l10n = AppLocalizations.of(context)!;
    final service = ref.read(hermesApiServiceProvider);
    if (service is! HermesDesktopApiService) return;
    if (ref.read(isChatStreamingProvider)) {
      setState(() {
        _result = null;
        _compactError = l10n.hermesContextCompactWait;
      });
      return;
    }
    setState(() {
      _compacting = true;
      _result = null;
      _compactError = null;
    });
    try {
      final result = await service.compactSession(
        widget.sessionId,
        focus: _focus.text,
      );
      if (!mounted) return;
      setState(() => _result = result);
      if (result.changed) {
        _focus.clear();
        ref.invalidate(hermesContextReportProvider(widget.sessionId));
      }
    } on HermesDesktopRpcException catch (error) {
      if (!mounted) return;
      // Hermes refuses to compact a chat whose turn is still running.
      setState(
        () => _compactError = error.code == 4009
            ? l10n.hermesContextCompactWait
            : l10n.hermesContextCompactFailed,
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _compactError = l10n.hermesContextCompactFailed);
    } finally {
      if (mounted) setState(() => _compacting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    // A compaction still running when it answered is done once the chat's
    // transcript changes: the report is read again and the note goes.
    // Also after the sheet was opened again while one ran.
    ref.listen(hermesDesktopTranscriptChangesProvider, (_, next) {
      if (!_shownPending || next.asData?.value.storedId != widget.sessionId) {
        return;
      }
      setState(() => _result = null);
      ref.invalidate(hermesContextReportProvider(widget.sessionId));
    });
    _shownPending = _compactionPending;
    final report = ref.watch(hermesContextReportProvider(widget.sessionId));
    final model = report.asData?.value.model;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SheetHandle(),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(
              Spacing.lg,
              Spacing.xs,
              Spacing.lg,
              Spacing.lg,
            ),
            children: [
              Text(
                l10n.hermesContextUsage,
                style: AppTypography.titleMediumStyle.copyWith(
                  color: theme.textPrimary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (model != null)
                Text(
                  model,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.bodySmallStyle.copyWith(
                    color: theme.textSecondary,
                  ),
                ),
              const SizedBox(height: Spacing.md),
              ...report.when(
                data: (report) => _sections(context, report),
                loading: () => const [
                  Padding(
                    padding: EdgeInsets.all(Spacing.xl),
                    child: Center(child: AdaptiveProgressIndicator()),
                  ),
                ],
                error: (_, _) => [
                  Text(
                    l10n.hermesContextLoadFailed,
                    style: AppTypography.bodySmallStyle.copyWith(
                      color: theme.error,
                    ),
                  ),
                  const SizedBox(height: Spacing.sm),
                  ConduitButton(
                    key: const ValueKey<String>('hermes-context-reload'),
                    text: l10n.retry,
                    isSecondary: true,
                    isCompact: true,
                    onPressed: () => ref.invalidate(
                      hermesContextReportProvider(widget.sessionId),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  List<Widget> _sections(BuildContext context, HermesContextReport report) {
    final l10n = AppLocalizations.of(context)!;
    final numbers = NumberFormat.decimalPattern(
      Localizations.localeOf(context).toString(),
    );
    final plan = report.providerPlan;
    final gauges = plan != null && plan.gauges.isNotEmpty
        ? plan.gauges
        : report.planGauges;
    final bars = report.usageBars;
    final showPlan =
        gauges.isNotEmpty ||
        bars != null ||
        report.creditsLines.isNotEmpty ||
        (plan != null && !plan.isEmpty);
    return [
      _Heading(l10n.hermesContextWindow),
      ..._window(context, report, numbers),
      if (report.categories.isNotEmpty) ...[
        const SizedBox(height: Spacing.lg),
        _Heading(l10n.hermesContextBreakdown),
        _Breakdown(report: report, numbers: numbers),
      ],
      if (!report.totals.isEmpty) ...[
        const SizedBox(height: Spacing.lg),
        _Heading(l10n.hermesContextTotals),
        ..._totals(context, report.totals, numbers),
      ],
      if (showPlan) ...[
        const SizedBox(height: Spacing.lg),
        _Heading(l10n.hermesContextPlan),
        ..._plan(context, report, gauges),
      ],
      if (report.canCompact) ...[
        const SizedBox(height: Spacing.lg),
        _Heading(l10n.hermesContextCompactSection),
        ..._compactSection(context, numbers),
      ],
    ];
  }

  List<Widget> _window(
    BuildContext context,
    HermesContextReport report,
    NumberFormat numbers,
  ) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final fraction = report.contextFraction;
    final hint = AppTypography.bodySmallStyle.copyWith(
      color: theme.textSecondary,
    );
    if (fraction == null) {
      final estimate = report.estimatedTotal;
      return [
        Text(
          estimate == null
              ? l10n.hermesContextNoWindow
              : l10n.hermesContextRequestEstimate(numbers.format(estimate)),
          style: hint,
        ),
      ];
    }
    final percent = (fraction * 100).round();
    return [
      _Bar(
        key: const ValueKey<String>('hermes-context-meter'),
        fraction: fraction,
        color: fraction >= 0.9
            ? theme.error
            : fraction >= 0.7
            ? theme.warning
            : theme.buttonPrimary,
      ),
      const SizedBox(height: Spacing.xs),
      Row(
        children: [
          Expanded(
            child: Text(
              l10n.hermesContextUsed(
                numbers.format(report.contextUsed),
                numbers.format(report.contextMax),
              ),
              style: AppTypography.standard.copyWith(color: theme.textPrimary),
            ),
          ),
          Text(
            [
              l10n.hermesContextPercentFull(percent),
              if (report.contextEstimated) l10n.hermesContextEstimatedNote,
            ].join(' · '),
            style: hint,
          ),
        ],
      ),
    ];
  }

  List<Widget> _totals(
    BuildContext context,
    HermesTokenTotals totals,
    NumberFormat numbers,
  ) {
    final l10n = AppLocalizations.of(context)!;
    String count(int value) => numbers.format(value);
    final cost = totals.costUsd;
    return [
      if (totals.input case final input?)
        _Row(l10n.hermesContextInput, count(input)),
      if (totals.output case final output?)
        _Row(l10n.hermesContextOutput, count(output)),
      if (totals.reasoning case final reasoning? when reasoning > 0)
        _Row(l10n.hermesContextReasoning, count(reasoning)),
      if (totals.cacheRead case final read? when read > 0)
        _Row(l10n.hermesContextCacheRead, count(read)),
      if (totals.cacheWrite case final written? when written > 0)
        _Row(l10n.hermesContextCacheWrite, count(written)),
      if (totals.cacheHitPercent case final hits?)
        _Row(l10n.hermesContextCacheHits, '$hits%'),
      if (totals.calls case final calls?)
        _Row(l10n.hermesContextCalls, count(calls)),
      if (totals.compressions case final compressions?)
        _Row(l10n.hermesContextCompactions, count(compressions)),
      if (cost != null)
        _Row(
          totals.costEstimated
              ? l10n.hermesContextCostEstimated
              : l10n.hermesContextCost,
          NumberFormat.simpleCurrency(
            locale: Localizations.localeOf(context).toString(),
            name: 'USD',
            decimalDigits: cost < 1 ? 4 : 2,
          ).format(cost),
        ),
    ];
  }

  List<Widget> _plan(
    BuildContext context,
    HermesContextReport report,
    List<HermesPlanGauge> gauges,
  ) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final hint = AppTypography.bodySmallStyle.copyWith(
      color: theme.textSecondary,
    );
    final plan = report.providerPlan;
    final bars = report.usageBars;
    final planName = plan?.planName ?? bars?.planName;
    final level = plan?.usageLevel;
    final limitedUntil = plan?.rateLimitedUntil;
    return [
      if (planName != null)
        Text(
          [
            planName,
            if (bars?.renews case final renews?)
              l10n.hermesContextRenews(renews),
          ].join(' · '),
          style: AppTypography.standard.copyWith(color: theme.textPrimary),
        ),
      for (final gauge in gauges)
        _GaugeRow(
          label: _gaugeLabel(l10n, gauge),
          fraction: gauge.usedFraction,
          detail: [
            l10n.hermesContextUsedPercent((gauge.usedFraction * 100).round()),
            if (gauge.resetsAt case final reset?)
              l10n.hermesContextResets(formatHermesMoment(context, reset)),
          ].join(' · '),
        ),
      if (bars?.plan case final bar?)
        _GaugeRow(
          label: bars?.planName ?? l10n.hermesContextPlan,
          fraction: bar.fill,
          detail: _barDetail(l10n, bar),
        ),
      if (bars?.topup case final bar?)
        _GaugeRow(
          label: l10n.hermesContextTopUp,
          fraction: bar.fill,
          detail: _barDetail(l10n, bar),
        ),
      if (plan?.rateLimited ?? false)
        Padding(
          padding: const EdgeInsets.only(top: Spacing.xs),
          child: Text(
            limitedUntil == null
                ? l10n.hermesContextRateLimited
                : l10n.hermesContextRateLimitedUntil(
                    formatHermesMoment(context, limitedUntil),
                  ),
            style: hint.copyWith(color: theme.warning),
          ),
        ),
      if (level != null)
        Padding(
          padding: const EdgeInsets.only(top: Spacing.xs),
          child: Text(
            l10n.hermesContextUsageLevel(switch (level) {
              'free' => l10n.hermesContextLevelFree,
              'low' => l10n.hermesContextLevelLow,
              'medium' => l10n.hermesContextLevelMedium,
              _ => l10n.hermesContextLevelTopTier,
            }),
            style: hint,
          ),
        ),
      for (final line in report.creditsLines)
        Padding(
          padding: const EdgeInsets.only(top: Spacing.xs),
          child: Text(line, style: hint),
        ),
    ];
  }

  List<Widget> _compactSection(BuildContext context, NumberFormat numbers) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final hint = AppTypography.bodySmallStyle.copyWith(
      color: theme.textSecondary,
    );
    final result = _result;
    final error = _compactError;
    return [
      Text(l10n.hermesContextCompactHint, style: hint),
      const SizedBox(height: Spacing.sm),
      AdaptiveTextField(
        key: const ValueKey<String>('hermes-context-focus'),
        controller: _focus,
        placeholder: l10n.hermesContextCompactFocus,
        maxLength: 200,
        enabled: !_compacting && !_compactionPending,
        textCapitalization: TextCapitalization.sentences,
        inputFormatters: [LengthLimitingTextInputFormatter(200)],
      ),
      const SizedBox(height: Spacing.sm),
      ConduitButton(
        key: const ValueKey<String>('hermes-context-compact'),
        text: l10n.hermesContextCompactNow,
        isFullWidth: true,
        isLoading: _compacting,
        onPressed: _compacting || _compactionPending ? null : _compact,
      ),
      if (result != null) ...[
        const SizedBox(height: Spacing.sm),
        for (final line in _resultLines(l10n, result, numbers))
          Text(
            line,
            style: AppTypography.bodySmallStyle.copyWith(
              color: theme.textPrimary,
            ),
          ),
      ],
      if (error != null) ...[
        const SizedBox(height: Spacing.sm),
        Text(error, style: hint.copyWith(color: theme.error)),
      ],
    ];
  }
}

/// What a compaction did, in a line or three.
List<String> _resultLines(
  AppLocalizations l10n,
  HermesCompactResult result,
  NumberFormat numbers,
) {
  final beforeTokens = result.beforeTokens;
  final afterTokens = result.afterTokens;
  final beforeMessages = result.beforeMessages;
  final afterMessages = result.afterMessages;
  return switch (result.outcome) {
    HermesCompactOutcome.compacted => [
      l10n.hermesContextCompacted,
      if (beforeTokens != null && afterTokens != null)
        l10n.hermesContextCompactedTokens(
          numbers.format(beforeTokens),
          numbers.format(afterTokens),
        ),
      if (beforeMessages != null && afterMessages != null)
        l10n.hermesContextCompactedMessages(beforeMessages, afterMessages),
    ],
    HermesCompactOutcome.unchanged => [l10n.hermesContextCompactUnchanged],
    HermesCompactOutcome.refused => [l10n.hermesContextCompactRefused],
    HermesCompactOutcome.aborted => [l10n.hermesContextCompactAborted],
    HermesCompactOutcome.pending => [l10n.hermesContextCompactPending],
    HermesCompactOutcome.busy => [l10n.hermesContextCompactBusy],
  };
}

String _gaugeLabel(AppLocalizations l10n, HermesPlanGauge gauge) =>
    switch (gauge.id) {
      'day' => l10n.hermesContextGaugeDay,
      'week' => l10n.hermesContextGaugeWeek,
      'month' => l10n.hermesContextGaugeMonth,
      'top_tier' => l10n.hermesContextGaugeTopTier,
      _ => gauge.title ?? gauge.id,
    };

String _barDetail(AppLocalizations l10n, HermesUsageBar bar) {
  final remaining = bar.remaining;
  final total = bar.total;
  return [
    if (remaining != null && total != null)
      l10n.hermesContextLeftOf(remaining, total)
    else
      ?remaining,
    if (bar.usedPercent case final percent?)
      l10n.hermesContextUsedPercent(percent),
  ].join(' · ');
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: Spacing.xs),
    child: Text(
      text,
      style: AppTypography.bodySmallStyle.copyWith(
        color: context.conduitTheme.textSecondary,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Spacing.xxs),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: AppTypography.standard.copyWith(
                color: theme.textSecondary,
              ),
            ),
          ),
          Text(
            value,
            style: AppTypography.standard.copyWith(
              color: theme.textPrimary,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

/// A rounded bar filled to [fraction].
class _Bar extends StatelessWidget {
  const _Bar({super.key, required this.fraction, required this.color});

  final double fraction;
  final Color color;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(AppBorderRadius.round),
    child: SizedBox(
      height: 8,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: context.conduitTheme.surfaceContainerHighest),
          FractionallySizedBox(
            alignment: AlignmentDirectional.centerStart,
            widthFactor: fraction.clamp(0, 1),
            child: ColoredBox(color: color),
          ),
        ],
      ),
    ),
  );
}

class _GaugeRow extends StatelessWidget {
  const _GaugeRow({
    required this.label,
    required this.fraction,
    required this.detail,
  });

  final String label;
  final double fraction;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            label,
            style: AppTypography.standard.copyWith(color: theme.textPrimary),
          ),
          const SizedBox(height: Spacing.xxs),
          _Bar(
            fraction: fraction,
            color: fraction >= 0.9 ? theme.warning : theme.buttonPrimary,
          ),
          if (detail.isNotEmpty) ...[
            const SizedBox(height: Spacing.xxs),
            Text(
              detail,
              style: AppTypography.bodySmallStyle.copyWith(
                color: theme.textSecondary,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The context's categories as one stacked bar and a legend.
class _Breakdown extends StatelessWidget {
  const _Breakdown({required this.report, required this.numbers});

  final HermesContextReport report;
  final NumberFormat numbers;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final palette = [
      theme.buttonPrimary,
      theme.info,
      theme.warning,
      theme.success,
      theme.textTertiary,
    ];
    final categories = report.categories;
    final total = categories.fold<int>(0, (sum, item) => sum + item.tokens);
    Color colorAt(int index) => palette[index % palette.length];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(AppBorderRadius.round),
          child: SizedBox(
            height: 8,
            child: Row(
              children: [
                for (final (index, category) in categories.indexed)
                  Expanded(
                    // Every part keeps a sliver, however small.
                    flex: (category.tokens * 1000 ~/ total).clamp(1, 1000),
                    child: ColoredBox(color: colorAt(index)),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: Spacing.xs),
        for (final (index, category) in categories.indexed)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Spacing.xxs),
            child: Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: colorAt(index),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: Spacing.sm),
                Expanded(
                  child: Text(
                    switch (category.id) {
                      'system_prompt' => l10n.hermesContextSystemPrompt,
                      'tool_definitions' => l10n.hermesContextToolDefinitions,
                      'subagent_definitions' =>
                        l10n.hermesContextSubagentDefinitions,
                      'conversation' => l10n.hermesContextConversation,
                      _ => category.label,
                    },
                    style: AppTypography.standard.copyWith(
                      color: theme.textSecondary,
                    ),
                  ),
                ),
                Text(
                  numbers.format(category.tokens),
                  style: AppTypography.standard.copyWith(
                    color: theme.textPrimary,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
