import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  test('iOS placeholders sit a thin space clear of the caret', () {
    expect(
      placeholderClearOfCaret('Ask Conduit', platform: TargetPlatform.iOS),
      ' Ask Conduit',
    );
    // Applied once, however often a field rebuilds.
    expect(
      placeholderClearOfCaret(
        placeholderClearOfCaret('Ask Conduit', platform: TargetPlatform.iOS),
        platform: TargetPlatform.iOS,
      ),
      ' Ask Conduit',
    );
  });

  test('other platforms, empty and non-leading placeholders stay as is', () {
    expect(
      placeholderClearOfCaret('Ask Conduit', platform: TargetPlatform.android),
      'Ask Conduit',
    );
    expect(placeholderClearOfCaret('', platform: TargetPlatform.iOS), '');
    // An end-aligned or centred caret is not at the placeholder's start.
    expect(
      placeholderClearOfCaret(
        'Optional',
        platform: TargetPlatform.iOS,
        textAlign: TextAlign.end,
      ),
      'Optional',
    );
    expect(
      placeholderClearOfCaret(
        'Optional',
        platform: TargetPlatform.iOS,
        textAlign: TextAlign.center,
      ),
      'Optional',
    );
  });

  testWidgets('shared iOS text fields use the caret-clear placeholder', (
    tester,
  ) async {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    addTearDown(PlatformUiCapabilities.resetDebugOverrides);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: AdaptiveTextField(placeholder: 'Server URL')),
      ),
    );
    expect(find.text(' Server URL'), findsOneWidget);
    expect(maybePlaceholderClearOfCaret(null), isNull);
  });
}
