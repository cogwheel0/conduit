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
    this.contextTokens,
    this.incomplete = false,
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

  /// What the model's context window held when the reply ended: the prompt
  /// its last call read plus the answer it wrote. Null unless the usage
  /// gives both counts of one call.
  ///
  /// Not one of the figures [isEmpty] considers: it is measured against the
  /// model's context length, which the usage does not carry.
  final int? contextTokens;

  /// Whether Open WebUI marked the usage `incomplete`: some steps of the
  /// reply, a tool round say, reported none, so the figures may be low.
  final bool incomplete;

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
    // Open WebUI 0.12.5 sums input, output and total tokens over the model
    // calls of a reply (tool rounds), and keeps only the last call's count in
    // `prompt_tokens`/`completion_tokens`. A count without a rate is the
    // reply's; a rate stays with the count of the call it was measured on.
    final inputTokens = read('input_tokens');
    final outputTokens = read('output_tokens');
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
      generationCount = outputTokens ?? completionTokens;
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
      promptCount = inputTokens ?? promptTokens;
    }

    // The last call's prompt and answer. Over several calls, Open WebUI
    // 0.12.5 and Direct connections alike keep that call's counts in
    // prompt_tokens/completion_tokens and sum every call's in
    // input_tokens/output_tokens, so input/output without prompt/completion
    // are one call's (a Responses API reply), and come last. llama.cpp's
    // prompt_n leaves out the part of the prompt it reused from its cache
    // (cache_n).
    num? both(num? prompt, num? answer) =>
        prompt != null && answer != null ? prompt + answer : null;
    final contextCount =
        both(promptTokens, completionTokens) ??
        both(promptEvalCount, evalCount) ??
        both(
          promptN == null ? null : promptN + (read('cache_n') ?? 0),
          predictedN,
        ) ??
        both(inputTokens, outputTokens);

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
      // The total adds nothing when it is the two counts shown summed.
      totalTokens:
          totalTokens != null &&
              (generationCount == null ||
                  promptCount == null ||
                  totalTokens != generationCount + promptCount)
          ? totalTokens.toInt()
          : null,
      totalSeconds: seconds,
      queueSeconds: queueTime != null && queueTime > 0
          ? queueTime.toDouble()
          : null,
      loadSeconds: loadDuration != null && loadDuration > 0
          ? loadDuration / 1e9
          : null,
      contextTokens: contextCount != null && contextCount > 0
          ? contextCount.toInt()
          : null,
      incomplete: usage['incomplete'] == true,
    );
  }

  static num? _number(Object? value) => switch (value) {
    final num n => n,
    final String s => num.tryParse(s),
    _ => null,
  };
}

/// Whether [usage] reports anything. Open WebUI 0.12.5 can store only
/// `{incomplete: true}` for a reply whose provider gave no counts, which its
/// web client does not offer to show; neither does Conduit.
bool usageHasReport(Map<String, dynamic>? usage) =>
    usage != null && usage.keys.any((key) => key != 'incomplete');
