import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

/// A terminal socket a test drives: it is ready a microtask after it opens,
/// records what the client sends, and receives what the test pushes.
final class FakeEventsChannel implements WebSocketChannel {
  FakeEventsChannel() {
    scheduleMicrotask(() {
      if (!_ready.isCompleted) _ready.complete();
    });
  }

  final StreamController<dynamic> _incoming = StreamController<dynamic>();
  final Completer<void> _ready = Completer<void>();
  final List<Object?> sent = <Object?>[];
  late final _FakeSink _sink = _FakeSink(this);
  bool sinkClosed = false;
  int? _closeCode;

  List<Object?> get decodedSent =>
      sent.map((frame) => jsonDecode(frame! as String)).toList();

  void receive(Object frame) =>
      _incoming.add(frame is String ? frame : jsonEncode(frame));

  void closeFromServer(int code) {
    _closeCode = code;
    unawaited(_incoming.close());
  }

  void failHandshake() {
    _ready.completeError(WebSocketChannelException('refused'));
    _incoming.addError(WebSocketChannelException('refused'));
    unawaited(_incoming.close());
  }

  @override
  Stream<dynamic> get stream => _incoming.stream;

  @override
  WebSocketSink get sink => _sink;

  @override
  Future<void> get ready => _ready.future;

  @override
  int? get closeCode => _closeCode;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _FakeSink implements WebSocketSink {
  _FakeSink(this.channel);

  final FakeEventsChannel channel;

  @override
  void add(Object? data) => channel.sent.add(data);

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    channel.sinkClosed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
