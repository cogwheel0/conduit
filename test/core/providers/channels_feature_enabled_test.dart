import 'dart:io';

import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/models/user.dart';
import 'package:conduit/core/persistence/hive_boxes.dart';
import 'package:conduit/core/persistence/persistence_keys.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/features/auth/providers/unified_auth_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

void main() {
  const testUser = User(
    id: 'user-1',
    username: 'user',
    email: 'user@example.com',
    role: 'user',
  );

  group('channelsFeatureEnabledProvider', () {
    test('defaults to true (optimistic)', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(channelsFeatureEnabledProvider), isTrue);
    });

    test('setEnabled(false) sets state to false', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      container.read(channelsFeatureEnabledProvider.notifier).setEnabled(false);

      expect(container.read(channelsFeatureEnabledProvider), isFalse);
    });

    test('setEnabled(true) after false restores true', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      container.read(channelsFeatureEnabledProvider.notifier).setEnabled(false);
      container.read(channelsFeatureEnabledProvider.notifier).setEnabled(true);

      expect(container.read(channelsFeatureEnabledProvider), isTrue);
    });
  });

  group('server feature availability cache', () {
    late Directory tempDir;
    late Box<dynamic> preferences;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('feature-flags-test-');
      Hive.init(tempDir.path);
      preferences = await Hive.openBox<dynamic>(HiveBoxNames.preferences);
    });

    tearDown(() async {
      await Hive.close();
      await tempDir.delete(recursive: true);
    });

    test(
      'notes feature reads a cached disabled value for active server',
      () async {
        await preferences.put(PreferenceKeys.activeServerId, 'server-1');
        await preferences.put(PreferenceKeys.serverFeatureAvailability, {
          'server-1::user-1': {'notes': false},
        });

        final container = ProviderContainer(
          overrides: [currentUserProvider2.overrideWithValue(testUser)],
        );
        addTearDown(container.dispose);

        expect(container.read(notesFeatureEnabledProvider), isFalse);
      },
    );

    test(
      'setEnabled persists the disabled value for the active server',
      () async {
        await preferences.put(PreferenceKeys.activeServerId, 'server-1');

        final container = ProviderContainer(
          overrides: [currentUserProvider2.overrideWithValue(testUser)],
        );
        addTearDown(container.dispose);

        container
            .read(channelsFeatureEnabledProvider.notifier)
            .setEnabled(false);
        await Future<void>.delayed(Duration.zero);

        final cached = preferences.get(
          PreferenceKeys.serverFeatureAvailability,
        );
        expect(cached, {
          'server-1::user-1': {'channels': false},
        });
      },
    );

    test('recomputes cached flags when the active server changes', () async {
      const server1 = ServerConfig(
        id: 'server-1',
        name: 'Server 1',
        url: 'https://one.example.com',
      );
      const server2 = ServerConfig(
        id: 'server-2',
        name: 'Server 2',
        url: 'https://two.example.com',
      );
      await preferences.put(PreferenceKeys.serverFeatureAvailability, {
        'server-1::user-1': {'notes': false},
        'server-2::user-1': {'notes': true},
      });

      final activeServer =
          NotifierProvider<_ActiveServerNotifier, ServerConfig?>(
            () => _ActiveServerNotifier(server1),
          );
      final container = ProviderContainer(
        overrides: [
          activeServerProvider.overrideWith((ref) => ref.watch(activeServer)),
          currentUserProvider2.overrideWithValue(testUser),
        ],
      );
      addTearDown(container.dispose);

      expect(container.read(notesFeatureEnabledProvider), isFalse);

      container.read(activeServer.notifier).set(server2);

      expect(container.read(notesFeatureEnabledProvider), isTrue);
    });

    test(
      'keeps cached flags isolated between users on the same server',
      () async {
        const secondUser = User(
          id: 'user-2',
          username: 'other',
          email: 'other@example.com',
          role: 'user',
        );
        await preferences.put(PreferenceKeys.activeServerId, 'server-1');
        await preferences.put(PreferenceKeys.serverFeatureAvailability, {
          'server-1::user-1': {'channels': false},
          'server-1::user-2': {'channels': true},
        });

        final currentUser = NotifierProvider<_UserNotifier, User?>(
          () => _UserNotifier(testUser),
        );
        final container = ProviderContainer(
          overrides: [
            currentUserProvider2.overrideWith((ref) => ref.watch(currentUser)),
          ],
        );
        addTearDown(container.dispose);

        expect(container.read(channelsFeatureEnabledProvider), isFalse);

        container.read(currentUser.notifier).set(secondUser);

        expect(container.read(channelsFeatureEnabledProvider), isTrue);
      },
    );

    test(
      'persists feature flags with a token fallback before user restore',
      () async {
        await preferences.put(PreferenceKeys.activeServerId, 'server-1');

        final currentUser = NotifierProvider<_UserNotifier, User?>(
          () => _UserNotifier(null),
        );
        final container = ProviderContainer(
          overrides: [
            authTokenProvider3.overrideWithValue('startup-token'),
            currentUserProvider2.overrideWith((ref) => ref.watch(currentUser)),
          ],
        );
        addTearDown(container.dispose);

        expect(container.read(notesFeatureEnabledProvider), isTrue);

        container.read(notesFeatureEnabledProvider.notifier).setEnabled(false);
        await Future<void>.delayed(Duration.zero);

        container.read(currentUser.notifier).set(testUser);

        expect(container.read(notesFeatureEnabledProvider), isFalse);
        await Future<void>.delayed(Duration.zero);

        final cachedAfterUserRestore = preferences.get(
          PreferenceKeys.serverFeatureAvailability,
        );
        expect(cachedAfterUserRestore, contains('server-1::user-1'));
        expect((cachedAfterUserRestore as Map)['server-1::user-1'], {
          'notes': false,
        });

        container.read(notesFeatureEnabledProvider.notifier).setEnabled(true);
        await Future<void>.delayed(Duration.zero);

        final startupContainer = ProviderContainer(
          overrides: [
            authTokenProvider3.overrideWithValue('startup-token'),
            currentUserProvider2.overrideWithValue(null),
          ],
        );
        addTearDown(startupContainer.dispose);

        expect(startupContainer.read(notesFeatureEnabledProvider), isTrue);
      },
    );
  });
}

class _ActiveServerNotifier extends Notifier<ServerConfig?> {
  _ActiveServerNotifier(this._initial);

  final ServerConfig? _initial;

  @override
  ServerConfig? build() => _initial;

  void set(ServerConfig? server) {
    state = server;
  }
}

class _UserNotifier extends Notifier<User?> {
  _UserNotifier(this._initial);

  final User? _initial;

  @override
  User? build() => _initial;

  void set(User? user) {
    state = user;
  }
}
