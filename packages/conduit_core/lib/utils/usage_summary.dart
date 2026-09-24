/// What an answer's `usage` block says, reduced to the figures people read.
///
/// Providers report usage in at least four shapes: OpenAI's token counts,
/// Groq's counts plus seconds, Ollama's counts plus nanoseconds, and
/// llama.cpp's precomputed rates. This picks the best figure each shape
/// offers, in that order of preference, so both apps show the same numbers
/// for the same answer.
class UsageSummary {
  const UsageSummary({
    this.generationPerSecond,
    this.generationTokens,
    this.promptPerSecond,
    this.promptTokens,
    this.reasoningTokens,
    this.totalTokens,
    this.totalSeconds,
    this.queueSeconds,
    this.loadSeconds,
  });

  /// Tokens per second while answering, when the provider timed it.
  final double? generationPerSecond;
  final int? generationTokens;

  /// Tokens per second while reading the prompt, when timed.
  final double? promptPerSecond;
  final int? promptTokens;

  /// Tokens spent thinking, for models that report them separately.
  final int? reasoningTokens;

  /// Only when the parts are not both known: otherwise it adds nothing.
  final int? totalTokens;

  final double? totalSeconds;

  /// Time spent waiting for capacity (Groq).
  final double? queueSeconds;

  /// Time spent loading the model into memory (Ollama).
  final double? loadSeconds;

  bool get isEmpty =>
      generationPerSecond == null &&
      generationTokens == null &&
      promptPerSecond == null &&
      promptTokens == null &&
      reasoningTokens == null &&
      totalTokens == null &&
      totalSeconds == null &&
      queueSeconds == null &&
      loadSeconds == null;

  factory UsageSummary.fromUsage(Map<String, dynamic> usage) {
    num? read(String key) => _number(usage[key]);

    final evalCount = read('eval_count');
    final evalDuration = read('eval_duration');
    final promptEvalCount = read('prompt_eval_count');
    final promptEvalDuration = read('prompt_eval_duration');
    final completionTokens = read('completion_tokens');
    final promptTokens = read('prompt_tokens');
    final totalTokens = read('total_tokens');
    final completionTime = read('completion_time');
    final promptTime = read('prompt_time');
    final totalTime = read('total_time');
    final queueTime = read('queue_time');
    final totalDuration = read('total_duration');
    final loadDuration = read('load_duration');
    final details = usage['completion_tokens_details'];
    final reasoning = details is Map
        ? _number(details['reasoning_tokens'])
        : null;
    final predictedPerSecond = read('predicted_per_second');
    final promptPerSecond = read('prompt_per_second');
    final predictedN = read('predicted_n');
    final promptN = read('prompt_n');

    // Generation: llama.cpp's own rate, then Ollama's nanoseconds, then
    // Groq/OpenAI's seconds, then a bare count.
    double? generationRate;
    num? generationCount;
    if (predictedPerSecond != null && predictedPerSecond > 0) {
      generationRate = predictedPerSecond.toDouble();
      generationCount = predictedN;
    } else if (evalCount != null && evalDuration != null && evalDuration > 0) {
      generationRate = evalCount / (evalDuration / 1e9);
      generationCount = evalCount;
    } else if (completionTokens != null &&
        completionTime != null &&
        completionTime > 0) {
      generationRate = completionTokens / completionTime;
      generationCount = completionTokens;
    } else {
      generationCount = completionTokens;
    }

    double? promptRate;
    num? promptCount;
    if (promptPerSecond != null && promptPerSecond > 0) {
      promptRate = promptPerSecond.toDouble();
      promptCount = promptN;
    } else if (promptEvalCount != null &&
        promptEvalDuration != null &&
        promptEvalDuration > 0) {
      promptRate = promptEvalCount / (promptEvalDuration / 1e9);
      promptCount = promptEvalCount;
    } else if (promptTokens != null && promptTime != null && promptTime > 0) {
      promptRate = promptTokens / promptTime;
      promptCount = promptTokens;
    } else {
      promptCount = promptTokens;
    }

    double? seconds;
    if (totalDuration != null && totalDuration > 0) {
      seconds = totalDuration / 1e9;
    } else if (totalTime != null && totalTime > 0) {
      seconds = totalTime.toDouble();
    }

    return UsageSummary(
      generationPerSecond: generationRate,
      generationTokens: generationCount?.toInt(),
      promptPerSecond: promptRate,
      promptTokens: promptCount?.toInt(),
      reasoningTokens: reasoning != null && reasoning > 0
          ? reasoning.toInt()
          : null,
      totalTokens:
          totalTokens != null &&
              (completionTokens == null || promptTokens == null)
          ? totalTokens.toInt()
          : null,
      totalSeconds: seconds,
      queueSeconds: queueTime != null && queueTime > 0
          ? queueTime.toDouble()
          : null,
      loadSeconds: loadDuration != null && loadDuration > 0
          ? loadDuration / 1e9
          : null,
    );
  }

  static num? _number(Object? value) => switch (value) {
    final num n => n,
    final String s => num.tryParse(s),
    _ => null,
  };
}
