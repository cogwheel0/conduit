import 'package:conduit_core/features/integrations/providers/personal_connections_providers.dart'
    show
        PersonalConnectionsAccess,
        PersonalConnectionsBlock,
        personalConnectionsAccessProvider;
import 'package:conduit_core/providers/app_providers.dart';
import 'package:riverpod/riverpod.dart';

import 'settled.dart';

/// A server feature's rule ([read]) once the backend config and the
/// account's permissions have settled: nothing watches them here, so a cold
/// read would see them loading.
///
/// The config cached at connect time can be read before sign-in, when the
/// server leaves its feature flags out. When [stale] says the answer may be
/// that cached config's, the config is read again once and [read] asked
/// again. Every service that offers a server feature (the composer's tools,
/// personal connections, webhooks) asks through here, so none of them
/// answers from a pre-sign-in config while another refreshes it.
Future<T> readServerRule<T>(
  ProviderContainer container,
  T Function() read, {
  required bool Function(T value) stale,
}) async {
  // Each read starts right before it is awaited: one started early and
  // failing while another is awaited would be an error nobody handles.
  for (final source in <Future<Object?> Function()>[
    () => readSettled(container, backendConfigProvider.future),
    () => readSettled(container, userPermissionsProvider.future),
  ]) {
    try {
      await source();
    } on Object {
      // A failed source reads as a refusal, as core's rules have it.
    }
  }
  var value = read();
  if (stale(value)) {
    try {
      await container.read(backendConfigProvider.notifier).refresh();
    } on Object {
      // Still off, then.
    }
    value = read();
  }
  return value;
}

/// Whether the signed-in account may use personal connections now
/// ([readServerRule] over core's rule).
Future<PersonalConnectionsAccess> readPersonalConnectionsAccess(
  ProviderContainer container,
) async {
  if (container.read(apiServiceProvider) == null) {
    return const PersonalConnectionsAccess.blocked(
      PersonalConnectionsBlock.noAccount,
    );
  }
  return readServerRule(
    container,
    () => container.read(personalConnectionsAccessProvider),
    stale: (access) => access.block == PersonalConnectionsBlock.serverDisabled,
  );
}
