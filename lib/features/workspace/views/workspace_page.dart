import 'dart:async';

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:dio/dio.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/navigation_service.dart';
import 'package:conduit/core/utils/debug_logger.dart';
import 'package:conduit/features/workspace/models/workspace_knowledge.dart';
import 'package:conduit/features/workspace/models/workspace_prompt_command.dart';
import 'package:conduit/features/workspace/models/workspace_resources.dart';
import 'package:conduit/features/workspace/providers/workspace_capabilities_provider.dart';
import 'package:conduit/features/workspace/providers/workspace_providers.dart';
import 'package:conduit/features/workspace/widgets/workspace_section_editors.dart';
import 'package:conduit/features/workspace/widgets/workspace_resource_presentation.dart';
import 'package:conduit/features/workspace/workspace_navigation.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/widgets/adaptive_route_shell.dart';
import 'package:conduit/shared/widgets/adaptive_dropdown_field.dart';
import 'package:conduit/shared/widgets/adaptive_toolbar_components.dart';
import 'package:conduit/shared/widgets/chrome_gradient_fade.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:conduit/shared/widgets/conduit_loading.dart';

part 'workspace_collection_views.dart';
part 'workspace_detail_views.dart';

class WorkspacePage extends ConsumerWidget {
  const WorkspacePage({
    super.key,
    this.section,
    this.mode = WorkspaceRouteMode.collection,
    this.resourceId,
    this.openedFromNativeSheet = false,
  });

  final WorkspaceSection? section;
  final WorkspaceRouteMode mode;
  final String? resourceId;
  final bool openedFromNativeSheet;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = section;
    return WorkspaceNavigationScope(
      openedFromNativeSheet: openedFromNativeSheet,
      child: WorkspaceGate(
        section: selected,
        child: selected == null
            ? const SizedBox.shrink()
            : WorkspaceScaffold(
                section: selected,
                mode: mode,
                resourceId: resourceId,
              ),
      ),
    );
  }
}

class WorkspaceGate extends ConsumerWidget {
  const WorkspaceGate({super.key, required this.section, required this.child});

  final WorkspaceSection? section;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(reviewerModeProvider)) {
      return const _WorkspaceGateState(kind: _GateStateKind.denied);
    }

    final capabilities = ref.watch(workspaceCapabilitiesProvider);
    return capabilities.when(
      loading: () => const _WorkspaceGateState(
        key: Key('workspace-loading'),
        kind: _GateStateKind.loading,
      ),
      error: (error, _) => _WorkspaceGateState(
        key: const Key('workspace-error'),
        kind: _isUnsupported(error)
            ? _GateStateKind.unsupported
            : _GateStateKind.error,
        onRetry: () => ref.invalidate(workspaceCapabilitiesProvider),
      ),
      data: (value) {
        final permitted = permittedWorkspaceSections(value);
        final requested = section;
        if (requested == null) {
          return permitted.isEmpty
              ? const _WorkspaceGateState(
                  key: Key('workspace-denied'),
                  kind: _GateStateKind.denied,
                )
              : const _WorkspaceGateState(
                  key: Key('workspace-loading'),
                  kind: _GateStateKind.loading,
                );
        }
        if (!permitted.contains(requested)) {
          return const _WorkspaceGateState(
            key: Key('workspace-denied'),
            kind: _GateStateKind.denied,
          );
        }
        return child;
      },
    );
  }

  static bool _isUnsupported(Object error) {
    return error is DioException &&
        (error.response?.statusCode == 404 ||
            error.response?.statusCode == 405);
  }
}

enum _GateStateKind { loading, denied, unsupported, error }

class _WorkspaceGateState extends StatelessWidget {
  const _WorkspaceGateState({super.key, required this.kind, this.onRetry});

  final _GateStateKind kind;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final usesCupertinoChrome = context.usesCupertinoChrome;
    final pageBackground = usesCupertinoChrome
        ? CupertinoColors.systemGroupedBackground.resolveFrom(context)
        : theme.surfaceBackground;
    final topInset = usesCupertinoChrome
        ? MediaQuery.paddingOf(context).top +
              conduitAdaptiveToolbarHeightOf(context)
        : 0.0;
    return AdaptiveRouteShell(
      backgroundColor: pageBackground,
      appBar: _workspaceSimpleAppBar(context, title: l10n.workspaceTitle),
      body: Stack(
        children: [
          Positioned.fill(
            child: Padding(
              padding: EdgeInsets.only(top: topInset),
              child: _WorkspaceStatusContent(kind: kind, onRetry: onRetry),
            ),
          ),
          if (usesCupertinoChrome)
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: ConduitChromeGradientFade.top(contentHeight: topInset),
            ),
        ],
      ),
    );
  }
}

AdaptiveAppBar _workspaceSimpleAppBar(
  BuildContext context, {
  required String title,
}) {
  final theme = context.conduitTheme;
  return AdaptiveAppBar(
    title: title,
    useNativeToolbar: false,
    tintColor: theme.textPrimary,
    leading: _workspaceExitButton(context),
    cupertinoNavigationBar: ConduitAdaptiveCupertinoNavigationBar(
      textScaler: MediaQuery.textScalerOf(context),
      leading: _workspaceExitButton(context),
      middle: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: conduitAdaptiveToolbarPillTextStyle(context),
      ),
    ),
  );
}

class _WorkspaceStatusContent extends StatelessWidget {
  const _WorkspaceStatusContent({required this.kind, this.onRetry});

  final _GateStateKind kind;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final message = switch (kind) {
      _GateStateKind.loading => l10n.loadingShort,
      _GateStateKind.denied => l10n.workspaceDenied,
      _GateStateKind.unsupported => l10n.workspaceUnsupported,
      _GateStateKind.error => l10n.workspaceLoadFailed,
    };
    final icon = switch (kind) {
      _GateStateKind.loading => null,
      _GateStateKind.denied => Icons.lock_outline,
      _GateStateKind.unsupported => Icons.cloud_off_outlined,
      _GateStateKind.error => Icons.error_outline,
    };
    if (kind == _GateStateKind.loading) {
      return Semantics(
        liveRegion: true,
        label: message,
        child: Center(child: ConduitLoading.primary(message: message)),
      );
    }
    return Semantics(
      liveRegion: true,
      label: message,
      child: ConduitEmptyState(
        icon: icon!,
        title: l10n.workspaceTitle,
        message: message,
        action: onRetry == null
            ? null
            : ConduitButton(
                key: const Key('workspace-retry'),
                text: l10n.workspaceRetry,
                onPressed: onRetry,
              ),
      ),
    );
  }
}

class WorkspaceScaffold extends ConsumerWidget {
  const WorkspaceScaffold({
    super.key,
    required this.section,
    required this.mode,
    this.resourceId,
  });

  final WorkspaceSection section;
  final WorkspaceRouteMode mode;
  final String? resourceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final permitted = ref
        .watch(workspaceCapabilitiesProvider)
        .maybeWhen(
          data: permittedWorkspaceSections,
          orElse: () => const <WorkspaceSection>[],
        );
    // The three-pane layout reserves 184px for the rail and 320px for the
    // collection list (plus dividers); anything below the Material expanded
    // breakpoint leaves the detail/editor pane too narrow to render forms, so
    // fall back to the single-pane compact layout there.
    final wide = MediaQuery.sizeOf(context).width >= 840;
    final theme = context.conduitTheme;
    final pageBackground = context.usesCupertinoChrome
        ? CupertinoColors.systemGroupedBackground.resolveFrom(context)
        : theme.surfaceBackground;

    // iOS compact collection uses native Cupertino chrome (a sliver navigation
    // bar with search + a pinned segmented switcher), so it hosts its own
    // CupertinoPageScaffold and must NOT be wrapped in an AdaptiveRouteShell —
    // doing so would stack a second navigation bar.
    if (!wide && PlatformInfo.isIOS && mode == WorkspaceRouteMode.collection) {
      return _WorkspaceIosCollectionShell(
        section: section,
        permitted: permitted,
      );
    }

    // Compact editors own their native navigation chrome so Save, Edit, and
    // More live in the platform app bar without an inline duplicate toolbar.
    if (!wide && mode != WorkspaceRouteMode.collection) {
      return Material(
        color: pageBackground,
        child: _buildCompact(context, permitted),
      );
    }

    // iOS 26 native toolbars contribute their height to MediaQuery padding.
    // Older Cupertino bars still need the explicit status-bar + navigation-bar
    // offset.
    final isIos = Theme.of(context).platform == TargetPlatform.iOS;
    final usesNativeToolbarInset = isIos && PlatformInfo.isIOS26OrHigher();
    final topInset = isIos && !usesNativeToolbarInset
        ? MediaQuery.paddingOf(context).top +
              conduitAdaptiveToolbarHeightOf(context)
        : 0.0;

    final appBar = !wide && mode == WorkspaceRouteMode.collection
        ? _workspaceCompactCollectionAppBar(
            context,
            section: section,
            permitted: permitted,
            canCreate: _canCreateSection(ref, section),
          )
        : AdaptiveAppBar(
            title: l10n.workspaceTitle,
            subtitle: _sectionLabel(l10n, section),
            leading: _workspaceExitButton(context),
          );

    return AdaptiveRouteShell(
      backgroundColor: pageBackground,
      appBar: appBar,
      body: Material(
        color: Colors.transparent,
        child: Padding(
          padding: EdgeInsets.only(top: topInset),
          child: SafeArea(
            top: usesNativeToolbarInset,
            child: wide
                ? _buildWide(context, permitted)
                : _buildCompact(context, permitted),
          ),
        ),
      ),
    );
  }

  Widget _buildCompact(BuildContext context, List<WorkspaceSection> permitted) {
    if (mode == WorkspaceRouteMode.collection) {
      return _WorkspaceCollectionPanel(
        section: section,
        showCreateAction: false,
      );
    }
    return _WorkspaceDetailPanel(
      section: section,
      mode: mode,
      resourceId: resourceId,
    );
  }

  Widget _buildWide(BuildContext context, List<WorkspaceSection> permitted) {
    final theme = context.conduitTheme;
    return Row(
      children: [
        SizedBox(
          width: 184,
          child: Material(
            color: theme.surfaceContainer,
            child: _WorkspaceSectionRail(
              selected: section,
              permitted: permitted,
            ),
          ),
        ),
        VerticalDivider(width: 1, color: theme.dividerColor),
        SizedBox(
          width: 320,
          child: _WorkspaceCollectionPanel(
            section: section,
            selectedId: resourceId,
          ),
        ),
        VerticalDivider(width: 1, color: theme.dividerColor),
        Expanded(
          child: _WorkspaceDetailPanel(
            section: section,
            mode: mode,
            resourceId: resourceId,
          ),
        ),
      ],
    );
  }
}

/// Compact Workspace chrome. The current section lives in the adaptive app
/// bar and opens a native popup menu, so every permitted destination remains
/// visible without squeezing labels into a segmented control.
AdaptiveAppBar _workspaceCompactCollectionAppBar(
  BuildContext context, {
  required WorkspaceSection section,
  required List<WorkspaceSection> permitted,
  required bool canCreate,
}) {
  final theme = context.conduitTheme;
  final isIos = PlatformInfo.isIOS;
  final textScaler = MediaQuery.textScalerOf(context);
  final controlExtent = conduitScaledControlExtent(context);
  final toolbarHeight = conduitAdaptiveToolbarHeightOf(context);

  Widget sectionMenu({required bool activePlatform}) => _WorkspaceSectionMenu(
    key: activePlatform ? const Key('workspace-section-tabs') : null,
    selected: section,
    permitted: permitted,
  );

  Widget createButton({required bool activePlatform}) => Tooltip(
    message: AppLocalizations.of(context)!.workspaceCreate,
    child: KeyedSubtree(
      key: activePlatform ? Key('workspace-create-${section.name}') : null,
      child: ConduitAdaptiveAppBarIconButton(
        icon: PlatformInfo.isIOS ? CupertinoIcons.add : Icons.add,
        iconColor: theme.textPrimary,
        onPressed: () => context.pushWorkspace(section.routes.createPattern),
      ),
    ),
  );

  final materialLeading = ConduitSystemTextScaling(
    textScaler: textScaler,
    child: _workspaceExitButton(context),
  );
  final materialTitle = ConduitSystemTextScaling(
    textScaler: textScaler,
    child: sectionMenu(activePlatform: !isIos),
  );
  final materialCreate = ConduitSystemTextScaling(
    textScaler: textScaler,
    child: createButton(activePlatform: !isIos),
  );

  return AdaptiveAppBar(
    useNativeToolbar: false,
    tintColor: theme.textPrimary,
    cupertinoNavigationBar: ConduitAdaptiveCupertinoNavigationBar(
      textScaler: textScaler,
      leading: _workspaceExitButton(context),
      middle: sectionMenu(activePlatform: isIos),
      trailing: canCreate
          ? createButton(activePlatform: isIos)
          : const SizedBox.shrink(),
    ),
    appBar: AppBar(
      automaticallyImplyLeading: false,
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      elevation: Elevation.none,
      scrolledUnderElevation: Elevation.none,
      toolbarHeight: toolbarHeight,
      centerTitle: true,
      leadingWidth: controlExtent + Spacing.md,
      leading: materialLeading,
      title: materialTitle,
      actions: canCreate
          ? [
              Padding(
                padding: const EdgeInsets.only(right: Spacing.inputPadding),
                child: materialCreate,
              ),
            ]
          : null,
    ),
  );
}

class _WorkspaceSectionMenu extends StatelessWidget {
  const _WorkspaceSectionMenu({
    super.key,
    required this.selected,
    required this.permitted,
  });

  final WorkspaceSection selected;
  final List<WorkspaceSection> permitted;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final label = _sectionLabel(l10n, selected);
    if (permitted.length < 2) {
      return Text(label, style: conduitAdaptiveToolbarPillTextStyle(context));
    }

    final textStyle = conduitAdaptiveToolbarPillTextStyle(context);
    final controlScale = conduitSystemControlScaleOf(context);
    final iconSize = conduitScaledIconExtent(context, IconSize.small);
    final availableWidth =
        MediaQuery.sizeOf(context).width -
        (conduitScaledControlExtent(context) + Spacing.md) * 2;
    final maxPillWidth = availableWidth.clamp(80.0, 260.0);
    final targetWidth = resolveConduitAdaptiveTextPillWidth(
      context: context,
      label: label,
      textStyle: textStyle,
      maxWidth: maxPillWidth,
      minWidth: maxPillWidth < 120 ? maxPillWidth : 120,
      horizontalPadding: 24,
      trailingWidth: iconSize + Spacing.sm,
    );

    final menuSize = Size(targetWidth, 32 * controlScale);
    final options = [
      for (final item in permitted)
        AdaptiveDropdownOption<WorkspaceSection>(
          value: item,
          label: _sectionLabel(l10n, item),
          iosSymbol: _sectionIosSymbol(item),
        ),
    ];
    final child = PlatformInfo.isIOS
        ? buildConduitAdaptiveToolbarPillSurface(
            width: menuSize.width,
            height: menuSize.height,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textStyle,
                    ),
                  ),
                  const SizedBox(width: Spacing.sm),
                  ConduitSystemAdaptiveIcon(
                    CupertinoIcons.chevron_down,
                    key: const Key('workspace-section-chevron'),
                    size: iconSize,
                    color: context.conduitTheme.iconSecondary,
                  ),
                ],
              ),
            ),
          )
        : SizedBox.fromSize(
            size: menuSize,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 9),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textStyle,
                    ),
                  ),
                  const SizedBox(width: Spacing.sm),
                  ConduitSystemAdaptiveIcon(
                    key: const Key('workspace-section-chevron'),
                    PlatformInfo.isIOS
                        ? CupertinoIcons.chevron_down
                        : Icons.keyboard_arrow_down_rounded,
                    size: iconSize,
                    color: context.conduitTheme.iconSecondary,
                  ),
                ],
              ),
            ),
          );
    return AdaptiveSingleChoiceTrigger<WorkspaceSection>(
      value: selected,
      options: options,
      onChanged: (next) => _selectSection(context, next),
      nativeTitle: l10n.workspaceTitle,
      semanticLabel: label,
      fallbackReplacement: SizedBox.fromSize(size: menuSize),
      child: child,
    );
  }

  void _selectSection(BuildContext context, WorkspaceSection? next) {
    if (next != null && next != selected) {
      context.replaceWorkspace(next.path);
    }
  }
}

class _WorkspaceSectionRail extends StatelessWidget {
  const _WorkspaceSectionRail({
    required this.selected,
    required this.permitted,
  });

  final WorkspaceSection selected;
  final List<WorkspaceSection> permitted;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    return ListView(
      key: const Key('workspace-section-rail'),
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.sm,
        vertical: Spacing.sm,
      ),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            Spacing.xs,
            Spacing.md,
            Spacing.xs,
            Spacing.sm,
          ),
          child: Text(
            l10n.workspaceSubtitle,
            style: theme.bodySmall?.copyWith(color: theme.textSecondary),
          ),
        ),
        for (final item in permitted)
          ListTile(
            key: Key('workspace-rail-${item.name}'),
            selected: item == selected,
            selectedTileColor: theme.buttonPrimary.withValues(alpha: 0.1),
            selectedColor: theme.buttonPrimary,
            dense: true,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppBorderRadius.small),
            ),
            leading: Icon(_sectionIcon(item), size: IconSize.small),
            title: Text(_sectionLabel(l10n, item)),
            onTap: () => context.replaceWorkspace(item.path),
          ),
      ],
    );
  }
}

Widget _workspaceExitButton(BuildContext context) {
  final button = Tooltip(
    message: MaterialLocalizations.of(context).backButtonTooltip,
    child: ConduitAdaptiveAppBarIconButton(
      key: const Key('workspace-exit'),
      icon: PlatformInfo.isIOS ? CupertinoIcons.back : Icons.arrow_back,
      iconColor: context.conduitTheme.textPrimary,
      onPressed: () {
        if (WorkspaceNavigationScope.maybeOf(context)?.openedFromNativeSheet ==
            true) {
          context.go(Routes.chat);
          return;
        }
        if (context.canPop()) {
          context.pop();
        } else {
          context.go(Routes.profile);
        }
      },
    ),
  );

  // Material gives AppBar.leading tight 56x56 constraints. Loosen them around
  // the adaptive control so its painted surface remains the standard 44dp
  // toolbar action size instead of expanding to fill the entire leading slot.
  return context.usesCupertinoChrome
      ? button
      : Center(
          child: SizedBox.square(
            dimension: conduitScaledControlExtent(context),
            child: button,
          ),
        );
}

/// A per-section bundle of the collection state and its notifier callbacks,
/// resolved once by [_withCollectionBinding] so the box (Android/tablet) and
/// sliver (iOS) renderers never duplicate the section switch.
