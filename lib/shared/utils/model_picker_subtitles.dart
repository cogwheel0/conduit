import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit_core/utils/model_display_name.dart';

/// The line a model picker shows under each of Apple's Foundation Models, in
/// the app's language: where it runs, in a few words, so those rows take one
/// line like the ids under the other models.
///
/// Null without localizations; the picker then keeps the models' own
/// descriptions.
AppleModelPickerSubtitles? appleModelPickerSubtitles(AppLocalizations? l10n) {
  if (l10n == null) return null;
  return (
    onDevice: l10n.modelPickerAppleOnDeviceSubtitle,
    privateCloud: l10n.modelPickerApplePccSubtitle,
  );
}
