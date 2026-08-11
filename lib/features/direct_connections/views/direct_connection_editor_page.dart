import 'dart:async';

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers/backend_mode_providers.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/services/navigation_service.dart';
import '../../../core/utils/debug_logger.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/themed_dialogs.dart';
import '../../../shared/widgets/connection_components.dart';
import '../../../shared/widgets/utility_components.dart';
import '../controllers/direct_connection_editor_controller.dart';
export '../controllers/direct_connection_editor_controller.dart';
import '../models/direct_connection_profile.dart';
import '../models/direct_remote_model.dart';
import '../models/openwebui_direct_connection.dart';
import '../providers/direct_connection_providers.dart';
import 'direct_connection_editor_sections.dart';

final class _OpenWebUiDirectConnectionOwnershipChanged implements Exception {
  const _OpenWebUiDirectConnectionOwnershipChanged();
}

enum DirectEditorEntry { overview, chooser }

class DirectConnectionEditorPage extends ConsumerStatefulWidget {
  const DirectConnectionEditorPage({
    super.key,
    required this.profileId,
    this.isOnboarding = false,
    this.isOpenWebUi = false,
    this.entry = DirectEditorEntry.overview,
  });

  final String profileId;
  final bool isOnboarding;
  final bool isOpenWebUi;
  final DirectEditorEntry entry;

  bool get isNew => profileId == 'new';

  @override
  ConsumerState<DirectConnectionEditorPage> createState() =>
      _DirectConnectionEditorPageState();
}

class _DirectConnectionEditorPageState
    extends ConsumerState<DirectConnectionEditorPage> {
  late final DirectConnectionEditorController _draftController;

  DirectConnectionEditorState get _editorState => _draftController.state;
  bool get _saving => _editorState.operation == DirectEditorOperation.saving;
  bool get _testing => _editorState.operation == DirectEditorOperation.testing;
  bool get _deleting =>
      _editorState.operation == DirectEditorOperation.deleting;
  ConnectionAttemptState get _attempt => _editorState.attempt;
  String? get _operationError => _editorState.operationError;

  @override
  void initState() {
    super.initState();
    _draftController = DirectConnectionEditorController(
      isOpenWebUi: widget.isOpenWebUi,
      isNew: widget.isNew,
    )..addListener(_handleDraftControllerChanged);
  }

  void _handleDraftControllerChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _draftController.removeListener(_handleDraftControllerChanged);
    _draftController.dispose();
    super.dispose();
  }

  void _hydrate(
    DirectConnectionProfile? profile, {
    OpenWebUiDirectConnectionRecord? openWebUiRecord,
  }) {
    _draftController.hydrateOnce(profile, openWebUiRecord: openWebUiRecord);
  }

  void _refreshOpenWebUiRecord(OpenWebUiDirectConnectionRecord? record) {
    if (!_editorState.hydrated) return;
    // A pure reindex changes the compare-and-swap revision without changing
    // the raw content. Refresh only that authoritative base; a same-id edit
    // (for example enable/tags) must retain the stale revision and conflict.
    _draftController.refreshOpenWebUiRecord(record);
  }

  DirectConnectionProfile? _profileById(
    List<DirectConnectionProfile> profiles,
  ) {
    if (widget.isNew) return null;
    for (final profile in profiles) {
      if (profile.id == widget.profileId) return profile;
    }
    return null;
  }

  void _captureOpenWebUiOwner(OpenWebUiDirectConnectionsSnapshot snapshot) {
    _draftController.captureOwner(
      serverId: snapshot.serverId,
      accountId: snapshot.accountId,
      authEpoch: ref.read(openWebUiAuthSessionEpochProvider),
    );
  }

  bool _matchesCapturedOpenWebUiOwner(
    OpenWebUiDirectConnectionsSnapshot snapshot,
  ) => _draftController.ownerMatches(
    serverId: snapshot.serverId,
    accountId: snapshot.accountId,
    authEpoch: ref.read(openWebUiAuthSessionEpochProvider),
  );

  bool _openWebUiOwnerIsCurrent() {
    if (!widget.isOpenWebUi || _editorState.owner == null) return false;
    final snapshot = ref.read(openWebUiDirectConnectionsProvider).value;
    return snapshot != null && _matchesCapturedOpenWebUiOwner(snapshot);
  }

  bool _ensureOpenWebUiOwnerIsCurrent() {
    if (!widget.isOpenWebUi || _openWebUiOwnerIsCurrent()) return true;
    if (mounted) {
      _draftController.setOperationError(
        AppLocalizations.of(context)!.openWebUiDirectConnectionsUnavailable,
      );
    }
    return false;
  }

  DirectConnectionProfile? _buildDraft({required bool validateFields}) {
    final l10n = AppLocalizations.of(context)!;
    final result = _draftController.buildDraft(
      validateFields: validateFields,
      openWebUiFallbackName: l10n.openWebUiDirectConnectionFallbackName,
    );
    return result.profile;
  }

  Future<bool> _confirmOriginSecretTransfer(
    DirectConnectionProfile draft,
  ) async {
    if (_draftController.originSecretsConfirmed ||
        !requiresDirectOriginCredentialConfirmation(
          previous: _draftController.savedProfile,
          draft: draft,
        )) {
      return true;
    }
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await ThemedDialogs.confirm(
      context,
      title: l10n.directConnectionCredentialTransferTitle,
      message: l10n.directConnectionCredentialTransferMessage,
      confirmText: l10n.directConnectionCredentialTransferConfirm,
      barrierDismissible: false,
    );
    if (confirmed && mounted) {
      _draftController.markOriginSecretsConfirmed();
    }
    return confirmed;
  }

  Future<void> _save({DirectConnectionProfile? testedDraft}) async {
    if (_editorState.isBusy || !_ensureOpenWebUiOwnerIsCurrent()) return;
    if (!_draftController.beginOperation(DirectEditorOperation.saving)) return;
    final draft = testedDraft ?? _buildDraft(validateFields: true);
    if (draft == null) {
      if (mounted) _draftController.finishOperation();
      return;
    }
    final originConfirmed = await _confirmOriginSecretTransfer(draft);
    if (!mounted || !originConfirmed) {
      if (mounted) _draftController.finishOperation();
      return;
    }
    try {
      if (widget.isOpenWebUi) {
        if (!_ensureOpenWebUiOwnerIsCurrent()) {
          if (mounted) _draftController.finishOperation();
          return;
        }
        final controller = ref.read(
          openWebUiDirectConnectionsProvider.notifier,
        );
        final authType = switch (_draftController.authentication) {
          DirectAuthenticationMode.bearer => 'bearer',
          DirectAuthenticationMode.none => 'none',
          DirectAuthenticationMode.apiKeyHeader ||
          DirectAuthenticationMode.unsupported => null,
        };
        if (widget.isNew) {
          await controller.add(draft, authType: authType);
        } else {
          final record = _draftController.savedOpenWebUiRecord;
          if (record == null) {
            throw StateError('Open WebUI direct connection not found.');
          }
          await controller.updateConnection(record, draft, authType: authType);
        }
        if (!_ensureOpenWebUiOwnerIsCurrent()) {
          if (mounted) _draftController.finishOperation();
          return;
        }
      } else {
        await ref
            .read(directConnectionProfilesProvider.notifier)
            .upsert(
              draft,
              expectedPrevious: _draftController.savedProfile,
              secretsConfirmedForNewOrigin:
                  !_draftController.originChanged ||
                  !_draftController.savedHasOriginBoundSecrets ||
                  _draftController.originSecretsConfirmed,
            );
      }
      if (!mounted) return;
      if (widget.isOnboarding) {
        context.goNamed(
          RouteNames.directConnections,
          queryParameters: const {'onboarding': 'true'},
        );
      } else {
        context.pop(true);
      }
    } on DirectConnectionProfileConflictException {
      _showSaveConflict();
    } on OpenWebUiDirectConnectionConflictException {
      if (!mounted) return;
      if (!_ensureOpenWebUiOwnerIsCurrent()) {
        _draftController.finishOperation();
        return;
      }
      _showSaveConflict();
    } catch (_) {
      if (!mounted) return;
      if (!_ensureOpenWebUiOwnerIsCurrent()) {
        _draftController.finishOperation();
        return;
      }
      AdaptiveSnackBar.show(
        context,
        message: AppLocalizations.of(context)!.directConnectionSaveFailed,
        type: AdaptiveSnackBarType.error,
      );
      _draftController.finishOperation();
    }
  }

  void _showSaveConflict() {
    if (!mounted) return;
    final message = AppLocalizations.of(context)!.directConnectionSaveConflict;
    _draftController.finishOperation(error: message);
    AdaptiveSnackBar.show(
      context,
      message: message,
      type: AdaptiveSnackBarType.error,
    );
  }

  Future<DirectConnectionProfile?> _testConnection() async {
    if (_editorState.isBusy || !_ensureOpenWebUiOwnerIsCurrent()) return null;
    if (!_draftController.beginOperation(DirectEditorOperation.testing)) {
      return null;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    final draft = _buildDraft(validateFields: true);
    if (draft == null) {
      if (mounted) _draftController.finishOperation();
      return null;
    }
    final originConfirmed = await _confirmOriginSecretTransfer(draft);
    if (!mounted || !originConfirmed) {
      if (mounted) _draftController.finishOperation();
      return null;
    }
    if (!_ensureOpenWebUiOwnerIsCurrent()) {
      if (mounted) _draftController.finishOperation();
      return null;
    }
    _draftController.setAttempt(
      ConnectionAttemptState.connecting(
        AppLocalizations.of(context)!.connecting,
      ),
    );
    try {
      final result = await ref
          .read(directConnectionProfilesProvider.notifier)
          .probe(draft);
      if (!mounted) return null;
      final message = _probeMessage(result, AppLocalizations.of(context)!);
      _draftController.finishOperation(
        attempt: result.reachable
            ? ConnectionAttemptState.connected(message)
            : ConnectionAttemptState.failed(message),
      );
      return result.reachable ? draft : null;
    } catch (_) {
      if (!mounted) return null;
      _draftController.finishOperation(
        attempt: ConnectionAttemptState.failed(
          AppLocalizations.of(context)!.directConnectionReachFailed,
        ),
      );
      return null;
    }
  }

  Future<void> _connectAndSave() async {
    final testedDraft = await _testConnection();
    if (!mounted || testedDraft == null) return;
    await _save(testedDraft: testedDraft);
  }

  Future<void> _delete() async {
    if (_editorState.isBusy) return;
    final saved = _draftController.savedProfile;
    if (saved == null) return;
    final l10n = AppLocalizations.of(context)!;
    if (!_draftController.beginOperation(DirectEditorOperation.deleting)) {
      return;
    }
    try {
      final confirmed = await ThemedDialogs.confirm(
        context,
        title: l10n.directConnectionDeleteTitle,
        message: widget.isOpenWebUi
            ? l10n.openWebUiDirectConnectionDeleteMessage(saved.name)
            : l10n.directConnectionDeleteMessage(saved.name),
        confirmText: l10n.delete,
        isDestructive: true,
      );
      if (!confirmed || !mounted) {
        if (mounted) _draftController.finishOperation();
        return;
      }
      if (!_ensureOpenWebUiOwnerIsCurrent()) {
        if (mounted) _draftController.finishOperation();
        return;
      }
      // Another editor can update the provider while confirmation is open.
      final currentProfiles = await ref.read(
        effectiveDirectConnectionProfilesFutureProvider.future,
      );
      if (!mounted) return;
      if (!_ensureOpenWebUiOwnerIsCurrent()) {
        _draftController.finishOperation();
        return;
      }
      final hasAnotherUsable = currentProfiles.any(
        (profile) => profile.id != saved.id && profile.isUsable,
      );
      final preferredBackendController = ref.read(
        preferredBackendProvider.notifier,
      );
      final clearDirectPreference =
          !hasAnotherUsable &&
          ref.read(preferredBackendProvider) == PreferredBackend.direct;
      var clearedDirectPreference = false;
      if (clearDirectPreference) {
        try {
          await preferredBackendController.set(PreferredBackend.unset);
          clearedDirectPreference = true;
        } catch (error) {
          DebugLogger.error(
            'Failed to clear the direct backend before profile deletion',
            scope: 'direct/editor',
            data: {'errorType': error.runtimeType.toString()},
          );
          rethrow;
        }
      }
      try {
        if (!_ensureOpenWebUiOwnerIsCurrent()) {
          throw const _OpenWebUiDirectConnectionOwnershipChanged();
        }
        if (widget.isOpenWebUi) {
          final record = _draftController.savedOpenWebUiRecord;
          if (record == null) {
            throw StateError('Open WebUI direct connection not found.');
          }
          await ref
              .read(openWebUiDirectConnectionsProvider.notifier)
              .delete(record);
        } else {
          await ref
              .read(directConnectionProfilesProvider.notifier)
              .remove(saved.id);
        }
      } catch (error, stackTrace) {
        final deletionMayHaveCommitted =
            widget.isOpenWebUi &&
            error is OpenWebUiDirectConnectionCommitUncertainException;
        if (clearedDirectPreference && !deletionMayHaveCommitted) {
          try {
            await preferredBackendController.set(PreferredBackend.direct);
          } catch (restoreError) {
            DebugLogger.error(
              'Failed to restore the direct backend after profile deletion failed',
              scope: 'direct/editor',
              data: {'errorType': restoreError.runtimeType.toString()},
            );
          }
        }
        Error.throwWithStackTrace(error, stackTrace);
      }
      if (!mounted) return;
      // The deletion is committed once the repository call returns. A later
      // ownership/UI change must not restore a preference that now points at
      // no usable direct profile.
      if (!_ensureOpenWebUiOwnerIsCurrent()) {
        _draftController.finishOperation();
        return;
      }
      context.pop(true);
    } on _OpenWebUiDirectConnectionOwnershipChanged {
      if (!mounted) return;
      _draftController.finishOperation();
    } catch (error) {
      DebugLogger.error(
        'Direct profile deletion failed',
        scope: 'direct/editor',
        data: {'errorType': error.runtimeType.toString()},
      );
      if (!mounted) return;
      if (!_ensureOpenWebUiOwnerIsCurrent()) {
        _draftController.finishOperation();
        return;
      }
      _draftController.finishOperation();
      AdaptiveSnackBar.show(
        context,
        message: l10n.directConnectionDeleteFailed,
        type: AdaptiveSnackBarType.error,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.isOpenWebUi) return _buildOpenWebUiEditor();

    final l10n = AppLocalizations.of(context)!;
    final profiles = ref.watch(directConnectionProfilesProvider);
    return profiles.when(
      loading: () => _buildEditorScaffold(
        title: widget.isNew
            ? l10n.addDirectConnection
            : l10n.editDirectConnection,
        children: const [
          SizedBox(height: Spacing.xxl),
          Center(child: CircularProgressIndicator.adaptive()),
        ],
        bottomAction: ConduitButton(
          text: AppLocalizations.of(context)!.save,
          isFullWidth: true,
          isLoading: true,
          useNativeLabel: true,
        ),
      ),
      error: (_, _) => _buildEditorScaffold(
        title: widget.isNew
            ? l10n.addDirectConnection
            : l10n.editDirectConnection,
        children: [
          DirectConnectionEditorError(
            onRetry: () =>
                ref.read(directConnectionProfilesProvider.notifier).reload(),
          ),
        ],
      ),
      data: (items) {
        final profile = _profileById(items);
        if (!widget.isNew && profile == null) {
          return _buildEditorScaffold(
            title: l10n.editDirectConnection,
            children: [
              const SizedBox(height: Spacing.xl),
              Center(child: Text(l10n.directConnectionNoLongerExists)),
            ],
          );
        }
        _hydrate(profile);
        return _buildForm(context);
      },
    );
  }

  Widget _buildOpenWebUiEditor() {
    final l10n = AppLocalizations.of(context)!;
    final connections = ref.watch(openWebUiDirectConnectionsProvider);
    return connections.when(
      loading: () => _buildEditorScaffold(
        title: widget.isNew
            ? l10n.addDirectConnection
            : l10n.editDirectConnection,
        children: const [
          SizedBox(height: Spacing.xxl),
          Center(child: CircularProgressIndicator.adaptive()),
        ],
        bottomAction: ConduitButton(
          text: AppLocalizations.of(context)!.save,
          isFullWidth: true,
          isLoading: true,
          useNativeLabel: true,
        ),
      ),
      error: (_, _) => _buildEditorScaffold(
        title: widget.isNew
            ? l10n.addDirectConnection
            : l10n.editDirectConnection,
        children: [
          DirectConnectionEditorError(
            onRetry: () => unawaited(
              ref.read(openWebUiDirectConnectionsProvider.notifier).reload(),
            ),
          ),
        ],
      ),
      data: (snapshot) {
        if (snapshot == null) {
          return _buildEditorScaffold(
            title: widget.isNew
                ? l10n.addDirectConnection
                : l10n.editDirectConnection,
            children: [
              const SizedBox(height: Spacing.xl),
              Center(child: Text(l10n.openWebUiDirectConnectionsUnavailable)),
            ],
          );
        }
        if (_editorState.owner == null) {
          _captureOpenWebUiOwner(snapshot);
        } else if (!_matchesCapturedOpenWebUiOwner(snapshot)) {
          return _buildEditorScaffold(
            title: widget.isNew
                ? l10n.addDirectConnection
                : l10n.editDirectConnection,
            children: [
              const SizedBox(height: Spacing.xl),
              Center(child: Text(l10n.openWebUiDirectConnectionsUnavailable)),
            ],
          );
        }
        final record = widget.isNew
            ? null
            : snapshot.recordByProfileId(widget.profileId);
        if (!widget.isNew && record == null) {
          return _buildEditorScaffold(
            title: l10n.editDirectConnection,
            children: [
              const SizedBox(height: Spacing.xl),
              Center(child: Text(l10n.directConnectionNoLongerExists)),
            ],
          );
        }
        _refreshOpenWebUiRecord(record);
        _hydrate(record?.profile, openWebUiRecord: record);
        return _buildForm(context);
      },
    );
  }

  Widget _buildEditorScaffold({
    required String title,
    required List<Widget> children,
    Widget bottomAction = const SizedBox.shrink(),
  }) {
    if (widget.isOnboarding) {
      final l10n = AppLocalizations.of(context)!;
      return UtilityPageScaffold.auth(
        title: title,
        backLabel: l10n.back,
        backButtonKey: const ValueKey<String>('direct-editor-back-button'),
        onBack: () => context.goNamed(
          widget.entry == DirectEditorEntry.chooser
              ? RouteNames.backendChooser
              : RouteNames.directConnections,
          queryParameters: widget.entry == DirectEditorEntry.chooser
              ? const <String, String>{}
              : const {'onboarding': 'true'},
        ),
        bottomAction: bottomAction,
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      );
    }

    return UtilityPageScaffold.settings(title: title, children: children);
  }

  Widget _buildForm(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final formError =
        _operationError ??
        directDraftValidationMessage(l10n, _draftController.errors.form) ??
        _draftController.errors.profile;
    final content = <Widget>[
      UtilityIdentityHeader(
        leading: ConnectionMark(
          child: Icon(
            widget.isOpenWebUi
                ? (context.usesCupertinoChrome
                      ? CupertinoIcons.cloud
                      : Icons.cloud_outlined)
                : (context.usesCupertinoChrome
                      ? CupertinoIcons.link
                      : Icons.link_rounded),
            color: theme.buttonPrimary,
            size: IconSize.medium,
          ),
        ),
        title: widget.isNew
            ? l10n.directConnectProviderTitle
            : l10n.editDirectConnection,
        subtitle: widget.isOpenWebUi
            ? l10n.openWebUiDirectConnectionEditorDescription
            : l10n.backendChooserDirectSubtitle,
        trailing: widget.isOpenWebUi
            ? Text(
                l10n.openWebUiDirectConnectionSourceLabel,
                style: theme.bodySmall?.copyWith(color: theme.textTertiary),
              )
            : null,
      ),
      const SizedBox(height: Spacing.xl),
      if (!widget.isOnboarding) ...[
        DirectConnectionAvailabilitySection(controller: _draftController),
        const SizedBox(height: Spacing.lg),
      ],
      DirectConnectionProviderSection(controller: _draftController),
      const SizedBox(height: Spacing.lg),
      DirectConnectionDetailsSection(controller: _draftController),
      if (formError != null) ...[
        const SizedBox(height: Spacing.lg),
        Container(
          key: const ValueKey<String>('direct-form-error'),
          padding: const EdgeInsets.all(Spacing.md),
          decoration: BoxDecoration(
            color: theme.error.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(AppBorderRadius.md),
            border: Border.all(color: theme.error.withValues(alpha: 0.3)),
          ),
          child: Text(
            formError,
            style: theme.bodySmall?.copyWith(color: theme.error),
          ),
        ),
      ],
      const SizedBox(height: Spacing.lg),
      DirectConnectionAdvancedSettingsSection(controller: _draftController),
      if (!widget.isOnboarding) ...[
        const SizedBox(height: Spacing.lg),
        Wrap(
          spacing: Spacing.md,
          runSpacing: Spacing.sm,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            ConduitButton(
              text: l10n.save,
              icon: Icons.check,
              isLoading: _saving,
              onPressed:
                  _testing ||
                      _deleting ||
                      _draftController.authentication ==
                          DirectAuthenticationMode.unsupported
                  ? null
                  : _save,
            ),
            ConduitButton(
              text: l10n.testDirectConnection,
              isSecondary: true,
              isLoading: _testing,
              useNativeLabel: true,
              onPressed:
                  _saving ||
                      _deleting ||
                      _draftController.authentication ==
                          DirectAuthenticationMode.unsupported
                  ? null
                  : _testConnection,
            ),
            if (_attempt.isVisible)
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320),
                child: ConnectionAttemptBanner(state: _attempt),
              ),
          ],
        ),
      ],
      if (!widget.isNew) ...[
        const SizedBox(height: Spacing.xl),
        ConduitButton(
          text: 'Delete connection',
          icon: Icons.delete_outline,
          isDestructive: true,
          isLoading: _deleting,
          onPressed: _saving || _testing ? null : _delete,
        ),
      ],
    ];

    return _buildEditorScaffold(
      title: widget.isNew
          ? l10n.addDirectConnection
          : l10n.editDirectConnection,
      children: [
        for (final (index, child) in content.indexed)
          AbsorbPointer(
            key: index == 0
                ? const ValueKey<String>('direct-editor-form-interaction-lock')
                : null,
            absorbing: _testing,
            child: child,
          ),
      ],
      bottomAction: widget.isOnboarding
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ConnectionAttemptBanner(state: _attempt),
                if (_attempt.isVisible) const SizedBox(height: Spacing.sm),
                ConduitButton(
                  key: const ValueKey<String>('direct-editor-save-button'),
                  text: l10n.directConnectProvider,
                  isFullWidth: true,
                  isLoading: _testing || _saving,
                  useNativeLabel: true,
                  onPressed:
                      _testing ||
                          _saving ||
                          _deleting ||
                          _draftController.authentication ==
                              DirectAuthenticationMode.unsupported
                      ? null
                      : _connectAndSave,
                ),
              ],
            )
          : const SizedBox.shrink(),
    );
  }
}

class DirectConnectionEditorError extends StatelessWidget {
  const DirectConnectionEditorError({super.key, required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    return Column(
      children: [
        const SizedBox(height: Spacing.xl),
        Text(
          l10n.openWebUiDirectConnectionsLoadFailed,
          style: theme.bodyMedium?.copyWith(color: theme.textSecondary),
        ),
        const SizedBox(height: Spacing.md),
        ConduitButton(
          text: l10n.retry,
          icon: Icons.refresh,
          onPressed: onRetry,
        ),
      ],
    );
  }
}

String _probeMessage(DirectConnectionProbe probe, AppLocalizations l10n) {
  if (!probe.reachable) {
    return probe.message?.trim().isNotEmpty == true
        ? probe.message!.trim()
        : l10n.directConnectionReachFailed;
  }
  final modelCount = probe.modelCount;
  if (modelCount == null) return l10n.directConnectionProbeConnected;
  return l10n.directConnectionProbeConnectedModels(modelCount);
}
