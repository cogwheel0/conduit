import 'dart:async';
import 'dart:io';

import 'package:conduit/features/push/push_host_bindings.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/platform/conduit_platform_apis.g.dart';
import 'package:conduit/platform/mobile_push_platform.dart';
import 'package:conduit_core/conduit_core.dart';
import 'package:conduit_core/features/push/providers/push_providers.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the bundled Open WebUI function loads with its version', () async {
    final source = await loadBundledConduitPushFunction();
    final template = File('server-plugins/openwebui/conduit_push.template.py')
        .readAsStringSync();
    final version = RegExp(
      r'^version: (.+)$',
      multiLine: true,
    ).firstMatch(template)!.group(1)!.trim();

    expect(source, isNotNull);
    expect(source!.version, version);
    expect(source.description, isNotEmpty);
  });

  test('every language has every push string', () {
    for (final locale in AppLocalizations.supportedLocales) {
      final strings = pushDisplayStrings(lookupAppLocalizations(locale));
      expect(strings.keys.toSet(), kPushDefaultStrings.keys.toSet());
      expect(
        strings.values.where((value) => value.trim().isEmpty),
        isEmpty,
        reason: '$locale',
      );
    }
    expect(
      pushDisplayStrings(lookupAppLocalizations(const Locale('en'))),
      kPushDefaultStrings,
    );
  });

  group('MobilePushPlatform', () {
    test('a build without the native bridge has no transports', () async {
      expect(await MobilePushPlatform().availableTransports(), isEmpty);
    });

    test('turns pigeon callbacks into core events', () async {
      final platform = MobilePushPlatform();
      final events = <PushPlatformEvent>[];
      final subscription = platform.events.listen(events.add);
      platform
        ..onToken(
          PlatformPushToken(
            transport: PlatformPushTransport.fcm,
            token: 'token',
            app: 'app.cogwheel.conduit',
            env: 'prod',
          ),
        )
        ..onTestReceived('sid', 'nonce')
        ..onUnregistered('sid')
        ..onUnifiedPushEndpoint('sid', 'https://up.example/x')
        ..onForegroundPush(
          PlatformPushMessage(sid: 'sid', scope: 'owui:a', payloadJson: '{}'),
        )
        ..onTap(PlatformPushTap(scope: 'owui:a', payloadJson: '{}'));
      await pumpEventQueue();
      await subscription.cancel();

      expect(events, hasLength(6));
      final token = (events[0] as PushTokenEvent).token;
      expect(token.transport, PushTransport.fcm);
      expect(token.env, 'prod');
      expect((events[1] as PushTestReceivedEvent).nonce, 'nonce');
      expect((events[2] as PushUnregisteredEvent).sid, 'sid');
      expect(
        (events[3] as PushUnifiedPushEndpointEvent).endpoint,
        'https://up.example/x',
      );
      expect((events[4] as PushForegroundEvent).message.scope, 'owui:a');
      expect((events[5] as PushTapEvent).tap.scope, 'owui:a');
    });
  });
}

Future<void> pumpEventQueue() =>
    Future<void>.delayed(Duration.zero)
        .then((_) => Future<void>.delayed(Duration.zero));
