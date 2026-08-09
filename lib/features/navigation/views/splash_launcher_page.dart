import 'package:flutter/material.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/adaptive_route_shell.dart';

class SplashLauncherPage extends StatefulWidget {
  const SplashLauncherPage({super.key});

  @override
  State<SplashLauncherPage> createState() => _SplashLauncherPageState();
}

class _SplashLauncherPageState extends State<SplashLauncherPage> {
  bool _didPrecacheMarks = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_didPrecacheMarks) return;
    _didPrecacheMarks = true;
    precacheImage(const AssetImage('assets/icons/open_webui.png'), context);
    precacheImage(const AssetImage('assets/icons/hermes_agent.png'), context);
  }

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
