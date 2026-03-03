import 'dart:io' show Platform;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// Native system colors for content on glass surfaces.
///
/// Uses CupertinoColors on iOS for truly native appearance,
/// and Material ColorScheme on other platforms.
class GlassColors {
  GlassColors._();

  /// Primary label color for text and icons on glass.
  static Color label(BuildContext context) {
    if (Platform.isIOS) {
      return CupertinoColors.label.resolveFrom(context);
    }
    return Theme.of(context).colorScheme.onSurface;
  }

  /// Secondary label color for hints, metadata, and
  /// less prominent content on glass.
  static Color secondaryLabel(BuildContext context) {
    if (Platform.isIOS) {
      return CupertinoColors.secondaryLabel
          .resolveFrom(context);
    }
    return Theme.of(context).colorScheme.onSurfaceVariant;
  }
}
