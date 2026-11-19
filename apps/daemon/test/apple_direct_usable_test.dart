@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:test/test.dart';

import 'support/null_sink.dart';

/// With no Open WebUI account, Apple's on-device model alone carries the
/// app when the Mac's model answers: the core hands a signed-out window
/// over to Direct on it, so `direct.list` says Direct is usable too (the
/// window's session then routes it as a Direct window).
void main() {
  late Directory temporary;
  late CoreRuntime runtime;

  setUpAll(() async {
    temporary = Directory.systemTemp.createTempSync('apple-direct-test');
    runtime = await CoreRuntime.start(
      config: BootstrapConfig(
        sessionToken: 'a' * 43,
        masterKey: base64.encode(List<int>.generate(32, (i) => i)),
        userDataDir: temporary.path,
      ),
      directories: DaemonDirectories.create(temporary.path),
      log: DaemonLog(level: 'error', sink: NullSink()),
    );
  });

  tearDownAll(() async {
    await runtime.dispose();
    temporary.deleteSync(recursive: true);
  });

  test(
    'Apple On-Device alone makes Direct usable, and only while it answers',
    () async {
      final bus = EventBus();
      runtime.apple.bind(bus);
      final apple = AppleModelsService(
        runtime.container,
        bridge: runtime.apple,
      );
      var engine = const AppleEngineStatus(
        availability: AppleAvailability.unavailable,
        reason: AppleUnavailableReason.modelNotReady,
        supportsCurrentLocale: true,
      );
      // The window's engine: answers each status it is asked for.
      bus.attach('window', (envelope) {
        if (envelope.event != ConduitEvents.appleCommand) return;
        final command = AppleCommand.fromJson(envelope.payload);
        if (command.kind == AppleCommandKind.status) {
          scheduleMicrotask(
            () => apple.report(
              AppleReport(id: command.id, status: engine),
              from: 'window',
            ),
          );
        }
      });
      addTearDown(() => bus.detach('window'));
      final direct = DirectService(runtime.container);

      // No engine yet, then one whose model is not ready: nothing to use.
      expect((await direct.list()).usable, isFalse);
      apple.report(
        const AppleReport(kind: AppleReportKind.ready, supported: true),
        from: 'window',
      );
      await apple.refresh();
      expect(runtime.container.read(appleOnDeviceAnswersProvider), isFalse);
      expect((await direct.list()).usable, isFalse);

      // The model answers: Direct is usable, with no connection listed (the
      // Apple connection is the app's own).
      engine = const AppleEngineStatus(
        availability: AppleAvailability.available,
        contextSize: 4096,
        supportsCurrentLocale: true,
      );
      // Check Again has offered it by the time it returns.
      await apple.refresh();
      expect(runtime.container.read(appleOnDeviceAnswersProvider), isTrue);
      final list = await direct.list();
      expect(list.usable, isTrue);
      expect(list.connections, isEmpty);
    },
  );

  test('the first-run Apple row prefers Direct on the model only while it '
      'answers, history kept on this Mac', () async {
    final bus = EventBus();
    runtime.apple.bind(bus);
    final apple = AppleModelsService(runtime.container, bridge: runtime.apple);
    var engine = const AppleEngineStatus(
      availability: AppleAvailability.unavailable,
      reason: AppleUnavailableReason.appleIntelligenceNotEnabled,
      supportsCurrentLocale: true,
    );
    bus.attach('window', (envelope) {
      if (envelope.event != ConduitEvents.appleCommand) return;
      final command = AppleCommand.fromJson(envelope.payload);
      if (command.kind == AppleCommandKind.status) {
        scheduleMicrotask(
          () => apple.report(
            AppleReport(id: command.id, status: engine),
            from: 'window',
          ),
        );
      }
    });
    addTearDown(() => bus.detach('window'));
    final direct = DirectService(runtime.container);
    await direct.setPreferred(preferred: false);
    apple.report(
      const AppleReport(kind: AppleReportKind.ready, supported: true),
      from: 'window',
    );

    // Not answering: the reason, and nothing chosen.
    final refused = await apple.choose();
    expect(refused.availability, AppleAvailability.unavailable);
    expect(refused.reason, AppleUnavailableReason.appleIntelligenceNotEnabled);
    expect((await direct.list()).preferred, isFalse);

    // Answering: Direct is preferred and usable, history on this Mac.
    engine = const AppleEngineStatus(
      availability: AppleAvailability.available,
      contextSize: 4096,
      supportsCurrentLocale: true,
    );
    final chosen = await apple.choose();
    expect(chosen.availability, AppleAvailability.available);
    final list = await direct.list();
    expect(list.preferred, isTrue);
    expect(list.usable, isTrue);
    expect(list.localHistory, isTrue);
  });
}
