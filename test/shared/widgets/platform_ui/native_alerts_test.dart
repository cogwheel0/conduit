import 'dart:async';

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const channel = MethodChannel('cn_alert');
  final calls = <MethodCall>[];
  Object? reply;

  setUp(() {
    PlatformUiCapabilities.debugIOSMajorVersionOverride = 27;
    PlatformUiCapabilities.debugNativeIOS26Override = true;
    calls.clear();
    reply = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return reply;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    PlatformUiCapabilities.resetDebugOverrides();
  });

  testWidgets('iOS alerts use the system presentation and selected action', (
    tester,
  ) async {
    await tester.pumpWidget(
      const CupertinoApp(home: CupertinoPageScaffold(child: SizedBox())),
    );
    var cancels = 0;
    var confirms = 0;
    reply = {'index': 1, 'textFields': <String>[]};
    final result = AdaptiveAlertDialog.show(
      context: tester.element(find.byType(CupertinoPageScaffold)),
      title: 'Remove sample?',
      message: 'The sample will be removed.',
      actions: [
        AlertAction(
          title: 'Cancel',
          style: AlertActionStyle.cancel,
          onPressed: () => cancels++,
        ),
        AlertAction(
          title: 'Remove',
          style: AlertActionStyle.destructive,
          onPressed: () => confirms++,
        ),
      ],
    );
    await tester.pumpAndSettle();
    expect(calls, hasLength(1));
    expect(calls.single.method, 'show');
    final payload = calls.single.arguments as Map;
    expect(payload['title'], 'Remove sample?');
    expect(payload['message'], 'The sample will be removed.');
    expect(payload['actions'], [
      containsPair('style', 'cancel'),
      containsPair('style', 'destructive'),
    ]);
    expect(find.byType(CupertinoAlertDialog), findsNothing);
    await result;
    expect(confirms, 1);
    expect(cancels, 0);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  for (final disabled in [
    (
      name: 'enabled flag',
      enabled: false,
      style: AlertActionStyle.defaultAction,
    ),
    (name: 'disabled style', enabled: true, style: AlertActionStyle.disabled),
  ]) {
    testWidgets('native alerts preserve the ${disabled.name}', (tester) async {
      await tester.pumpWidget(
        const CupertinoApp(home: CupertinoPageScaffold(child: SizedBox())),
      );
      var disabledCalls = 0;
      var enabledCalls = 0;
      reply = {'index': 0, 'textFields': <String>[]};
      final result = AdaptiveAlertDialog.show(
        context: tester.element(find.byType(CupertinoPageScaffold)),
        title: 'Keep sample?',
        actions: [
          AlertAction(
            title: 'Unavailable',
            enabled: disabled.enabled,
            style: disabled.style,
            onPressed: () => disabledCalls++,
          ),
          AlertAction(title: 'Keep', onPressed: () => enabledCalls++),
        ],
      );
      await tester.pumpAndSettle();
      expect(calls, hasLength(1));
      final payload = calls.single.arguments as Map;
      expect(payload['actions'], [
        containsPair('enabled', false),
        containsPair('enabled', true),
      ]);
      expect(find.byType(CupertinoAlertDialog), findsNothing);
      await result;
      expect(disabledCalls, 0);
      expect(enabledCalls, 0);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
  }

  testWidgets('native replies retain the actions that were presented', (
    tester,
  ) async {
    final response = Completer<Map<String, Object?>>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) => response.future);
    await tester.pumpWidget(
      const CupertinoApp(home: CupertinoPageScaffold(child: SizedBox())),
    );
    var answers = 0;
    final actions = [AlertAction(title: 'Keep', onPressed: () => answers++)];
    final result = AdaptiveAlertDialog.show(
      context: tester.element(find.byType(CupertinoPageScaffold)),
      title: 'Keep sample?',
      actions: actions,
    );
    await tester.pump();
    actions.clear();
    response.complete({'index': 0});
    await result;
    expect(answers, 1);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('an unanswered native alert invokes no action', (tester) async {
    await tester.pumpWidget(
      const CupertinoApp(home: CupertinoPageScaffold(child: SizedBox())),
    );
    var answers = 0;
    final result = AdaptiveAlertDialog.show(
      context: tester.element(find.byType(CupertinoPageScaffold)),
      title: 'Sample',
      actions: [AlertAction(title: 'OK', onPressed: () => answers++)],
    );
    await tester.pumpAndSettle();
    expect(calls, hasLength(1));
    await result;
    expect(answers, 0);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
  testWidgets('native alert results do not outlive the presenting route', (
    tester,
  ) async {
    final response = Completer<Map<String, Object?>>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) => response.future);
    await tester.pumpWidget(
      const CupertinoApp(home: CupertinoPageScaffold(child: SizedBox())),
    );
    var answers = 0;
    final result = AdaptiveAlertDialog.show(
      context: tester.element(find.byType(CupertinoPageScaffold)),
      title: 'Sample',
      actions: [AlertAction(title: 'OK', onPressed: () => answers++)],
    );
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    response.complete({'index': 0});
    await result;
    expect(answers, 0);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('forced app themes keep their appearance when the OS differs', (
    tester,
  ) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await tester.pumpWidget(
      const CupertinoApp(
        theme: CupertinoThemeData(brightness: Brightness.dark),
        home: CupertinoPageScaffold(child: SizedBox()),
      ),
    );
    var answers = 0;
    final result = AdaptiveAlertDialog.show(
      context: tester.element(find.byType(CupertinoPageScaffold)),
      title: 'Sample',
      actions: [AlertAction(title: 'OK', onPressed: () => answers++)],
    );
    await tester.pumpAndSettle();
    expect(calls, isEmpty);
    expect(find.byType(CupertinoAlertDialog), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await result;
    expect(answers, 1);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
}
