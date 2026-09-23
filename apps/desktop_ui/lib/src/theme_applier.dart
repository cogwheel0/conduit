import 'package:conduit_protocol/conduit_protocol.dart';

/// Applies the chosen palette and mode to the document.
///
/// A port for the same reason [ExternalSignInPort] is one: the settings page
/// and its tests run on the VM, and `document.documentElement` does not exist
/// there. The browser implementation is in `bridge.dart`.
///
/// The contract is deliberately narrow -- two attributes and one variable on
/// one element -- because that is the entire mechanism. `theme.css` is generated with
/// `[data-palette="..."][data-mode="..."]` selectors for every combination,
/// so switching a palette is an attribute write and a repaint, with no
/// stylesheet to rebuild and no flash of the previous colours. The font size
/// is `--ui-font-size`, which the `text-ui-*` scale is computed from.
abstract interface class ThemeApplierPort {
  void apply({
    required String paletteId,
    required AppThemeMode mode,
    int uiFontSize = kDefaultUiFontSize,
  });
}

/// Records what it was asked to do. The default outside a browser.
final class RecordingThemeApplier implements ThemeApplierPort {
  final List<({String paletteId, AppThemeMode mode, int uiFontSize})> applied =
      <({String paletteId, AppThemeMode mode, int uiFontSize})>[];

  @override
  void apply({
    required String paletteId,
    required AppThemeMode mode,
    int uiFontSize = kDefaultUiFontSize,
  }) => applied.add((paletteId: paletteId, mode: mode, uiFontSize: uiFontSize));
}
