import 'dart:typed_data';

import 'package:conduit/features/direct_connections/services/apple_pcc_adapter.dart';
import 'package:conduit/platform/conduit_platform_apis.g.dart' as pigeon;
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('status and requests copy field for field', () async {
    final api = _FakePigeonHostApi();
    final host = PigeonApplePccHost(api: api);

    final status = await host.getStatus(PlatformAppleModel.onDevice);
    expect(api.statusModel, pigeon.PlatformAppleModel.onDevice);
    expect(status.availability, PlatformPccAvailability.available);
    expect(status.quotaStatus, PlatformPccQuotaStatus.approachingLimit);
    expect(status.contextSize, 4096);

    await host.start(
      PlatformPccCompletionRequest(
        runId: 'run-1',
        model: PlatformAppleModel.privateCloudCompute,
        messages: [
          PlatformPccMessage(
            role: 'user',
            content: 'Hi',
            images: [
              PlatformPccImage(
                mimeType: 'image/png',
                bytes: Uint8List.fromList([1, 2]),
              ),
            ],
          ),
        ],
        tools: [
          PlatformPccToolDefinition(
            name: 'weather',
            toolDescription: 'Weather',
            inputSchemaJson: '{}',
          ),
        ],
        allowOnDeviceFallback: true,
        reasoningLevel: 'light',
        topP: 0.9,
      ),
    );
    final sent = api.started!;
    expect(sent.model, pigeon.PlatformAppleModel.privateCloudCompute);
    expect(sent.messages.single.images.single.bytes, [1, 2]);
    expect(sent.tools.single.toolDescription, 'Weather');
    expect(sent.allowOnDeviceFallback, isTrue);
    expect(sent.reasoningLevel, 'light');
    expect(sent.topP, 0.9);
  });

  test('native events and tool calls reach the attached listener', () async {
    final host = PigeonApplePccHost(api: _FakePigeonHostApi());
    final listener = _RecordingListener();
    host.attach(listener);

    host.onEvent(
      pigeon.PlatformPccStreamEvent(
        runId: 'run-1',
        kind: pigeon.PlatformPccEventKind.content,
        content: 'Hello',
      ),
    );
    final result = await host.onToolCall(
      pigeon.PlatformPccToolCall(
        runId: 'run-1',
        callId: 'call-1',
        name: 'weather',
        argumentsJson: '{}',
      ),
    );

    expect(listener.events.single.kind, PlatformPccEventKind.content);
    expect(listener.events.single.content, 'Hello');
    expect(listener.calls.single.callId, 'call-1');
    expect(result.content, 'Sunny');
    expect(result.cancelled, isFalse);
  });
}

final class _FakePigeonHostApi extends pigeon.PccHostApi {
  pigeon.PlatformAppleModel? statusModel;
  pigeon.PlatformPccCompletionRequest? started;

  @override
  Future<pigeon.PlatformPccStatus> getStatus(
    pigeon.PlatformAppleModel model,
  ) async {
    statusModel = model;
    return pigeon.PlatformPccStatus(
      availability: pigeon.PlatformPccAvailability.available,
      quotaStatus: pigeon.PlatformPccQuotaStatus.approachingLimit,
      quotaLimitReached: false,
      canIncreaseQuota: false,
      contextSize: 4096,
    );
  }

  @override
  Future<void> start(pigeon.PlatformPccCompletionRequest request) async {
    started = request;
  }
}

final class _RecordingListener implements ApplePccHostListener {
  final events = <PlatformPccStreamEvent>[];
  final calls = <PlatformPccToolCall>[];

  @override
  void onEvent(PlatformPccStreamEvent event) => events.add(event);

  @override
  Future<PlatformPccToolResult> onToolCall(PlatformPccToolCall call) async {
    calls.add(call);
    return PlatformPccToolResult(content: 'Sunny', cancelled: false);
  }
}
