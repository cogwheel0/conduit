import 'package:conduit_core/utils/system_prompt.dart';
import 'package:test/test.dart';

void main() {
  test('the settings default, wherever the server keeps it', () {
    expect(systemPromptFromSettings({'system': ' Be brief. '}), 'Be brief.');
    expect(
      systemPromptFromSettings({
        'ui': {'system': 'Be kind.'},
      }),
      'Be kind.',
    );
    expect(systemPromptFromSettings({'ui': <String, dynamic>{}}), isNull);
    expect(systemPromptFromSettings({'system': '   '}), isNull);
  });

  test("the conversation's own prompt wins", () {
    expect(
      effectiveSystemPrompt(
        conversationPrompt: 'Pirate.',
        settings: {'system': 'Brief.'},
      ),
      'Pirate.',
    );
    expect(
      effectiveSystemPrompt(conversationPrompt: ' ', settings: {'system': 'B'}),
      'B',
    );
  });

  test('prepended once, never over an existing system message', () {
    final user = <String, dynamic>{'role': 'user', 'content': 'hi'};
    expect(withSystemMessage([user], 'P').first, {
      'role': 'system',
      'content': 'P',
    });
    final already = [
      <String, dynamic>{'role': 'system', 'content': 'X'},
      user,
    ];
    expect(withSystemMessage(already, 'P'), same(already));
    expect(withSystemMessage([user], null), [user]);
  });
}
