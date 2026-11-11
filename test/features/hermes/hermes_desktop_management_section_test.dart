import 'package:conduit/features/hermes/views/hermes_settings_sections.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/widgets/legacy_design_compatibility.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// A Desktop Gateway connection whose Sign Out cannot end its dashboard
/// session (Hermes could not be reached, or did not sign it out).
class _SignOutFails extends HermesConfigController {
  var signOuts = 0;

  @override
  HermesConfig build() =>
      const HermesConfig(mode: HermesBackendMode.desktopGateway);

  @override
  Future<void> signOutDesktop() async {
    signOuts++;
    throw StateError('Hermes dashboard cookies could not be cleared.');
  }
}

void main() {
  // A Sign Out that could not end the dashboard session said only
  // "Hermes action failed.", not what failed or what to do.
  testWidgets('a Sign Out that fails says to check the connection', (
    tester,
  ) async {
    final config = _SignOutFails();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          hermesConfigProvider.overrideWith(() => config),
          hermesInstalledSkillsProvider.overrideWith((ref) async => const []),
        ],
        child: MaterialApp(
          localizationsDelegates: conduitLocalizationsDelegates,
          builder: (context, child) => LegacyDesignCompatibility(child: child!),
          home: const Scaffold(body: HermesDesktopManagementSection()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final l10n = AppLocalizations.of(
      tester.element(find.byType(HermesDesktopManagementSection)),
    )!;

    await tester.tap(find.text(l10n.hermesSignOut));
    await tester.pumpAndSettle();

    expect(config.signOuts, 1);
    expect(find.text(l10n.hermesSignOutFailed), findsOneWidget);
    expect(find.text(l10n.hermesActionFailed), findsNothing);
  });
}
