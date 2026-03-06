import 'package:checks/checks.dart';
import 'package:conduit/features/chat/services/reviewer_mode_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ReviewerModeService', () {
    group('generateResponse', () {
      group('returns non-empty string for any input', () {
        test('with a simple message', () {
          final result = ReviewerModeService.generateResponse(
            userMessage: 'anything at all',
          );
          check(result).isNotEmpty();
        });

        test('with an empty message', () {
          final result = ReviewerModeService.generateResponse(
            userMessage: '',
          );
          check(result).isNotEmpty();
        });

        test('with filename provided', () {
          final result = ReviewerModeService.generateResponse(
            userMessage: 'see my file',
            filename: 'photo.png',
          );
          check(result).isNotEmpty();
        });

        test('with voice input', () {
          final result = ReviewerModeService.generateResponse(
            userMessage: 'voice test',
            isVoiceInput: true,
          );
          check(result).isNotEmpty();
        });
      });

      group('categorizes by message keywords', () {
        test('greeting keywords produce greeting responses', () {
          for (final keyword in ['hello', 'hi', 'hey', 'greet']) {
            final result = ReviewerModeService.generateResponse(
              userMessage: keyword,
            );
            final hasGreeting =
                result.contains('help you explore') ||
                result.contains('Welcome to Conduit') ||
                result.contains('chat capabilities');
            check(hasGreeting)
                .isTrue();
          }
        });

        test('code keywords produce code responses', () {
          for (final keyword in [
            'code',
            'program',
            'function',
            'debug',
          ]) {
            final result = ReviewerModeService.generateResponse(
              userMessage: 'Tell me about $keyword',
            );
            check(result).contains('```');
          }
        });

        test('feature keywords produce feature responses', () {
          for (final keyword in [
            'feature',
            'capability',
            'what can',
            'help',
          ]) {
            final result = ReviewerModeService.generateResponse(
              userMessage: keyword,
            );
            final hasFeature =
                result.contains('Real-time streaming') ||
                result.contains('Chat with AI');
            check(hasFeature).isTrue();
          }
        });
      });

      group('filename placeholder replacement', () {
        test('replaces {filename} with provided filename', () {
          // Run multiple times to cover random selection
          final results = <String>{};
          for (var i = 0; i < 50; i++) {
            results.add(
              ReviewerModeService.generateResponse(
                userMessage: 'see my upload',
                filename: 'readme.md',
              ),
            );
          }
          for (final result in results) {
            check(result).contains('readme.md');
            check(result.contains('{filename}')).isFalse();
          }
        });

        test(
          'uses "file" as default when filename is null '
          'and general category is selected',
          () {
            final result = ReviewerModeService.generateResponse(
              userMessage: 'random question',
            );
            check(result.contains('{filename}')).isFalse();
          },
        );
      });

      group('voice input detection', () {
        test(
          'uses voice category when isVoiceInput is true '
          'and no keyword match',
          () {
            final results = <String>{};
            for (var i = 0; i < 50; i++) {
              results.add(
                ReviewerModeService.generateResponse(
                  userMessage: 'some voice text',
                  isVoiceInput: true,
                ),
              );
            }
            final allResults = results.join('\n');
            check(allResults.toLowerCase()).contains('voice');
          },
        );

        test('replaces {transcript} with user message', () {
          final results = <String>{};
          for (var i = 0; i < 50; i++) {
            results.add(
              ReviewerModeService.generateResponse(
                userMessage: 'my spoken words',
                isVoiceInput: true,
              ),
            );
          }
          for (final result in results) {
            check(result).contains('my spoken words');
            check(result.contains('{transcript}')).isFalse();
          }
        });

        test('keyword match takes priority over voice input', () {
          final result = ReviewerModeService.generateResponse(
            userMessage: 'hello there',
            isVoiceInput: true,
          );
          final hasGreeting =
              result.contains('help you explore') ||
              result.contains('Welcome to Conduit') ||
              result.contains('chat capabilities');
          check(hasGreeting).isTrue();
        });
      });

      group('fallback to general category', () {
        test('unknown message falls back to general response', () {
          final results = <String>{};
          for (var i = 0; i < 50; i++) {
            results.add(
              ReviewerModeService.generateResponse(
                userMessage: 'bananas and oranges',
              ),
            );
          }
          final allResults = results.join('\n');
          check(allResults.toLowerCase()).contains('demo');
        });

        test('replaces {query} with the user message', () {
          final result = ReviewerModeService.generateResponse(
            userMessage: 'bananas and oranges',
          );
          check(result).contains('bananas and oranges');
          check(result.contains('{query}')).isFalse();
        });
      });
    });

    group('generateStreamingResponse', () {
      test('returns non-empty string', () {
        final result = ReviewerModeService.generateStreamingResponse(
          userMessage: 'test message',
        );
        check(result).isNotEmpty();
      });

      test('respects keyword categorization', () {
        final result = ReviewerModeService.generateStreamingResponse(
          userMessage: 'show me some code',
        );
        check(result).contains('```');
      });

      test('passes filename through', () {
        final results = <String>{};
        for (var i = 0; i < 50; i++) {
          results.add(
            ReviewerModeService.generateStreamingResponse(
              userMessage: 'read my upload',
              filename: 'data.csv',
            ),
          );
        }
        for (final result in results) {
          check(result).contains('data.csv');
        }
      });

      test('passes isVoiceInput through', () {
        final results = <String>{};
        for (var i = 0; i < 50; i++) {
          results.add(
            ReviewerModeService.generateStreamingResponse(
              userMessage: 'spoken words',
              isVoiceInput: true,
            ),
          );
        }
        final allResults = results.join('\n');
        check(allResults.toLowerCase()).contains('voice');
      });
    });
  });
}
