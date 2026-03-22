import 'package:conduit/core/providers/app_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('channelsFeatureEnabledProvider', () {
    test('defaults to true (optimistic)', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(channelsFeatureEnabledProvider), isTrue);
    });

    test('setEnabled(false) sets state to false', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      container.read(channelsFeatureEnabledProvider.notifier).setEnabled(false);

      expect(container.read(channelsFeatureEnabledProvider), isFalse);
    });

    test('setEnabled(true) after false restores true', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      container.read(channelsFeatureEnabledProvider.notifier).setEnabled(false);
      container.read(channelsFeatureEnabledProvider.notifier).setEnabled(true);

      expect(container.read(channelsFeatureEnabledProvider), isTrue);
    });
  });
}
