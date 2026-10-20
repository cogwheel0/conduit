import 'package:conduit/platform/carplay_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _channel = MethodChannel('conduit/carplay');
const _codec = StandardMethodCodec();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  test('calls from the scene reach the handler over the channel', () async {
    const bridge = MethodChannelCarPlayBridge();
    bridge.setCallHandler(
      (method) async => {'success': true, 'method': method},
    );
    addTearDown(() => bridge.setCallHandler(null));

    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    ByteData? reply;
    await messenger.handlePlatformMessage(
      'conduit/carplay',
      _codec.encodeMethodCall(const MethodCall('startVoiceConversation')),
      (data) => reply = data,
    );

    expect(_codec.decodeEnvelope(reply!), {
      'success': true,
      'method': 'startVoiceConversation',
    });
  });

  test('a missing native bridge reads as CarPlayBridgeUnavailable', () async {
    const bridge = MethodChannelCarPlayBridge();

    await expectLater(
      bridge.invoke('carPlayDartReady'),
      throwsA(isA<CarPlayBridgeUnavailable>()),
    );
  });

  test('state changes go to the scene with their payload', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          calls.add(call);
          return null;
        });
    const bridge = MethodChannelCarPlayBridge();

    await bridge.invoke('voiceConversationStateChanged', {'phase': 'idle'});

    expect(calls.single.method, 'voiceConversationStateChanged');
    expect(calls.single.arguments, {'phase': 'idle'});
  });
}
