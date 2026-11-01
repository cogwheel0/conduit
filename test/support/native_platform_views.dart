import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Acknowledges embedded-view lifecycle and property updates in layout tests.
/// UIKit rendering and gestures are verified separately on the simulator.
void stubNativePlatformViews() {
  final binding = TestWidgetsFlutterBinding.instance;
  final messenger = binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform_views, (
    call,
  ) async {
    if (call.method == 'create') {
      final arguments = call.arguments as Map;
      final channel = MethodChannel(
        '${arguments['viewType']}_${arguments['id']}',
      );
      messenger.setMockMethodCallHandler(channel, (_) async => null);
    }
    return null;
  });
  // Flutter clears these handlers after the test, once its final widget tree
  // and platform views have been disposed.
}
