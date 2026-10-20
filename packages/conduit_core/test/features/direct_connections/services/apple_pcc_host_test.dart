import 'package:conduit_core/features/direct_connections/models/direct_completion.dart';
import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/features/direct_connections/services/apple_pcc_adapter.dart';
import 'package:test/test.dart';

void main() {
  group('without a native bridge', () {
    test('both Apple models report unsupported and never start', () async {
      final adapter = ApplePccAdapter();

      final status = await adapter.status(PlatformAppleModel.onDevice);
      expect(status.availability, PlatformPccAvailability.unsupported);
      await expectLater(
        adapter.listModels(DirectConnectionProfile.applePrivateCloudCompute()),
        throwsA(isA<DirectProviderException>()),
      );
      expect(await adapter.showQuotaIncreaseSuggestion(), isFalse);
    });
  });
}
