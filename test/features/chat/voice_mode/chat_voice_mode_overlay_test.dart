import 'package:conduit/features/chat/voice_mode/chat_voice_mode_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('inactive overlay does not collapse a loose Stack', (
    tester,
  ) async {
    const stackKey = Key('chat-stack');
    const bodyKey = Key('chat-body');

    await tester.pumpWidget(
      const ProviderScope(
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: SizedBox(
              width: 300,
              height: 500,
              child: Align(
                alignment: Alignment.topLeft,
                child: Stack(
                  key: stackKey,
                  children: [
                    Positioned.fill(
                      child: ColoredBox(key: bodyKey, color: Colors.black),
                    ),
                    ChatVoiceModeOverlay(bottomOffset: 0),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );

    expect(tester.getSize(find.byKey(stackKey)), const Size(300, 500));
    expect(tester.getSize(find.byKey(bodyKey)), const Size(300, 500));
  });
}
