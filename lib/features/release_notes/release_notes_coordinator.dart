import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/persistence/persistence_keys.dart';
import '../../core/persistence/preferences_store.dart';
import '../../core/providers/app_providers.dart';
import '../../core/providers/backend_mode_providers.dart';
import '../../core/utils/debug_logger.dart';
import '../../features/auth/providers/unified_auth_providers.dart';
import '../../l10n/app_localizations.dart';
import 'data/release_notes_repository.dart';
import 'models/release_note.dart';
import 'release_notes_bootstrap.dart';
import 'release_notes_banner_controller.dart';
import 'services/release_notes_service.dart';

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
    if (_canPresentReleaseNotes(authState, preferredBackend)) {
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
      if (!_canPresentReleaseNotes(
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
      final lastSeenVersion = releaseNotesPreviousVersionForEvaluation(
        PreferencesStore.getString(PreferenceKeys.lastSeenReleaseVersion),
      );
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
      final decision = widget.service.evaluate(
        currentVersion: currentVersion,
        lastSeenVersion: lastSeenVersion,
        notes: notes,
      );

      switch (decision.type) {
        case ReleaseNotesDecisionType.none:
          _restoreBanner(currentVersion: currentVersion, notes: notes);
          completed = true;
          return;
        case ReleaseNotesDecisionType.persistOnly:
          await _clearBanner();
          await _markVersionSeen(decision.currentVersion);
          completed = true;
          return;
        case ReleaseNotesDecisionType.show:
          await _prepareBanner(decision);
          await _markVersionSeen(decision.currentVersion);
          completed = true;
          return;
      }
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

  bool _canPresentReleaseNotes(
    AuthNavigationState authState,
    PreferredBackend preferredBackend,
  ) {
    if (authState == AuthNavigationState.authenticated) {
      return true;
    }
    return switch (preferredBackend) {
      PreferredBackend.direct =>
        PreferencesStore.getBool(PreferenceKeys.directConnectionsConfigured) ==
            true,
      PreferredBackend.chatgpt =>
        PreferencesStore.getString(
              PreferenceKeys.chatGptAccountFingerprint,
            )?.isNotEmpty ==
            true,
      PreferredBackend.hermes =>
        PreferencesStore.getBool(PreferenceKeys.hermesEnabled) == true,
      PreferredBackend.unset || PreferredBackend.owui => false,
    };
  }

  Future<void> _markVersionSeen(String version) {
    return PreferencesStore.put(PreferenceKeys.lastSeenReleaseVersion, version);
  }

  Future<void> _prepareBanner(ReleaseNotesDecision decision) async {
    final previousVersion = decision.previousVersion;
    if (previousVersion == null) return;
    await PreferencesStore.put(
      PreferenceKeys.releaseNotesBannerPreviousVersion,
      previousVersion,
    );
    if (!mounted) return;
    ref
        .read(releaseNotesBannerProvider.notifier)
        .show(
          ReleaseNotesBannerData(
            currentVersion: decision.currentVersion,
            notes: decision.notes,
          ),
        );
  }

  void _restoreBanner({
    required String currentVersion,
    required List<ReleaseNote> notes,
  }) {
    final previousVersion = PreferencesStore.getString(
      PreferenceKeys.releaseNotesBannerPreviousVersion,
    );
    final decision = widget.service.evaluate(
      currentVersion: currentVersion,
      lastSeenVersion: previousVersion,
      notes: notes,
    );
    if (decision.type != ReleaseNotesDecisionType.show ||
        decision.previousVersion == null) {
      ref.read(releaseNotesBannerProvider.notifier).clear();
      return;
    }
    ref
        .read(releaseNotesBannerProvider.notifier)
        .show(
          ReleaseNotesBannerData(
            currentVersion: decision.currentVersion,
            notes: decision.notes,
          ),
        );
  }

  Future<void> _clearBanner() async {
    await PreferencesStore.remove(
      PreferenceKeys.releaseNotesBannerPreviousVersion,
    );
    if (mounted) {
      ref.read(releaseNotesBannerProvider.notifier).clear();
    }
  }
}
