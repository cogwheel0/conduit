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
  late final AnimationController _animationController;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    );
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
      _animationController
        ..stop()
        ..value = 0;
      return;
    }

    if (!_animationController.isAnimating) {
      _animationController.repeat();
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    final ring = RepaintBoundary(
      child: _DotRing(color: widget.color, size: size),
    );

    if (!widget.animate) {
      return ring;
    }

    return SizedBox(
      width: size,
      height: size,
      child: AnimatedBuilder(
        animation: _animationController,
        child: ring,
        builder: (_, child) {
          return Transform.rotate(
            angle: _animationController.value * math.pi * 2,
            child: child,
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }
}

class _DotRing extends StatelessWidget {
  const _DotRing({required this.color, required this.size});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    const dotCount = 5;
    const startAngle = -math.pi / 2;
    final radius = size * 0.34;
    final dotSize = size * 0.22;

    return SizedBox.square(
      dimension: size,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          for (var index = 0; index < dotCount; index += 1)
            Transform.translate(
              offset: Offset(
                math.cos(startAngle + 2 * math.pi * index / dotCount) * radius,
                math.sin(startAngle + 2 * math.pi * index / dotCount) * radius,
              ),
              child: Container(
                width: dotSize,
                height: dotSize,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
            ),
        ],
      ),
    );
  }
}
