import 'dart:async';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';

import 'rpc_providers.dart';

/// Questions the server is waiting on a person to answer (WP-3.6).
///
/// Oldest first. Every window holds the same queue: the daemon sends each
/// request to all of them, and a `ui.settled` removes it from all of them
/// when any one answers. So no window offers a choice that no longer
/// counts.
final uiRequestsProvider = NotifierProvider<UiRequests, List<UiRequest>>(
  UiRequests.new,
);

class UiRequests extends Notifier<List<UiRequest>> {
  @override
  List<UiRequest> build() {
    final client = ref.watch(rpcClientProvider);
    final subscription = client.events.listen((envelope) {
      switch (envelope.event) {
        case ConduitEvents.uiRequest:
          final request = UiRequest.fromJson(envelope.payload);
          // A window that reconnects is sent what is waiting again; a
          // request it already holds is the same question, not a second.
          if (state.any((r) => r.requestId == request.requestId)) return;
          state = <UiRequest>[...state, request];
        case ConduitEvents.uiSettled:
          _drop(envelope.payload['requestId'] as String?);
        // The daemon's other request of a window: a page for the system
        // browser, such as an MCP server's sign-in.
        case ConduitEvents.openUrl:
          ref
              .read(windowCommandsProvider)
              .openExternal(OpenUrl.fromJson(envelope.payload).url);
      }
    });
    ref.onDispose(subscription.cancel);
    return const <UiRequest>[];
  }

  /// Answers [request] and takes it off this window's queue.
  ///
  /// Off the queue first, then sent: a slow round trip must not leave the
  /// card on screen inviting a second, contradictory answer.
  Future<void> answer(
    UiRequest request, {
    required bool allow,
    String? text,
  }) async {
    _drop(request.requestId);
    await ref
        .read(rpcClientProvider)
        .call(
          ConduitMethods.uiRespond,
          params: UiResponse(
            requestId: request.requestId,
            choice: allow ? 'allow' : request.defaultChoice,
            text: text,
          ).toJson(),
          decode: (json) => json,
        )
        .catchError((Object _) => <String, dynamic>{});
  }

  void _drop(String? requestId) {
    if (requestId == null) return;
    state = <UiRequest>[
      for (final request in state)
        if (request.requestId != requestId) request,
    ];
  }
}
