part of 'workspace_prompt_editor.dart';

extension _WorkspacePromptEditorSections on _WorkspacePromptFormState {
  Widget _nameField(AppLocalizations l10n) {
    if (_isDetail) {
      return WorkspaceValueRow(
        key: const Key('workspace-prompt-name'),
        label: l10n.workspacePromptName,
        value: _nameController.text,
      );
    }
    return ConduitInput(
      key: const Key('workspace-prompt-name'),
      controller: _nameController,
      label: l10n.workspacePromptName,
      enabled: !_fieldsReadOnly,
      onChanged: _onNameChanged,
      textInputAction: TextInputAction.next,
    );
  }

  Widget _commandField(AppLocalizations l10n) {
    if (_isDetail) {
      return WorkspaceValueRow(
        key: const Key('workspace-prompt-command'),
        label: l10n.workspacePromptCommand,
        value: WorkspacePromptCommand.display(_commandController.text),
      );
    }
    final theme = context.conduitTheme;
    return WorkspaceLabeledField(
      helperText: l10n.workspacePromptCommandHint,
      child: ConduitInput(
        key: const Key('workspace-prompt-command'),
        controller: _commandController,
        label: l10n.workspacePromptCommand,
        enabled: !_fieldsReadOnly,
        onChanged: _onCommandChanged,
        errorText: _commandError ? l10n.workspacePromptCommandInvalid : null,
        prefixIcon: Padding(
          padding: const EdgeInsets.only(left: Spacing.md, right: Spacing.xs),
          child: Text(
            '/',
            style: AppTypography.standard.copyWith(color: theme.textSecondary),
          ),
        ),
      ),
    );
  }

  Widget _tagsField(AppLocalizations l10n) {
    final theme = context.conduitTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.workspacePromptTags, style: theme.label),
        const SizedBox(height: Spacing.xs),
        Wrap(
          spacing: Spacing.xs,
          runSpacing: Spacing.xs,
          children: [
            for (final tag in _tags)
              InputChip(
                key: Key('workspace-prompt-tag-$tag'),
                label: Text(tag),
                onDeleted: _fieldsReadOnly
                    ? null
                    : () => _mutate(() {
                        _tags = [..._tags]..remove(tag);
                        _dirty = true;
                      }),
              ),
            if (!_fieldsReadOnly)
              ActionChip(
                key: const Key('workspace-prompt-tag-add'),
                avatar: const Icon(Icons.add, size: IconSize.small),
                label: Text(l10n.workspacePromptTagAdd),
                onPressed: () => _addTag(l10n),
              ),
          ],
        ),
      ],
    );
  }

  Widget _contentEditor(AppLocalizations l10n) {
    final theme = context.conduitTheme;
    if (_isDetail) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.workspacePromptContent, style: theme.headingSmall),
          const SizedBox(height: Spacing.sm),
          _previewPane(l10n),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                l10n.workspacePromptContent,
                style: theme.headingSmall,
              ),
            ),
            // The adaptive segmented control renders a native platform view on
            // iOS 26; a non-flex child in a Row is measured with unbounded
            // width, which makes the native layer's frame infinite (NaN) and
            // crashes. Give it a definite width.
            SizedBox(
              width: 200,
              child: AdaptiveSegmentedControl(
                key: const Key('workspace-prompt-preview-toggle'),
                shrinkWrap: true,
                labels: [
                  l10n.workspacePromptWriteTab,
                  l10n.workspacePromptPreviewTab,
                ],
                selectedIndex: _previewMode ? 1 : 0,
                onValueChanged: (index) =>
                    _mutate(() => _previewMode = index == 1),
              ),
            ),
          ],
        ),
        const SizedBox(height: Spacing.sm),
        if (_previewMode)
          _previewPane(l10n)
        else
          AdaptiveTextField(
            key: const Key('workspace-prompt-content'),
            controller: _contentController,
            enabled: !_fieldsReadOnly,
            minLines: 6,
            maxLines: 20,
            onChanged: (_) => _markDirty(),
            style: theme.code?.copyWith(color: theme.textPrimary),
            placeholder: l10n.workspacePromptContentHint,
          ),
      ],
    );
  }

  Widget _previewPane(AppLocalizations l10n) {
    final theme = context.conduitTheme;
    final content = _contentController.text.trim();
    return Container(
      key: const Key('workspace-prompt-preview'),
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: 120),
      padding: const EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: theme.surfaceContainer,
        borderRadius: BorderRadius.circular(AppBorderRadius.medium),
        border: Border.all(color: theme.dividerColor),
      ),
      child: content.isEmpty
          ? Text(
              l10n.workspacePromptPreviewEmpty,
              style: theme.bodySmall?.copyWith(color: theme.textSecondary),
            )
          : ConduitMarkdownWidget(data: content),
    );
  }

  Widget _versionSection(AppLocalizations l10n) {
    return WorkspaceDisclosureSection(
      key: const Key('workspace-prompt-version-disclosure'),
      title: l10n.workspacePromptVersionSection,
      expanded: _versionExpanded,
      onChanged: (value) => _mutate(() => _versionExpanded = value),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ConduitInput(
            key: const Key('workspace-prompt-commit-message'),
            controller: _commitController,
            label: l10n.workspacePromptCommitMessage,
            hint: l10n.workspacePromptCommitMessageHint,
            enabled: !_fieldsReadOnly,
            onChanged: (_) => _markDirty(),
          ),
          const SizedBox(height: Spacing.xs),
          AdaptiveListTile(
            key: const Key('workspace-prompt-production-toggle'),
            padding: EdgeInsets.zero,
            title: Text(l10n.workspacePromptSetProduction),
            subtitle: Text(l10n.workspacePromptSetProductionSubtitle),
            trailing: AdaptiveSwitch(
              value: _isProduction,
              onChanged: _fieldsReadOnly
                  ? null
                  : (value) => _mutate(() {
                      _isProduction = value;
                      _dirty = true;
                    }),
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
      key: const Key('workspace-prompt-access'),
      icon: isPublic ? Icons.public : Icons.lock_outline,
      title: l10n.workspacePromptManageAccess,
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
        if (capabilities.prompts.importItems)
          WorkspaceEditorAction(
            label: l10n.workspacePromptImport,
            icon: Icons.upload_file_outlined,
            menuKey: const Key('workspace-prompt-action-import'),
            onSelected: _import,
          ),
        if (capabilities.prompts.exportItems)
          WorkspaceEditorAction(
            label: l10n.workspacePromptExport,
            icon: Icons.download_outlined,
            menuKey: const Key('workspace-prompt-action-export'),
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
          label: l10n.workspacePromptClone,
          icon: Icons.copy_outlined,
          menuKey: const Key('workspace-prompt-action-clone'),
          onSelected: _clone,
        ),
      if (canWrite && _isEdit)
        WorkspaceEditorAction(
          label: l10n.workspacePromptUpdateDetails,
          icon: Icons.drive_file_rename_outline,
          menuKey: const Key('workspace-prompt-action-update-details'),
          onSelected: _updateDetailsOnly,
        ),
      if (canWrite)
        WorkspaceEditorAction(
          label: summary.isActive
              ? l10n.workspacePromptDeactivate
              : l10n.workspacePromptActivate,
          icon: summary.isActive
              ? Icons.toggle_on_outlined
              : Icons.toggle_off_outlined,
          menuKey: const Key('workspace-prompt-action-toggle'),
          onSelected: _toggleActive,
        ),
      WorkspaceEditorAction(
        label: l10n.workspacePromptManageAccess,
        icon: Icons.group_outlined,
        menuKey: const Key('workspace-prompt-action-access'),
        onSelected: _manageAccess,
      ),
      if (capabilities.prompts.exportItems)
        WorkspaceEditorAction(
          label: l10n.workspacePromptExport,
          icon: Icons.download_outlined,
          menuKey: const Key('workspace-prompt-action-export'),
          onSelected: _export,
        ),
      if (canWrite)
        WorkspaceEditorAction(
          label: l10n.workspacePromptDelete,
          icon: Icons.delete_outline,
          isDestructive: true,
          menuKey: const Key('workspace-prompt-action-delete'),
          onSelected: _delete,
        ),
    ];
  }

  // --- Interactions ---------------------------------------------------------
}
