import 'package:checks/checks.dart';
import 'package:conduit_core/features/integrations/personal_connection_settings.dart';
import 'package:test/test.dart';

Map<String, dynamic> _keyed(String id, String name) => <String, dynamic>{
  'url': 'https://$id.example',
  'path': '/openapi.json',
  'info': <String, dynamic>{'id': id, 'name': name},
};

Map<String, dynamic> _keyless(String host) => <String, dynamic>{
  'url': 'https://$host.example',
  'path': '/openapi.json',
  'info': <String, dynamic>{'name': host},
};

String _token(List<dynamic> servers, int index) =>
    personalToolServerSelectionId(servers, index);

void main() {
  group('personal tool server selections', () {
    test('a keyed selection follows its server through a reorder', () {
      final before = <dynamic>[_keyed('a', 'A'), _keyed('b', 'B')];
      final after = <dynamic>[before[1], before[0]];

      final result = reconcilePersonalToolSelections(
        before: before,
        after: after,
        indexMap: const <int, int>{0: 1, 1: 0},
        selectedIds: <String>[_token(before, 1), 'calculator'],
      );

      check(result.selectedIds)
          .deepEquals(<String>['direct_server:b', 'calculator']);
      check(result.clearedNames).isEmpty();
      // The same id still names the same server in the new order.
      check(resolvePersonalToolServerToken(after, 'b')).equals(0);
    });

    test(
      'a keyless selection is re-pointed to its server, never to the old slot',
      () {
        final before = <dynamic>[_keyless('x'), _keyless('y')];
        final selectY = _token(before, 1);
        final after = <dynamic>[before[1]]; // x deleted, y moved to slot 0

        // An id taken before the deletion no longer lands on whoever is at 1,
        // and it finds y at its new position by fingerprint.
        check(
          resolvePersonalToolServerToken(
            after,
            selectY.substring(kDirectServerSelectionPrefix.length),
          ),
        ).equals(0);
        final result = reconcilePersonalToolSelections(
          before: before,
          after: after,
          indexMap: const <int, int>{1: 0},
          selectedIds: <String>[selectY],
        );
        check(result.selectedIds).deepEquals(<String>[_token(after, 0)]);
        check(result.clearedNames).isEmpty();
      },
    );

    test('a selection of a removed server is cleared and named', () {
      final before = <dynamic>[_keyless('x'), _keyless('y')];
      final result = reconcilePersonalToolSelections(
        before: before,
        after: <dynamic>[before[1]],
        indexMap: const <int, int>{1: 0},
        selectedIds: <String>[_token(before, 0), _token(before, 1)],
      );

      check(result.clearedNames).deepEquals(<String>['x']);
      check(result.selectedIds).deepEquals(<String>[
        _token(<dynamic>[before[1]], 0),
      ]);
    });

    test(
      'a position taken from an older list never selects a different server',
      () {
        final older = <dynamic>[_keyless('x'), _keyless('y')];
        final staleToken = _token(
          older,
          0,
        ).substring(kDirectServerSelectionPrefix.length);
        final replaced = <dynamic>[_keyless('z'), _keyless('y')];

        check(resolvePersonalToolServerToken(replaced, staleToken)).isNull();
      },
    );

    test(
      'a bare position names no server, even a keyless one at that slot',
      () {
        final servers = <dynamic>[_keyed('a', 'A'), _keyless('y')];

        check(resolvePersonalToolServerToken(servers, '0')).isNull();
        check(resolvePersonalToolServerToken(servers, '1')).isNull();
      },
    );

    test(
      'stamping a key on a keyless server moves its selection to the key',
      () {
        final before = <dynamic>[_keyless('x')];
        final after = <dynamic>[
          <String, dynamic>{
            ...(before[0] as Map<String, dynamic>),
            'info': <String, dynamic>{'name': 'x', 'id': 'conduit-1'},
          },
        ];

        final result = reconcilePersonalToolSelections(
          before: before,
          after: after,
          indexMap: const <int, int>{0: 0},
          selectedIds: <String>[_token(before, 0)],
        );

        check(result.selectedIds)
            .deepEquals(<String>['direct_server:conduit-1']);
      },
    );
  });

  group('personal connection list precedence', () {
    test('a present ui list wins over a stale root list, even when empty', () {
      final root = <dynamic>[
        <String, dynamic>{'url': 'https://stale.example'},
      ];
      final fresh = <dynamic>[
        <String, dynamic>{'url': 'https://fresh.example'},
      ];

      check(
        effectivePersonalServerList(<String, dynamic>{
          'toolServers': root,
          'ui': <String, dynamic>{'toolServers': fresh},
        }, 'toolServers'),
      ).deepEquals(fresh);
      check(
        effectivePersonalServerList(<String, dynamic>{
          'toolServers': root,
          'ui': <String, dynamic>{'toolServers': <dynamic>[]},
        }, 'toolServers'),
      ).isEmpty();
      check(
        effectivePersonalServerList(<String, dynamic>{
          'toolServers': root,
          'ui': <String, dynamic>{'theme': 'dark'},
        }, 'toolServers'),
      ).deepEquals(root);
    });
  });
}
