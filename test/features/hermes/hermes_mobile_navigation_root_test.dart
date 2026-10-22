import 'package:conduit/features/hermes/providers/hermes_mobile_navigation.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final area in HermesWorkArea.values) {
    test('bottom ${area.name} opens its root instead of retaining a chat', () {
      final container = ProviderContainer(
        overrides: [hermesApiServiceProvider.overrideWithValue(null)],
      );
      addTearDown(container.dispose);
      final navigation = container.read(
        hermesMobileNavigationProvider.notifier,
      );
      navigation.newConversation(task: true);
      final draft = container.read(hermesMobileNavigationProvider).draft;
      navigation.select(area);
      final state = container.read(hermesMobileNavigationProvider);
      expect(state.area, area);
      expect(state.conversation, isFalse);
      expect(state.draft, draft);
      expect(state.taskDraft, isTrue);
      navigation.select(HermesWorkArea.chat);
      expect(
        container.read(hermesMobileNavigationProvider).conversation,
        isFalse,
      );
    });
  }
  test('chat reselect consumes the conversation return without reopening it on Back', () {
    final container = ProviderContainer(
      overrides: [hermesApiServiceProvider.overrideWithValue(null)],
    );
    addTearDown(container.dispose);
    final navigation = container.read(hermesMobileNavigationProvider.notifier);
    navigation.showConversation();
    navigation.select(HermesWorkArea.chat);
    expect(navigation.canGoBack, isFalse);
  });
}
