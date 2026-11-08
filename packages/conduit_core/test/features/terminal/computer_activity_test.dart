import 'package:conduit_core/features/terminal/models/computer_activity.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:test/test.dart';

ChatMessage message({
  String role = 'assistant',
  String content = '',
  List<Map<String, dynamic>>? output,
}) => ChatMessage(
  id: 'synthetic',
  role: role,
  content: content,
  output: output,
  timestamp: DateTime.utc(2026),
);

void main() {
  for (final name in [
    'browser_tabs',
    'browser_snapshot',
    'browser_screenshot',
    'browser_action',
    'desktop_screenshot',
    'desktop_action',
  ]) {
    test('recognizes the real Open Terminal operation $name', () {
      expect(
        usesComputer(
          message(
            output: [
              {'type': 'function_call', 'name': name},
            ],
          ),
        ),
        isTrue,
      );
      expect(
        usesComputer(
          message(
            output: [
              {
                'type': 'tool_call',
                'function': {'name': name},
              },
            ],
          ),
        ),
        isTrue,
      );
      expect(
        usesComputer(
          message(
            content:
                '<details type="tool_calls" name="$name" done="false">\n<summary>Working</summary>\n</details>',
          ),
        ),
        isTrue,
      );
    });
  }
  test('ignores unrelated tools, user text and code examples', () {
    const details =
        '<details type="tool_calls" name="desktop_action">\n<summary>Example</summary>\n</details>';
    for (final m in [
      message(role: 'user', content: details),
      message(content: 'Use browser_action to browse.'),
      message(content: '```html\n$details\n```'),
      message(content: '`<details type="tool_calls" name="desktop_action">`'),
      message(
        output: [
          {'type': 'function_call', 'name': 'run_command'},
        ],
      ),
      message(
        output: [
          {'type': 'computer_call'},
        ],
      ),
      message(
        content: details,
        output: [
          {'type': 'message', 'content': details},
        ],
      ),
    ]) {
      expect(usesComputer(m), isFalse);
    }
  });
}
