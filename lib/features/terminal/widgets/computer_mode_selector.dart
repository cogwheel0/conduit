import 'package:conduit_core/features/terminal/models/computer_models.dart';
import 'package:flutter/widgets.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/platform_ui/platform_ui.dart';

/// The mode remains explicit, including on terminals with only one surface.
class ComputerModeSelector extends StatelessWidget {
  const ComputerModeSelector({
    super.key,
    required this.capabilities,
    required this.selected,
    required this.onChanged,
  });

  final ComputerCapabilities capabilities;
  final ComputerSurface selected;
  final ValueChanged<ComputerSurface> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (!capabilities.desktop || !capabilities.browser) {
      return Text(
        selected == ComputerSurface.desktop
            ? l10n.computerDesktop
            : l10n.computerBrowser,
        style: const TextStyle(fontWeight: FontWeight.w600),
      );
    }
    return AdaptiveValueSegmentedControl<ComputerSurface>(
      value: selected,
      segments: [
        AdaptiveSegment(
          value: ComputerSurface.desktop,
          label: Text(l10n.computerDesktop),
        ),
        AdaptiveSegment(
          value: ComputerSurface.browser,
          label: Text(l10n.computerBrowser),
        ),
      ],
      onChanged: (value) {
        if (value != selected) onChanged(value);
      },
    );
  }
}
