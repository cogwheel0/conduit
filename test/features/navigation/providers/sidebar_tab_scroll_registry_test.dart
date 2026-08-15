import 'package:conduit/features/navigation/providers/sidebar_tab_scroll_registry.dart';
import 'package:conduit/features/navigation/models/sidebar_navigation_model.dart';
import 'package:material_ui/material_ui.dart';
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
      SidebarTabId.notes,
      owner: owner,
      resolve: () => controller,
    );

    await registry.scrollToTop(
      SidebarTabId.notes,
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
      SidebarTabId.chats,
      owner: originalOwner,
      resolve: () => original,
    );
    registry.registerController(
      SidebarTabId.chats,
      owner: replacementOwner,
      resolve: () => replacement,
    );
    registry.unregister(SidebarTabId.chats, owner: originalOwner);

    await registry.scrollToTop(SidebarTabId.chats, duration: Duration.zero);
    verify(() => replacement.jumpTo(0)).called(1);
  });
}
