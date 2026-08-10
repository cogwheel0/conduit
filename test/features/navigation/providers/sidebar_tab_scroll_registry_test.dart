import 'package:conduit/features/navigation/providers/sidebar_tab_scroll_registry.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockScrollController extends Mock implements ScrollController {}

void main() {
  test('selected sidebar tab animates its registered controller', () async {
    final registry = SidebarTabScrollRegistry();
    final owner = Object();
    final controller = _MockScrollController();
    when(() => controller.hasClients).thenReturn(true);
    when(
      () => controller.animateTo(
        0,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
      ),
    ).thenAnswer((_) async {});

    registry.registerController(
      'notes',
      owner: owner,
      resolve: () => controller,
    );

    await registry.scrollToTop(
      'notes',
      duration: const Duration(milliseconds: 200),
    );
    verify(
      () => controller.animateTo(
        0,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
      ),
    ).called(1);
  });

  test('stale owners cannot unregister a replacement callback', () async {
    final registry = SidebarTabScrollRegistry();
    final originalOwner = Object();
    final replacementOwner = Object();
    final original = _MockScrollController();
    final replacement = _MockScrollController();
    when(() => replacement.hasClients).thenReturn(true);

    registry.registerController(
      'chats',
      owner: originalOwner,
      resolve: () => original,
    );
    registry.registerController(
      'chats',
      owner: replacementOwner,
      resolve: () => replacement,
    );
    registry.unregister('chats', owner: originalOwner);

    await registry.scrollToTop('chats', duration: Duration.zero);
    verify(() => replacement.jumpTo(0)).called(1);
  });
}
