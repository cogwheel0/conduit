import 'package:checks/checks.dart';
import 'package:conduit_core/features/chat/composer/ask_conduit.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

void main() {
  group('askConduitInsertionText', () {
    test('returns the selection as selected, whitespace included', () {
      check(
        askConduitInsertionText(
          selectedText: '  two lines\nof text \n',
          composerTargetId: chatComposerTextInsertionTargetId,
        ),
      ).equals('  two lines\nof text \n');
    });

    test('offers nothing for a blank or missing selection', () {
      for (final selected in <String?>[null, '', '   ', '\n\t \n']) {
        check(
          askConduitInsertionText(
            selectedText: selected,
            composerTargetId: chatComposerTextInsertionTargetId,
          ),
        ).isNull();
      }
    });

    test('offers nothing without a composer to receive it', () {
      for (final target in <String?>[null, '']) {
        check(
          askConduitInsertionText(
            selectedText: 'hello',
            composerTargetId: target,
          ),
        ).isNull();
      }
    });

    test('feeds the composer insertion the composer listens to', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final text = askConduitInsertionText(
        selectedText: 'selected words',
        composerTargetId: chatComposerTextInsertionTargetId,
      );
      check(text).isNotNull();
      container
          .read(composerTextInsertionProvider.notifier)
          .insert(targetId: chatComposerTextInsertionTargetId, text: text!);
      final insertion = container.read(composerTextInsertionProvider);
      check(insertion).isNotNull();
      check(insertion!.targetId).equals(chatComposerTextInsertionTargetId);
      check(insertion.text).equals('selected words');
    });
  });
}
