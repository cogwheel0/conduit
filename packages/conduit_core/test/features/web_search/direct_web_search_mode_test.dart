import 'package:conduit_core/features/web_search/services/direct_web_search_mode.dart';
import 'package:test/test.dart';

void main() {
  test('recognizes providers rejecting tool definitions', () {
    // Wording as surfaced by normalizeDirectProviderErrorWithBody.
    const rejected = [
      'The provider returned HTTP 400: registry.ollama.ai/library/gemma:2b '
          'does not support tools',
      'The provider returned HTTP 400: tools param requires --jinja flag',
      'The provider returned HTTP 400: "auto" tool choice requires '
          '--enable-auto-tool-choice and --tool-call-parser to be set',
      'The provider returned HTTP 400: Unrecognized request argument '
          'supplied: tools',
      'The provider returned HTTP 422: Tool calling is not supported for '
          'this model.',
      "The provider returned HTTP 400: This model doesn't support function "
          'calling',
    ];
    for (final message in rejected) {
      expect(isDirectToolsUnsupportedError(message), isTrue, reason: message);
    }

    const unrelated = [
      // A rejected request for another reason.
      'The provider returned HTTP 400: max_tokens is too large',
      // Tool wording, but not a rejected request.
      'The provider returned HTTP 500: model does not support tools',
      'The model requested an unavailable local tool.',
      null,
    ];
    for (final message in unrelated) {
      expect(isDirectToolsUnsupportedError(message), isFalse, reason: message);
    }
  });
}
