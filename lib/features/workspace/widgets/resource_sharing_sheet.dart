import 'dart:async';

import 'package:conduit/features/workspace/models/workspace_capabilities.dart';
import 'package:conduit/features/workspace/providers/workspace_capabilities_provider.dart';
import 'package:conduit/features/workspace/widgets/workspace_access_grants.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:conduit/shared/widgets/conduit_loading.dart';
import 'package:conduit/shared/widgets/themed_sheets.dart';
import 'package:conduit_core/features/sharing/models/resource_access.dart';
import 'package:conduit_core/features/sharing/providers/resource_access_controller.dart';
import 'package:conduit_core/features/workspace/models/workspace_common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Edits who can reach one chat, folder or note.
///
/// The sheet is a thin view over a [ResourceAccessController], which was
/// opened at the moment the user asked to share and holds the account, API and
/// resource id from then on. Opening or closing the sheet writes nothing; the
/// only write is the Save button, which sends the edited grants, reads the
/// server's answer back, and keeps the form open with a message if the save
/// is refused or the server kept only part of it.
class ResourceSharingSheet extends ConsumerStatefulWidget {
  const ResourceSharingSheet({
    super.key,
    required this.controller,
    this.onSaved,
    this.resourceName,
    this.owner,
  });

  final ResourceAccessController controller;

  /// Called with the server's answer after each successful save.
  final void Function(ResourceAccessSnapshot fresh)? onSaved;

  /// The chat, folder or note's name, shown under the title when known.
  final String? resourceName;

  /// Who owns the resource, shown at the top of the list when known.
  final WorkspaceAccessOwner? owner;

  /// Opens the session for [resourceId] now and shows the sheet.
  ///
  /// Returns the last saved state, or null when nothing was saved. [kind] and
  /// [resourceId] are fixed here, before the first request: for a chat
  /// [resourceId] is the chat's own id, not its link's `share_id`.
  static Future<ResourceAccessSnapshot?> show(
    BuildContext context,
    WidgetRef ref, {
    required ResourceKind kind,
    required String resourceId,
    String? resourceName,
    WorkspaceAccessOwner? owner,
  }) {
    final controller = ResourceAccessController.open(
      ref,
      kind: kind,
      resourceId: resourceId,
    );
    if (controller == null) return Future.value();
    return showWith(
      context,
      controller,
      resourceName: resourceName,
      owner: owner,
    );
  }

  /// Shows the sheet for a controller opened earlier, such as when a share
  /// flow began before a native sheet took over the screen.
  static Future<ResourceAccessSnapshot?> showWith(
    BuildContext context,
    ResourceAccessController controller, {
    String? resourceName,
    WorkspaceAccessOwner? owner,
  }) async {
    ResourceAccessSnapshot? saved;
    await ThemedSheets.showCustom<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => ResourceSharingSheet(
        controller: controller,
        resourceName: resourceName,
        owner: owner,
        onSaved: (fresh) => saved = fresh,
      ),
    );
    return saved;
  }

  @override
  ConsumerState<ResourceSharingSheet> createState() =>
      _ResourceSharingSheetState();
}

class _ResourceSharingSheetState extends ConsumerState<ResourceSharingSheet> {
  /// The loading and error states keep roughly the height of a short access
  /// list, so the sheet does not jump when the list arrives.
  static const _placeholderHeight = 220.0;

  ResourceAccessSnapshot? _snapshot;
  ResourceAccessException? _loadFailure;
  Object? _loadError;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loadFailure = null;
      _loadError = null;
    });
    try {
      final snapshot = await widget.controller.load();
      if (!mounted) return;
      setState(() => _snapshot = snapshot);
    } on ResourceAccessException catch (error) {
      if (mounted) setState(() => _loadFailure = error);
    } catch (error) {
      if (mounted) setState(() => _loadError = error);
    }
  }

  String _failureMessage(AppLocalizations l10n, ResourceAccessFailure failure) {
    return switch (failure) {
      ResourceAccessFailure.sessionChanged =>
        l10n.resourceSharingSessionChanged,
      ResourceAccessFailure.denied => l10n.resourceSharingDenied,
      ResourceAccessFailure.missing => l10n.resourceSharingMissing,
      ResourceAccessFailure.notEditable => l10n.resourceSharingDenied,
    };
  }

  /// Saves the edited grants and compares the server's answer with what was
  /// sent: anything it did not keep keeps the sheet open on that answer.
  Future<WorkspaceAccessSaveOutcome> _save(
    List<WorkspaceAccessGrantInput> grants,
    ResourceAudience? audience,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final base = _snapshot;
    if (base == null) {
      return WorkspaceAccessSaveOutcome.failed(l10n.resourceSharingSaveFailed);
    }
    try {
      final fresh = await widget.controller.save(
        base,
        grants,
        audience: audience,
      );
      widget.onSaved?.call(fresh);
      // A later save starts from the server's answer.
      if (mounted) setState(() => _snapshot = fresh);
      final kept = workspaceGrantKeys(fresh.editableGrants);
      final keptAll =
          kept.containsAll(workspaceGrantKeys(grants)) &&
          (audience == null || fresh.audience == audience);
      if (!keptAll) {
        return WorkspaceAccessSaveOutcome.partial(
          keptGrants: fresh.editableGrants,
          keptAudience: fresh.audience,
          message: l10n.resourceSharingFiltered,
        );
      }
      if (mounted) {
        AdaptiveSnackBar.show(
          context,
          message: l10n.resourceSharingSaved,
          type: AdaptiveSnackBarType.success,
        );
      }
      return const WorkspaceAccessSaveOutcome.saved();
    } on ResourceAccessException catch (error) {
      return WorkspaceAccessSaveOutcome.failed(
        _failureMessage(l10n, error.failure),
      );
    } catch (_) {
      return WorkspaceAccessSaveOutcome.failed(l10n.resourceSharingSaveFailed);
    }
  }

  ResourceSharingCapabilities _capabilities(WorkspaceCapabilities all) {
    return switch (widget.controller.kind) {
      ResourceKind.chat => all.chats,
      ResourceKind.folder => all.folders,
      ResourceKind.note => all.notes,
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final snapshot = _snapshot;
    final capabilities = ref.watch(workspaceCapabilitiesProvider);

    if (snapshot != null && capabilities.hasValue) {
      final sharing = _capabilities(capabilities.requireValue);
      return WorkspaceAccessGrantSheet(
        initialGrants: snapshot.editableGrants,
        capabilities: sharing.section,
        allowUserGrants: sharing.allowUserGrants,
        allowGroupGrants: sharing.allowGroupGrants,
        // Open WebUI's chat audience is read-only; folders and notes can have
        // recipients who edit.
        allowWriteGrants: widget.controller.kind != ResourceKind.chat,
        readOnly: !snapshot.canEdit,
        // Only a chat has "Anyone with the link"; a folder offers no general
        // access and a note follows its own public flag.
        audience: widget.controller.kind == ResourceKind.chat
            ? WorkspaceAudienceChoice(
                initial: snapshot.audience,
                canChooseOpen: sharing.shareOpenly,
              )
            : null,
        showVisibility: widget.controller.kind != ResourceKind.folder,
        resourceName: widget.resourceName,
        owner: widget.owner,
        onSave: _save,
      );
    }

    final failure = _loadFailure;
    final theme = context.conduitTheme;
    final failed = failure != null || _loadError != null;
    return ConduitModalSheetSurface(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          WorkspaceAccessSheetHeader(
            subtitle: widget.resourceName,
            onClose: () => Navigator.of(context).maybePop(),
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: _placeholderHeight),
            child: Center(
              child: !failed
                  ? ConduitLoading.inline(context: context)
                  : Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: Spacing.lg,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            failure == null
                                ? l10n.resourceSharingLoadFailed
                                : _failureMessage(l10n, failure.failure),
                            key: const Key('resource-sharing-error'),
                            textAlign: TextAlign.center,
                            style: theme.bodyMedium?.copyWith(
                              color: theme.error,
                            ),
                          ),
                          if (failure?.failure !=
                                  ResourceAccessFailure.sessionChanged &&
                              failure?.failure !=
                                  ResourceAccessFailure.denied) ...[
                            const SizedBox(height: Spacing.md),
                            ConduitButton(
                              key: const Key('resource-sharing-retry'),
                              text: l10n.retry,
                              isSecondary: true,
                              isFullWidth: true,
                              onPressed: _load,
                            ),
                          ],
                        ],
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
