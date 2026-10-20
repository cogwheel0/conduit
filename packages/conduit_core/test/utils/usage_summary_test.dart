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

  test('nothing usable is empty', () {
    expect(UsageSummary.fromUsage(<String, dynamic>{'x': 'y'}).isEmpty, isTrue);
  });
}
