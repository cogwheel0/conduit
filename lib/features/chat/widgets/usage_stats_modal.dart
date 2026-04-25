import 'package:flutter/material.dart';

import 'package:conduit/l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';

/// Modal bottom sheet displaying usage/performance statistics for a
/// chat response, matching Open WebUI's info button behavior.
class UsageStatsModal {
  UsageStatsModal._();

  /// Shows a bottom sheet with usage/performance statistics for the response.
  static void show(BuildContext context, Map<String, dynamic> usage) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: theme.surfaceBackground,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppBorderRadius.dialog),
        ),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(Spacing.lg),
            child: Column(
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
            ),
          ),
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

    // Parse all possible fields
    final evalCount = _parseNum(usage['eval_count']);
    final evalDuration = _parseNum(usage['eval_duration']);
    final promptEvalCount = _parseNum(usage['prompt_eval_count']);
    final promptEvalDuration = _parseNum(usage['prompt_eval_duration']);
    final completionTokens = _parseNum(usage['completion_tokens']);
    final promptTokens = _parseNum(usage['prompt_tokens']);
    final totalTokens = _parseNum(usage['total_tokens']);
    // Time fields in seconds (Groq/OpenAI extended format)
    final completionTime = _parseNum(usage['completion_time']);
    final promptTime = _parseNum(usage['prompt_time']);
    final totalTime = _parseNum(usage['total_time']);
    final queueTime = _parseNum(usage['queue_time']);
    // Time fields in nanoseconds (Ollama/llama.cpp format)
    final totalDuration = _parseNum(usage['total_duration']);
    final loadDuration = _parseNum(usage['load_duration']);
    // Reasoning tokens (OpenAI o1/o3 models, Groq)
    final completionDetails = usage['completion_tokens_details'];
    final reasoningTokens = completionDetails is Map
        ? _parseNum(completionDetails['reasoning_tokens'])
        : null;

    // llama.cpp server format: pre-calculated tokens/second values
    final predictedPerSecond = _parseNum(usage['predicted_per_second']);
    final promptPerSecond = _parseNum(usage['prompt_per_second']);
    final predictedN = _parseNum(usage['predicted_n']);
    final promptN = _parseNum(usage['prompt_n']);

    // --- Token Generation Speed ---
    // Priority: llama.cpp direct > Ollama calculated > Groq/OpenAI > count only
    if (predictedPerSecond != null && predictedPerSecond > 0) {
      // llama.cpp server: pre-calculated tokens/second
      stats.add(
        _UsageStatRow(
          label: l10n.usageTokenGeneration,
          value: l10n.usageTokensPerSecond(
            predictedPerSecond.toStringAsFixed(1),
          ),
          detail: predictedN != null
              ? l10n.usageTokenCount(predictedN.toInt())
              : null,
          theme: theme,
        ),
      );
    } else if (evalCount != null && evalDuration != null && evalDuration > 0) {
      // Ollama: duration in nanoseconds
      final tgSpeed = evalCount / (evalDuration / 1e9);
      stats.add(
        _UsageStatRow(
          label: l10n.usageTokenGeneration,
          value: l10n.usageTokensPerSecond(tgSpeed.toStringAsFixed(1)),
          detail: l10n.usageTokenCount(evalCount.toInt()),
          theme: theme,
        ),
      );
    } else if (completionTokens != null &&
        completionTime != null &&
        completionTime > 0) {
      // Groq/OpenAI extended: time in seconds
      final tgSpeed = completionTokens / completionTime;
      stats.add(
        _UsageStatRow(
          label: l10n.usageTokenGeneration,
          value: l10n.usageTokensPerSecond(tgSpeed.toStringAsFixed(1)),
          detail: l10n.usageTokenCount(completionTokens.toInt()),
          theme: theme,
        ),
      );
    } else if (completionTokens != null) {
      // Basic OpenAI: token count only
      stats.add(
        _UsageStatRow(
          label: l10n.usageTokenGeneration,
          value: l10n.usageTokenCount(completionTokens.toInt()),
          theme: theme,
        ),
      );
    }

    // --- Prompt Processing Speed ---
    // Priority: llama.cpp direct > Ollama calculated > Groq/OpenAI > count only
    if (promptPerSecond != null && promptPerSecond > 0) {
      // llama.cpp server: pre-calculated tokens/second
      stats.add(
        _UsageStatRow(
          label: l10n.usagePromptEval,
          value: l10n.usageTokensPerSecond(promptPerSecond.toStringAsFixed(1)),
          detail: promptN != null
              ? l10n.usageTokenCount(promptN.toInt())
              : null,
          theme: theme,
        ),
      );
    } else if (promptEvalCount != null &&
        promptEvalDuration != null &&
        promptEvalDuration > 0) {
      // Ollama: duration in nanoseconds
      final ppSpeed = promptEvalCount / (promptEvalDuration / 1e9);
      stats.add(
        _UsageStatRow(
          label: l10n.usagePromptEval,
          value: l10n.usageTokensPerSecond(ppSpeed.toStringAsFixed(1)),
          detail: l10n.usageTokenCount(promptEvalCount.toInt()),
          theme: theme,
        ),
      );
    } else if (promptTokens != null && promptTime != null && promptTime > 0) {
      // Groq/OpenAI extended: time in seconds
      final ppSpeed = promptTokens / promptTime;
      stats.add(
        _UsageStatRow(
          label: l10n.usagePromptEval,
          value: l10n.usageTokensPerSecond(ppSpeed.toStringAsFixed(1)),
          detail: l10n.usageTokenCount(promptTokens.toInt()),
          theme: theme,
        ),
      );
    } else if (promptTokens != null) {
      // Basic OpenAI: token count only
      stats.add(
        _UsageStatRow(
          label: l10n.usagePromptEval,
          value: l10n.usageTokenCount(promptTokens.toInt()),
          theme: theme,
        ),
      );
    }

    // --- Reasoning Tokens (for o1/o3 models) ---
    if (reasoningTokens != null && reasoningTokens > 0) {
      stats.add(
        _UsageStatRow(
          label: l10n.usageReasoningTokens,
          value: l10n.usageTokenCount(reasoningTokens.toInt()),
          theme: theme,
        ),
      );
    }

    // --- Total Tokens (if not already shown via completion + prompt) ---
    if (totalTokens != null &&
        (completionTokens == null || promptTokens == null)) {
      stats.add(
        _UsageStatRow(
          label: l10n.usageTotalTokens,
          value: l10n.usageTokenCount(totalTokens.toInt()),
          theme: theme,
        ),
      );
    }

    // --- Total Duration ---
    if (totalDuration != null && totalDuration > 0) {
      // Ollama/llama.cpp: nanoseconds
      final totalSec = totalDuration / 1e9;
      stats.add(
        _UsageStatRow(
          label: l10n.usageTotalDuration,
          value: l10n.usageSecondsFormat(totalSec.toStringAsFixed(2)),
          theme: theme,
        ),
      );
    } else if (totalTime != null && totalTime > 0) {
      // Groq/OpenAI extended: seconds
      stats.add(
        _UsageStatRow(
          label: l10n.usageTotalDuration,
          value: l10n.usageSecondsFormat(totalTime.toStringAsFixed(2)),
          theme: theme,
        ),
      );
    }

    // --- Queue Time (Groq) ---
    if (queueTime != null && queueTime > 0) {
      stats.add(
        _UsageStatRow(
          label: l10n.usageQueueTime,
          value: l10n.usageSecondsFormat(queueTime.toStringAsFixed(3)),
          theme: theme,
        ),
      );
    }

    // --- Model Load Time (Ollama) ---
    if (loadDuration != null && loadDuration > 0) {
      final loadSec = loadDuration / 1e9;
      stats.add(
        _UsageStatRow(
          label: l10n.usageLoadDuration,
          value: l10n.usageSecondsFormat(loadSec.toStringAsFixed(2)),
          theme: theme,
        ),
      );
    }

    return stats;
  }

  /// Safely parse a number from dynamic value.
  static num? _parseNum(dynamic value) {
    if (value == null) return null;
    if (value is num) return value;
    if (value is String) return num.tryParse(value);
    return null;
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
