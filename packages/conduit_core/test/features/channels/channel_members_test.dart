import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:dio/dio.dart';
import 'package:riverpod/misc.dart' show Override;
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/channels/providers/channel_members_providers.dart';
import 'package:conduit_core/features/channels/providers/channel_providers.dart';
import 'package:conduit_core/models/channel.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/services/worker_manager.dart';

const _server = ServerConfig(
  id: 'test',
  name: 'Test',
  url: 'http://localhost:0',
);

Map<String, dynamic> _groupChannel({
  String id = 'channel-1',
  String? type = 'group',
  String owner = 'user-a',
  bool manager = true,
}) => {
  'id': id,
  'name': 'Team',
  'type': ?type,
  'user_id': owner,
  'is_manager': manager,
};

Map<String, dynamic> _person(int n) => {
  'id': 'user-$n',
  'name': 'Person ${n.toString().padLeft(3, '0')}',
  'email': 'p$n@example.com',
  'role': 'user',
  'is_active': false,
};

List<Map<String, dynamic>> _people(int from, int to) => [
  for (var n = from; n <= to; n++) _person(n),
];

void main() {
  group('browsing', () {
    test('every page is reachable by an ordinary member, listed by name, '
        'without management', () async {
      final harness = await _Harness.open(directory: _people(1, 65));
      final controller = harness.controller();
      await harness.settled();

      var state = harness.state();
      check(state.members).length.equals(30);
      check(state.total).equals(65);
      check(state.hasMore).isTrue();

      await controller.loadMore();
      await controller.loadMore();
      state = harness.state();
      check(state.members.map((m) => m.id))
          .deepEquals([for (final person in _people(1, 65)) person['id']]);
      check(state.hasMore).isFalse();

      final sent = harness.requests.length;
      await controller.loadMore();
      check(harness.requests).length.equals(sent);
      check(harness.requests.map((r) => r.queryParameters['page']))
          .deepEquals([1, 2, 3]);
      for (final request in harness.requests) {
        check(request.queryParameters['order_by']).equals('name');
        check(request.queryParameters['direction']).equals('asc');
        check(request.queryParameters).not((it) => it.containsKey('query'));
      }
      // No mutation was available, and none was sent.
      check(harness.mutations).isEmpty();
    });

    test('a server that repeats a page ends the walk instead of looping, '
        'and shows each user once', () async {
      final firstPage = _people(1, 30);
      final harness = await _Harness.open(
        directory: firstPage,
        handler: (request) => _json({'users': firstPage, 'total': 100}),
      );
      final controller = harness.controller();
      await harness.settled();
      check(harness.state().hasMore).isTrue();

      await controller.loadMore();

      final state = harness.state();
      check(state.members).length.equals(30);
      check(state.hasMore).isFalse();
      check(harness.requests).length.equals(2);
    });

    test('a failed page keeps the members and can be retried', () async {
      var failPageTwo = true;
      late final _Harness harness;
      harness = await _Harness.open(
        directory: _people(1, 65),
        handler: (request) {
          if (request.queryParameters['page'] == 2 && failPageTwo) {
            return _json({'detail': 'boom'}, statusCode: 500);
          }
          return harness.serve(request);
        },
      );
      final controller = harness.controller();
      await harness.settled();

      await controller.loadMore();
      var state = harness.state();
      check(state.members).length.equals(30);
      check(state.loadMoreFailed).isTrue();
      check(state.loadingMore).isFalse();

      failPageTwo = false;
      await controller.loadMore();
      state = harness.state();
      check(state.members).length.equals(60);
      check(state.loadMoreFailed).isFalse();
    });

    test('a stale search result cannot replace a newer one', () async {
      final older = Completer<ResponseBody>();
      final newer = Completer<ResponseBody>();
      late final _Harness harness;
      harness = await _Harness.open(
        directory: _people(1, 5),
        handler: (request) => switch (request.queryParameters['query']) {
          'al' => older.future,
          'bo' => newer.future,
          _ => harness.serve(request),
        },
      );
      final controller = harness.controller();
      await harness.settled();

      final first = controller.setQuery('al');
      final second = controller.setQuery('bo');
      newer.complete(
        _json({
          'users': [_person(2)],
          'total': 1,
        }),
      );
      await second;
      older.complete(
        _json({
          'users': [_person(1)],
          'total': 1,
        }),
      );
      await first;

      final state = harness.state();
      check(state.query).equals('bo');
      check(state.members.map((m) => m.id)).deepEquals(['user-2']);
    });

    test('a page of an earlier query that arrives late is dropped', () async {
      final latePage = Completer<ResponseBody>();
      late final _Harness harness;
      harness = await _Harness.open(
        directory: _people(1, 65),
        handler: (request) {
          final unfilteredSecondPage =
              request.queryParameters['page'] == 2 &&
              !request.queryParameters.containsKey('query');
          return unfilteredSecondPage
              ? latePage.future
              : harness.serve(request);
        },
      );
      final controller = harness.controller();
      await harness.settled();

      final paging = controller.loadMore();
      await pumpEventQueue();
      await controller.setQuery('Person 00');
      final searched = harness.state();
      latePage.complete(_json({'users': _people(31, 60), 'total': 65}));
      await paging;

      final state = harness.state();
      check(state.members.map((m) => m.id))
          .deepEquals(searched.members.map((m) => m.id).toList());
      check(state.query).equals('Person 00');
      check(state.loadingMore).isFalse();
      check(state.nextPage).equals(searched.nextPage);
    });
  });

  group('owner', () {
    test(
      'an account switch while the first page loads hydrates nothing',
      () async {
        final firstPage = Completer<ResponseBody>();
        final harness = await _Harness.open(
          directory: _people(1, 5),
          handler: (request) => firstPage.future,
        );
        harness.controller();
        await pumpEventQueue();
        check(harness.requests).length.equals(1);

        harness.signInAs('user-b', 'token-b');
        firstPage.complete(_json({'users': _people(1, 5), 'total': 5}));
        await pumpEventQueue();

        final state = harness.state();
        check(state.phase).equals(ChannelMembersPhase.ownerChanged);
        check(state.members).isEmpty();
      },
    );

    test('a token that rotates for the same user retires the list, and '
        'nothing more is sent for it', () async {
      final harness = await _Harness.open(
        directory: _people(1, 65),
        channel: _groupChannel(),
      );
      final controller = harness.controller();
      await harness.settled();
      final sent = harness.requests.length;

      // The same account, ApiService and auth epoch; only the bearer changed.
      harness.rotateToken('token-rotated');

      check(harness.state().phase).equals(ChannelMembersPhase.ownerChanged);
      check(harness.state().members).isEmpty();
      await controller.loadMore();
      await controller.setQuery('Person');
      final result = await controller.removeMember('user-5');
      check(result).equals(ChannelMemberMutationResult.ownerChanged);
      check(harness.requests).length.equals(sent);
    });

    test('a mutation that succeeds after an account switch changes nothing '
        'here and reloads nothing', () async {
      final removal = Completer<ResponseBody>();
      late final _Harness harness;
      harness = await _Harness.open(
        directory: _people(1, 5),
        channel: _groupChannel(),
        handler: (request) =>
            request.method == 'POST' ? removal.future : harness.serve(request),
      );
      final controller = harness.controller();
      await harness.settled();

      final pending = controller.removeMember('user-3');
      await pumpEventQueue();
      check(harness.mutations).length.equals(1);
      final sent = harness.requests.length;

      harness.signInAs('user-b', 'token-b');
      removal.complete(_json(true));
      final result = await pending;

      check(result).equals(ChannelMemberMutationResult.ownerChanged);
      check(harness.requests).length.equals(sent);
      check(harness.state().phase).equals(ChannelMembersPhase.ownerChanged);
      check(harness.state().members).isEmpty();
    });
  });

  group('management', () {
    // Each case says whether Add and Remove are offered, and then tries a
    // remove: it is sent exactly when the sheet would have offered it.
    final cases =
        <
          String,
          ({
            bool manage,
            Map<String, dynamic> channel,
            String role,
            Object permissions,
            void Function(_Harness harness)? afterOpen,
          })
        >{
          'owner of a group channel, with Advanced off': (
            manage: true,
            channel: _groupChannel(),
            role: 'user',
            permissions: const <String, dynamic>{},
            afterOpen: null,
          ),
          'admin who manages a group channel they do not own': (
            manage: true,
            channel: _groupChannel(owner: 'someone-else'),
            role: 'admin',
            permissions: const <String, dynamic>{},
            afterOpen: null,
          ),
          'direct message channel': (
            manage: false,
            channel: _groupChannel(type: 'dm'),
            role: 'user',
            permissions: const <String, dynamic>{},
            afterOpen: null,
          ),
          'standard channel without a type': (
            manage: false,
            channel: _groupChannel(type: null),
            role: 'user',
            permissions: const <String, dynamic>{},
            afterOpen: null,
          ),
          'group member who is not a manager': (
            manage: false,
            channel: _groupChannel(manager: false),
            role: 'user',
            permissions: const <String, dynamic>{},
            afterOpen: null,
          ),
          'manager who is neither owner nor admin': (
            manage: false,
            channel: _groupChannel(owner: 'someone-else'),
            role: 'user',
            permissions: const <String, dynamic>{},
            afterOpen: null,
          ),
          'Channels feature turned off for the account': (
            manage: false,
            channel: _groupChannel(),
            role: 'user',
            permissions: const <String, dynamic>{
              'features': {'channels': false},
            },
            afterOpen: null,
          ),
          'permissions the server could not answer': (
            manage: false,
            channel: _groupChannel(),
            role: 'user',
            permissions: StateError('permissions unavailable'),
            afterOpen: null,
          ),
          'another channel became the active one': (
            manage: false,
            channel: _groupChannel(),
            role: 'user',
            permissions: const <String, dynamic>{},
            afterOpen: (harness) =>
                harness.activate(_groupChannel(id: 'channel-2')),
          ),
        };

    for (final entry in cases.entries) {
      test(
        '${entry.key}: ${entry.value.manage ? 'offered and sent' : 'neither offered nor sent'}',
        () async {
          final c = entry.value;
          final harness = await _Harness.open(
            directory: _people(1, 5),
            channel: c.channel,
            role: c.role,
            permissions: c.permissions,
          );
          final controller = harness.controller();
          await harness.settled();
          c.afterOpen?.call(harness);
          final offered = harness.management().canManage;

          final result = await controller.removeMember('user-3');

          // The control is offered exactly when the send is accepted.
          check(offered).equals(c.manage);
          check(result).equals(
            c.manage
                ? ChannelMemberMutationResult.done
                : ChannelMemberMutationResult.notPermitted,
          );
          check(harness.mutations).length.equals(c.manage ? 1 : 0);
        },
      );
    }

    test('add and remove each read the list again from the server', () async {
      final harness = await _Harness.open(
        directory: _people(1, 5),
        channel: _groupChannel(),
      );
      final controller = harness.controller();
      await harness.settled();

      harness.directory.add(_person(6));
      check(await controller.addMembers(userIds: ['user-6']))
          .equals(ChannelMemberMutationResult.done);
      check(harness.state().members.map((m) => m.id)).contains('user-6');
      check(harness.state().total).equals(6);

      check(await controller.removeMember('user-2'))
          .equals(ChannelMemberMutationResult.done);
      check(harness.state().members.map((m) => m.id))
          .not((it) => it.contains('user-2'));
      check(harness.state().total).equals(5);
    });

    test('you cannot remove yourself', () async {
      final harness = await _Harness.open(
        directory: _people(1, 5),
        channel: _groupChannel(owner: 'user-a'),
      );
      final controller = harness.controller();
      await harness.settled();

      check(await controller.removeMember('user-a'))
          .equals(ChannelMemberMutationResult.notPermitted);
      check(harness.mutations).isEmpty();
    });

    test(
      'a server denial changes nothing and the change can be retried',
      () async {
        var deny = true;
        late final _Harness harness;
        harness = await _Harness.open(
          directory: _people(1, 5),
          channel: _groupChannel(),
          handler: (request) => request.method == 'POST' && deny
              ? _json({'detail': 'no'}, statusCode: 403)
              : harness.serve(request),
        );
        final controller = harness.controller();
        await harness.settled();

        check(await controller.removeMember('user-3'))
            .equals(ChannelMemberMutationResult.denied);
        check(harness.state().members.map((m) => m.id)).contains('user-3');
        check(harness.state().mutating).isFalse();

        deny = false;
        check(await controller.removeMember('user-3'))
            .equals(ChannelMemberMutationResult.done);
        check(harness.state().members.map((m) => m.id))
            .not((it) => it.contains('user-3'));
      },
    );

    test('a kind of principal the account may not grant is not sent', () async {
      final harness = await _Harness.open(
        directory: _people(1, 5),
        channel: _groupChannel(),
        permissions: const <String, dynamic>{
          'access_grants': {'allow_users': false},
        },
      );
      final controller = harness.controller();
      await harness.settled();

      // Picker policy narrows what can be added; it does not remove Add.
      check(harness.management().canManage).isTrue();
      check(harness.management().allowUsers).isFalse();
      check(harness.management().allowGroups).isTrue();

      check(await controller.addMembers(userIds: ['user-6']))
          .equals(ChannelMemberMutationResult.notPermitted);
      check(harness.mutations).isEmpty();

      check(await controller.addMembers(groupIds: ['group-1']))
          .equals(ChannelMemberMutationResult.done);
      check(harness.mutations).length.equals(1);
    });

    test('a second change while one is running is refused', () async {
      final removal = Completer<ResponseBody>();
      late final _Harness harness;
      harness = await _Harness.open(
        directory: _people(1, 5),
        channel: _groupChannel(),
        handler: (request) =>
            request.method == 'POST' ? removal.future : harness.serve(request),
      );
      final controller = harness.controller();
      await harness.settled();

      final first = controller.removeMember('user-3');
      await pumpEventQueue();
      check(await controller.removeMember('user-4'))
          .equals(ChannelMemberMutationResult.busy);

      removal.complete(_json(true));
      check(await first).equals(ChannelMemberMutationResult.done);
      check(harness.mutations).length.equals(1);
    });
  });
}

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

class _Session {
  const _Session(this.userId, this.token, this.epoch);

  final String userId;
  final String token;

  /// The auth session the app reports. A token can rotate without it changing.
  final Object epoch;
}

class _SessionNotifier extends Notifier<_Session> {
  @override
  _Session build() => _Session('user-a', 'token-a', Object());

  void set(_Session value) => state = value;
}

final _sessionProvider = NotifierProvider<_SessionNotifier, _Session>(
  _SessionNotifier.new,
);

typedef _Handler = FutureOr<ResponseBody> Function(RequestOptions request);

class _Harness {
  _Harness._(this.container, this.requests, this.directory, this.owner);

  final ProviderContainer container;
  final List<RequestOptions> requests;

  /// The members the fake server holds, in name order.
  final List<Map<String, dynamic>> directory;
  final ChannelMembersOwner owner;

  /// The add and remove requests that reached the server.
  Iterable<RequestOptions> get mutations =>
      requests.where((request) => request.method == 'POST');

  /// The server answers [handler] first; unhandled requests are served from
  /// [directory] by [serve]. [permissions] is the map the server reports, or an
  /// error for a failed read.
  static Future<_Harness> open({
    required List<Map<String, dynamic>> directory,
    Map<String, dynamic>? channel,
    String role = 'user',
    Object permissions = const <String, dynamic>{},
    _Handler? handler,
  }) async {
    final requests = <RequestOptions>[];
    final members = List<Map<String, dynamic>>.of(directory);
    final api = ApiService(
      serverConfig: _server,
      workerManager: WorkerManager(),
    );
    late final _Harness harness;
    api.dio.httpClientAdapter = _Adapter((request) {
      requests.add(request);
      return handler != null ? handler(request) : harness.serve(request);
    });
    api.dio.interceptors.clear();
    final container = ProviderContainer(
      retry: (_, _) => null,
      overrides: <Override>[
        apiServiceProvider.overrideWithValue(api),
        activeServerProvider.overrideWith((ref) => _server),
        authTokenProvider3.overrideWith(
          (ref) => ref.watch(_sessionProvider).token,
        ),
        currentUserProvider2.overrideWith((ref) {
          final session = ref.watch(_sessionProvider);
          return User(
            id: session.userId,
            username: session.userId,
            email: '${session.userId}@example.com',
            role: role,
          );
        }),
        openWebUiAuthSessionEpochProvider.overrideWith(
          (ref) => ref.watch(_sessionProvider.select((s) => s.epoch)),
        ),
        // The shared permissions transport is covered with its own provider;
        // here the policy is a fixture these tests can state.
        userPermissionsProvider.overrideWith((ref) async {
          if (permissions is Map<String, dynamic>) return permissions;
          throw permissions;
        }),
        // Advanced stays off: membership management does not depend on it.
        appSettingsProvider.overrideWithValue(const AppSettings()),
      ],
    );
    addTearDown(container.dispose);
    await container.read(activeServerProvider.future);
    if (channel != null) {
      container
          .read(activeChannelProvider.notifier)
          .set(Channel.fromJson(channel));
    }
    final owner = ChannelMembersOwner.capture(container.read, 'channel-1')!;
    harness = _Harness._(container, requests, members, owner);
    return harness;
  }

  /// Serves the members route and the two write routes from [directory].
  ResponseBody serve(RequestOptions request) {
    if (request.method == 'GET') {
      final query = request.queryParameters['query'] as String?;
      final page = request.queryParameters['page'] as int? ?? 1;
      final matching = [
        for (final person in directory)
          if (query == null ||
              (person['name'] as String).toLowerCase().contains(
                query.toLowerCase(),
              ))
            person,
      ];
      final start = (page - 1) * channelMembersPageSize;
      final slice = matching.skip(start).take(channelMembersPageSize).toList();
      return _json({'users': slice, 'total': matching.length});
    }
    final body = request.data as Map<String, dynamic>;
    if (request.path.endsWith('/members/remove')) {
      final ids = (body['user_ids'] as List).cast<String>();
      directory.removeWhere((person) => ids.contains(person['id']));
    }
    return _json(true);
  }

  void signInAs(String userId, String token) => container
      .read(_sessionProvider.notifier)
      .set(_Session(userId, token, Object()));

  /// Changes only the bearer: same API, same user, same auth epoch.
  void rotateToken(String token) {
    final session = container.read(_sessionProvider);
    container
        .read(_sessionProvider.notifier)
        .set(_Session(session.userId, token, session.epoch));
  }

  void activate(Map<String, dynamic> channel) => container
      .read(activeChannelProvider.notifier)
      .set(Channel.fromJson(channel));

  ChannelMemberManagement management() =>
      container.read(channelMemberManagementProvider(owner));

  ChannelMembersController controller() {
    final provider = channelMembersControllerProvider(owner);
    // A listener keeps the auto-dispose controller alive like an open sheet.
    container.listen(provider, (_, _) {});
    container.listen(channelMemberManagementProvider(owner), (_, _) {});
    return container.read(provider.notifier);
  }

  ChannelMembersState state() =>
      container.read(channelMembersControllerProvider(owner));

  Future<void> settled() async {
    for (var i = 0; i < 50; i++) {
      await pumpEventQueue();
      if (state().phase != ChannelMembersPhase.loading) return;
    }
  }
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.handler);

  final _Handler handler;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => handler(options);

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Object? value, {int statusCode = 200}) => ResponseBody(
  Stream.value(Uint8List.fromList(utf8.encode(jsonEncode(value)))),
  statusCode,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  },
);
