import 'package:checks/checks.dart';
import 'package:conduit/core/models/model.dart';
import 'package:conduit/features/chat/views/chat_page.dart';
import 'package:conduit/features/hermes/models/hermes_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('shouldShowChatModelDropdown', () {
    test('keeps switching available for Hermes in a mixed setup', () {
      check(
        shouldShowChatModelDropdown(
          selectedModel: hermesSyntheticModel(),
          isHermesOnly: false,
        ),
      ).isTrue();
    });

    test('hides switching for the single-agent Hermes-only setup', () {
      check(
        shouldShowChatModelDropdown(
          selectedModel: hermesSyntheticModel(),
          isHermesOnly: true,
        ),
      ).isFalse();
    });

    test('shows switching for OpenWebUI or an empty selection', () {
      const openWebUiModel = Model(id: 'gpt', name: 'GPT');

      check(
        shouldShowChatModelDropdown(
          selectedModel: openWebUiModel,
          isHermesOnly: true,
        ),
      ).isTrue();
      check(
        shouldShowChatModelDropdown(selectedModel: null, isHermesOnly: true),
      ).isTrue();
    });
  });
}
