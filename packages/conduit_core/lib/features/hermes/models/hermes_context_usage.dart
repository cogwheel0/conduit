import 'package:conduit_core/features/hermes/services/hermes_identifier.dart';

/// The most context categories, plan gauges and credit lines a report keeps.
const int _kMaxHermesContextRows = 16;

/// One part of what fills a chat's context window.
final class HermesContextCategory {
  const HermesContextCategory({
    required this.id,
    required this.label,
    required this.tokens,
  });

  /// Hermes' stable id (`system_prompt`, `tool_definitions`, ...).
  final String id;

  /// Hermes' own name for it, shown for ids Conduit has no words for.
  final String label;
  final int tokens;
}

/// A chat's token counters so far.
final class HermesTokenTotals {
  const HermesTokenTotals({
    this.input,
    this.output,
    this.reasoning,
    this.cacheRead,
    this.cacheWrite,
    this.cacheHitPercent,
    this.total,
    this.calls,
    this.compressions,
    this.costUsd,
    this.costEstimated = false,
  });

  final int? input;
  final int? output;
  final int? reasoning;
  final int? cacheRead;
  final int? cacheWrite;
  final int? cacheHitPercent;
  final int? total;
  final int? calls;
  final int? compressions;
  final double? costUsd;

  /// Whether [costUsd] is Hermes' estimate rather than the provider's bill.
  final bool costEstimated;

  /// Whether no counter the sheet shows has anything to say.
  bool get isEmpty =>
      (input ?? 0) == 0 &&
      (output ?? 0) == 0 &&
      (reasoning ?? 0) == 0 &&
      (cacheRead ?? 0) == 0 &&
      (cacheWrite ?? 0) == 0 &&
      (cacheHitPercent ?? 0) == 0 &&
      (total ?? 0) == 0 &&
      (calls ?? 0) == 0 &&
      (compressions ?? 0) == 0 &&
      costUsd == null;
}

/// One plan allowance: how much of it is used and when it resets.
final class HermesPlanGauge {
  const HermesPlanGauge({
    required this.id,
    required this.usedFraction,
    this.title,
    this.resetsAt,
  });

  /// `day`, `week`, `month`, `top_tier`, or another server id.
  final String id;

  /// Hermes' words for an id Conduit has none for.
  final String? title;

  /// 0 (untouched) to 1 (used up).
  final double usedFraction;
  final DateTime? resetsAt;
}

/// One of Hermes' dollar bars (`usage.bars`): a plan or top-up balance.
final class HermesUsageBar {
  const HermesUsageBar({
    required this.kind,
    required this.fill,
    this.remaining,
    this.total,
    this.spent,
    this.usedPercent,
  });

  /// `plan` or `topup`.
  final String kind;

  /// 0 to 1, as Hermes fills the bar.
  final double fill;

  /// Amounts Hermes formats itself (`$4.20`).
  final String? remaining;
  final String? total;
  final String? spent;
  final int? usedPercent;
}

/// The account's subscription and top-up balance (`usage.bars`).
final class HermesUsageBars {
  const HermesUsageBars({
    this.planName,
    this.renews,
    this.plan,
    this.topup,
    this.totalSpendable,
  });

  final String? planName;

  /// When the plan renews, as Hermes words it.
  final String? renews;
  final HermesUsageBar? plan;
  final HermesUsageBar? topup;
  final String? totalSpendable;
}

/// What the chat's provider says about its plan and limits
/// (`model.options`, the current provider's row).
final class HermesProviderPlan {
  const HermesProviderPlan({
    this.provider,
    this.planName,
    this.gauges = const [],
    this.rateLimited = false,
    this.rateLimitedUntil,
    this.usageLevel,
  });

  final String? provider;
  final String? planName;
  final List<HermesPlanGauge> gauges;

  /// Whether the account or the chat's model is rate limited now.
  final bool rateLimited;
  final DateTime? rateLimitedUntil;

  /// How much the chat's model draws on the plan: `free`, `low`, `medium`
  /// or `top_tier`.
  final String? usageLevel;

  bool get isEmpty =>
      planName == null && gauges.isEmpty && !rateLimited && usageLevel == null;
}

/// A chat's context window, token totals, plan allowances, and whether it
/// can be compacted, as one connection reports them.
final class HermesContextReport {
  const HermesContextReport({
    this.model,
    this.contextUsed,
    this.contextMax,
    this.contextEstimated = false,
    this.estimatedTotal,
    this.categories = const [],
    this.totals = const HermesTokenTotals(),
    this.planGauges = const [],
    this.creditsLines = const [],
    this.usageBars,
    this.providerPlan,
    this.canCompact = false,
  });

  final String? model;

  /// Tokens the model read on its last call, out of [contextMax].
  final int? contextUsed;
  final int? contextMax;
  final bool contextEstimated;

  /// Hermes' estimate of a full request: prompt, tools and transcript.
  final int? estimatedTotal;
  final List<HermesContextCategory> categories;
  final HermesTokenTotals totals;

  /// Plan allowances the session reports (`plan_gauge`).
  final List<HermesPlanGauge> planGauges;

  /// Hermes' own credit lines (Nous accounts), shown as they are.
  final List<String> creditsLines;
  final HermesUsageBars? usageBars;
  final HermesProviderPlan? providerPlan;

  /// Whether this connection can compact the chat on the server.
  final bool canCompact;

  /// How full the window is, 0 to 1, or null without a window size.
  double? get contextFraction {
    final used = contextUsed;
    final max = contextMax;
    if (used == null || max == null || max <= 0) return null;
    return (used / max).clamp(0, 1).toDouble();
  }
}

/// How a compaction ended.
enum HermesCompactOutcome {
  /// Older messages were summarized.
  compacted,

  /// Nothing could be removed (a short chat).
  unchanged,

  /// A summary would have been longer than what it replaces.
  refused,

  /// The summary failed; no messages were removed.
  aborted,

  /// Still running on the server; the chat refreshes when it finishes.
  pending,

  /// Another compaction holds the chat.
  busy,
}

/// What Hermes reported about one compaction.
final class HermesCompactResult {
  const HermesCompactResult({
    required this.outcome,
    this.beforeTokens,
    this.afterTokens,
    this.beforeMessages,
    this.afterMessages,
  });

  /// Reads a legacy `session.compress` result or a canonical
  /// `session.mutate compress` receipt.
  factory HermesCompactResult.fromJson(Map<String, dynamic> json) {
    final summary = json['summary'];
    final report = summary is Map ? summary : const <Object?, Object?>{};
    final status = json['status'];
    final outcome = json['lock_held'] == true || json['compressed'] == false
        ? HermesCompactOutcome.busy
        : status == 'pending'
        ? HermesCompactOutcome.pending
        : report['refused_would_grow'] == true
        ? HermesCompactOutcome.refused
        : report['aborted'] == true || status == 'aborted'
        ? HermesCompactOutcome.aborted
        : report['noop'] == true || status == 'noop'
        ? HermesCompactOutcome.unchanged
        : HermesCompactOutcome.compacted;
    // A session authority reports the estimate only in its token line
    // (`Approx request size: ~12,351 → ~4,020 tokens`).
    final line = report['token_line'];
    final match = line is String && line.length <= 256
        ? RegExp(r'~([\d,]+)\s*→\s*~([\d,]+)').firstMatch(line)
        : null;
    int? lineTokens(int group) =>
        int.tryParse(match?.group(group)?.replaceAll(',', '') ?? '');
    return HermesCompactResult(
      outcome: outcome,
      beforeTokens: _count(json['before_tokens']) ?? lineTokens(1),
      afterTokens: _count(json['after_tokens']) ?? lineTokens(2),
      beforeMessages: _count(json['before_messages']),
      afterMessages:
          _count(json['after_messages']) ?? _count(json['message_count']),
    );
  }

  final HermesCompactOutcome outcome;
  final int? beforeTokens;
  final int? afterTokens;
  final int? beforeMessages;
  final int? afterMessages;

  /// Whether the chat's transcript changed on the server.
  bool get changed => outcome == HermesCompactOutcome.compacted;
}

/// Builds a Desktop Gateway chat's report from what its reads returned;
/// a null read is one the gateway does not offer or that failed.
HermesContextReport hermesDesktopContextReport({
  Map<String, dynamic>? usage,
  Map<String, dynamic>? stats,
  Map<String, dynamic>? breakdown,
  Map<String, dynamic>? bars,
  Map<String, dynamic>? modelOptions,
  Map<String, dynamic>? lastTurnUsage,
  bool canCompact = true,
}) {
  final tui = usage ?? (stats == null ? null : hermesStatsAsUsage(stats));
  final sources = [?tui, ?breakdown, ?lastTurnUsage];
  final windowSource = sources.firstWhere(
    (source) => (_count(source['context_max']) ?? 0) > 0,
    orElse: () => tui ?? const <String, dynamic>{},
  );
  final gauge = _planGauge(tui?['plan_gauge']);
  return HermesContextReport(
    model: _text(tui?['model'], 256) ?? _text(breakdown?['model'], 256),
    contextUsed: _count(windowSource['context_used']),
    contextMax: _positive(windowSource['context_max']),
    contextEstimated: windowSource['context_estimated'] == true,
    estimatedTotal: _positive(breakdown?['estimated_total']),
    categories: _categories(breakdown?['categories']),
    totals: tui == null ? const HermesTokenTotals() : _totals(tui),
    planGauges: [?gauge],
    creditsLines: _lines(tui?['credits_lines']),
    usageBars: bars == null ? null : _usageBars(bars),
    providerPlan: modelOptions == null ? null : _providerPlan(modelOptions),
    canCompact: canCompact,
  );
}

/// Builds an API server chat's report from its session row: token and cost
/// totals only, since the API server reports no context window.
HermesContextReport hermesRestContextReport(Map<String, dynamic> session) {
  final actual = _money(session['actual_cost_usd']);
  final estimated = _money(session['estimated_cost_usd']);
  final input = _count(session['input_tokens']);
  final output = _count(session['output_tokens']);
  return HermesContextReport(
    model: _text(session['model'], 256),
    totals: HermesTokenTotals(
      input: input,
      output: output,
      reasoning: _count(session['reasoning_tokens']),
      cacheRead: _count(session['cache_read_tokens']),
      cacheWrite: _count(session['cache_write_tokens']),
      total: input == null && output == null
          ? null
          : (input ?? 0) + (output ?? 0),
      calls: _count(session['api_call_count']),
      costUsd: actual ?? estimated,
      costEstimated: actual == null && estimated != null,
    ),
  );
}

/// A session authority's `session.stats` counters in the shape legacy
/// `session.usage` answers, as Hermes' own `tui_usage` maps them.
Map<String, dynamic> hermesStatsAsUsage(Map<String, dynamic> stats) {
  int count(String key) => _count(stats[key]) ?? 0;
  final usage = <String, dynamic>{
    'model': stats['model'],
    'input': count('input_tokens') > 0
        ? count('input_tokens')
        : count('prompt_tokens'),
    'output': count('output_tokens') > 0
        ? count('output_tokens')
        : count('completion_tokens'),
    'reasoning': count('reasoning_tokens'),
    'total': count('total_tokens'),
    'calls': count('api_calls'),
    'cache_read': count('cache_read_tokens'),
    'cache_write': count('cache_write_tokens'),
  };
  final used = count('last_prompt_tokens');
  final max = count('context_length');
  if (used > 0 && max > 0) {
    final source = stats['context_source'] ?? 'provider_usage';
    usage
      ..['context_used'] = used < max ? used : max
      ..['context_max'] = max
      ..['context_estimated'] = source != 'provider_usage';
  }
  if (stats['context_source'] != null) {
    usage['compressions'] = count('compression_count');
  }
  final prompt = count('prompt_tokens');
  final cacheRead = count('cache_read_tokens');
  if (prompt > 0 && cacheRead > 0) {
    usage['cache_hit_pct'] = (cacheRead / prompt * 100).round().clamp(0, 100);
  }
  if (stats['plan_gauge'] is Map) usage['plan_gauge'] = stats['plan_gauge'];
  return usage;
}

HermesTokenTotals _totals(Map<String, dynamic> usage) {
  final cost = _money(usage['cost_usd']);
  return HermesTokenTotals(
    input: _count(usage['input']),
    output: _count(usage['output']),
    reasoning: _count(usage['reasoning']),
    cacheRead: _count(usage['cache_read']),
    cacheWrite: _count(usage['cache_write']),
    cacheHitPercent: _percent(usage['cache_hit_pct']),
    total: _count(usage['total']),
    calls: _count(usage['calls']),
    compressions: _count(usage['compressions']),
    costUsd: cost,
    costEstimated: cost != null && usage['cost_status'] != 'actual',
  );
}

List<HermesContextCategory> _categories(Object? value) {
  if (value is! List) return const [];
  final categories = <HermesContextCategory>[];
  for (final raw in value.take(_kMaxHermesContextRows)) {
    if (raw is! Map) continue;
    final id = validateHermesOpaqueIdentifier(raw['id']);
    final tokens = _count(raw['tokens']);
    if (id == null || tokens == null || tokens == 0) continue;
    categories.add(
      HermesContextCategory(
        id: id,
        label: _text(raw['label'], 80) ?? id,
        tokens: tokens,
      ),
    );
  }
  return categories;
}

HermesPlanGauge? _planGauge(Object? value) {
  if (value is! Map) return null;
  final id = validateHermesOpaqueIdentifier(value['id']);
  final used = _count(value['used_bp']);
  if (id == null || used == null) return null;
  return HermesPlanGauge(
    id: id,
    title: _text(value['label'], 80),
    usedFraction: (used / 10000).clamp(0, 1).toDouble(),
    resetsAt: _epochMilliseconds(value['resets_at_ms']),
  );
}

HermesUsageBars? _usageBars(Map<String, dynamic> bars) {
  if (bars['available'] != true) return null;
  final plan = _usageBar(bars['plan_bar']);
  final topup = _usageBar(bars['topup_bar']);
  final planName = _text(bars['plan_name'], 80);
  if (plan == null && topup == null && planName == null) return null;
  return HermesUsageBars(
    planName: planName,
    renews: _text(bars['renews_display'], 80),
    plan: plan,
    topup: topup,
    totalSpendable: _text(bars['total_spendable_display'], 40),
  );
}

HermesUsageBar? _usageBar(Object? value) {
  if (value is! Map) return null;
  final kind = value['kind'];
  final fill = value['fill_fraction'];
  if ((kind != 'plan' && kind != 'topup') || fill is! num || !fill.isFinite) {
    return null;
  }
  return HermesUsageBar(
    kind: kind as String,
    fill: fill.clamp(0, 1).toDouble(),
    remaining: _text(value['remaining_display'], 40),
    total: _text(value['total_display'], 40),
    spent: _text(value['spent_display'], 40),
    usedPercent: _percent(value['pct_used']),
  );
}

HermesProviderPlan? _providerPlan(Map<String, dynamic> options) {
  final providers = options['providers'];
  if (providers is! List) return null;
  final current = validateHermesOpaqueIdentifier(options['provider']);
  final model = validateHermesOpaqueIdentifier(options['model']);
  Map? row;
  for (final candidate in providers.take(1000)) {
    if (candidate is! Map) continue;
    if (candidate['is_current'] == true ||
        (current != null && candidate['slug'] == current)) {
      row = candidate;
      break;
    }
  }
  if (row == null) return null;
  final planUsage = row['plan_usage'];
  final plan = planUsage is Map ? planUsage : const <Object?, Object?>{};
  final gauges = plan['gauges'];
  final limit = row['limit'];
  final limitMap = limit is Map ? limit : const <Object?, Object?>{};
  final limitedModels = limitMap['models'];
  final modelLimited =
      limitedModels is Map && model != null && limitedModels[model] != null;
  final levels = row['usage_levels'];
  final level = levels is Map && model != null ? levels[model] : null;
  final result = HermesProviderPlan(
    provider:
        _text(row['name'], 80) ?? validateHermesOpaqueIdentifier(row['slug']),
    planName: _text(plan['plan'], 80),
    gauges: [
      if (gauges is List)
        for (final raw in gauges.take(_kMaxHermesContextRows))
          ?_providerGauge(raw),
    ],
    rateLimited: limitMap['scope'] == 'account' || modelLimited,
    rateLimitedUntil: limitMap['scope'] == 'account'
        ? _isoTime(limitMap['resets_at'])
        : modelLimited
        ? _isoTime(limitedModels[model])
        : null,
    usageLevel: switch (level) {
      'free' || 'low' || 'medium' || 'top_tier' => level as String,
      _ => null,
    },
  );
  return result.isEmpty ? null : result;
}

HermesPlanGauge? _providerGauge(Object? value) {
  if (value is! Map) return null;
  final id = validateHermesOpaqueIdentifier(value['label']);
  final left = value['left_fraction'];
  if (id == null || left is! num || !left.isFinite) return null;
  return HermesPlanGauge(
    id: id,
    title: _text(value['title'], 80),
    usedFraction: (1 - left.clamp(0, 1)).toDouble(),
    resetsAt: _epochMilliseconds(value['resets_at_ms']),
  );
}

List<String> _lines(Object? value) => [
  if (value is List)
    for (final line in value.take(_kMaxHermesContextRows)) ?_text(line, 200),
];

String? _text(Object? value, int max) =>
    validateHermesBoundedString(value, maxCharacters: max);

int? _count(Object? value) =>
    value is int && value >= 0 && value < 1 << 53 ? value : null;

int? _positive(Object? value) {
  final count = _count(value);
  return count == null || count == 0 ? null : count;
}

int? _percent(Object? value) =>
    value is num && value.isFinite ? value.round().clamp(0, 100) : null;

double? _money(Object? value) =>
    value is num && value.isFinite && value >= 0 && value < 1e9
    ? value.toDouble()
    : null;

DateTime? _epochMilliseconds(Object? value) =>
    value is int && value > 0 && value <= 253402300799000
    ? DateTime.fromMillisecondsSinceEpoch(value, isUtc: true)
    : null;

DateTime? _isoTime(Object? value) {
  final text = _text(value, 64);
  return text == null ? null : DateTime.tryParse(text)?.toUtc();
}
