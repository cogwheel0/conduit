import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/features/direct_connections/services/direct_adapter_helpers.dart';
import 'package:conduit_core/features/direct_connections/services/direct_chat_bridge.dart';
import 'package:test/test.dart';

void main() {
  group('DirectToolLoopGuard', () {
    test('asks for the answer after failed calls in a row', () {
      final guard = DirectToolLoopGuard();
      for (var call = 1; call < kDirectMaxConsecutiveToolFailures; call++) {
        guard
          ..recordResult(isError: true)
          ..completeRound();
        expect(guard.mustAnswer, isFalse);
      }
      guard
        ..recordResult(isError: true)
        ..completeRound();
      expect(guard.mustAnswer, isTrue);
    });

    test('a successful call starts the failure count again', () {
      final guard = DirectToolLoopGuard();
      for (var round = 0; round < 10; round++) {
        for (var call = 1; call < kDirectMaxConsecutiveToolFailures; call++) {
          guard.recordResult(isError: true);
        }
        guard
          ..recordResult(isError: false)
          ..completeRound();
        expect(guard.mustAnswer, isFalse);
      }
    });

    test('successful rounds run until the internal backstop', () {
      final guard = DirectToolLoopGuard();
      for (var round = 1; round < kDirectToolRoundBackstop; round++) {
        guard
          ..recordResult(isError: false)
          ..completeRound();
        expect(guard.mustAnswer, isFalse, reason: 'round $round');
      }
      guard
        ..recordResult(isError: false)
        ..completeRound();
      expect(guard.mustAnswer, isTrue);
    });
  });

  test('the final-answer note follows the last tool result', () {
    expect(
      withDirectFinalAnswerNote('{"results":[]}'),
      '{"results":[]}\n\n$kDirectFinalAnswerToolNote',
    );
    expect(withDirectFinalAnswerNote('  '), kDirectFinalAnswerToolNote);
  });

  test('recognizes the stored no-answer error', () {
    expect(
      isDirectToolLoopNoAnswerError(kDirectToolLoopNoAnswerMessage),
      isTrue,
    );
    expect(isDirectToolLoopNoAnswerError('The provider failed.'), isFalse);
    expect(isDirectToolLoopNoAnswerError(null), isFalse);
  });

  group('effectiveDirectMaxImagesPerRequest', () {
    test('keeps the setting for HTTP providers', () {
      expect(
        effectiveDirectMaxImagesPerRequest(
          adapterKey: kOpenAiCompatibleAdapterKey,
          configured: 30,
        ),
        30,
      );
      expect(
        effectiveDirectMaxImagesPerRequest(
          adapterKey: kOllamaAdapterKey,
          configured: 0,
        ),
        kMinDirectMaxImagesPerRequest,
      );
    });

    test('caps Apple Foundation Models at what the bridge accepts', () {
      expect(
        effectiveDirectMaxImagesPerRequest(
          adapterKey: kApplePccAdapterKey,
          configured: kDefaultDirectMaxImagesPerRequest,
        ),
        kApplePccMaxImages,
      );
      expect(
        effectiveDirectMaxImagesPerRequest(
          adapterKey: kApplePccAdapterKey,
          configured: 2,
        ),
        2,
      );
    });
  });

  group('isDirectTooManyImagesError', () {
    test('matches provider refusals about the image count', () {
      for (final message in const [
        'The provider returned HTTP 400: Too many images provided. '
            'Maximum of 5 images per request.',
        'The provider returned HTTP 400: At most 1 image(s) may be provided '
            'in one prompt.',
        'The provider returned HTTP 500: this model only supports one image '
            'while more than one image requested',
        'The provider returned HTTP 413: You can send a maximum of 8 images.',
      ]) {
        expect(isDirectTooManyImagesError(message), isTrue, reason: message);
      }
    });

    test('ignores other failures and Conduit preflight messages', () {
      for (final message in const [
        'The provider returned HTTP 400: Invalid image URL.',
        'The provider returned HTTP 429: Too many requests.',
        'Direct chats support up to 10 images per request.',
        'Direct chats support up to 4 images per message.',
      ]) {
        expect(isDirectTooManyImagesError(message), isFalse, reason: message);
      }
      expect(isDirectTooManyImagesError(null), isFalse);
    });
  });
}
