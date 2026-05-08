import 'package:flutter/material.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/adaptive_route_shell.dart';

class SplashLauncherPage extends StatelessWidget {
  const SplashLauncherPage({super.key});

  @override
  Widget build(BuildContext context) {
    return AdaptiveRouteShell(
      body: Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(
            strokeWidth: 2.5,
            valueColor: AlwaysStoppedAnimation<Color>(
              context.conduitTheme.loadingIndicator,
            ),
          ),
        ),
      ),
    );
  }
}
