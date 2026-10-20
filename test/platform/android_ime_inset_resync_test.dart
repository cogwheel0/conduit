import 'package:conduit/platform/android_ime_inset_resync.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final android = TargetPlatformVariant.only(TargetPlatform.android);

  List<String> recordResyncCalls(WidgetTester tester) {
    final calls = <String>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(AndroidImeInsetResync.channel, (
      call,
    ) async {
      calls.add(call.method);
      return true;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(
        AndroidImeInsetResync.channel,
        null,
      ),
    );
    final resync = AndroidImeInsetResync.instance..install();
    addTearDown(resync.uninstall);
    addTearDown(tester.view.reset);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    return calls;
  }

  testWidgets('checks a keyboard inset with native once it stops changing', (
    tester,
  ) async {
    final calls = recordResyncCalls(tester);

    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pump(AndroidImeInsetResync.settleDelay ~/ 2);
    tester.view.viewInsets = const FakeViewPadding(bottom: 320);
    await tester.pump(AndroidImeInsetResync.settleDelay ~/ 2);
    expect(calls, isEmpty);

    await tester.pump(AndroidImeInsetResync.settleDelay);
    expect(calls, ['resyncImeInsets']);
  }, variant: android);

  testWidgets('leaves a settled zero inset alone', (tester) async {
    final calls = recordResyncCalls(tester);

    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pump(const Duration(milliseconds: 16));
    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pump(AndroidImeInsetResync.settleDelay * 2);

    expect(calls, isEmpty);
  }, variant: android);
}
