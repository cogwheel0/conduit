import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/features/auth/providers/unified_auth_providers.dart';

class WorkspaceSessionChanged implements Exception {
  const WorkspaceSessionChanged();

  @override
  String toString() => 'The active workspace session changed.';
}

class WorkspaceSessionIdentity {
  const WorkspaceSessionIdentity({
    required this.api,
    required this.serverId,
    required this.userId,
    required this.token,
  });

  final ApiService api;
  final String serverId;
  final String userId;
  final String token;

  static WorkspaceSessionIdentity? watchNullable(Ref ref) {
    final api = ref.watch(apiServiceProvider);
    final serverId = ref.watch(
      activeServerProvider.select((value) => value.asData?.value?.id),
    );
    final userId = ref.watch(currentUserProvider2.select((user) => user?.id));
    final token = ref.watch(authTokenProvider3);
    if (api == null || serverId == null || userId == null || token == null) {
      return null;
    }
    return WorkspaceSessionIdentity(
      api: api,
      serverId: serverId,
      userId: userId,
      token: token,
    );
  }

  static WorkspaceSessionIdentity watch(Ref ref) {
    return watchNullable(ref) ??
        (throw StateError(
          'Workspace requires an authenticated server session.',
        ));
  }

  static WorkspaceSessionIdentity read(Ref ref) {
    final api = ref.read(apiServiceProvider);
    final serverId = ref.read(activeServerProvider).asData?.value?.id;
    final userId = ref.read(currentUserProvider2)?.id;
    final token = ref.read(authTokenProvider3);
    if (api == null || serverId == null || userId == null || token == null) {
      throw StateError('Workspace requires an authenticated server session.');
    }
    return WorkspaceSessionIdentity(
      api: api,
      serverId: serverId,
      userId: userId,
      token: token,
    );
  }

  bool isCurrent(Ref ref) {
    return ref.mounted &&
        identical(api, ref.read(apiServiceProvider)) &&
        serverId == ref.read(activeServerProvider).asData?.value?.id &&
        userId == ref.read(currentUserProvider2)?.id &&
        token == ref.read(authTokenProvider3);
  }

  void ensureCurrent(Ref ref) {
    if (!isCurrent(ref)) throw const WorkspaceSessionChanged();
  }
}
