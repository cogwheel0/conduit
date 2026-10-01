import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:conduit_core/persistence/preferences_store.dart';

import 'package:conduit_core/providers/backend_mode_providers.dart';

import 'package:conduit_core/utils/debug_logger.dart';

import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';

import '../../l10n/app_localizations.dart';
import 'data/release_notes_repository.dart';

import 'package:conduit_core/features/release_notes/release_notes_coordination.dart';

import 'release_notes_banner_controller.dart';
import 'services/release_notes_service.dart';
import '../../shared/services/app_package_info.dart';

class ReleaseNotesCoordinator extends ConsumerStatefulWidget {
  const ReleaseNotesCoordinator({
    super.key,
    required this.child,
    this.service = const ReleaseNotesService(),
    this.repository = const ReleaseNotesRepository(),
  });

  final Widget child;
  final ReleaseNotesService service;
  final ReleaseNotesRepository repository;

  @override
  ConsumerState<ReleaseNotesCoordinator> createState() =>
      _ReleaseNotesCoordinatorState();
}

class _ReleaseNotesCoordinatorState
    extends ConsumerState<ReleaseNotesCoordinator> {
  bool _attemptInFlight = false;
  bool _completedForSession = false;
  Locale? _locale;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final locale = Localizations.localeOf(context);
    if (_locale != locale) {
      _locale = locale;
      _completedForSession = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authNavigationStateProvider);
    final preferredBackend = ref.watch(preferredBackendProvider);
    if (canPresentReleaseNotes(authState, preferredBackend)) {
      _scheduleAttempt();
    }
    return widget.child;
  }

  void _scheduleAttempt() {
    if (_attemptInFlight || _completedForSession) {
      return;
    }
    _attemptInFlight = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_maybeShowReleaseNotes());
    });
  }

  Future<void> _maybeShowReleaseNotes() async {
    var completed = false;
    var retryForLocaleChange = false;
    Locale? attemptedLocale;
    try {
      if (!mounted || !PreferencesStore.isReady) {
        return;
      }
      if (!canPresentReleaseNotes(
        ref.read(authNavigationStateProvider),
        ref.read(preferredBackendProvider),
      )) {
        return;
      }

      final packageInfo = await ref.read(packageInfoProvider.future);
      if (!mounted) {
        return;
      }

      final currentVersion = packageInfo.version.trim();
      final lastSeenVersion = readReleaseNotesLastSeenVersion();
      if (AppLocalizations.of(context) == null) {
        return;
      }

      attemptedLocale = _locale ?? Localizations.localeOf(context);
      final notes = await widget.repository.load(attemptedLocale);
      if (!mounted) {
        return;
      }
      if (attemptedLocale != _locale) {
        retryForLocaleChange = true;
        return;
      }
      final banner = ref.read(releaseNotesBannerProvider.notifier);
      await applyReleaseNotesDecision(
        service: widget.service,
        currentVersion: currentVersion,
        lastSeenVersion: lastSeenVersion,
        notes: notes,
        isActive: () => mounted,
        showBanner: banner.show,
        clearBanner: banner.clear,
      );
      completed = true;
    } catch (error, stackTrace) {
      DebugLogger.error(
        'release-notes-coordinator-failed',
        scope: 'release-notes',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      if (mounted) {
        _attemptInFlight = false;
        final localeChanged =
            retryForLocaleChange ||
            (attemptedLocale != null && attemptedLocale != _locale);
        _completedForSession = completed && !localeChanged;
        if (localeChanged) {
          _scheduleAttempt();
        }
      }
    }
  }
}
