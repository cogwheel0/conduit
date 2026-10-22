import 'package:conduit_core/models/response_animation.dart';
import 'package:material_ui/material_ui.dart';

const responseFinishDuration = Duration(milliseconds: 200);

/// Shared by the chat exit and Settings previews. Progress runs from 1 to 0.
class ResponseFinishTransition extends StatelessWidget {
  const ResponseFinishTransition({
    super.key,
    required this.style,
    required this.progress,
    required this.child,
  });

  final ResponseFinishStyle style;
  final Animation<double> progress;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (style == ResponseFinishStyle.clear) {
      return FadeTransition(
        opacity: progress.drive(CurveTween(curve: const _ClearFinishCurve())),
        child: child,
      );
    }
    return FadeTransition(
      opacity: progress.drive(CurveTween(curve: Curves.easeOutCubic)),
      child: style == ResponseFinishStyle.shrink
          ? ScaleTransition(
              scale: progress.drive(Tween<double>(begin: .72, end: 1)),
              child: child,
            )
          : child,
    );
  }
}

class _ClearFinishCurve extends Curve {
  const _ClearFinishCurve();

  @override
  double transformInternal(double t) => t == 1 ? 1 : 0;
}
