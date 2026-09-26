import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../l10n/strings.g.dart';

/// How an answer was produced: speed, tokens, time.
///
/// The closed line is the one figure most people look for -- how fast, or
/// failing that how long -- and opening it gives the rest. The labels are
/// the mobile app's, so the two read the same.
class UsageDetails extends StatelessComponent {
  const UsageDetails(this.usage, {super.key});

  final ChatUsageDto usage;

  @override
  Component build(BuildContext context) {
    final rows = <(String, String)>[
      if (usage.generationPerSecond case final rate?)
        (
          t.app.usageTokenGeneration,
          _withCount(
            t.app.usageTokensPerSecond(speed: rate.toStringAsFixed(1)),
            usage.generationTokens,
          ),
        )
      else if (usage.generationTokens case final tokens?)
        (t.app.usageTokenGeneration, t.app.usageTokenCount(count: tokens)),
      if (usage.promptPerSecond case final rate?)
        (
          t.app.usagePromptEval,
          _withCount(
            t.app.usageTokensPerSecond(speed: rate.toStringAsFixed(1)),
            usage.promptTokens,
          ),
        )
      else if (usage.promptTokens case final tokens?)
        (t.app.usagePromptEval, t.app.usageTokenCount(count: tokens)),
      if (usage.reasoningTokens case final tokens?)
        (t.app.usageReasoningTokens, t.app.usageTokenCount(count: tokens)),
      if (usage.totalTokens case final tokens?)
        (t.app.usageTotalTokens, t.app.usageTokenCount(count: tokens)),
      if (usage.totalSeconds case final seconds?)
        (
          t.app.usageTotalDuration,
          t.app.usageSecondsFormat(seconds: seconds.toStringAsFixed(2)),
        ),
      if (usage.queueSeconds case final seconds?)
        (
          t.app.usageQueueTime,
          t.app.usageSecondsFormat(seconds: seconds.toStringAsFixed(3)),
        ),
      if (usage.loadSeconds case final seconds?)
        (
          t.app.usageLoadDuration,
          t.app.usageSecondsFormat(seconds: seconds.toStringAsFixed(2)),
        ),
    ];
    if (rows.isEmpty) return const Component.empty();

    return details(
      classes: 'text-ui-sm text-foreground-subtle',
      attributes: <String, String>{'aria-label': t.app.usageInfoTitle},
      [
        Component.element(
          tag: 'summary',
          classes: 'cursor-pointer select-none hover:text-foreground',
          children: <Component>[Component.text(_headline())],
        ),
        dl(classes: 'mt-1 grid grid-cols-[auto_1fr] gap-x-4 gap-y-0.5', [
          for (final (label, value) in rows) ...[
            dt([Component.text(label)]),
            dd(classes: 'text-foreground tabular-nums', [
              Component.text(value),
            ]),
          ],
        ]),
      ],
    );
  }

  String _headline() {
    if (usage.generationPerSecond case final rate?) {
      return t.app.usageTokensPerSecond(speed: rate.toStringAsFixed(1));
    }
    if (usage.totalSeconds case final seconds?) {
      return t.app.usageSecondsFormat(seconds: seconds.toStringAsFixed(2));
    }
    final tokens = usage.generationTokens ?? usage.totalTokens;
    return tokens != null
        ? t.app.usageTokenCount(count: tokens)
        : t.app.usageInfoTitle;
  }

  static String _withCount(String rate, int? tokens) =>
      tokens == null ? rate : '$rate · ${t.app.usageTokenCount(count: tokens)}';
}
