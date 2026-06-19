// Adapted from loading_animation_widget's FourRotatingDots.
//
// BSD 3-Clause License
//
// Copyright (c) 2021, Watery Desert
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//
// 1. Redistributions of source code must retain the above copyright notice, this
//    list of conditions and the following disclaimer.
//
// 2. Redistributions in binary form must reproduce the above copyright notice,
//    this list of conditions and the following disclaimer in the documentation
//    and/or other materials provided with the distribution.
//
// 3. Neither the name of the copyright holder nor the names of its
//    contributors may be used to endorse or promote products derived from
//    this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
// FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
// DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
// SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
// CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
// OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

import 'dart:math' as math;

import 'package:flutter/material.dart';

class FiveRotatingDots extends StatefulWidget {
  const FiveRotatingDots({
    super.key,
    required this.color,
    required this.size,
    this.animate = true,
  });

  final Color color;
  final double size;
  final bool animate;

  @override
  State<FiveRotatingDots> createState() => _FiveRotatingDotsState();
}

class _FiveRotatingDotsState extends State<FiveRotatingDots>
    with SingleTickerProviderStateMixin {
  static const int _dotCount = 5;
  static const double _startAngle = -math.pi / 2;
  static const double _quarterStepAngle = math.pi / 10;
  static const double _halfStepAngle = math.pi / 5;
  static const double _nearFullTurnAngle = 2 * math.pi - _halfStepAngle;

  AnimationController? _animationController;

  @override
  void initState() {
    super.initState();
    _syncAnimationController();
  }

  @override
  void didUpdateWidget(FiveRotatingDots oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.animate != oldWidget.animate) {
      _syncAnimationController();
    }
  }

  void _syncAnimationController() {
    if (!widget.animate) {
      _animationController?.dispose();
      _animationController = null;
      return;
    }

    _animationController ??= AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    )..repeat();
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    final dotMaxSize = size * 0.30;
    final dotMinSize = size * 0.14;
    final maxOffset = size * 0.35;
    final controller = _animationController;

    if (controller == null) {
      return SizedBox(
        width: size,
        height: size,
        child: _dotStack(
          offsets: _pentagonOffsets(maxOffset),
          dotSize: dotMaxSize,
          color: widget.color,
        ),
      );
    }

    return SizedBox(
      width: size,
      height: size,
      child: AnimatedBuilder(
        animation: controller,
        builder: (_, _) {
          return Stack(
            fit: StackFit.expand,
            children: <Widget>[
              Transform.rotate(
                angle: controller._evalDouble(
                  to: _quarterStepAngle,
                  begin: 0.0,
                  end: 0.18,
                ),
                child: _animatingDots(
                  controller: controller,
                  visible: controller.value <= 0.18,
                  fixedSize: true,
                  color: widget.color,
                  dotInitialSize: dotMaxSize,
                  initialOffset: maxOffset,
                  finalOffset: 0,
                  interval: const Interval(
                    0.0,
                    0.18,
                    curve: Curves.easeInQuart,
                  ),
                ),
              ),
              Transform.rotate(
                angle: controller._evalDouble(
                  from: _quarterStepAngle,
                  to: _halfStepAngle,
                  begin: 0.18,
                  end: 0.36,
                ),
                child: _animatingDots(
                  controller: controller,
                  visible: controller.value >= 0.18 && controller.value <= 0.36,
                  fixedSize: false,
                  color: widget.color,
                  dotInitialSize: dotMaxSize,
                  dotFinalSize: dotMinSize,
                  initialOffset: 0,
                  finalOffset: maxOffset,
                  interval: const Interval(
                    0.18,
                    0.36,
                    curve: Curves.easeOutQuart,
                  ),
                ),
              ),
              _rotatingDots(
                controller: controller,
                visible: controller.value >= 0.36 && controller.value <= 0.60,
                color: widget.color,
                dotSize: dotMinSize,
                initialAngle: _halfStepAngle,
                finalAngle: _nearFullTurnAngle,
                interval: const Interval(
                  0.36,
                  0.60,
                  curve: Curves.easeInOutSine,
                ),
                offset: maxOffset,
              ),
              Transform.rotate(
                angle: controller._evalDouble(
                  from: _nearFullTurnAngle,
                  to: 2 * math.pi,
                  begin: 0.60,
                  end: 0.78,
                ),
                child: _animatingDots(
                  controller: controller,
                  visible: controller.value >= 0.60 && controller.value <= 0.78,
                  fixedSize: false,
                  color: widget.color,
                  dotInitialSize: dotMinSize,
                  dotFinalSize: dotMaxSize,
                  initialOffset: maxOffset,
                  finalOffset: 0,
                  interval: const Interval(
                    0.60,
                    0.78,
                    curve: Curves.easeInQuart,
                  ),
                ),
              ),
              _animatingDots(
                controller: controller,
                visible: controller.value >= 0.78 && controller.value <= 1.0,
                fixedSize: true,
                color: widget.color,
                dotInitialSize: dotMaxSize,
                initialOffset: 0,
                finalOffset: maxOffset,
                interval: const Interval(
                  0.78,
                  0.96,
                  curve: Curves.easeOutQuart,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _rotatingDots({
    required AnimationController controller,
    required bool visible,
    required Color color,
    required double dotSize,
    required double offset,
    required double initialAngle,
    required double finalAngle,
    required Interval interval,
  }) {
    if (!visible) {
      return const SizedBox.shrink();
    }

    final angle = controller._eval(
      Tween<double>(begin: initialAngle, end: finalAngle),
      curve: interval,
    );

    return Transform.rotate(
      angle: angle,
      child: _dotStack(
        offsets: _pentagonOffsets(offset),
        dotSize: dotSize,
        color: color,
      ),
    );
  }

  Widget _animatingDots({
    required AnimationController controller,
    required bool fixedSize,
    required Color color,
    required double dotInitialSize,
    required double initialOffset,
    required double finalOffset,
    required Interval interval,
    required bool visible,
    double? dotFinalSize,
  }) {
    if (!visible) {
      return const SizedBox.shrink();
    }

    final dotSize = fixedSize
        ? dotInitialSize
        : controller._eval(
            Tween<double>(
              begin: dotInitialSize,
              end: dotFinalSize ?? dotInitialSize,
            ),
            curve: interval,
          );

    return _dotStack(
      offsets: List<Offset>.generate(_dotCount, (index) {
        return controller._eval(
          Tween<Offset>(
            begin: _pentagonOffset(initialOffset, index),
            end: _pentagonOffset(finalOffset, index),
          ),
          curve: interval,
        );
      }),
      dotSize: dotSize,
      color: color,
    );
  }

  Widget _dotStack({
    required List<Offset> offsets,
    required double dotSize,
    required Color color,
  }) {
    return Stack(
      alignment: Alignment.center,
      children: <Widget>[
        for (final offset in offsets)
          Transform.translate(
            offset: offset,
            child: _RotatingDot(dotSize: dotSize, color: color),
          ),
      ],
    );
  }

  List<Offset> _pentagonOffsets(double radius) {
    return List<Offset>.generate(
      _dotCount,
      (index) => _pentagonOffset(radius, index),
    );
  }

  Offset _pentagonOffset(double radius, int index) {
    final angle = _startAngle + (2 * math.pi * index / _dotCount);
    return Offset(math.cos(angle) * radius, math.sin(angle) * radius);
  }

  @override
  void dispose() {
    _animationController?.dispose();
    super.dispose();
  }
}

class _RotatingDot extends StatelessWidget {
  const _RotatingDot({required this.dotSize, required this.color});

  final double dotSize;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: dotSize,
      height: dotSize,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

extension _AnimationControllerEval on AnimationController {
  T _eval<T>(Tween<T> tween, {Curve curve = Curves.linear}) {
    return tween.transform(curve.transform(value));
  }

  double _evalDouble({
    double from = 0,
    double to = 1,
    double begin = 0,
    double end = 1,
    Curve curve = Curves.linear,
  }) {
    return _eval(
      Tween<double>(begin: from, end: to),
      curve: Interval(begin, end, curve: curve),
    );
  }
}
