import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'outbox_drainer.dart';

part 'request_completion_runner_provider.g.dart';

/// Inversion seam (E3) so `core/sync` never imports `features/chat`.
///
/// The concrete [RequestCompletionRunner] lives in
/// `features/chat/services/request_completion_runner.dart` (it touches the
/// streaming providers). The [SyncEngine]'s drainer reads THIS provider to get
/// the runner; `main.dart` `overrideWith`s it with the chat
/// implementation. Until overridden it is a throwing stub — the drainer only
/// invokes it for `requestCompletion` ops, which never exist before the chat
/// layer (and its override) is installed.
@Riverpod(keepAlive: true)
RequestCompletionRunner requestCompletionRunner(Ref ref) =>
    const _UnconfiguredRequestCompletionRunner();

/// Default stub: throws if a `requestCompletion` op is ever drained before the
/// chat implementation overrides this provider. Treated as a transient error
/// by the drainer's default classifier, so the op retries (it never parks the
/// turn on a misconfiguration) until the override lands.
class _UnconfiguredRequestCompletionRunner implements RequestCompletionRunner {
  const _UnconfiguredRequestCompletionRunner();

  @override
  Future<void> run({
    required String chatId,
    required Map<String, dynamic> payload,
  }) {
    throw StateError(
      'requestCompletionRunnerProvider was not overridden with the chat '
      'implementation before a requestCompletion op was drained',
    );
  }
}
