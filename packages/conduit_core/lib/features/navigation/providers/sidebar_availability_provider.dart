import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/navigation/models/sidebar_navigation_model.dart';
import 'package:conduit_core/features/terminal/providers/terminal_providers.dart';
import 'package:conduit_core/providers/app_providers.dart';

/// Which sidebar destinations the session can use, from the signals every
/// host gates them on: the backend in charge, and each Open WebUI feature's
/// own flag.
///
/// The phone's tab bar and the Mac's source list both read this, through
/// [visibleSidebarTabs], so they cannot disagree about when a destination
/// exists.
final sidebarTabAvailabilityProvider = Provider<SidebarTabAvailability>((ref) {
  return SidebarTabAvailability(
    hermesOnly: ref.watch(hermesOnlyModeProvider),
    hasOpenWebUi: ref.watch(openWebUiAccountAvailableProvider),
    hermesEnabled: ref.watch(hermesEnabledProvider),
    notesEnabled: ref.watch(notesFeatureEnabledProvider),
    terminalEnabled: ref.watch(terminalTabVisibleProvider),
    channelsEnabled: ref.watch(channelsFeatureEnabledProvider),
  );
});
