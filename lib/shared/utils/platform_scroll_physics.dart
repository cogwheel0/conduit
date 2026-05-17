import 'package:flutter/material.dart';

ScrollPhysics platformAlwaysScrollablePhysics(BuildContext context) {
  return switch (Theme.of(context).platform) {
    TargetPlatform.iOS || TargetPlatform.macOS => const BouncingScrollPhysics(
      parent: AlwaysScrollableScrollPhysics(),
    ),
    _ => const AlwaysScrollableScrollPhysics(),
  };
}
