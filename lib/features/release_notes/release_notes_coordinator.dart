import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/persistence/persistence_keys.dart';
import '../../core/persistence/preferences_store.dart';
import '../../core/providers/app_providers.dart';
import '../../core/services/navigation_service.dart';
import '../../core/utils/debug_logger.dart';
import '../../features/auth/providers/unified_auth_providers.dart';
import '../../l10n/app_localizations.dart';
import 'data/release_notes_repository.dart';
import 'release_notes_presenter.dart';
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

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authNavigationStateProvider);
    if (authState == AuthNavigationState.authenticated) {
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
    try {
      if (!mounted || !PreferencesStore.isReady) {
        return;
      }
      if (ref.read(authNavigationStateProvider) !=
          AuthNavigationState.authenticated) {
        return;
      }

      final packageInfo = await ref.read(packageInfoProvider.future);
      if (!mounted) {
        return;
      }

      final currentVersion = packageInfo.version.trim();
      final lastSeenVersion = PreferencesStore.getString(
        PreferenceKeys.lastSeenReleaseVersion,
      );
      final l10nContext = NavigationService.context;
      if (l10nContext == null) {
        return;
      }
      if (!l10nContext.mounted) {
        return;
      }
      if (AppLocalizations.of(l10nContext) == null) {
        return;
      }

      final notes = await widget.repository.load(
        Localizations.localeOf(l10nContext),
      );
      if (!mounted || !l10nContext.mounted) {
        return;
      }
      final decision = widget.service.evaluate(
        currentVersion: currentVersion,
        lastSeenVersion: lastSeenVersion,
        notes: notes,
      );

      switch (decision.type) {
        case ReleaseNotesDecisionType.none:
          completed = true;
          return;
        case ReleaseNotesDecisionType.persistOnly:
          await _markVersionSeen(decision.currentVersion);
          completed = true;
          return;
        case ReleaseNotesDecisionType.show:
          await _showSheet(l10nContext, decision);
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
        if (completed) {
          _completedForSession = true;
        }
      }
    }
  }

  Future<void> _showSheet(
    BuildContext context,
    ReleaseNotesDecision decision,
  ) async {
    await showReleaseNotesSheet(
      context: context,
      currentVersion: decision.currentVersion,
      previousVersion: decision.previousVersion,
      notes: decision.notes,
    );
  }

  Future<void> _markVersionSeen(String version) {
    return PreferencesStore.put(PreferenceKeys.lastSeenReleaseVersion, version);
  }
}
