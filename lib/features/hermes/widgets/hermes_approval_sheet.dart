import 'package:material_ui/material_ui.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';

/// Opens once for a new request; dismissing only hides its review surface.
class HermesApprovalSheetLauncher extends StatefulWidget {
  const HermesApprovalSheetLauncher({super.key, required this.builder});
  final WidgetBuilder builder;

  @override
  State<HermesApprovalSheetLauncher> createState() =>
      _HermesApprovalSheetLauncherState();
}

class _HermesApprovalSheetLauncherState
    extends State<HermesApprovalSheetLauncher> {
  ModalRoute<void>? _route;
  NavigatorState? _navigator;
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && ModalRoute.of(context)?.isCurrent != false) _open();
    });
  }

  Future<void> _open() async {
    if (!mounted || _opening) return;
    _opening = true;
    FocusManager.instance.primaryFocus?.unfocus();
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: true,
        backgroundColor: context.conduitTheme.surfaceContainerHighest,
        builder: (sheetContext) {
          _route = ModalRoute.of<void>(sheetContext);
          _navigator = Navigator.of(sheetContext);
          return SafeArea(
            top: false,
            child: SingleChildScrollView(
              padding: EdgeInsets.only(
                bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
              ),
              child: widget.builder(sheetContext),
            ),
          );
        },
      );
    } finally {
      _opening = false;
      _route = null;
      _navigator = null;
    }
  }

  @override
  void dispose() {
    final route = _route;
    final navigator = _navigator;
    if (route != null && navigator != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (navigator.mounted && route.isActive) navigator.removeRoute(route);
      });
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    return Material(
      color: theme.surfaceContainerHighest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: theme.cardBorder),
      ),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        dense: true,
        leading: const Icon(Icons.verified_user_outlined),
        title: Text(l10n.hermesApprovalRequired),
        subtitle: Text(l10n.hermesWaitingForResponse),
        trailing: const Icon(Icons.chevron_right),
        onTap: _open,
      ),
    );
  }
}
