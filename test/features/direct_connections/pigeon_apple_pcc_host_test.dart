import 'dart:typed_data';

import 'package:conduit/features/direct_connections/services/apple_pcc_adapter.dart';
import 'package:conduit/platform/conduit_platform_apis.g.dart' as pigeon;
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('status copies every field, for each enum value', () async {
    final api = _FakePigeonHostApi();
    final host = PigeonApplePccHost(api: api);

    final status = await host.getStatus(PlatformAppleModel.onDevice);

    expect(api.statusModel, pigeon.PlatformAppleModel.onDevice);
    expect(status.availability, PlatformPccAvailability.unavailable);
    expect(status.quotaStatus, PlatformPccQuotaStatus.approachingLimit);
    expect(status.quotaLimitReached, isTrue);
    expect(status.canIncreaseQuota, isTrue);
    expect(status.message, 'Quota almost used');
    expect(status.quotaResetAtMilliseconds, 1767225600000);
    expect(status.contextSize, 4096);
    expect(status.supportsCurrentLocale, isFalse);

    await host.getStatus(PlatformAppleModel.privateCloudCompute);
    expect(api.statusModel, pigeon.PlatformAppleModel.privateCloudCompute);
  });

  test('every availability and quota value maps to its namesake', () async {
    for (final availability in pigeon.PlatformPccAvailability.values) {
      for (final quota in pigeon.PlatformPccQuotaStatus.values) {
        final host = PigeonApplePccHost(
          api: _FakePigeonHostApi(availability: availability, quota: quota),
        );
        final status = await host.getStatus(PlatformAppleModel.onDevice);
        expect(status.availability.name, availability.name);
        expect(status.quotaStatus.name, quota.name);
      }
    }
  });

  test('a request copies every field across the boundary', () async {
    final api = _FakePigeonHostApi();
    final host = PigeonApplePccHost(api: api);

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
              PlatformPccImage(
                mimeType: 'image/jpeg',
                bytes: Uint8List.fromList([3]),
              ),
            ],
          ),
          PlatformPccMessage(role: 'assistant', content: 'Hello', images: []),
        ],
        tools: [
          PlatformPccToolDefinition(
            name: 'weather',
            toolDescription: 'Weather',
            inputSchemaJson: '{"type":"object"}',
          ),
        ],
        allowOnDeviceFallback: true,
        reasoningLevel: 'light',
        temperature: 0.4,
        maximumResponseTokens: 512,
        topP: 0.9,
        topK: 40,
        seed: 7,
        greedySampling: true,
        responseSchemaName: 'Answer',
        responseSchemaJson: '{"type":"string"}',
      ),
    );

    final sent = api.started!;
    expect(sent.runId, 'run-1');
    expect(sent.model, pigeon.PlatformAppleModel.privateCloudCompute);
    expect(sent.messages.map((m) => m.role), ['user', 'assistant']);
    expect(sent.messages.map((m) => m.content), ['Hi', 'Hello']);
    expect(sent.messages.first.images.map((i) => i.mimeType), [
      'image/png',
      'image/jpeg',
    ]);
    expect(sent.messages.first.images.map((i) => i.bytes), [
      [1, 2],
      [3],
    ]);
    expect(sent.messages.last.images, isEmpty);
    expect(sent.tools.single.name, 'weather');
    expect(sent.tools.single.toolDescription, 'Weather');
    expect(sent.tools.single.inputSchemaJson, '{"type":"object"}');
    expect(sent.allowOnDeviceFallback, isTrue);
    expect(sent.reasoningLevel, 'light');
    expect(sent.temperature, 0.4);
    expect(sent.maximumResponseTokens, 512);
    expect(sent.topP, 0.9);
    expect(sent.topK, 40);
    expect(sent.seed, 7);
    expect(sent.greedySampling, isTrue);
    expect(sent.responseSchemaName, 'Answer');
    expect(sent.responseSchemaJson, '{"type":"string"}');
  });

  test('a request leaves unset options unset', () async {
    final api = _FakePigeonHostApi();
    final host = PigeonApplePccHost(api: api);

    await host.start(
      PlatformPccCompletionRequest(
        runId: 'run-2',
        model: PlatformAppleModel.onDevice,
        messages: const [],
        tools: const [],
        allowOnDeviceFallback: false,
      ),
    );

    final sent = api.started!;
    expect(sent.allowOnDeviceFallback, isFalse);
    expect(sent.reasoningLevel, isNull);
    expect(sent.temperature, isNull);
    expect(sent.maximumResponseTokens, isNull);
    expect(sent.topP, isNull);
    expect(sent.topK, isNull);
    expect(sent.seed, isNull);
    expect(sent.greedySampling, isNull);
    expect(sent.responseSchemaName, isNull);
    expect(sent.responseSchemaJson, isNull);
  });

  test('cancel and the quota suggestion reach the native side', () async {
    final api = _FakePigeonHostApi();
    final host = PigeonApplePccHost(api: api);

    await host.cancel('run-9');
    final shown = await host.showQuotaIncreaseSuggestion();

    expect(api.cancelledRunId, 'run-9');
    expect(shown, isTrue);
  });

  test('native events copy every field to the attached listener', () {
    final host = PigeonApplePccHost(api: _FakePigeonHostApi());
    final listener = _RecordingListener();
    host.attach(listener);

    for (final kind in pigeon.PlatformPccEventKind.values) {
      host.onEvent(pigeon.PlatformPccStreamEvent(runId: 'run-1', kind: kind));
    }
    host.onEvent(
      pigeon.PlatformPccStreamEvent(
        runId: 'run-2',
        kind: pigeon.PlatformPccEventKind.usage,
        content: 'Hello',
        inputTokenCount: 11,
        outputTokenCount: 22,
        reasoningTokenCount: 33,
        totalTokenCount: 66,
      ),
    );

    expect(
      listener.events
          .take(pigeon.PlatformPccEventKind.values.length)
          .map((e) => e.kind.name),
      pigeon.PlatformPccEventKind.values.map((k) => k.name),
    );
    final usage = listener.events.last;
    expect(usage.runId, 'run-2');
    expect(usage.kind, PlatformPccEventKind.usage);
    expect(usage.content, 'Hello');
    expect(usage.inputTokenCount, 11);
    expect(usage.outputTokenCount, 22);
    expect(usage.reasoningTokenCount, 33);
    expect(usage.totalTokenCount, 66);
  });

  test('a tool call reaches the listener and its result goes back', () async {
    final host = PigeonApplePccHost(api: _FakePigeonHostApi());
    final listener = _RecordingListener();
    host.attach(listener);

    final result = await host.onToolCall(
      pigeon.PlatformPccToolCall(
        runId: 'run-1',
        callId: 'call-1',
        name: 'weather',
        argumentsJson: '{"city":"Oslo"}',
      ),
    );

    final call = listener.calls.single;
    expect(call.runId, 'run-1');
    expect(call.callId, 'call-1');
    expect(call.name, 'weather');
    expect(call.argumentsJson, '{"city":"Oslo"}');
    expect(result.content, 'Sunny');
    expect(result.cancelled, isFalse);
  });

  test('a cancelled tool result is passed back as cancelled', () async {
    final host = PigeonApplePccHost(api: _FakePigeonHostApi());
    host.attach(_RecordingListener(cancelTools: true));

    final result = await host.onToolCall(
      pigeon.PlatformPccToolCall(
        runId: 'run-1',
        callId: 'call-2',
        name: 'weather',
        argumentsJson: '{}',
      ),
    );

    expect(result.cancelled, isTrue);
  });

  test('a tool call with no listener attached is cancelled', () async {
    final host = PigeonApplePccHost(api: _FakePigeonHostApi());

    final result = await host.onToolCall(
      pigeon.PlatformPccToolCall(
        runId: 'run-1',
        callId: 'call-3',
        name: 'weather',
        argumentsJson: '{}',
      ),
    );

    expect(result.cancelled, isTrue);
    expect(result.content, isEmpty);
  });
}

final class _FakePigeonHostApi extends pigeon.PccHostApi {
  _FakePigeonHostApi({
    this.availability = pigeon.PlatformPccAvailability.unavailable,
    this.quota = pigeon.PlatformPccQuotaStatus.approachingLimit,
  });

  final pigeon.PlatformPccAvailability availability;
  final pigeon.PlatformPccQuotaStatus quota;
  pigeon.PlatformAppleModel? statusModel;
  pigeon.PlatformPccCompletionRequest? started;
  String? cancelledRunId;

  @override
  Future<pigeon.PlatformPccStatus> getStatus(
    pigeon.PlatformAppleModel model,
  ) async {
    statusModel = model;
    return pigeon.PlatformPccStatus(
      availability: availability,
      quotaStatus: quota,
      quotaLimitReached: true,
      canIncreaseQuota: true,
      message: 'Quota almost used',
      quotaResetAtMilliseconds: 1767225600000,
      contextSize: 4096,
      supportsCurrentLocale: false,
    );
  }

  @override
  Future<bool> showQuotaIncreaseSuggestion() async => true;

  @override
  Future<void> start(pigeon.PlatformPccCompletionRequest request) async {
    started = request;
  }

  @override
  Future<void> cancel(String runId) async {
    cancelledRunId = runId;
  }
}

final class _RecordingListener implements ApplePccHostListener {
  _RecordingListener({this.cancelTools = false});

  final bool cancelTools;
  final events = <PlatformPccStreamEvent>[];
  final calls = <PlatformPccToolCall>[];

  @override
  void onEvent(PlatformPccStreamEvent event) => events.add(event);

  @override
  Future<PlatformPccToolResult> onToolCall(PlatformPccToolCall call) async {
    calls.add(call);
    return PlatformPccToolResult(content: 'Sunny', cancelled: cancelTools);
  }
}
