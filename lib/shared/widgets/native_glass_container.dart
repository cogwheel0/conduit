import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';

/// Native iOS glass container background with Flutter child overlay.
class NativeGlassContainer extends StatelessWidget {
  const NativeGlassContainer({
    super.key,
    required this.child,
    this.borderRadius,
    this.blurStyle = BlurStyle.systemUltraThinMaterial,
  });

  static const String _viewType = 'conduit/native_glass_container';

  final Widget child;
  final BorderRadius? borderRadius;
  final BlurStyle blurStyle;

  @override
  Widget build(BuildContext context) {
    final br = borderRadius ?? BorderRadius.zero;
    final radius = br.topLeft.x;

    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) {
      return AdaptiveBlurView(
        blurStyle: blurStyle,
        borderRadius: br,
        child: child,
      );
    }

    return ClipRRect(
      borderRadius: br,
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: UiKitView(
                viewType: _viewType,
                creationParams: {
                  'blurStyle': blurStyle.name,
                  'cornerRadius': radius,
                },
                creationParamsCodec: const StandardMessageCodec(),
              ),
            ),
          ),
          child,
        ],
      ),
    );
  }
}
