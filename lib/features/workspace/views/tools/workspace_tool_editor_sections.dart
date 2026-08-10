part of 'workspace_tool_editor.dart';

extension _WorkspaceToolEditorSections on _WorkspaceToolFormState {
  Widget _nameField(AppLocalizations l10n) {
    if (_isDetail) {
      return WorkspaceValueRow(
        key: const Key('workspace-tool-name'),
        label: l10n.workspaceToolName,
        value: _nameController.text,
      );
    }
    return ConduitInput(
      key: const Key('workspace-tool-name'),
      controller: _nameController,
      label: l10n.workspaceToolName,
      hint: l10n.workspaceToolNameHint,
      enabled: !_fieldsReadOnly,
      onChanged: _onNameChanged,
      textInputAction: TextInputAction.next,
    );
  }

  Widget _idField(AppLocalizations l10n) {
    if (_isDetail) {
      return WorkspaceValueRow(
        key: const Key('workspace-tool-id'),
        label: l10n.workspaceToolId,
        value: _idController.text,
      );
    }
    return WorkspaceLabeledField(
      helperText: l10n.workspaceToolIdHint,
      child: ConduitInput(
        key: const Key('workspace-tool-id'),
        controller: _idController,
        label: l10n.workspaceToolId,
        enabled: !_idReadOnly,
        onChanged: _onIdChanged,
        errorText: _idError ? l10n.workspaceToolIdInvalid : null,
      ),
    );
  }

  Widget _descriptionField(AppLocalizations l10n) {
    if (_isDetail) {
      return WorkspaceValueRow(
        key: const Key('workspace-tool-description'),
        label: l10n.workspaceToolDescription,
        value: _descriptionController.text,
      );
    }
    return ConduitInput(
      key: const Key('workspace-tool-description'),
      controller: _descriptionController,
      label: l10n.workspaceToolDescription,
      hint: l10n.workspaceToolDescriptionHint,
      enabled: !_fieldsReadOnly,
      onChanged: (_) => _markDirty(),
      textInputAction: TextInputAction.next,
    );
  }

  Widget _contentEditor(AppLocalizations l10n) {
    final theme = context.conduitTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.workspaceToolContent, style: theme.headingSmall),
        const SizedBox(height: Spacing.sm),
        if (_isDetail)
          Container(
            key: const Key('workspace-tool-content'),
            width: double.infinity,
            constraints: const BoxConstraints(minHeight: 160),
            padding: const EdgeInsets.all(Spacing.md),
            decoration: BoxDecoration(
              color: theme.surfaceContainer,
              borderRadius: BorderRadius.circular(AppBorderRadius.medium),
              border: Border.all(color: theme.dividerColor),
            ),
            child: SelectableText(
              _contentController.text,
              style: theme.code?.copyWith(color: theme.textPrimary),
            ),
          )
        else
          AdaptiveTextField(
            key: const Key('workspace-tool-content'),
            controller: _contentController,
            enabled: !_fieldsReadOnly,
            minLines: 12,
            maxLines: 32,
            onChanged: _onContentChanged,
            style: theme.code?.copyWith(color: theme.textPrimary),
            placeholder: l10n.workspaceToolContentHint,
          ),
      ],
    );
  }

  Widget _incompatibilityBanner(AppLocalizations l10n) {
    final theme = context.conduitTheme;
    return Container(
      key: const Key('workspace-tool-incompatible'),
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: Spacing.md),
      padding: const EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: theme.errorBackground,
        borderRadius: BorderRadius.circular(AppBorderRadius.medium),
        border: Border.all(color: theme.error),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.warning_amber_outlined,
            size: IconSize.small,
            color: theme.error,
          ),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Text(
              l10n.workspaceToolIncompatible(
                _requiredVersion ?? '0.0.0',
                _currentServerVersion ?? '?',
              ),
              style: theme.bodySmall?.copyWith(color: theme.error),
            ),
          ),
        ],
      ),
    );
  }

  Widget _warning(AppLocalizations l10n) {
    final theme = context.conduitTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          Icons.info_outline,
          size: IconSize.small,
          color: theme.textSecondary,
        ),
        const SizedBox(width: Spacing.xs),
        Expanded(
          child: Text(
            l10n.workspaceToolWarning,
            style: theme.caption?.copyWith(color: theme.textSecondary),
          ),
        ),
      ],
    );
  }

  Widget _manifestSummary(AppLocalizations l10n, WorkspaceToolSummary summary) {
    final manifest = workspaceJsonMap(summary.meta['manifest']);
    if (manifest.isEmpty) return const SizedBox.shrink();
    final theme = context.conduitTheme;
    final version = manifest['version']?.toString();
    final requiredVersion = manifest['required_open_webui_version']?.toString();
    final fundingUrl = manifest['funding_url']?.toString();
    return Padding(
      key: const Key('workspace-tool-manifest'),
      padding: const EdgeInsets.only(bottom: Spacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.workspaceToolManifest, style: theme.headingSmall),
          const SizedBox(height: Spacing.sm),
          if (version != null && version.isNotEmpty)
            Text(
              l10n.workspaceToolManifestVersion(version),
              style: theme.bodySmall?.copyWith(color: theme.textSecondary),
            ),
          if (requiredVersion != null && requiredVersion.isNotEmpty)
            Text(
              l10n.workspaceToolManifestRequiredVersion(requiredVersion),
              style: theme.bodySmall?.copyWith(color: theme.textSecondary),
            ),
          if (fundingUrl != null && fundingUrl.isNotEmpty)
            Text(
              l10n.workspaceToolManifestFunding(fundingUrl),
              style: theme.bodySmall?.copyWith(color: theme.textSecondary),
            ),
        ],
      ),
    );
  }

  Widget _specsSummary(AppLocalizations l10n, WorkspaceToolSummary summary) {
    final theme = context.conduitTheme;
    final specs = summary.specs;
    return Padding(
      key: const Key('workspace-tool-specs'),
      padding: const EdgeInsets.only(bottom: Spacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.workspaceToolSpecs, style: theme.headingSmall),
          const SizedBox(height: Spacing.sm),
          if (specs.isEmpty)
            Text(
              l10n.workspaceToolSpecsEmpty,
              style: theme.bodySmall?.copyWith(color: theme.textSecondary),
            )
          else
            for (final spec in specs)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: Spacing.xxs),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      spec['name']?.toString() ?? '',
                      style: theme.bodyMedium?.copyWith(
                        color: theme.textPrimary,
                      ),
                    ),
                    if ((spec['description']?.toString() ?? '').isNotEmpty)
                      Text(
                        spec['description'].toString(),
                        style: theme.caption?.copyWith(
                          color: theme.textSecondary,
                        ),
                      ),
                  ],
                ),
              ),
        ],
      ),
    );
  }

  Widget _accessTile(AppLocalizations l10n) {
    final principals = workspaceSharedPrincipals(_grants);
    final isPublic = workspaceGrantsArePublic(_grants);
    return WorkspaceResourceTile(
      key: const Key('workspace-tool-access'),
      icon: isPublic ? Icons.public : Icons.lock_outline,
      title: l10n.workspaceToolManageAccess,
      subtitle: isPublic
          ? l10n.workspaceAccessVisibilityLabel
          : l10n.workspaceModelSelectCount(principals.length),
      onTap: _manageAccess,
    );
  }

  List<WorkspaceEditorAction> _buildActions(
    AppLocalizations l10n,
    WorkspaceCapabilities capabilities,
  ) {
    if (_isCreate) {
      return [
        if (capabilities.tools.importItems)
          WorkspaceEditorAction(
            label: l10n.workspaceToolImportJson,
            icon: Icons.data_object_outlined,
            menuKey: const Key('workspace-tool-action-import-json'),
            onSelected: _importJson,
          ),
        // URL import is admin-only, independent of the tools_import permission.
        if (_isAdmin)
          WorkspaceEditorAction(
            label: l10n.workspaceToolImportUrl,
            icon: Icons.link_outlined,
            menuKey: const Key('workspace-tool-action-import-url'),
            onSelected: _importUrl,
          ),
        if (capabilities.tools.exportItems)
          WorkspaceEditorAction(
            label: l10n.workspaceToolExport,
            icon: Icons.download_outlined,
            menuKey: const Key('workspace-tool-action-export'),
            onSelected: _export,
          ),
      ];
    }
    final summary = widget.summary;
    if (summary == null) return const [];
    final canWrite = _writeAccess;
    return [
      if (canWrite)
        WorkspaceEditorAction(
          label: l10n.workspaceToolClone,
          icon: Icons.copy_outlined,
          menuKey: const Key('workspace-tool-action-clone'),
          onSelected: _clone,
        ),
      if (canWrite)
        WorkspaceEditorAction(
          label: l10n.workspaceToolValves,
          icon: Icons.tune_outlined,
          menuKey: const Key('workspace-tool-action-valves'),
          onSelected: _openValves,
        ),
      WorkspaceEditorAction(
        label: l10n.workspaceToolManageAccess,
        icon: Icons.group_outlined,
        menuKey: const Key('workspace-tool-action-access'),
        onSelected: _manageAccess,
      ),
      if (capabilities.tools.exportItems)
        WorkspaceEditorAction(
          label: l10n.workspaceToolExport,
          icon: Icons.download_outlined,
          menuKey: const Key('workspace-tool-action-export'),
          onSelected: _export,
        ),
      if (canWrite)
        WorkspaceEditorAction(
          label: l10n.workspaceToolDelete,
          icon: Icons.delete_outline,
          isDestructive: true,
          menuKey: const Key('workspace-tool-action-delete'),
          onSelected: _delete,
        ),
    ];
  }

  // --- Interactions ---------------------------------------------------------
}
