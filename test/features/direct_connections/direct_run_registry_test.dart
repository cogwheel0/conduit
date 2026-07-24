import 'package:conduit/features/direct_connections/services/direct_run_registry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const key = (
    ownerConversationId: 'conversation',
    assistantMessageId: 'assistant',
  );

  test('app-data clear barrier rejects and can resume run admission', () {
    final registry = DirectRunRegistry();

    registry.blockAdmissionForAppDataClear();
    expect(() => registry.reserve(key, 'profile'), throwsStateError);

    registry.resumeAdmissionAfterAppDataClearAbort();
    expect(registry.reserve(key, 'profile'), isA<DirectRunReservation>());
  });
}
