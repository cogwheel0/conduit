import 'dart:async';

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers/app_providers.dart';
import '../../../core/services/navigation_service.dart';
import '../../../core/utils/debug_logger.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/themed_dialogs.dart';
import '../../../shared/widgets/connection_components.dart';
import '../../../shared/widgets/utility_components.dart';
import '../controllers/direct_connection_editor_draft.dart';
import '../controllers/direct_connection_editor_form.dart';
import '../controllers/direct_connection_editor_workflow.dart';
import '../controllers/riverpod_direct_connection_editor_gateway.dart';
import '../models/direct_connection_profile.dart';
import '../models/direct_remote_model.dart';
import '../models/openwebui_direct_connection.dart';
import '../providers/direct_connection_providers.dart';
import 'direct_connection_editor_sections.dart';

enum DirectEditorEntry { overview, chooser }

class DirectConnectionEditorPage extends ConsumerStatefulWidget {
  const DirectConnectionEditorPage({
    super.key,
    required this.mode,
    this.isOnboarding = false,
    this.entry = DirectEditorEntry.overview,
  });

  final DirectConnectionEditorMode mode;
  final bool isOnboarding;
  final DirectEditorEntry entry;

  @override
  ConsumerState<DirectConnectionEditorPage> createState() =>
      _DirectConnectionEditorPageState();
}

class _DirectConnectionEditorPageState
    extends ConsumerState<DirectConnectionEditorPage> {
  late final DirectConnectionEditorWorkflow _workflow;
  ProviderSubscription<AsyncValue<List<DirectConnectionProfile>>>?
  _profilesSubscription;
  ProviderSubscription<AsyncValue<OpenWebUiDirectConnectionsSnapshot?>>?
  _openWebUiSubscription;

  DirectConnectionEditorForm get _form => _workflow.form;

  DirectConnectionEditorMode get _mode => _workflow.mode;
  DirectConnectionEditorState get _editorState => _workflow.state;
  bool get _saving => _editorState.operation == DirectEditorOperation.saving;
  bool get _testing => _editorState.operation == DirectEditorOperation.testing;
  bool get _deleting =>
      _editorState.operation == DirectEditorOperation.deleting;
  ConnectionAttemptState get _attempt => _editorState.attempt;
  String? get _operationError => _editorState.operationError;

  @override
  void initState() {
    super.initState();
    final mode = widget.mode;
    _workflow = DirectConnectionEditorWorkflow(
      target: riverpodDirectConnectionEditorTarget(ref, mode),
    );
    if (mode.isOpenWebUi) {
      _openWebUiSubscription = ref.listenManual(
        openWebUiDirectConnectionsProvider,
        (_, next) => next.whenData(_hydrateFromOpenWebUiSnapshot),
        fireImmediately: true,
      );
    } else {
      _profilesSubscription = ref.listenManual(
        directConnectionProfilesProvider,
        (_, next) => next.whenData(_hydrateFromLocalProfiles),
        fireImmediately: true,
      );
    }
    _workflow.addListener(_handleEditorChanged);
  }

  void _handleEditorChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _profilesSubscription?.close();
    _openWebUiSubscription?.close();
    _workflow.removeListener(_handleEditorChanged);
    _workflow.dispose();
    super.dispose();
  }

  void _hydrateFromLocalProfiles(List<DirectConnectionProfile> profiles) {
    final profile = _profileById(profiles);
    if (!_mode.isNew && profile == null) return;
    _workflow.hydrate(profile);
  }

  void _hydrateFromOpenWebUiSnapshot(
    OpenWebUiDirectConnectionsSnapshot? snapshot,
  ) {
    if (snapshot == null) return;
    if (_editorState.owner == null) {
      _captureOpenWebUiOwner(snapshot);
    } else if (!_matchesCapturedOpenWebUiOwner(snapshot)) {
      return;
    }
    final record = _mode.isNew
        ? null
        : snapshot.recordByProfileId(_mode.profileId!);
    if (!_mode.isNew && record == null) return;
    _refreshOpenWebUiRecord(record);
    _workflow.hydrate(record?.profile, openWebUiRecord: record);
  }

  void _refreshOpenWebUiRecord(OpenWebUiDirectConnectionRecord? record) {
    if (!_editorState.hydrated) return;
    // A pure reindex changes the compare-and-swap revision without changing
    // the raw content. Refresh only that authoritative base; a same-id edit
    // (for example enable/tags) must retain the stale revision and conflict.
    _form.refreshOpenWebUiRecord(record);
  }

  DirectConnectionProfile? _profileById(
    List<DirectConnectionProfile> profiles,
  ) {
    if (_mode.isNew) return null;
    for (final profile in profiles) {
      if (profile.id == _mode.profileId) return profile;
    }
    return null;
  }

  void _captureOpenWebUiOwner(OpenWebUiDirectConnectionsSnapshot snapshot) {
    _workflow.captureOwner(
      serverId: snapshot.serverId,
      accountId: snapshot.accountId,
      authEpoch: ref.read(openWebUiAuthSessionEpochProvider),
    );
  }

  bool _matchesCapturedOpenWebUiOwner(
    OpenWebUiDirectConnectionsSnapshot snapshot,
  ) => _workflow.ownerMatches(
    serverId: snapshot.serverId,
    accountId: snapshot.accountId,
    authEpoch: ref.read(openWebUiAuthSessionEpochProvider),
  );

  bool _openWebUiOwnerIsCurrent() {
    if (!_mode.isOpenWebUi || _editorState.owner == null) return false;
    final snapshot = ref.read(openWebUiDirectConnectionsProvider).value;
    return snapshot != null && _matchesCapturedOpenWebUiOwner(snapshot);
  }

  bool _operationOwnerIsCurrent() =>
      !_mode.isOpenWebUi || (mounted && _openWebUiOwnerIsCurrent());

  DirectEditorMessages _editorMessages() {
    final l10n = AppLocalizations.of(context)!;
    return DirectEditorMessages(
      openWebUiFallbackName: l10n.openWebUiDirectConnectionFallbackName,
      connecting: l10n.connecting,
      reachFailed: l10n.directConnectionReachFailed,
      saveConflict: l10n.directConnectionSaveConflict,
      saveFailed: l10n.directConnectionSaveFailed,
      unavailable: l10n.openWebUiDirectConnectionsUnavailable,
      probeMessage: (probe) => _probeMessage(probe, l10n),
    );
  }

  Future<bool> _confirmOriginSecretTransfer(DirectConnectionProfile draft) {
    final l10n = AppLocalizations.of(context)!;
    return ThemedDialogs.confirm(
      context,
      title: l10n.directConnectionCredentialTransferTitle,
      message: l10n.directConnectionCredentialTransferMessage,
      confirmText: l10n.directConnectionCredentialTransferConfirm,
      barrierDismissible: false,
    );
  }

  Future<bool> _confirmDelete(DirectConnectionProfile saved) {
    final l10n = AppLocalizations.of(context)!;
    return ThemedDialogs.confirm(
      context,
      title: l10n.directConnectionDeleteTitle,
      message: _mode.isOpenWebUi
          ? l10n.openWebUiDirectConnectionDeleteMessage(saved.name)
          : l10n.directConnectionDeleteMessage(saved.name),
      confirmText: l10n.delete,
      isDestructive: true,
    );
  }

  Future<void> _save() async {
    final result = await _workflow.save(
      messages: _editorMessages(),
      confirmCredentialTransfer: _confirmOriginSecretTransfer,
      ownerIsCurrent: _operationOwnerIsCurrent,
    );
    _handleSaveResult(result);
  }

  Future<void> _testConnection() async {
    FocusManager.instance.primaryFocus?.unfocus();
    await _workflow.testConnection(
      messages: _editorMessages(),
      confirmCredentialTransfer: _confirmOriginSecretTransfer,
      ownerIsCurrent: _operationOwnerIsCurrent,
    );
  }

  Future<void> _connectAndSave() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final result = await _workflow.connectAndSave(
      messages: _editorMessages(),
      confirmCredentialTransfer: _confirmOriginSecretTransfer,
      ownerIsCurrent: _operationOwnerIsCurrent,
    );
    _handleSaveResult(result);
  }

  Future<void> _delete() async {
    final result = await _workflow.delete(
      messages: _editorMessages(),
      confirmDelete: _confirmDelete,
      ownerIsCurrent: _operationOwnerIsCurrent,
    );
    if (!mounted) return;
    if (result.succeeded) {
      unawaited(Navigator.of(context).maybePop(true));
      return;
    }
    if (result.outcome == DirectEditorActionOutcome.failed) {
      DebugLogger.error(
        'Direct profile deletion failed',
        scope: 'direct/editor',
        data: {'errorType': result.error.runtimeType.toString()},
      );
      AdaptiveSnackBar.show(
        context,
        message: AppLocalizations.of(context)!.directConnectionDeleteFailed,
        type: AdaptiveSnackBarType.error,
      );
    }
  }

  void _handleSaveResult(DirectEditorActionResult result) {
    if (!mounted) return;
    if (result.succeeded) {
      if (widget.isOnboarding) {
        context.goNamed(
          RouteNames.directConnections,
          queryParameters: const {'onboarding': 'true'},
        );
      } else {
        unawaited(Navigator.of(context).maybePop(true));
      }
      return;
    }
    final message = switch (result.outcome) {
      DirectEditorActionOutcome.conflict => AppLocalizations.of(
        context,
      )!.directConnectionSaveConflict,
      DirectEditorActionOutcome.failed => AppLocalizations.of(
        context,
      )!.directConnectionSaveFailed,
      _ => null,
    };
    if (message != null) {
      AdaptiveSnackBar.show(
        context,
        message: message,
        type: AdaptiveSnackBarType.error,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_mode.isOpenWebUi) return _buildOpenWebUiEditor();

    final l10n = AppLocalizations.of(context)!;
    final profiles = ref.watch(directConnectionProfilesProvider);
    return profiles.when(
      loading: () => _buildEditorScaffold(
        title: _mode.isNew
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
        title: _mode.isNew
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
        if (!_mode.isNew && profile == null) {
          return _buildEditorScaffold(
            title: l10n.editDirectConnection,
            children: [
              const SizedBox(height: Spacing.xl),
              Center(child: Text(l10n.directConnectionNoLongerExists)),
            ],
          );
        }
        return _buildForm(context);
      },
    );
  }

  Widget _buildOpenWebUiEditor() {
    final l10n = AppLocalizations.of(context)!;
    final connections = ref.watch(openWebUiDirectConnectionsProvider);
    return connections.when(
      loading: () => _buildEditorScaffold(
        title: _mode.isNew
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
        title: _mode.isNew
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
            title: _mode.isNew
                ? l10n.addDirectConnection
                : l10n.editDirectConnection,
            children: [
              const SizedBox(height: Spacing.xl),
              Center(child: Text(l10n.openWebUiDirectConnectionsUnavailable)),
            ],
          );
        }
        if (_editorState.owner == null ||
            !_matchesCapturedOpenWebUiOwner(snapshot)) {
          return _buildEditorScaffold(
            title: _mode.isNew
                ? l10n.addDirectConnection
                : l10n.editDirectConnection,
            children: [
              const SizedBox(height: Spacing.xl),
              Center(child: Text(l10n.openWebUiDirectConnectionsUnavailable)),
            ],
          );
        }
        final record = _mode.isNew
            ? null
            : snapshot.recordByProfileId(_mode.profileId!);
        if (!_mode.isNew && record == null) {
          return _buildEditorScaffold(
            title: l10n.editDirectConnection,
            children: [
              const SizedBox(height: Spacing.xl),
              Center(child: Text(l10n.directConnectionNoLongerExists)),
            ],
          );
        }
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
        backNavigation: UtilityBackNavigation(
          label: l10n.back,
          buttonKey: const ValueKey<String>('direct-editor-back-button'),
          onPressed: () => context.goNamed(
            widget.entry == DirectEditorEntry.chooser
                ? RouteNames.backendChooser
                : RouteNames.directConnections,
            queryParameters: widget.entry == DirectEditorEntry.chooser
                ? const <String, String>{}
                : const {'onboarding': 'true'},
          ),
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
        directDraftValidationMessage(l10n, _form.errors.form) ??
        _form.errors.profile;
    final content = <Widget>[
      UtilityIdentityHeader(
        leading: ConnectionMark(
          child: Icon(
            _mode.isOpenWebUi
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
        title: _mode.isNew
            ? l10n.directConnectProviderTitle
            : l10n.editDirectConnection,
        subtitle: _mode.isOpenWebUi
            ? l10n.openWebUiDirectConnectionEditorDescription
            : l10n.backendChooserDirectSubtitle,
        trailing: _mode.isOpenWebUi
            ? Text(
                l10n.openWebUiDirectConnectionSourceLabel,
                style: theme.bodySmall?.copyWith(color: theme.textTertiary),
              )
            : null,
      ),
      const SizedBox(height: Spacing.xl),
      if (!widget.isOnboarding) ...[
        DirectConnectionAvailabilitySection(form: _form),
        const SizedBox(height: Spacing.lg),
      ],
      DirectConnectionProviderSection(form: _form),
      const SizedBox(height: Spacing.lg),
      DirectConnectionDetailsSection(form: _form),
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
      DirectConnectionAdvancedSettingsSection(form: _form),
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
                      _form.authentication ==
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
                      _form.authentication ==
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
      if (!_mode.isNew) ...[
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
      title: _mode.isNew ? l10n.addDirectConnection : l10n.editDirectConnection,
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
                          _form.authentication ==
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
