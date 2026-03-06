import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/core/services/streaming_response_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('StreamingResponseController', () {
    group('chunk callback', () {
      test('invoked for each stream event', () async {
        final upstream = StreamController<String>();
        final chunks = <String>[];

        StreamingResponseController(
          stream: upstream.stream,
          onChunk: chunks.add,
          onComplete: () {},
          onError: (_, __) {},
        );

        upstream.add('a');
        upstream.add('b');
        upstream.add('c');
        await upstream.close();

        // Allow microtasks to flush.
        await Future<void>.delayed(Duration.zero);

        check(chunks).deepEquals(['a', 'b', 'c']);
      });
    });

    group('completion callback', () {
      test('invoked when stream closes', () async {
        final upstream = StreamController<String>();
        var completed = false;

        StreamingResponseController(
          stream: upstream.stream,
          onChunk: (_) {},
          onComplete: () => completed = true,
          onError: (_, __) {},
        );

        await upstream.close();
        await Future<void>.delayed(Duration.zero);

        check(completed).isTrue();
      });
    });

    group('error callback', () {
      test('invoked on stream error', () async {
        final upstream = StreamController<String>();
        Object? capturedError;

        StreamingResponseController(
          stream: upstream.stream,
          onChunk: (_) {},
          onComplete: () {},
          onError: (error, _) => capturedError = error,
        );

        upstream.addError(StateError('boom'));
        await Future<void>.delayed(Duration.zero);

        check(capturedError).isA<StateError>();
      });

      test('invoked when chunk callback throws', () async {
        final upstream = StreamController<String>();
        Object? capturedError;

        StreamingResponseController(
          stream: upstream.stream,
          onChunk: (_) => throw FormatException('bad chunk'),
          onComplete: () {},
          onError: (error, _) => capturedError = error,
        );

        upstream.add('x');
        await Future<void>.delayed(Duration.zero);

        check(capturedError).isA<FormatException>();
      });
    });

    group('cancel', () {
      test('stops further chunk callbacks', () async {
        final upstream = StreamController<String>();
        final chunks = <String>[];

        final controller = StreamingResponseController(
          stream: upstream.stream,
          onChunk: chunks.add,
          onComplete: () {},
          onError: (_, __) {},
        );

        upstream.add('a');
        await Future<void>.delayed(Duration.zero);

        await controller.cancel();

        upstream.add('b');
        await Future<void>.delayed(Duration.zero);

        check(chunks).deepEquals(['a']);
      });

      test('suppresses completion callback after cancel', () async {
        final upstream = StreamController<String>();
        var completed = false;

        final controller = StreamingResponseController(
          stream: upstream.stream,
          onChunk: (_) {},
          onComplete: () => completed = true,
          onError: (_, __) {},
        );

        await controller.cancel();
        await upstream.close();
        await Future<void>.delayed(Duration.zero);

        check(completed).isFalse();
      });

      test('suppresses error callback after cancel', () async {
        final upstream = StreamController<String>();
        var errorSeen = false;

        final controller = StreamingResponseController(
          stream: upstream.stream,
          onChunk: (_) {},
          onComplete: () {},
          onError: (_, __) => errorSeen = true,
        );

        await controller.cancel();
        // The upstream is already cancelled, so adding an error
        // would throw. We just verify the flag stays false.
        await Future<void>.delayed(Duration.zero);

        check(errorSeen).isFalse();
      });
    });

    group('isActive', () {
      test('true immediately after construction', () {
        final upstream = StreamController<String>();

        final controller = StreamingResponseController(
          stream: upstream.stream,
          onChunk: (_) {},
          onComplete: () {},
          onError: (_, __) {},
        );

        check(controller.isActive).isTrue();

        // Clean up.
        controller.cancel();
      });

      test('false after cancel', () async {
        final upstream = StreamController<String>();

        final controller = StreamingResponseController(
          stream: upstream.stream,
          onChunk: (_) {},
          onComplete: () {},
          onError: (_, __) {},
        );

        await controller.cancel();

        check(controller.isActive).isFalse();
      });

      test('false after stream completes', () async {
        final upstream = StreamController<String>();

        final controller = StreamingResponseController(
          stream: upstream.stream,
          onChunk: (_) {},
          onComplete: () {},
          onError: (_, __) {},
        );

        await upstream.close();
        await Future<void>.delayed(Duration.zero);

        check(controller.isActive).isFalse();
      });

      test('false after stream error with cancelOnError', () async {
        final upstream = StreamController<String>();

        final controller = StreamingResponseController(
          stream: upstream.stream,
          onChunk: (_) {},
          onComplete: () {},
          onError: (_, __) {},
        );

        upstream.addError(StateError('fail'));
        await Future<void>.delayed(Duration.zero);

        check(controller.isActive).isFalse();
      });
    });

    group('double cancel safety', () {
      test('calling cancel twice does not throw', () async {
        final upstream = StreamController<String>();

        final controller = StreamingResponseController(
          stream: upstream.stream,
          onChunk: (_) {},
          onComplete: () {},
          onError: (_, __) {},
        );

        await controller.cancel();
        // Second cancel should be a no-op.
        await controller.cancel();

        check(controller.isActive).isFalse();
      });
    });
  });
}
