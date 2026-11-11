import 'package:conduit/features/navigation/providers/sidebar_tab_scroll_registry.dart';
import 'package:conduit_core/features/navigation/models/sidebar_navigation_model.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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

  testWidgets('a scoped list cannot replace the sidebar list it repeats', (
    tester,
  ) async {
    final sidebar = ScrollController();
    final mainPane = ScrollController();
    final pageRegistry = SidebarTabScrollRegistry();
    late SidebarTabScrollRegistry registry;
    Widget list(ScrollController controller) => SizedBox(
      height: 200,
      child: _RegisteredList(controller: controller),
    );
    await tester.pumpWidget(
      ProviderScope(
        child: Consumer(
          builder: (context, ref, _) {
            registry = ref.read(sidebarTabScrollRegistryProvider);
            return Directionality(
              textDirection: TextDirection.ltr,
              child: Column(
                children: [
                  list(sidebar),
                  // Mounted after the sidebar's, as a page opened later is.
                  SidebarTabScrollRegistryScope(
                    registry: pageRegistry,
                    child: list(mainPane),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
    sidebar.jumpTo(300);
    mainPane.jumpTo(300);

    await registry.scrollToTop(SidebarTabId.hermes, duration: Duration.zero);
    expect(sidebar.offset, 0);
    expect(mainPane.offset, 300);

    await pageRegistry.scrollToTop(
      SidebarTabId.hermes,
      duration: Duration.zero,
    );
    expect(mainPane.offset, 0);
  });
}

class _RegisteredList extends ConsumerStatefulWidget {
  const _RegisteredList({required this.controller});

  final ScrollController controller;

  @override
  ConsumerState<_RegisteredList> createState() => _RegisteredListState();
}

class _RegisteredListState extends ConsumerState<_RegisteredList>
    with SidebarTabScrollRegistration<_RegisteredList> {
  @override
  SidebarTabId get sidebarTabId => SidebarTabId.hermes;

  @override
  ScrollController get sidebarScrollController => widget.controller;

  @override
  Widget build(BuildContext context) => ListView(
    controller: widget.controller,
    children: [for (var i = 0; i < 40; i++) const SizedBox(height: 50)],
  );
}
