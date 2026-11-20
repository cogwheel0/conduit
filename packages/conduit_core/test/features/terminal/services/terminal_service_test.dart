import 'package:conduit_core/features/terminal/models/terminal_models.dart';
import 'package:conduit_core/features/terminal/services/terminal_service.dart';
import 'package:test/test.dart';

void main() {
  test('parses chat context availability and saved-chat scoping', () {
    expect(parseTerminalChatContextForTest(null), (
      available: true,
      requiresSavedChat: false,
    ));
    expect(parseTerminalChatContextForTest(const {'chat': false}), (
      available: false,
      requiresSavedChat: false,
    ));
    expect(
      parseTerminalChatContextForTest(const {
        'chat': {'context_id': 'chat_id'},
      }),
      (available: true, requiresSavedChat: true),
    );
    // Open WebUI 0.13.4 lists a terminal template with the scope its
    // machines are made for, and no `contexts`.
    expect(parseTerminalChatContextForTest(null, scope: 'chat'), (
      available: true,
      requiresSavedChat: true,
    ));
    expect(parseTerminalChatContextForTest(null, scope: 'user'), (
      available: true,
      requiresSavedChat: false,
    ));

    final scoped = TerminalServerInfo(
      kind: TerminalServerKind.system,
      selectionId: 'scoped',
      baseUrl: Uri.parse('https://example.test'),
      requiresSavedChatContext: true,
    );
    expect(scoped.isAvailableForChatScope('sidebar-terminal'), isFalse);
    expect(scoped.isAvailableForChatScope('local:draft'), isFalse);
    expect(scoped.isAvailableForChatScope('temporary:socket'), isFalse);
    expect(scoped.isAvailableForChatScope('channel:team'), isFalse);
    expect(scoped.isAvailableForChatScope('saved-chat'), isTrue);
  });
}
