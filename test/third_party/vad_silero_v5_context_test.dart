import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:flutter_test/flutter_test.dart';
// The fix lives in the vendored package (third_party/vad); its model needs
// onnxruntime, which tests cannot load, so the framing is tested on its own.
// ignore: implementation_imports
import 'package:vad/src/platform/native/inference/silero_v5_context.dart';

/// Silero v5 scores each 512-sample frame with the last 64 samples of the
/// frame before it in front, as the reference implementation does (#752).
void main() {
  Float32List frame(int length, double Function(int i) sample) =>
      Float32List.fromList([for (var i = 0; i < length; i++) sample(i)]);

  test('puts 64 samples of silence before the first frame', () {
    final context = SileroV5Context(16000);
    final first = frame(512, (i) => i + 1.0);

    final input = context.prepend(first);

    check(input).length.equals(576);
    check(input.sublist(0, 64)).every((sample) => sample.equals(0));
    check(input.sublist(64)).deepEquals(first);
  });

  test('puts the end of each frame before the next', () {
    final context = SileroV5Context(16000);
    final first = frame(512, (i) => i + 1.0);
    final second = frame(512, (i) => -(i + 1.0));
    final third = frame(512, (i) => 1000.0 + i);

    context.prepend(first);
    final secondInput = context.prepend(second);
    final thirdInput = context.prepend(third);

    check(secondInput.sublist(0, 64)).deepEquals(first.sublist(448));
    check(secondInput.sublist(64)).deepEquals(second);
    check(thirdInput.sublist(0, 64)).deepEquals(second.sublist(448));
  });

  test('forgets the previous frame on reset', () {
    final context = SileroV5Context(16000);
    context.prepend(frame(512, (i) => 1.0));

    context.reset();
    final input = context.prepend(frame(512, (i) => 2.0));

    check(input.sublist(0, 64)).every((sample) => sample.equals(0));
  });

  test('carries 32 samples at 8 kHz', () {
    final context = SileroV5Context(8000);
    final first = frame(256, (i) => i + 1.0);

    context.prepend(first);
    final input = context.prepend(frame(256, (i) => 0));

    check(context.length).equals(32);
    check(input).length.equals(288);
    check(input.sublist(0, 32)).deepEquals(first.sublist(224));
  });

  test('keeps its own copy of the context', () {
    final context = SileroV5Context(16000);
    final first = frame(512, (i) => 3.0);

    final firstInput = context.prepend(first);
    firstInput.fillRange(0, firstInput.length, 9);
    first.fillRange(0, first.length, 9);
    final input = context.prepend(frame(512, (i) => 0));

    check(input.sublist(0, 64)).every((sample) => sample.equals(3));
  });
}
