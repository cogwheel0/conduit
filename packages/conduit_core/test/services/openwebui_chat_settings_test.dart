import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit_core/models/openwebui_chat_settings.dart';
import 'package:test/test.dart';

/// Expected values below are the reference web client's behavior
/// (`Chat.svelte`: `params?.system || $settings.system ? { role: 'system',
/// content: params?.system ?? $settings?.system ?? '' }`, the
/// `{...$settings.params, ...params, stop: getStopTokens()}` merge, and
/// `settings-access.ts`), written out per case rather than derived from the
/// resolver under test.
void main() {
  group('system message', () {
    // chat params.system x global prompt, per the reference truth table.
    final cases =
        <({String name, Object? saved, String? global, String? expected})>[
          (
            name: 'absent, no global',
            saved: _absent,
            global: null,
            expected: null,
          ),
          (name: 'absent, global', saved: _absent, global: 'G', expected: 'G'),
          (name: 'null, no global', saved: null, global: null, expected: null),
          (name: 'null, global', saved: null, global: 'G', expected: 'G'),
          // `'' || 'G'` is truthy, and `'' ?? 'G'` is '': an empty message.
          (name: 'empty, global', saved: '', global: 'G', expected: ''),
          // `'' || ''` is falsy: nothing is sent at all.
          (name: 'empty, no global', saved: '', global: null, expected: null),
          (
            name: 'empty, blank global',
            saved: '',
            global: '  ',
            expected: null,
          ),
          (name: 'text, global', saved: 'S', global: 'G', expected: 'S'),
          (name: 'text, no global', saved: 'S', global: null, expected: 'S'),
          // Sent verbatim: the reference does not trim a saved prompt.
          (
            name: 'whitespace text',
            saved: '  S  ',
            global: 'G',
            expected: '  S  ',
          ),
        ];
    for (final c in cases) {
      test(c.name, () {
        final params = identical(c.saved, _absent)
            ? <String, dynamic>{}
            : <String, dynamic>{'system': c.saved};
        check(
          resolveOpenWebUiSystemMessage(
            chatParams: params,
            globalSystem: c.global,
          ),
        ).equals(c.expected);
      });
    }

    test(
      'legacy chat.system applies only when params.system is absent or null',
      () {
        check(
          resolveOpenWebUiSystemMessage(
            chatParams: const {},
            legacyChatSystem: ' L ',
            globalSystem: 'G',
          ),
        ).equals('L');
        check(
          resolveOpenWebUiSystemMessage(
            chatParams: const {'system': null},
            legacyChatSystem: 'L',
            globalSystem: 'G',
          ),
        ).equals('L');
        check(
          resolveOpenWebUiSystemMessage(
            chatParams: const {'system': 'S'},
            legacyChatSystem: 'L',
            globalSystem: 'G',
          ),
        ).equals('S');
        // An explicit empty override also beats the legacy field.
        check(
          resolveOpenWebUiSystemMessage(
            chatParams: const {'system': ''},
            legacyChatSystem: 'L',
            globalSystem: 'G',
          ),
        ).equals('');
      },
    );

    test('a malformed saved value is not mistaken for an override', () {
      check(
        resolveOpenWebUiSystemMessage(
          chatParams: const {'system': 42},
          globalSystem: 'G',
        ),
      ).equals('G');
    });
  });

  group('request params', () {
    test('chat keys win over global keys, others are kept, none invented', () {
      final merged = resolveOpenWebUiRequestParams(
        globalParams: {'temperature': 0.2, 'top_p': 0.9, 'seed': 1},
        chatParams: {'temperature': 0.7, 'max_tokens': 64},
      );
      check(merged).deepEquals({
        'temperature': 0.7,
        'top_p': 0.9,
        'seed': 1,
        'max_tokens': 64,
      });
    });

    test(
      'a saved null still overrides the global value (the server skips it)',
      () {
        check(
          resolveOpenWebUiRequestParams(
            globalParams: {'temperature': 0.2},
            chatParams: {'temperature': null},
          ),
        ).deepEquals({'temperature': null});
      },
    );

    test('unknown chat keys travel untouched', () {
      final merged = resolveOpenWebUiRequestParams(
        globalParams: null,
        chatParams: {
          'custom_params': {'a': 1},
          'future_key': [1, 2],
        },
      );
      check(merged).deepEquals({
        'custom_params': {'a': 1},
        'future_key': [1, 2],
      });
    });

    test('no params on either side is an empty map', () {
      check(resolveOpenWebUiRequestParams()).deepEquals({});
    });

    group('stop', () {
      Object? stopOf({Object? global, Object? chat}) =>
          resolveOpenWebUiRequestParams(
            globalParams: {'stop': ?global},
            chatParams: {'stop': ?chat},
          )['stop'];

      test('chat stop wins over global stop', () {
        check(stopOf(global: 'a', chat: 'b'))
            .isA<List<String>>()
            .deepEquals(['b']);
      });

      test('global stop applies when the chat has none', () {
        check(stopOf(global: 'a, b ,,c'))
            .isA<List<String>>()
            .deepEquals(['a', 'b', 'c']);
      });

      test('a list is kept, dropping empty entries', () {
        check(stopOf(chat: ['x', '', 'y']))
            .isA<List<String>>()
            .deepEquals(['x', 'y']);
      });

      test('an empty chat string suppresses the global stop', () {
        // `'' ?? global` is '', which getStopTokens() turns into undefined.
        check(stopOf(global: 'a', chat: '')).isNull();
      });

      test('an explicit null chat stop is the model default, not the global', () {
        final merged = resolveOpenWebUiRequestParams(
          globalParams: {'stop': 'a', 'temperature': 0.2},
          chatParams: {'stop': null, 'temperature': null, 'future': null},
        );
        check(merged.containsKey('stop')).isFalse();
        // Every other explicit null still travels (the server skips it).
        check(merged).deepEquals({'temperature': null, 'future': null});
      });

      test('nothing left means no stop key at all', () {
        check(stopOf(chat: <String>[])).isNull();
        check(stopOf()).isNull();
      });

      test('JSON and percent escapes are decoded like the web client', () {
        check(stopOf(chat: r'\n,User:%20,%E2%9C%93'))
            .isA<List<String>>()
            .deepEquals(['\n', 'User: ', '✓']);
      });

      test('undecodable or non-ASCII tokens are kept as typed', () {
        check(stopOf(chat: r'\x,100%,ユーザー:'))
            .isA<List<String>>()
            .deepEquals([r'\x', '100%', 'ユーザー:']);
      });

      test('stop is normalized once: already-split output is stable', () {
        final first = resolveOpenWebUiRequestParams(
          chatParams: {'stop': 'a,b'},
        );
        final second = resolveOpenWebUiRequestParams(chatParams: first);
        check(second['stop']).isA<List<String>>().deepEquals(['a', 'b']);
      });
    });
  });

  group('params projection', () {
    test('anything but an object reads as empty', () {
      check(openWebUiChatParamsFrom(null)).deepEquals({});
      check(openWebUiChatParamsFrom('oops')).deepEquals({});
      check(openWebUiChatParamsFrom(<Object?>[1])).deepEquals({});
    });

    test('a read is a deep copy, never an alias of the stored value', () {
      final stored = <String, dynamic>{
        'custom_params': {
          'nested': [1, 2],
        },
      };
      final read = openWebUiChatParamsFrom(stored);
      (read['custom_params'] as Map)['nested'] = ['changed'];
      check(stored['custom_params']).isA<Map<String, dynamic>>().deepEquals({
        'nested': [1, 2],
      });
    });

    test('rawExtra envelopes read leniently', () {
      check(
        openWebUiChatParamsFromRawExtra(
          jsonEncode({
            'params': {'seed': 7},
          }),
        ),
      ).deepEquals({'seed': 7});
      check(openWebUiChatParamsFromRawExtra('')).deepEquals({});
      check(openWebUiChatParamsFromRawExtra('not json')).deepEquals({});
      check(openWebUiChatParamsFromRawExtra('[1]')).deepEquals({});
    });
  });

  group('admission snapshot', () {
    test('round-trips params and the reasoning pick', () {
      final snapshot = OpenWebUiChatSettingsSnapshot(
        params: {'temperature': 0.3, 'system': ''},
        reasoningEffort: 'high',
      );
      final restored = OpenWebUiChatSettingsSnapshot.tryFromJson(
        jsonDecode(jsonEncode(snapshot.toJson())),
      );
      check(restored).equals(snapshot);
    });

    test('an intentionally empty snapshot is not an absent one', () {
      final empty = OpenWebUiChatSettingsSnapshot.tryFromJson(
        OpenWebUiChatSettingsSnapshot().toJson(),
      );
      check(empty).isNotNull();
      check(empty!.params).isEmpty();
      check(OpenWebUiChatSettingsSnapshot.tryFromJson(null)).isNull();
    });

    test('unknown versions and malformed shapes read as no snapshot', () {
      check(
        OpenWebUiChatSettingsSnapshot.tryFromJson({
          'v': 99,
          'params': {'a': 1},
        }),
      ).isNull();
      check(OpenWebUiChatSettingsSnapshot.tryFromJson({'params': {}})).isNull();
      check(OpenWebUiChatSettingsSnapshot.tryFromJson({'v': 1, 'params': 'x'}))
          .isNull();
      check(OpenWebUiChatSettingsSnapshot.tryFromJson('x')).isNull();
    });

    test('its params are not mutable through the snapshot', () {
      final snapshot = OpenWebUiChatSettingsSnapshot(params: {'a': 1});
      check(() => snapshot.params['a'] = 2).throws<UnsupportedError>();
    });

    test('the admitted baseline round-trips, a null system message included', () {
      for (final system in <String?>[null, '', 'Be brief']) {
        final snapshot = OpenWebUiChatSettingsSnapshot(
          params: {'seed': 1},
          baseline: OpenWebUiAdmittedBaseline(
            globalParams: {'temperature': 0.2, 'stop': 'a, b'},
            systemMessage: system,
          ),
        );
        final restored = OpenWebUiChatSettingsSnapshot.tryFromJson(
          jsonDecode(jsonEncode(snapshot.toJson())),
        );
        check(restored).equals(snapshot);
        check(restored!.baseline!.systemMessage).equals(system);
        // Stored as typed: normalizing here would normalize it twice later.
        check(restored.baseline!.globalParams['stop']).equals('a, b');
      }
    });

    test('an admitted "no global defaults" is not a missing baseline', () {
      final restored = OpenWebUiChatSettingsSnapshot.tryFromJson(
        jsonDecode(
          jsonEncode(
            OpenWebUiChatSettingsSnapshot(
              baseline: OpenWebUiAdmittedBaseline(),
            ).toJson(),
          ),
        ),
      );
      check(restored!.baseline).isNotNull();
      check(restored.baseline!.globalParams).isEmpty();
      check(restored.baseline!.systemMessage).isNull();
    });

    test('a version 1 snapshot is still read, without a baseline', () {
      final restored = OpenWebUiChatSettingsSnapshot.tryFromJson({
        'v': 1,
        'params': {'seed': 3},
        'reasoningEffort': 'low',
      });
      check(restored).isNotNull();
      check(restored!.params).deepEquals({'seed': 3});
      check(restored.reasoningEffort).equals('low');
      check(restored.baseline).isNull();
    });

    test('a malformed baseline reads as none rather than as empty', () {
      for (final bad in <Object?>[
        'x',
        {'globalParams': 'x', 'systemMessage': null},
        {'globalParams': <String, dynamic>{}},
        {'globalParams': <String, dynamic>{}, 'systemMessage': 5},
      ]) {
        final restored = OpenWebUiChatSettingsSnapshot.tryFromJson({
          'v': 2,
          'params': <String, dynamic>{},
          'baseline': bad,
        });
        check(restored).isNotNull();
        check(restored!.baseline).isNull();
      }
    });
  });

  group('global params in the settings document', () {
    // `SettingsModal.svelte` saves the whole `ui` object, so a global set in
    // the browser lives under `ui.params`; root `params` is the older shape.
    test('ui.params wins over root params', () {
      check(
        openWebUiGlobalParamsFromSettings({
          'ui': {
            'params': {'temperature': 0.7},
          },
          'params': {'temperature': 0.1, 'seed': 9},
        }),
      ).isNotNull().deepEquals({'temperature': 0.7});
    });

    test('an empty ui.params still wins: clearing defaults is a change', () {
      check(
        openWebUiGlobalParamsFromSettings({
          'ui': {'params': <String, dynamic>{}},
          'params': {'temperature': 0.1},
        }),
      ).isNotNull().isEmpty();
    });

    test('root params apply only when ui.params is absent or not an object', () {
      for (final ui in <Object?>[
        null,
        <String, dynamic>{},
        {'params': null},
        {'params': 'x'},
        'x',
      ]) {
        check(
          openWebUiGlobalParamsFromSettings({
            'ui': ui,
            'params': {'seed': 9},
          }),
        ).isNotNull().deepEquals({'seed': 9});
      }
    });

    test('no params anywhere is null, not empty', () {
      check(openWebUiGlobalParamsFromSettings(null)).isNull();
      check(openWebUiGlobalParamsFromSettings(const {})).isNull();
      check(openWebUiGlobalParamsFromSettings({'params': 'x'})).isNull();
    });
  });

  group('edit access', () {
    OpenWebUiChatSettingsAccess access(String? role, Map<String, dynamic>? p) =>
        OpenWebUiChatSettingsAccess.fromPermissions(role: role, permissions: p);

    test('an admin may always edit', () {
      final a = access('admin', {
        'chat': {'controls': false, 'system_prompt': false, 'params': false},
      });
      check(a.canEditSystemPrompt).isTrue();
      check(a.canEditParameters).isTrue();
    });

    test(
      'anything the server does not report is allowed, like the web client',
      () {
        for (final p in <Map<String, dynamic>?>[
          null,
          {},
          {'chat': {}},
          {'chat': 'x'},
        ]) {
          final a = access('user', p);
          check(a.canEditSystemPrompt).isTrue();
          check(a.canEditParameters).isTrue();
        }
      },
    );

    test('controls gates both halves', () {
      final a = access('user', {
        'chat': {'controls': false},
      });
      check(a.canEditSystemPrompt).isFalse();
      check(a.canEditParameters).isFalse();
      check(a.canEditAnything).isFalse();
    });

    test('system prompt and parameters are gated independently', () {
      final prompt = access('user', {
        'chat': {'controls': true, 'system_prompt': false, 'params': true},
      });
      check(prompt.canEditSystemPrompt).isFalse();
      check(prompt.canEditParameters).isTrue();
      final params = access('user', {
        'chat': {'controls': true, 'system_prompt': true, 'params': false},
      });
      check(params.canEditSystemPrompt).isTrue();
      check(params.canEditParameters).isFalse();
    });
  });
}

const Object _absent = Object();
