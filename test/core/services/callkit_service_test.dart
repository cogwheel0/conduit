import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/core/services/callkit_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pluginChannel = MethodChannel('flutter_callkit_incoming');
  const telecomChannel = MethodChannel('app.cogwheel.conduit/telecom_call');

  group('CallKitService on Android', () {
    late List<MethodCall> pluginCalls;
    late List<Object?> telecomWaits;
    late Completer<bool> telecomConnection;
    late CallKitService service;

    setUp(() {
      pluginCalls = <MethodCall>[];
      telecomWaits = <Object?>[];
      telecomConnection = Completer<bool>();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(pluginChannel, (call) async {
        pluginCalls.add(call);
        return true;
      });
      messenger.setMockMethodCallHandler(telecomChannel, (call) async {
        if (call.method != 'awaitConnection') return null;
        telecomWaits.add(call.arguments);
        return telecomConnection.future;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(pluginChannel, null);
        messenger.setMockMethodCallHandler(telecomChannel, null);
      });
      service = CallKitService()..debugTreatAsAndroid = true;
    });

    Iterable<String> pluginMethods() => pluginCalls.map((call) => call.method);

    test('marks a call connected only once Telecom has created it', () async {
      final id = await service.startOutgoingVoiceCall(
        calleeName: 'Model',
        handle: 'Conduit AI',
      );
      check(id).isNotNull();

      // A Standard call marks itself connected a few hundred milliseconds
      // after starting, before Telecom has created the plugin's connection.
      // The plugin dropped that signal and left the call dialing until
      // Telecom ended it two minutes in (issue #846).
      final marking = service.markCallConnected(id!);
      await pumpEventQueue();
      check(telecomWaits).deepEquals(<Object?>[
        {'callId': id},
      ]);
      check(pluginMethods()).not((it) => it.contains('callConnected'));

      telecomConnection.complete(true);
      await marking;
      check(pluginCalls.last.method).equals('callConnected');
      check(
        pluginCalls.last.arguments as Map<Object?, Object?>,
      ).deepEquals({'id': id});
    });

    test('leaves a call hung up while Telecom set it up ended', () async {
      final id = await service.startOutgoingVoiceCall(
        calleeName: 'Model',
        handle: 'Conduit AI',
      );
      final marking = service.markCallConnected(id!);
      await pumpEventQueue();
      await service.endCall(id);

      telecomConnection.complete(true);
      await marking;
      check(pluginMethods()).not((it) => it.contains('callConnected'));
    });

    test('leaves a call hung up from the system UI ended', () async {
      const eventChannel = EventChannel('flutter_callkit_incoming_events');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      MockStreamHandlerEventSink? pluginEvents;
      messenger.setMockStreamHandler(
        eventChannel,
        MockStreamHandler.inline(
          onListen: (_, events) => pluginEvents = events,
        ),
      );
      addTearDown(() => messenger.setMockStreamHandler(eventChannel, null));

      final id = await service.startOutgoingVoiceCall(
        calleeName: 'Model',
        handle: 'Conduit AI',
      );
      // The voice call follows CallKit events for as long as it runs.
      final subscription = service.events.listen((_) {});
      addTearDown(subscription.cancel);
      final marking = service.markCallConnected(id!);
      await pumpEventQueue();

      // Hanging up from Android's call notification ends the call without
      // endCall, so only the event says the call is over.
      pluginEvents!.success(<String, Object?>{
        'event': 'com.hiennv.flutter_callkit_incoming.ACTION_CALL_ENDED',
        'body': <String, Object?>{'id': id},
      });
      await pumpEventQueue();

      telecomConnection.complete(true);
      await marking;
      check(pluginMethods()).not((it) => it.contains('callConnected'));
    });

    test('still marks the call connected without the bridge', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(telecomChannel, null);
      final id = await service.startOutgoingVoiceCall(
        calleeName: 'Model',
        handle: 'Conduit AI',
      );

      await service.markCallConnected(id!);
      check(pluginCalls.last.method).equals('callConnected');
    });
  });
}
