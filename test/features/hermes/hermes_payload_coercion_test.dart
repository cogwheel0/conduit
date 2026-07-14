import 'package:checks/checks.dart';
import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/features/chat/providers/chat_providers.dart';
import 'package:conduit/features/hermes/models/hermes_config.dart';
import 'package:conduit/features/hermes/models/hermes_job.dart';
import 'package:conduit/features/hermes/models/hermes_session.dart';
import 'package:conduit/features/hermes/models/hermes_toolset.dart';
import 'package:conduit/features/hermes/providers/hermes_providers.dart';
import 'package:conduit/features/hermes/services/hermes_api_service.dart';
import 'package:conduit/features/hermes/services/hermes_message_mapper.dart';
import 'package:conduit/features/hermes/services/hermes_run_transport.dart';
import 'package:conduit/features/hermes/utils/hermes_time_parsing.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final class _ExplosiveToString {
  const _ExplosiveToString();

  @override
  String toString() => throw StateError('provider value was coerced');
}

final class _SkillsService extends HermesApiService {
  _SkillsService(this.skills)
    : super(
        config: const HermesConfig(
          enabled: true,
          baseUrl: 'https://hermes.example',
          apiKey: 'key',
        ),
      );

  final List<Map<String, dynamic>> skills;

  @override
  Future<List<Map<String, dynamic>>> listSkills() async => skills;
}

String _repeat(String value, int count) =>
    List<String>.filled(count, value).join();

void main() {
  group('bounded Hermes models', () {
    test('session fields require scalar strings and enforce display caps', () {
      check(
        HermesSessionSummary.fromJson({
          'id': const <String>['nested'],
        }),
      ).isNull();

      final exact = HermesSessionSummary.fromJson({
        'id': 'session-1',
        'title': _repeat('t', kMaxHermesSessionTitleCharacters),
        'preview': _repeat('p', kMaxHermesSessionPreviewCharacters),
        'source': _repeat('s', kMaxHermesSessionSourceCharacters),
      });
      check(exact).isNotNull();
      check(exact!.title).length.equals(kMaxHermesSessionTitleCharacters);
      check(exact.preview!).length.equals(kMaxHermesSessionPreviewCharacters);
      check(exact.source!).length.equals(kMaxHermesSessionSourceCharacters);

      final malformed = HermesSessionSummary.fromJson({
        'id': 'session-2',
        'title': const _ExplosiveToString(),
        'preview': <String>['forged'],
        'source': _repeat('s', kMaxHermesSessionSourceCharacters + 1),
      });
      check(malformed).isNotNull();
      check(malformed!.title).equals('Untitled session');
      check(malformed.preview).isNull();
      check(malformed.source).isNull();

      final fallback = HermesSessionSummary.fromJson({
        'id': '',
        'session_id': 'fallback-session',
        'title': '',
        'name': 'Fallback title',
      });
      check(fallback).isNotNull();
      check(fallback!.id).equals('fallback-session');
      check(fallback.title).equals('Fallback title');
    });

    test('toolsets bound labels, descriptions, tool ids, and tool count', () {
      check(
        HermesToolset.fromJson({
          'name': {'nested': 'toolset'},
        }),
      ).isNull();
      final tools = <Object?>[
        const _ExplosiveToString(),
        {
          'name': const <String>['nested'],
        },
        for (var index = 0; index < kMaxHermesToolsPerToolset + 20; index++)
          'tool-$index',
      ];
      final toolset = HermesToolset.fromJson({
        'name': 'safe-toolset',
        'label': _repeat('l', kMaxHermesToolsetLabelCharacters + 1),
        'description': _repeat('d', kMaxHermesToolsetDescriptionCharacters + 1),
        'tools': tools,
      });

      check(toolset).isNotNull();
      check(toolset!.label).equals('safe-toolset');
      check(toolset.description).isNull();
      check(toolset.tools).length.equals(kMaxHermesToolsPerToolset);
      check(toolset.tools.first).equals('tool-0');

      final fallback = HermesToolset.fromJson({
        'name': '',
        'id': 'fallback-toolset',
      });
      check(fallback).isNotNull();
      check(fallback!.name).equals('fallback-toolset');
      check(fallback.label).equals('fallback-toolset');
    });

    test('toolsets count malformed entries against the scan budget', () {
      final toolset = HermesToolset.fromJson({
        'name': 'bounded-scan',
        'tools': <Object?>[
          for (
            var index = 0;
            index < kMaxHermesToolEntriesScannedPerToolset - 1;
            index++
          )
            null,
          'boundary-tool',
          'late-tool',
        ],
      });

      check(toolset).isNotNull();
      check(toolset!.tools).deepEquals(['boundary-tool']);
    });

    test('jobs require scalar bounded control and display fields', () {
      check(
        HermesJob.fromJson({
          'id': const <String>['job'],
        }),
      ).isNull();
      check(
        HermesJob.fromJson({
          'id': 'job-map-prompt',
          'prompt': {'x': 'y'},
        }),
      ).isNull();
      check(
        HermesJob.fromJson({
          'id': 'job-long-prompt',
          'prompt': _repeat('p', kMaxHermesJobPromptCharacters + 1),
        }),
      ).isNull();

      final exact = HermesJob.fromJson({
        'id': 'job-exact',
        'name': _repeat('n', kMaxHermesJobNameCharacters),
        'prompt': _repeat('p', kMaxHermesJobPromptCharacters),
        'schedule': _repeat('s', kMaxHermesJobScheduleCharacters),
        'status': _repeat('x', kMaxHermesJobStatusCharacters),
      });
      check(exact).isNotNull();
      check(exact!.name!).length.equals(kMaxHermesJobNameCharacters);
      check(exact.prompt).length.equals(kMaxHermesJobPromptCharacters);
      check(exact.schedule).length.equals(kMaxHermesJobScheduleCharacters);
      check(exact.lastStatus!).length.equals(kMaxHermesJobStatusCharacters);

      final bounded = HermesJob.fromJson({
        'id': 'job-bounded',
        'name': const _ExplosiveToString(),
        'prompt': 'safe',
        'schedule': _repeat('s', kMaxHermesJobScheduleCharacters + 1),
        'status': const <String>['forged'],
      });
      check(bounded).isNotNull();
      check(bounded!.name).isNull();
      check(bounded.schedule).isEmpty();
      check(bounded.lastStatus).isNull();
    });

    test('job displayName never regex-scans a multi-megabyte prompt', () {
      final job = HermesJob(
        id: 'job-display',
        prompt: _repeat('word ', 500000),
        schedule: 'once',
      );

      check(job.displayName.runes.length).equals(81);
      check(job.displayName).endsWith('…');
    });

    test('job displayName truncates mixed UTF-16 input by scalar', () {
      final job = HermesJob(
        id: 'job-unicode-display',
        name: '${_repeat('n', kMaxHermesJobNameCharacters - 1)}😀tail',
        prompt: 'unused',
        schedule: 'once',
      );

      check(job.displayName.runes.length).equals(kMaxHermesJobNameCharacters);
      check(job.displayName).endsWith('😀');
    });
  });

  test('timestamp parsing accepts only bounded strings and finite numbers', () {
    check(parseHermesTimestamp(const _ExplosiveToString())).isNull();
    check(parseHermesTimestamp(const <String>['1781947724'])).isNull();
    check(parseHermesTimestamp(double.nan)).isNull();
    check(parseHermesTimestamp(double.infinity)).isNull();
    check(parseHermesTimestamp(_repeat('1', 129))).isNull();
    check(parseHermesTimestamp('1781947724')).isNotNull();
  });

  test('message mapper never stringifies structured text, roles, or ids', () {
    final messages = hermesMessagesToChatMessages([
      {
        'id': const _ExplosiveToString(),
        'role': 'user',
        'metadata': {1: 'ignored', 'safe': true},
        'content': <Object?>[
          const _ExplosiveToString(),
          7,
          {'type': const _ExplosiveToString(), 'text': 'forged'},
          {
            'type': 'text',
            'text': const <String>['forged'],
          },
          {'type': 'text', 'text': 'safe'},
        ],
      },
      {
        'role': const <String>['assistant'],
        'content': 'structured role',
      },
      {
        'role': 'assistant',
        'content': 'answer',
        'run_id': const _ExplosiveToString(),
        'response_id': const <String>['forged'],
        'session_id': {'nested': 'forged'},
      },
    ]);

    check(messages).length.equals(2);
    check(messages.first.content).equals('safe');
    check(messages.first.id).not((value) => value.contains('provider value'));
    check(messages.last.metadata).isNull();
  });

  test(
    'skills accept only bounded opaque names and scalar descriptions',
    () async {
      final validDescription = _repeat('d', 4096);
      final service = _SkillsService(<Map<String, dynamic>>[
        {'name': const _ExplosiveToString(), 'description': 'forged'},
        {
          'name': const <String>['nested'],
          'description': 'forged',
        },
        {'name': 'safe-skill', 'description': validDescription},
        {
          'name': 'fallback-title',
          'description': {'nested': 'forged'},
        },
      ]);
      final container = ProviderContainer(
        overrides: [hermesApiServiceProvider.overrideWithValue(service)],
      );
      addTearDown(container.dispose);

      final prompts = await container.read(hermesSkillPromptsProvider.future);
      check(prompts).length.equals(2);
      check(prompts.first.command).equals('/safe-skill');
      check(prompts.first.title).equals(validDescription);
      check(prompts.last.title).isEmpty();
    },
  );

  test('fork alignment rejects coerced roles and identifiers', () {
    final valid = alignHermesForkedMessageIds(
      const <Map<String, dynamic>>[
        {'id': 'source-1', 'role': 'user', 'content': 'same'},
      ],
      const <Map<String, dynamic>>[
        {'id': 'target-1', 'role': 'user', 'content': 'same'},
      ],
    );
    check(
      valid,
    ).isNotNull().deepEquals(<String, String>{'source-1': 'target-1'});
    check(
      alignHermesForkedMessageIds(
        const <Map<String, dynamic>>[
          {'id': 1, 'role': 'user', 'content': 'same'},
        ],
        const <Map<String, dynamic>>[
          {'id': 2, 'role': 'user', 'content': 'same'},
        ],
      ),
    ).isNull();
    check(
      alignHermesForkedMessageIds(
        <Map<String, dynamic>>[
          {
            'id': 'source-1',
            'role': const _ExplosiveToString(),
            'content': 'same',
          },
        ],
        const <Map<String, dynamic>>[
          {'id': 'target-1', 'role': 'user', 'content': 'same'},
        ],
      ),
    ).isNull();
  });

  test('recovery and committed-history statuses never coerce containers', () {
    check(hermesRecoveryStatusForTest(const _ExplosiveToString())).isNull();
    check(hermesRecoveryStatusForTest(const <String>['completed'])).isNull();
    check(hermesRecoveryStatusForTest('COMPLETED')).equals('completed');
    check(isHermesUserHistoryRoleForTest(const _ExplosiveToString())).isFalse();
    check(isHermesUserHistoryRoleForTest(const <String>['user'])).isFalse();
    check(isHermesUserHistoryRoleForTest('USER')).isTrue();
  });

  test('persisted replay scans a bounded number of strict image fields', () {
    final files = <Map<String, dynamic>>[
      for (var index = 0; index < 10000; index++)
        <String, dynamic>{
          'type': const _ExplosiveToString(),
          'url': const _ExplosiveToString(),
        },
      const <String, dynamic>{
        'type': 'image',
        'url': 'https://images.example/too-late.png',
      },
    ];
    final message = ChatMessage(
      id: 'user-1',
      role: 'user',
      content: 'safe text',
      timestamp: DateTime.utc(2026, 7, 14),
      files: files,
    );

    final history = buildHermesVisibleHistoryForTest(<ChatMessage>[
      message,
    ], inputImagesSupported: true);
    check(history).deepEquals(<Map<String, dynamic>>[
      <String, dynamic>{'role': 'user', 'content': 'safe text'},
    ]);
    check(
      persistedHermesReplayRequiresResponsesForTest(
        files: const <Map<String, dynamic>>[
          <String, dynamic>{
            'type': <String>['image'],
          },
        ],
        attachmentIds: const <String>[],
      ),
    ).isFalse();
    check(
      persistedHermesReplayRequiresResponsesForTest(
        files: files,
        attachmentIds: const <String>[],
      ),
    ).isTrue();
  });

  group('bounded Hermes history content', () {
    test(
      'accepts the text boundary and truncates without trust collisions',
      () {
        final sharedPrefix = _repeat(
          'p',
          kHermesMaxHistoryMessageTextCharacters,
        );
        check(hermesMessageTextContent(sharedPrefix)).equals(sharedPrefix);

        final sourceContent = '$sharedPrefix-source-tail';
        final targetContent = '$sharedPrefix-target-tail';
        check(hermesMessageTextContent(sourceContent)).isNull();
        check(hermesMessageTextContent(targetContent)).isNull();
        check(
          alignHermesForkedMessageIds(
            <Map<String, dynamic>>[
              <String, dynamic>{
                'id': 'source-message',
                'role': 'user',
                'content': sourceContent,
              },
            ],
            <Map<String, dynamic>>[
              <String, dynamic>{
                'id': 'target-message',
                'role': 'user',
                'content': targetContent,
              },
            ],
          ),
        ).isNull();

        final mapped = hermesMessagesToChatMessages(<Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'oversized-message',
            'role': 'user',
            'content': sourceContent,
          },
        ]);
        check(mapped).length.equals(1);
        check(mapped.single.content).equals(sharedPrefix);
        check(
          mapped.single.content.runes.length,
        ).equals(kHermesMaxHistoryMessageTextCharacters);
      },
    );

    test('bounds traversal nodes without recursively overflowing', () {
      final atBoundary = <Object?>[
        for (var index = 0; index < kHermesMaxHistoryContentNodes - 1; index++)
          'x',
      ];
      check(
        hermesMessageTextContent(atBoundary),
      ).equals(_repeat('x', kHermesMaxHistoryContentNodes - 1));
      final overBoundary = <Object?>[...atBoundary, 'different-tail'];
      check(hermesMessageTextContent(overBoundary)).isNull();

      Object? deeplyNested = 'safe';
      for (
        var index = 0;
        index < kHermesMaxHistoryContentNodes + 100;
        index++
      ) {
        deeplyNested = <Object?>[deeplyNested];
      }
      check(hermesMessageTextContent(deeplyNested)).isNull();
    });

    test('caps image count and accepts remote URLs only through 8 KiB', () {
      const remotePrefix = 'https://images.example/';
      final exactRemoteUrl =
          '$remotePrefix${_repeat('a', kHermesMaxHistoryRemoteImageUrlCharacters - remotePrefix.length)}';
      final tooLongRemoteUrl = '${exactRemoteUrl}a';
      final content = <Object?>[
        <String, dynamic>{'type': 'input_text', 'text': 'safe'},
        <String, dynamic>{'type': 'input_image', 'url': exactRemoteUrl},
        for (var index = 1; index < kHermesMaxHistoryImages; index++)
          <String, dynamic>{
            'type': 'input_image',
            'url': 'https://images.example/$index.png',
          },
        <String, dynamic>{
          'type': 'input_image',
          'url': 'https://images.example/over-count.png',
        },
        <String, dynamic>{'type': 'input_image', 'url': tooLongRemoteUrl},
      ];

      final mapped = hermesMessagesToChatMessages(<Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'bounded-images',
          'role': 'user',
          'content': content,
        },
      ]).single;
      final attachmentIds = mapped.attachmentIds;
      check(attachmentIds).isNotNull().length.equals(kHermesMaxHistoryImages);
      check(attachmentIds!.first).equals(exactRemoteUrl);
      check(attachmentIds.contains(tooLongRemoteUrl)).isFalse();
      check(hermesMessageTextContent(content)).isNull();
    });

    test('rejects malformed and over-character-budget inline data URLs', () {
      final oversizedDataUrl =
          'data:image/png;base64,${_repeat('A', kHermesMaxHistoryInlineImageDataUrlCharacters)}';
      final mapped = hermesMessagesToChatMessages(<Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'bounded-data-image',
          'role': 'user',
          'content': <Object?>[
            <String, dynamic>{'type': 'input_text', 'text': 'safe'},
            const <String, dynamic>{
              'type': 'input_image',
              'url': 'data:image/png;base64,***',
            },
            <String, dynamic>{'type': 'input_image', 'url': oversizedDataUrl},
          ],
        },
      ]).single;

      check(mapped.content).equals('safe');
      check(mapped.attachmentIds).isNull();
      check(mapped.files).isNull();
      check(
        hermesMessageTextContent(<Object?>[
          <String, dynamic>{'type': 'input_image', 'url': oversizedDataUrl},
        ]),
      ).isNull();
    });
  });
}
