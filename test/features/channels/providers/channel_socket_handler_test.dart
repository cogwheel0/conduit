import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/socket_service.dart';
import 'package:conduit/features/channels/providers/channel_socket_handler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final _socketOwnerProvider =
    NotifierProvider<_MutableSocketOwner, SocketService?>(
      _MutableSocketOwner.new,
    );
final _authEpochOwnerProvider = NotifierProvider<_MutableEpoch, Object>(
  _MutableEpoch.new,
);

void main() {
  test('active channel rebinds when socket or auth owner changes', () async {
    final firstSocket = _RecordingSocketService();
    final replacementSocket = _RecordingSocketService();
    final container = ProviderContainer(
      overrides: [
        socketServiceProvider.overrideWith(
          (ref) => ref.watch(_socketOwnerProvider),
        ),
        openWebUiAuthSessionEpochProvider.overrideWith(
          (ref) => ref.watch(_authEpochOwnerProvider),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.read(_socketOwnerProvider.notifier).set(firstSocket);
    final handlerSubscription = container.listen(
      channelSocketHandlerProvider,
      (_, _) {},
    );
    addTearDown(handlerSubscription.close);

    container
        .read(channelSocketHandlerProvider.notifier)
        .subscribe('channel-1');
    expect(firstSocket.channelSubscriptions, ['channel-1']);

    container.read(_socketOwnerProvider.notifier).set(replacementSocket);
    await pumpEventQueue(times: 3);
    expect(firstSocket.disposeCount, 1);
    expect(replacementSocket.channelSubscriptions, ['channel-1']);

    container.read(_authEpochOwnerProvider.notifier).rotate();
    await pumpEventQueue(times: 3);
    expect(replacementSocket.disposeCount, 1);
    expect(replacementSocket.channelSubscriptions, ['channel-1', 'channel-1']);
  });
}

class _MutableSocketOwner extends Notifier<SocketService?> {
  @override
  SocketService? build() => null;

  void set(SocketService? value) => state = value;
}

class _MutableEpoch extends Notifier<Object> {
  @override
  Object build() => Object();

  void rotate() => state = Object();
}

class _RecordingSocketService implements SocketService {
  final List<String> channelSubscriptions = [];
  int disposeCount = 0;

  @override
  SocketEventSubscription addChannelEventHandler({
    String? conversationId,
    String? sessionId,
    bool requireFocus = true,
    required SocketChannelEventHandler handler,
  }) {
    channelSubscriptions.add(conversationId ?? '');
    return SocketEventSubscription(() {
      disposeCount += 1;
    });
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
