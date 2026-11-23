import 'package:dio/dio.dart';
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

/// How the daemon's providers retry a failed build.
///
/// Riverpod 3 retries a provider that throws an [Exception] -- ten times,
/// backing off to 6.4 s -- and its `.future` waits for the last attempt.
/// A server's refusal is a `DioException` like any other, so a workspace
/// item that had been deleted took 42 s to come back as not found, and
/// the window sat on a spinner meanwhile. An answer from the server is an
/// answer: a 4xx is not retried. A dropped connection or a 5xx still is,
/// as before.
Duration? daemonProviderRetry(int retryCount, Object error) {
  if (error is Error) return null;
  if (error is DioException) {
    final status = error.response?.statusCode;
    if (status != null && status >= 400 && status < 500) return null;
  }
  if (retryCount >= 10) return null;
  final ms = 200 * (1 << retryCount);
  return Duration(milliseconds: ms > 6400 ? 6400 : ms);
}
