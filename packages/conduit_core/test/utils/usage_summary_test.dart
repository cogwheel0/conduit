import 'package:conduit_core/utils/usage_summary.dart';
import 'package:test/test.dart';

void main() {
  test('Ollama: counts over nanoseconds', () {
    final summary = UsageSummary.fromUsage(<String, dynamic>{
      'eval_count': 100,
      'eval_duration': 2e9,
      'prompt_eval_count': 50,
      'prompt_eval_duration': 5e8,
      'total_duration': 3e9,
      'load_duration': 1e9,
    });
    expect(summary.generationPerSecond, 50);
    expect(summary.generationTokens, 100);
    expect(summary.promptPerSecond, 100);
    expect(summary.promptTokens, 50);
    expect(summary.totalSeconds, 3);
    expect(summary.loadSeconds, 1);
  });

  test('Groq: counts over seconds, and the queue', () {
    final summary = UsageSummary.fromUsage(<String, dynamic>{
      'completion_tokens': 200,
      'completion_time': 0.5,
      'prompt_tokens': 30,
      'prompt_time': '0.1',
      'total_tokens': 230,
      'total_time': 0.7,
      'queue_time': 0.02,
      'completion_tokens_details': <String, dynamic>{'reasoning_tokens': 40},
    });
    expect(summary.generationPerSecond, 400);
    expect(summary.promptPerSecond, closeTo(300, 1e-9));
    expect(summary.reasoningTokens, 40);
    // Both parts known, so the total adds nothing.
    expect(summary.totalTokens, isNull);
    expect(summary.totalSeconds, 0.7);
    expect(summary.queueSeconds, 0.02);
  });

  test('llama.cpp: its own rates win', () {
    final summary = UsageSummary.fromUsage(<String, dynamic>{
      'predicted_per_second': 42.5,
      'predicted_n': 85,
      'eval_count': 1,
      'eval_duration': 1,
    });
    expect(summary.generationPerSecond, 42.5);
    expect(summary.generationTokens, 85);
  });

  test('plain OpenAI: counts only, with a total when a part is missing', () {
    final summary = UsageSummary.fromUsage(<String, dynamic>{
      'completion_tokens': 12,
      'total_tokens': 20,
    });
    expect(summary.generationPerSecond, isNull);
    expect(summary.generationTokens, 12);
    expect(summary.totalTokens, 20);
  });

  test('Open WebUI 0.12.5: usage some steps did not report is incomplete', () {
    final partial = UsageSummary.fromUsage(<String, dynamic>{
      'output_tokens': 120,
      'incomplete': true,
    });
    expect(partial.incomplete, isTrue);
    expect(partial.generationTokens, 120);
    expect(
      UsageSummary.fromUsage(<String, dynamic>{'output_tokens': 120}).incomplete,
      isFalse,
    );
  });

  test('nothing usable is empty', () {
    expect(UsageSummary.fromUsage(<String, dynamic>{'x': 'y'}).isEmpty, isTrue);
  });

  test('Open WebUI 0.12.5: a reply over tool rounds counts every call', () {
    // `prompt_tokens`/`completion_tokens` hold the last call; the canonical
    // counts are the reply's.
    final summary = UsageSummary.fromUsage(<String, dynamic>{
      'prompt_tokens': 900,
      'completion_tokens': 40,
      'input_tokens': 1500,
      'output_tokens': 120,
      'total_tokens': 1620,
    });
    expect(summary.promptTokens, 1500);
    expect(summary.generationTokens, 120);
    // The total is the two counts shown, so it is not repeated.
    expect(summary.totalTokens, isNull);
  });

  test('a rate keeps its call\'s count, and the reply\'s total shows', () {
    final summary = UsageSummary.fromUsage(<String, dynamic>{
      'completion_tokens': 40,
      'completion_time': 2,
      'prompt_tokens': 900,
      'prompt_time': 1,
      'input_tokens': 1500,
      'output_tokens': 120,
      'total_tokens': 1620,
    });
    expect(summary.generationPerSecond, 20);
    expect(summary.generationTokens, 40);
    expect(summary.promptTokens, 900);
    expect(summary.totalTokens, 1620);
  });

  test('the context window holds the last call\'s prompt and answer', () {
    int? context(Map<String, dynamic> usage) =>
        UsageSummary.fromUsage(usage).contextTokens;

    // Over tool rounds, the last call's counts, not the reply's sums.
    expect(
      context(<String, dynamic>{
        'prompt_tokens': 900,
        'completion_tokens': 40,
        'input_tokens': 1500,
        'output_tokens': 120,
      }),
      940,
    );
    expect(
      context(<String, dynamic>{'prompt_eval_count': 50, 'eval_count': 100}),
      150,
    );
    // llama.cpp counts the prompt it reused from its cache apart.
    expect(
      context(<String, dynamic>{
        'prompt_n': 10,
        'cache_n': 500,
        'predicted_n': 85,
      }),
      595,
    );
    expect(
      context(<String, dynamic>{'input_tokens': 1500, 'output_tokens': 120}),
      1620,
    );
    // One side alone says nothing about what the window held.
    expect(context(<String, dynamic>{'completion_tokens': 40}), isNull);
    expect(
      context(<String, dynamic>{'prompt_tokens': 900, 'output_tokens': 120}),
      isNull,
    );
  });

  test('usage holding only the incomplete mark reports nothing', () {
    expect(usageHasReport(<String, dynamic>{'incomplete': true}), isFalse);
    expect(usageHasReport(null), isFalse);
    expect(usageHasReport(<String, dynamic>{}), isFalse);
    expect(
      usageHasReport(<String, dynamic>{'incomplete': true, 'output_tokens': 3}),
      isTrue,
    );
  });
}
