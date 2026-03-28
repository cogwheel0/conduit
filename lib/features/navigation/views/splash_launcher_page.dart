import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/material.dart';
import '../../../shared/theme/theme_extensions.dart';

class SplashLauncherPage extends StatelessWidget {
  const SplashLauncherPage({super.key});

  @override
  Widget build(BuildContext context) {
    return AdaptiveScaffold(
      body: Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(
            strokeWidth: 2.5,
            valueColor: AlwaysStoppedAnimation<Color>(
              context.qonduitTheme.loadingIndicator,
            ),
          ),
        ),
      ),
    );
  }
}
