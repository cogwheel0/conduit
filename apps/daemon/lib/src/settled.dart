import 'package:riverpod/misc.dart' show ProviderListenable;
import 'package:riverpod/riverpod.dart';

/// Awaits [provider]'s value while holding a listener on it.
///
/// Use this instead of `container.read(provider.future)`, everywhere.
///
/// A plain `read` creates no listener. When a provider is still building and
/// one of the providers it `watch`es changes, Riverpod 3 invalidates that
/// build. If something is listening, it rebuilds at once and the pending
/// future resolves with the new result. If nothing is listening, nothing
/// rebuilds it, and the future stays pending until the container is
/// disposed.
///
/// The mobile app never sees this, because a widget is always watching. The
/// daemon has no widgets, so here it was the ordinary case. Signing in
/// certifies the account's storage about 30 ms after the first model read
/// starts. `modelsProvider` watches that certification, so `models.list`
/// hung on every fresh sign-in. The live suite's "lists models" failure had
/// looked like a slow server.
Future<T> readSettled<T>(
  ProviderContainer container,
  ProviderListenable<Future<T>> provider,
) async {
  final subscription = container.listen<Future<T>>(provider, (_, _) {});
  try {
    return await subscription.read();
  } finally {
    subscription.close();
  }
}
