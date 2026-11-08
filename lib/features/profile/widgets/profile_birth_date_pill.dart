import 'package:conduit_core/utils/account_profile_form.dart';
import 'package:flutter/widgets.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/platform_ui/platform_ui.dart';

/// A set birth date on iOS 26: the system's compact date pill, edited in
/// place, with Clear beside it, in the input surface of the account page's
/// other fields.
///
/// Only for a date that is set, as the pill always shows one. Check
/// [AdaptiveCompactDatePicker.isSupported] first.
class ProfileBirthDatePill extends StatelessWidget {
  const ProfileBirthDatePill({
    super.key,
    required this.date,
    required this.onChanged,
    required this.onClear,
  });

  /// The stored birth date.
  final DateTime date;

  /// Called with the picked date in the stored `YYYY-MM-DD` form. Null
  /// disables the pill.
  final ValueChanged<String>? onChanged;

  /// Called when Clear is pressed. Null disables it.
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final onChanged = this.onChanged;
    // Form field, not a grouped surface, like the page's other fields.
    return ConduitCard(
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.md,
        vertical: Spacing.sm,
      ),
      backgroundColor: theme.inputBackground,
      borderColor: theme.inputBorder,
      // The pill's width follows the date and the text size: when Clear no
      // longer fits beside it, Clear moves under it instead of overflowing.
      child: SizedBox(
        width: double.infinity,
        child: Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: Spacing.sm,
          children: [
            AdaptiveCompactDatePicker(
              value: clampProfileBirthDate(date),
              mode: AdaptiveCompactDatePickerMode.date,
              minimumDate: kEarliestProfileBirthDate,
              maximumDate: DateTime.now(),
              semanticLabel: l10n.birthDateLabel,
              onChanged: onChanged == null
                  ? null
                  : (picked) => onChanged(formatProfileBirthDate(picked)),
            ),
            ConduitTextButton(text: l10n.clear, onPressed: onClear),
          ],
        ),
      ),
    );
  }
}
