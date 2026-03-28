import 'package:flutter/widgets.dart';
import '../theme/theme_extensions.dart';

class SheetHandle extends StatelessWidget {
  final EdgeInsetsGeometry? margin;
  const SheetHandle({super.key, this.margin});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        margin:
            margin ??
            const EdgeInsets.only(top: Spacing.sm, bottom: Spacing.md),
        width: 40,
        height: 4,
        decoration: BoxDecoration(
          color: context.qonduitTheme.textPrimary.withValues(
            alpha: Alpha.medium,
          ),
          borderRadius: BorderRadius.circular(AppBorderRadius.xs),
        ),
      ),
    );
  }
}
