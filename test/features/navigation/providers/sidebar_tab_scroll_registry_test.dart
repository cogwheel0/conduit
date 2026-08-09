import 'package:checks/checks.dart';
import 'package:conduit/features/navigation/providers/sidebar_tab_scroll_registry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('selected sidebar tab invokes its registered scroll callback', () async {
    final registry = SidebarTabScrollRegistry();
    final owner = Object();
    var calls = 0;

    registry.register('notes', owner: owner, callback: () async => calls++);

    await registry.scrollToTop('notes');
    check(calls).equals(1);
  });

  test('stale owners cannot unregister a replacement callback', () async {
    final registry = SidebarTabScrollRegistry();
    final originalOwner = Object();
    final replacementOwner = Object();
    var calls = 0;

    registry.register('chats', owner: originalOwner, callback: () => calls++);
    registry.register(
      'chats',
      owner: replacementOwner,
      callback: () => calls += 10,
    );
    registry.unregister('chats', owner: originalOwner);

    await registry.scrollToTop('chats');
    check(calls).equals(10);
  });
}
