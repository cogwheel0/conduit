import 'dart:io' show Platform;

import 'package:collection/collection.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:conduit_core/features/chat/models/personal_valves.dart';
import 'package:conduit_core/features/chat/providers/personal_valves_providers.dart';
import 'package:conduit_core/features/workspace/models/workspace_valve_values.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit/core/services/haptic_service.dart';
import 'package:conduit/features/workspace/widgets/workspace_valve_form.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:conduit/shared/widgets/conduit_loading.dart';
import 'package:conduit/shared/widgets/discard_changes.dart';
import 'package:conduit/shared/widgets/sheet_handle.dart';
import 'package:conduit/shared/widgets/themed_sheets.dart';

/// Opens the signed-in user's personal settings for the selected tools,
/// filters, and pipe.
///
/// The native iOS keyboard menu and the Flutter composer panel both call this
/// one entry point. The account owner is captured here, synchronously, before
/// the sheet exists, and the sheet keeps that owner for every target it
/// loads or saves.
Future<void> showPersonalToolSettings(BuildContext context, WidgetRef ref) {
  if (!ref.read(personalValvesCommandAvailableProvider)) {
    return Future<void>.value();
  }
  final owner = PersonalValvesOwner.capture(ref.read);
  final targets = ref.read(personalValvesTargetsProvider);
  if (owner == null || targets.isEmpty) return Future<void>.value();
  return ThemedSheets.showCustom<void>(
    context: context,
    builder: (_) => PersonalValvesSheet(owner: owner, targets: targets),
  );
}

class PersonalValvesSheet extends ConsumerStatefulWidget {
  const PersonalValvesSheet({
    super.key,
    required this.owner,
    required this.targets,
  });

  final PersonalValvesOwner owner;
  final List<PersonalValvesTarget> targets;

  @override
  ConsumerState<PersonalValvesSheet> createState() =>
      _PersonalValvesSheetState();
}

class _PersonalValvesSheetState extends ConsumerState<PersonalValvesSheet> {
  late PersonalValvesTarget? _target = widget.targets.length == 1
      ? widget.targets.single
      : null;

  PersonalValvesEditorKey get _key =>
      PersonalValvesEditorKey(widget.owner, _target!);

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context)!;
    final failure = await ref
        .read(personalValvesEditorProvider(_key).notifier)
        .save();
    if (!mounted) return;
    if (failure == null) {
      ConduitHaptics.success();
      AdaptiveSnackBar.show(
        context,
        message: l10n.personalToolSettingsSaved,
        type: AdaptiveSnackBarType.success,
      );
      Navigator.of(context).pop();
      return;
    }
    AdaptiveSnackBar.show(
      context,
      message: switch (failure.reason) {
        PersonalValvesFailureReason.ownerChanged =>
          l10n.personalToolSettingsOwnerChanged,
        PersonalValvesFailureReason.invalid =>
          failure.detail ?? l10n.personalToolSettingsInvalid,
        PersonalValvesFailureReason.unavailable ||
        PersonalValvesFailureReason.denied =>
          l10n.personalToolSettingsUnavailable,
        PersonalValvesFailureReason.failed =>
          l10n.personalToolSettingsSaveFailed,
      },
      type: AdaptiveSnackBarType.error,
    );
  }

  /// Whether the open form holds edits that are not saved. Values are compared
  /// as they would be sent, so typing a value and then restoring it is clean.
  static bool _hasEdits(PersonalValvesEditorState state) {
    final document = state.document;
    if (state.phase != PersonalValvesPhase.ready || document == null) {
      return false;
    }
    final draft = WorkspaceValveValues.serialize(document.spec, state.draft);
    final stored = WorkspaceValveValues.serialize(
      document.spec,
      document.values,
    );
    const equality = DeepCollectionEquality();
    // A property the form switched back to its server default is null in
    // the draft and may be absent from what was loaded; both mean "default".
    return {...draft.keys, ...stored.keys}.any(
      (property) => !equality.equals(draft[property], stored[property]),
    );
  }

  bool get _dirty =>
      _target != null &&
      widget.owner.isCurrent(ref.read) &&
      _hasEdits(ref.read(personalValvesEditorProvider(_key)));

  Future<void> _backToTargets() async {
    if (_dirty && !await confirmDiscardChanges(context)) return;
    if (!mounted) return;
    setState(() => _target = null);
  }

  void _retry() => ref.invalidate(personalValvesEditorProvider(_key));

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    // Rebuilds when the account changes so the form and its values leave the
    // tree immediately instead of waiting for the next request to notice.
    ref.watch(openWebUiAuthSessionEpochProvider);
    final ownerCurrent = widget.owner.isCurrent(ref.read);
    final canGoBack = _target != null && widget.targets.length > 1;
    final editor = ownerCurrent && _target != null
        ? ref.watch(personalValvesEditorProvider(_key))
        : null;
    final dirty = editor != null && _hasEdits(editor);
    // A save on its way can't be called back, and it closes the sheet when it
    // lands; nothing closes or asks to discard until then.
    final saving = editor?.saving ?? false;

    // showCustom does not inset for the software keyboard, so the sheet does
    // it the way ThemedSheets.showSurface does. The surface wraps its child in
    // an unbounded column when it draws the handle, so the handle sits in this
    // column instead. The form then scrolls in the space left above the
    // keyboard and Save stays visible.
    // Back, the close button and a swipe all ask before throwing edits away.
    return DiscardChangesScope(
      dirty: dirty,
      busy: saving,
      child: AnimatedPadding(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SheetDismissGuard(
          guarded: dirty || saving,
          onDismissRequest: () => Navigator.of(context).maybePop(),
          child: ConduitModalSheetSurface(
            showHandle: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SheetHandle(),
                Row(
                  children: [
                    if (canGoBack)
                      ConduitIconButton(
                        key: const Key('personal-valves-back'),
                        tooltip: l10n.back,
                        onPressed: saving ? null : _backToTargets,
                        icon: Platform.isIOS
                            ? CupertinoIcons.chevron_back
                            : Icons.arrow_back,
                      ),
                    Expanded(
                      child: Text(
                        _target?.label ?? l10n.personalToolSettings,
                        style: theme.headingSmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    SheetCloseButton(
                      tooltip: l10n.close,
                      onPressed: saving
                          ? null
                          : () => Navigator.of(context).maybePop(),
                    ),
                  ],
                ),
                const SizedBox(height: Spacing.sm),
                if (!ownerCurrent)
                  _message(
                    const Key('personal-valves-owner-changed'),
                    l10n.personalToolSettingsOwnerChanged,
                  )
                else if (_target == null)
                  Flexible(
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final target in widget.targets)
                            ConduitListItem(
                              key: Key(
                                'personal-valves-target-${target.kind.name}-'
                                '${target.id}',
                              ),
                              isCompact: true,
                              leading: Icon(
                                Platform.isIOS
                                    ? CupertinoIcons.slider_horizontal_3
                                    : Icons.tune,
                                color: theme.iconPrimary,
                                size: IconSize.message,
                              ),
                              title: Text(
                                target.label,
                                style: theme.bodyMedium,
                              ),
                              trailing: Icon(
                                Platform.isIOS
                                    ? CupertinoIcons.chevron_forward
                                    : Icons.chevron_right,
                                color: theme.textSecondary,
                                size: IconSize.small,
                              ),
                              onTap: () => setState(() => _target = target),
                            ),
                        ],
                      ),
                    ),
                  )
                else
                  _editor(context, l10n, dirty: dirty),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _message(Key key, String text, {bool error = false}) {
    final theme = context.conduitTheme;
    return Padding(
      key: key,
      padding: const EdgeInsets.symmetric(vertical: Spacing.md),
      child: Text(
        text,
        style: theme.bodySmall?.copyWith(
          color: error ? theme.error : theme.textSecondary,
        ),
      ),
    );
  }

  Widget _editor(
    BuildContext context,
    AppLocalizations l10n, {
    required bool dirty,
  }) {
    final theme = context.conduitTheme;
    final key = _key;
    final state = ref.watch(personalValvesEditorProvider(key));
    final document = state.document;

    switch (state.phase) {
      case PersonalValvesPhase.loading:
        return Padding(
          padding: const EdgeInsets.all(Spacing.lg),
          child: Center(child: ConduitLoading.inline(context: context)),
        );
      case PersonalValvesPhase.unavailable:
        return _message(
          const Key('personal-valves-unavailable'),
          l10n.personalToolSettingsUnavailable,
        );
      case PersonalValvesPhase.loadFailed:
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _message(
              const Key('personal-valves-error'),
              l10n.personalToolSettingsLoadFailed,
              error: true,
            ),
            ConduitButton(
              key: const Key('personal-valves-retry'),
              text: l10n.retry,
              isSecondary: true,
              isCompact: true,
              onPressed: _retry,
            ),
          ],
        );
      case PersonalValvesPhase.ownerChanged:
        return _message(
          const Key('personal-valves-owner-changed'),
          l10n.personalToolSettingsOwnerChanged,
        );
      case PersonalValvesPhase.ready:
        return Flexible(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(l10n.personalToolSettingsYours, style: theme.label),
              const SizedBox(height: Spacing.xs),
              Flexible(
                child: SingleChildScrollView(
                  child: WorkspaceValveForm(
                    key: ValueKey(
                      'personal-valves-form-${key.target.kind.name}-'
                      '${key.target.id}',
                    ),
                    spec: document!.spec!,
                    initialValues: document.values,
                    enabled: !state.saving,
                    onChanged: ref
                        .read(personalValvesEditorProvider(key).notifier)
                        .setDraft,
                  ),
                ),
              ),
              const SizedBox(height: Spacing.md),
              ConduitButton(
                key: const Key('personal-valves-save'),
                text: l10n.save,
                isLoading: state.saving,
                isFullWidth: true,
                // Nothing to save until something changed.
                onPressed: state.saving || !dirty ? null : _save,
              ),
            ],
          ),
        );
    }
  }
}
