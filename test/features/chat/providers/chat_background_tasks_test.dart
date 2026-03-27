import 'package:checks/checks.dart';
import 'package:conduit/features/chat/providers/chat_providers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('buildOpenWebUiBackgroundTasksForTest', () {
    test('defaults follow-up generation to enabled on later turns', () {
      final tasks = buildOpenWebUiBackgroundTasksForTest(
        userSettings: null,
        shouldGenerateTitle: false,
      );

      check(tasks).deepEquals(const {'follow_up_generation': true});
    });

    test('defaults title, tags, and follow-ups to enabled on first turn', () {
      final tasks = buildOpenWebUiBackgroundTasksForTest(
        userSettings: null,
        shouldGenerateTitle: true,
      );

      check(tasks).deepEquals(const {
        'title_generation': true,
        'tags_generation': true,
        'follow_up_generation': true,
      });
    });

    test('reads root-level backend generation settings', () {
      final tasks = buildOpenWebUiBackgroundTasksForTest(
        userSettings: const {
          'title': {'auto': false},
          'autoTags': false,
          'autoFollowUps': false,
        },
        shouldGenerateTitle: true,
      );

      check(tasks).deepEquals(const <String, dynamic>{});
    });

    test('falls back to ui settings when root generation keys are absent', () {
      final tasks = buildOpenWebUiBackgroundTasksForTest(
        userSettings: const {
          'ui': {
            'title': {'auto': false},
            'autoTags': false,
            'autoFollowUps': false,
          },
        },
        shouldGenerateTitle: true,
      );

      check(tasks).deepEquals(const <String, dynamic>{});
    });

    test('prefers root settings over legacy ui fallback when both exist', () {
      final tasks = buildOpenWebUiBackgroundTasksForTest(
        userSettings: const {
          'title': {'auto': false},
          'autoTags': false,
          'autoFollowUps': false,
          'ui': {
            'title': {'auto': true},
            'autoTags': true,
            'autoFollowUps': true,
          },
        },
        shouldGenerateTitle: true,
      );

      check(tasks).deepEquals(const <String, dynamic>{});
    });
  });
}
