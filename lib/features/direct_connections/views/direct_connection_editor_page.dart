import 'dart:async';

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

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

  DirectConnectionEditorForm get _form => _workflow.form;

  DirectConnectionEditorMode get _mode => _workflow.mode;
  DirectConnectionEditorPolicy get _policy => _workflow.policy;
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
      gateway: riverpodDirectConnectionEditorGateway(ref, mode),
    );
    _workflow.addListener(_handleEditorChanged);
  }

  void _handleEditorChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _workflow.removeListener(_handleEditorChanged);
    _workflow.dispose();
    super.dispose();
  }

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
      message: _policy.showsManagedSource
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
    );
    if (mounted &&
        PlatformInfo.isIOS &&
        result.outcome == DirectEditorActionOutcome.invalidDraft &&
        _form.headerError != null) {
      await showDirectConnectionAdvancedSettings(context, _form);
      return;
    }
    _handleSaveResult(result);
  }

  Future<void> _testConnection() async {
    FocusManager.instance.primaryFocus?.unfocus();
    await _workflow.testConnection(
      messages: _editorMessages(),
      confirmCredentialTransfer: _confirmOriginSecretTransfer,
    );
  }

  Future<void> _connectAndSave() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final result = await _workflow.connectAndSave(
      messages: _editorMessages(),
      confirmCredentialTransfer: _confirmOriginSecretTransfer,
    );
    if (mounted &&
        PlatformInfo.isIOS &&
        result.outcome == DirectEditorActionOutcome.invalidDraft &&
        _form.headerError != null) {
      await showDirectConnectionAdvancedSettings(context, _form);
      return;
    }
    _handleSaveResult(result);
  }

  Future<void> _delete() async {
    final result = await _workflow.delete(
      messages: _editorMessages(),
      confirmDelete: _confirmDelete,
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
    final l10n = AppLocalizations.of(context)!;
    return switch (_workflow.resourceState) {
      DirectEditorLoadLoading() => _buildEditorScaffold(
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
        ),
      ),
      DirectEditorLoadFailure() => _buildEditorScaffold(
        title: _mode.isNew
            ? l10n.addDirectConnection
            : l10n.editDirectConnection,
        children: [
          DirectConnectionEditorError(
            onRetry: () => unawaited(_workflow.reload()),
          ),
        ],
      ),
      DirectEditorLoadData(:final resource) => _buildLoadedResource(
        context,
        resource,
      ),
    };
  }

  Widget _buildLoadedResource(
    BuildContext context,
    DirectEditorResource resource,
  ) {
    final l10n = AppLocalizations.of(context)!;
    final ownerChanged =
        _policy.requiresOwnerValidation &&
        !_workflow.resourceOwnerMatches(resource);
    if (ownerChanged ||
        resource.availability == DirectEditorResourceAvailability.unavailable) {
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
    if (resource.availability == DirectEditorResourceAvailability.missing) {
      return _buildEditorScaffold(
        title: l10n.editDirectConnection,
        children: [
          const SizedBox(height: Spacing.xl),
          Center(child: Text(l10n.directConnectionNoLongerExists)),
        ],
      );
    }
    return _buildForm(context);
  }

  Widget _buildEditorScaffold({
    required String title,
    required List<Widget> children,
    Widget bottomAction = const SizedBox.shrink(),
    Widget? trailing,
  }) {
    if (widget.isOnboarding) {
      final l10n = AppLocalizations.of(context)!;
      return UtilityPageScaffold.auth(
        title: title,
        backgroundColor: PlatformInfo.isIOS
            ? CupertinoColors.systemGroupedBackground.resolveFrom(context)
            : null,
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

    return UtilityPageScaffold.settings(
      title: title,
      backgroundColor: PlatformInfo.isIOS
          ? CupertinoColors.systemGroupedBackground.resolveFrom(context)
          : null,
      trailing: trailing,
      contentPadding: PlatformInfo.isIOS
          ? const EdgeInsets.fromLTRB(
              Spacing.screenPadding,
              Spacing.sm,
              Spacing.screenPadding,
              Spacing.lg,
            )
          : null,
      children: children,
    );
  }

  Widget _buildForm(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final formError =
        _operationError ??
        directDraftValidationMessage(l10n, _form.errors.form) ??
        _form.errors.profile;
    final content = <Widget>[
      if (!widget.isOnboarding && !_mode.isNew && !PlatformInfo.isIOS)
        UtilityIdentityHeader(
          leading: ConnectionMark(
            child: Icon(
              _policy.showsManagedSource
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
          subtitle: _policy.showsManagedSource
              ? l10n.openWebUiDirectConnectionEditorDescription
              : l10n.backendChooserDirectSubtitle,
          trailing: _policy.showsManagedSource
              ? Text(
                  l10n.openWebUiDirectConnectionSourceLabel,
                  style: theme.bodySmall?.copyWith(color: theme.textTertiary),
                )
              : null,
        ),
      if (!widget.isOnboarding && !_mode.isNew && !PlatformInfo.isIOS)
        const SizedBox(height: Spacing.xl),
      if (!widget.isOnboarding) ...[
        if (PlatformInfo.isIOS)
          DirectConnectionGeneralSection(form: _form)
        else
          DirectConnectionAvailabilitySection(form: _form),
        SizedBox(height: PlatformInfo.isIOS ? Spacing.md : Spacing.lg),
      ],
      if (widget.isOnboarding || !PlatformInfo.isIOS) ...[
        DirectConnectionProviderSection(form: _form, flat: widget.isOnboarding),
        SizedBox(height: PlatformInfo.isIOS ? Spacing.md : Spacing.lg),
      ],
      DirectConnectionDetailsSection(form: _form, flat: widget.isOnboarding),
      if (formError != null) ...[
        const SizedBox(height: Spacing.lg),
        KeyedSubtree(
          key: const ValueKey<String>('direct-form-error'),
          child: PlatformInfo.isIOS
              ? UtilityStatusBanner(
                  message: formError,
                  tone: UtilityStatusTone.error,
                )
              : Container(
                  padding: const EdgeInsets.all(Spacing.md),
                  decoration: BoxDecoration(
                    color: theme.error.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(AppBorderRadius.md),
                    border: Border.all(
                      color: theme.error.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Text(
                    formError,
                    style: theme.bodySmall?.copyWith(color: theme.error),
                  ),
                ),
        ),
      ],
      SizedBox(height: PlatformInfo.isIOS ? Spacing.md : Spacing.lg),
      DirectConnectionAdvancedSettingsSection(
        form: _form,
        flat: widget.isOnboarding,
      ),
      if (!widget.isOnboarding) ...[
        SizedBox(height: PlatformInfo.isIOS ? Spacing.md : Spacing.lg),
        if (PlatformInfo.isIOS) ...[
          InsetGroupedList(
            useNativeSurface: true,
            children: [
              UtilityRow(
                key: const ValueKey<String>(
                  'direct-editor-test-connection-row',
                ),
                title: l10n.testDirectConnection,
                titleFontWeight: FontWeight.w400,
                foregroundColor: CupertinoColors.activeBlue.resolveFrom(
                  context,
                ),
                enabled:
                    !_saving &&
                    !_deleting &&
                    _form.authentication !=
                        DirectAuthenticationMode.unsupported,
                status: _testing
                    ? const SizedBox.square(
                        dimension: IconSize.small,
                        child: CupertinoActivityIndicator(radius: 8),
                      )
                    : null,
                onTap: _testing ? null : _testConnection,
              ),
            ],
          ),
          if (_attempt.isVisible) ...[
            const SizedBox(height: Spacing.sm),
            ConnectionAttemptBanner(state: _attempt),
          ],
        ] else
          Wrap(
            spacing: Spacing.md,
            runSpacing: Spacing.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ConduitButton(
                text: l10n.save,
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
        if (PlatformInfo.isIOS)
          InsetGroupedList(
            useNativeSurface: true,
            children: [
              UtilityRow(
                title: l10n.delete,
                titleFontWeight: FontWeight.w400,
                destructive: true,
                enabled: !_saving && !_testing,
                status: _deleting
                    ? const SizedBox.square(
                        dimension: IconSize.small,
                        child: CupertinoActivityIndicator(radius: 8),
                      )
                    : null,
                onTap: _deleting ? null : _delete,
              ),
            ],
          )
        else
          ConduitButton(
            text: l10n.delete,
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
                  onPressed:
                      _testing || _saving || _deleting || !_form.isReadyToSubmit
                      ? null
                      : _connectAndSave,
                ),
              ],
            )
          : const SizedBox.shrink(),
      trailing: !widget.isOnboarding && PlatformInfo.isIOS
          ? CupertinoButton(
              key: const ValueKey<String>('direct-editor-save-toolbar-button'),
              padding: const EdgeInsets.symmetric(horizontal: Spacing.xs),
              minimumSize: const Size(0, TouchTarget.minimum),
              onPressed:
                  _testing ||
                      _saving ||
                      _deleting ||
                      _form.authentication ==
                          DirectAuthenticationMode.unsupported
                  ? null
                  : _save,
              child: _saving
                  ? const CupertinoActivityIndicator(radius: 8)
                  : Text(l10n.save),
            )
          : null,
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
