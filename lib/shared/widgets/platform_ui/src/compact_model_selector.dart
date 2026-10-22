import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../../theme/theme_extensions.dart';
import '../../../theme/color_tokens.dart';
import 'compact_mobile_chrome.dart';

class CompactModelChoice {
  const CompactModelChoice(
    this.id,
    this.name,
    this.provider,
    this.providerName, {
    this.recommended = false,
  });
  final String id, name, provider, providerName;
  final bool recommended;
}

/// The same compact control surface is used inline in settings and in chat.
class CompactModelSelector extends StatefulWidget {
  const CompactModelSelector({
    super.key,
    required this.model,
    required this.provider,
    required this.choices,
    required this.efforts,
    required this.effort,
    required this.fast,
    required this.fastAvailable,
    required this.busy,
    required this.onModel,
    required this.onEffort,
    required this.onFast,
    required this.onReset,
    required this.resetLabel,
    this.status,
    this.selectedModelId,
    this.currentProviderId,
    this.enableRecommendations = false,
    this.recommendationsLoading = false,
    this.onRetry,
  });
  final String model, provider, effort, resetLabel;
  final String? selectedModelId, currentProviderId;
  final List<CompactModelChoice> choices;
  final List<String> efforts;
  final bool fast, fastAvailable, busy;
  final bool enableRecommendations;
  final bool recommendationsLoading;
  final VoidCallback? onRetry;
  final ValueChanged<CompactModelChoice> onModel;
  final ValueChanged<String> onEffort;
  final VoidCallback? onFast, onReset;
  final String? status;
  @override
  State<CompactModelSelector> createState() => _CompactModelSelectorState();
}

class _CompactModelSelectorState extends State<CompactModelSelector> {
  bool _picking = false, _providers = false;
  bool _allModels = false;
  String? _provider;
  double? _drag;
  String _label(String value) => value.isEmpty
      ? 'Default'
      : '${value[0].toUpperCase()}${value.substring(1)}';
  @override
  void didUpdateWidget(CompactModelSelector old) {
    super.didUpdateWidget(old);
    // Recommendation hints can arrive after the real catalog. Do not shrink
    // or reorder the list a person is already browsing beneath their finger.
    if (_picking &&
        !old.choices.any((c) => c.recommended) &&
        widget.choices.any((c) => c.recommended)) {
      _allModels = true;
    }
    if (old.effort != widget.effort ||
        old.model != widget.model ||
        (old.busy && !widget.busy)) {
      _drag = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final material = Theme.of(context);
    final fastModeName =
        widget.provider.toLowerCase().contains('codex') ||
            const {'openai-codex', 'codex'}.contains(widget.currentProviderId)
        ? 'ChatGPT Fast mode'
        : 'Fast mode';
    final panel = theme.surfaceChrome;
    final accent = withMinContrast(theme.buttonPrimary, panel, 4.5);
    final fill = theme.buttonPrimary;
    final track = theme.selectionBackground;
    final selected = widget.choices
        .where(
          (c) => widget.selectedModelId != null
              ? c.id == widget.selectedModelId &&
                    c.provider == widget.currentProviderId
              : c.name == widget.model && c.providerName == widget.provider,
        )
        .firstOrNull;
    final providerIds = widget.choices.map((c) => c.provider).toSet();
    final provider =
        (providerIds.contains(_provider) ? _provider : null) ??
        selected?.provider ??
        (widget.currentProviderId?.isNotEmpty == true
            ? widget.currentProviderId
            : null) ??
        widget.choices.firstOrNull?.provider;
    final providerName =
        widget.choices
            .where((c) => c.provider == provider)
            .firstOrNull
            ?.providerName ??
        widget.provider;
    final providerChoices = widget.choices
        .where((c) => c.provider == provider)
        .toList();
    final hasRecommendations = providerChoices.any((c) => c.recommended);
    final missingCurrent =
        widget.selectedModelId != null &&
        selected == null &&
        provider == widget.currentProviderId;
    final showingAll =
        !widget.enableRecommendations || _allModels || !hasRecommendations;
    final visibleChoices = [
      if (selected != null && selected.provider == provider) selected,
      ...providerChoices.where(
        (c) => c != selected && (showingAll || c.recommended),
      ),
    ];
    final index = widget.efforts.indexOf(widget.effort);
    final value = _drag ?? (index < 0 ? 0.0 : index.toDouble());
    return Material(
      color: panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: theme.borderChrome),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                CompactIconAction(
                  icon: Icon(
                    _picking ? Icons.arrow_back_rounded : Icons.bolt_rounded,
                  ),
                  color: widget.fast && !_picking
                      ? accent
                      : theme.textSecondary,
                  tooltip: _picking
                      ? 'Back'
                      : !widget.fastAvailable
                      ? '$fastModeName unavailable for this model'
                      : widget.fast
                      ? 'Turn off $fastModeName'
                      : 'Turn on $fastModeName · May cost more',
                  onPressed: _picking
                      ? () => setState(() {
                          _picking = false;
                          _providers = false;
                        })
                      : widget.busy
                      ? null
                      : widget.onFast,
                ),
                Expanded(
                  child: TextButton(
                    onPressed: widget.choices.isEmpty
                        ? null
                        : () => setState(() {
                            if (_picking) {
                              _providers = !_providers;
                            } else {
                              _picking = true;
                              _providers = false;
                              _allModels = false;
                            }
                          }),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      minimumSize: const Size(48, 48),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _picking
                              ? (_providers ? 'Provider' : providerName)
                              : widget.model,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: material.textTheme.bodyMedium?.copyWith(
                            color: theme.textPrimary,
                            fontSize: 15,
                            height: 1.2,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 1),
                        Text(
                          _picking
                              ? (_providers
                                    ? 'Choose a provider'
                                    : 'Change provider ›')
                              : '${widget.provider} ›',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: material.textTheme.bodySmall?.copyWith(
                            color: theme.textSecondary,
                            fontSize: 12,
                            height: 1.25,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (widget.onRetry != null)
                  CompactIconAction(
                    icon: const Icon(Icons.refresh_rounded),
                    tooltip: 'Retry',
                    onPressed: widget.onRetry,
                  )
                else if (_picking)
                  CompactIconAction(
                    icon: const Icon(Icons.restart_alt_rounded),
                    tooltip: widget.resetLabel,
                    onPressed: widget.busy ? null : widget.onReset,
                  )
                else
                  const SizedBox(width: 48),
              ],
            ),
            if (_picking) ...[
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: widget.enableRecommendations && !_providers
                      ? 192
                      : 240,
                ),
                child: SingleChildScrollView(
                  child: _providers
                      ? Wrap(
                          spacing: 2,
                          runSpacing: 2,
                          children: [
                            for (final id
                                in widget.choices
                                    .map((c) => c.provider)
                                    .toSet())
                              SizedBox(
                                width: 112,
                                child: TextButton(
                                  style: TextButton.styleFrom(
                                    minimumSize: const Size(48, 48),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                      vertical: 4,
                                    ),
                                    foregroundColor: id == provider
                                        ? accent
                                        : theme.textPrimary,
                                    backgroundColor: id == provider
                                        ? accent.withValues(alpha: .12)
                                        : track.withValues(alpha: .5),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    textStyle: material.textTheme.bodySmall
                                        ?.copyWith(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w500,
                                        ),
                                  ),
                                  onPressed: () => setState(() {
                                    _provider = id;
                                    _providers = false;
                                  }),
                                  child: Text(
                                    widget.choices
                                        .firstWhere((c) => c.provider == id)
                                        .providerName,
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                              ),
                          ],
                        )
                      : Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (missingCurrent)
                              Semantics(
                                selected: true,
                                child: Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    10,
                                    8,
                                    10,
                                    8,
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        widget.model,
                                        style: material.textTheme.bodyMedium
                                            ?.copyWith(
                                              fontSize: 14,
                                              color: theme.textPrimary,
                                            ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        'Current model · not in catalog',
                                        style: material.textTheme.bodySmall
                                            ?.copyWith(
                                              color: theme.textSecondary,
                                            ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            if (widget.enableRecommendations)
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  10,
                                  6,
                                  10,
                                  4,
                                ),
                                child: Text(
                                  showingAll
                                      ? 'All supported models'
                                      : 'Recommended',
                                  style: material.textTheme.bodySmall?.copyWith(
                                    color: theme.textSecondary,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            for (final choice in visibleChoices)
                              Semantics(
                                selected: choice == selected,
                                child: TextButton(
                                  onPressed: widget.busy
                                      ? null
                                      : () {
                                          setState(() => _picking = false);
                                          widget.onModel(choice);
                                        },
                                  style: TextButton.styleFrom(
                                    alignment: Alignment.centerLeft,
                                    minimumSize: const Size(48, 48),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 4,
                                    ),
                                    foregroundColor:
                                        choice.id == selected?.id &&
                                            choice.provider ==
                                                selected?.provider
                                        ? accent
                                        : theme.textPrimary,
                                    textStyle: material.textTheme.bodyMedium
                                        ?.copyWith(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w400,
                                        ),
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(child: Text(choice.name)),
                                      if (choice.id == selected?.id &&
                                          choice.provider == selected?.provider)
                                        const Icon(
                                          Icons.check_rounded,
                                          size: 18,
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                          ],
                        ),
                ),
              ),
              if (widget.enableRecommendations &&
                  !_providers &&
                  hasRecommendations)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: () => setState(() => _allModels = !_allModels),
                    style: TextButton.styleFrom(
                      alignment: Alignment.centerLeft,
                      minimumSize: const Size(48, 48),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      foregroundColor: accent,
                      textStyle: material.textTheme.bodySmall,
                    ),
                    child: Text(
                      _allModels
                          ? 'Recommended models'
                          : 'All supported models',
                    ),
                  ),
                ),
              if (widget.enableRecommendations &&
                  !_providers &&
                  !hasRecommendations)
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    heightFactor: 1,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(10, 4, 10, 4),
                      child: Text(
                        widget.recommendationsLoading
                            ? 'Loading recommendations…'
                            : 'No recommendations available',
                        style: material.textTheme.bodySmall?.copyWith(
                          color: theme.textSecondary,
                        ),
                      ),
                    ),
                  ),
                ),
            ] else
              Row(
                children: [
                  Expanded(
                    child: widget.efforts.length < 2
                        ? Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 14,
                            ),
                            child: Text(
                              widget.efforts.isEmpty
                                  ? 'Reasoning unavailable'
                                  : _label(widget.efforts.first),
                              style: material.textTheme.bodySmall?.copyWith(
                                color: theme.textSecondary,
                              ),
                            ),
                          )
                        : SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              showValueIndicator: ShowValueIndicator.never,
                              trackHeight: 32,
                              trackShape: const RoundedRectSliderTrackShape(),
                              activeTrackColor: fill,
                              inactiveTrackColor: track,
                              disabledActiveTrackColor: fill.withValues(
                                alpha: .5,
                              ),
                              disabledInactiveTrackColor: track,
                              thumbColor: theme.buttonPrimaryText,
                              thumbShape: const RoundSliderThumbShape(
                                enabledThumbRadius: 14,
                              ),
                              overlayShape: const RoundSliderOverlayShape(
                                overlayRadius: 20,
                              ),
                              activeTickMarkColor: theme.buttonPrimaryText,
                              inactiveTickMarkColor: theme.textSecondary,
                              tickMarkShape: const RoundSliderTickMarkShape(
                                tickMarkRadius: 2,
                              ),
                            ),
                            child: Slider(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 3,
                                vertical: 8,
                              ),
                              value: value
                                  .clamp(0, widget.efforts.length - 1)
                                  .toDouble(),
                              min: 0,
                              max: (widget.efforts.length - 1).toDouble(),
                              divisions: widget.efforts.length - 1,
                              label: _label(
                                widget.efforts[value.round().clamp(
                                  0,
                                  widget.efforts.length - 1,
                                )],
                              ),
                              semanticFormatterCallback: (v) =>
                                  'Reasoning: ${_label(widget.efforts[v.round()])}',
                              onChanged: widget.busy
                                  ? null
                                  : (v) => setState(() => _drag = v),
                              onChangeEnd: widget.busy
                                  ? null
                                  : (v) {
                                      // Keep the selected position while the
                                      // server still publishes its old value.
                                      setState(() => _drag = v);
                                      widget.onEffort(
                                        widget.efforts[v.round()],
                                      );
                                    },
                            ),
                          ),
                  ),
                  if (widget.efforts.length > 1)
                    SizedBox(
                      width: 48,
                      child: Text(
                        index < 0 && _drag == null
                            ? _label(widget.effort)
                            : _label(
                                widget.efforts[value.round().clamp(
                                  0,
                                  widget.efforts.length - 1,
                                )],
                              ),
                        textAlign: TextAlign.center,
                        style: material.textTheme.bodySmall?.copyWith(
                          color: accent,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                ],
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
              child: ExcludeSemantics(
                excluding: widget.status == null,
                child: Semantics(
                  liveRegion: widget.status != null,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      widget.status ?? ' ',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: material.textTheme.bodySmall?.copyWith(
                        color: theme.textSecondary,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Keeps the exit visible, but removes its input and semantics immediately.
/// Reversing the controller also reverses an interrupted transition smoothly.
class CompactModelPopover extends StatefulWidget {
  const CompactModelPopover({
    super.key,
    required this.label,
    required this.child,
    this.onOpen,
    this.onDismissChanged,
    this.scope,
    this.enabled = true,
  });
  final String label;
  final Widget child;
  final VoidCallback? onOpen;
  final ValueChanged<VoidCallback?>? onDismissChanged;
  final String? scope;
  final bool enabled;
  @override
  State<CompactModelPopover> createState() => _CompactModelPopoverState();
}

class _CompactModelPopoverState extends State<CompactModelPopover>
    with SingleTickerProviderStateMixin {
  final _portal = OverlayPortalController();
  final _trigger = FocusNode();
  final _panel = FocusScopeNode();
  late final _motion =
      AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 240),
        reverseDuration: const Duration(milliseconds: 180),
      )..addStatusListener((status) {
        if (status == AnimationStatus.dismissed && !_open) _portal.hide();
      });
  bool _open = false;
  ({double left, double bottom, double maxHeight})? _panelPlacement;
  @override
  void didUpdateWidget(CompactModelPopover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.onDismissChanged != widget.onDismissChanged) {
      oldWidget.onDismissChanged?.call(null);
      if (_open) widget.onDismissChanged?.call(() => _toggle(false));
    }
    if (!widget.enabled && _open) _toggle(false, false);
  }

  void _toggle([bool? show, bool restoreFocus = true]) {
    final open = show ?? !_open;
    if (open == _open) return;
    setState(() => _open = open);
    widget.onDismissChanged?.call(open ? () => _toggle(false) : null);
    if (open) {
      if (!_portal.isShowing) _portal.show();
      widget.onOpen?.call();
    } else {
      Tooltip.dismissAllToolTips();
      _panel.unfocus();
      if (restoreFocus && widget.enabled) _trigger.requestFocus();
    }
    if (MediaQuery.disableAnimationsOf(context)) {
      _motion.value = open ? 1 : 0;
      if (!open) _portal.hide();
    } else if (open) {
      _motion.forward();
    } else {
      _motion.reverse();
    }
  }

  void _onTapOutside(PointerDownEvent event) {
    final media = MediaQuery.of(context);
    // Android's Back swipe starts with an outside pointer down. Leave the
    // panel open until Back commits, otherwise the same swipe also leaves chat.
    if (event.position.dx < media.systemGestureInsets.left ||
        event.position.dx >
            media.size.width - media.systemGestureInsets.right) {
      return;
    }
    _toggle(false, false);
  }

  @override
  void dispose() {
    widget.onDismissChanged?.call(null);
    _motion.dispose();
    _trigger.dispose();
    _panel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(child: _popover(context)),
        if (widget.scope != null)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Text(
              widget.scope!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontSize: 11,
                color: context.conduitTheme.textSecondary,
              ),
            ),
          ),
      ],
    );
    if (Router.maybeOf(context)?.backButtonDispatcher == null) return content;
    return BackButtonListener(
      onBackButtonPressed: () async {
        if (!_open || !widget.enabled) return false;
        _toggle(false);
        return true;
      },
      child: content,
    );
  }

  Widget _popover(BuildContext context) =>
      OverlayPortal.overlayChildLayoutBuilder(
        controller: _portal,
        overlayChildBuilder: (context, info) {
          // Keep the exit attached to its last visible position. A hidden
          // trigger has different paint geometry while its overlay fades out.
          if (_open || _panelPlacement == null) {
            _panelPlacement = (
              left: info.childPaintTransform.storage[12].clamp(
                16.0,
                math.max(16.0, info.overlaySize.width - 276),
              ),
              bottom:
                  info.overlaySize.height -
                  info.childPaintTransform.storage[13] +
                  8,
              maxHeight: math.max(
                64,
                info.childPaintTransform.storage[13] -
                    MediaQuery.paddingOf(context).top -
                    16,
              ),
            );
          }
          final placement = _panelPlacement!;
          return Positioned.fill(
            child: Stack(
              children: [
                Positioned(
                  left: placement.left,
                  bottom: placement.bottom,
                  child: TapRegion(
                    groupId: this,
                    child: TooltipVisibility(
                      visible: _open,
                      child: ExcludeSemantics(
                        excluding: !_open,
                        child: IgnorePointer(
                          ignoring: !_open,
                          child: FocusScope(
                            node: _panel,
                            canRequestFocus: _open,
                            child: CallbackShortcuts(
                              bindings: {
                                const SingleActivator(
                                  LogicalKeyboardKey.escape,
                                ): () =>
                                    _toggle(false),
                              },
                              child: AnimatedBuilder(
                                animation: _motion,
                                builder: (context, child) {
                                  final t = Curves.easeOutQuart.transform(
                                    _motion.value,
                                  );
                                  return Opacity(
                                    opacity: t,
                                    child: Transform.translate(
                                      offset: Offset(0, 7 * (1 - t)),
                                      child: Transform.scale(
                                        scale: .96 + .04 * t,
                                        alignment: Alignment.bottomLeft,
                                        child: child,
                                      ),
                                    ),
                                  );
                                },
                                child: SizedBox(
                                  width: math.min(
                                    260,
                                    MediaQuery.sizeOf(context).width - 32,
                                  ),
                                  child: ConstrainedBox(
                                    constraints: BoxConstraints(
                                      maxHeight: placement.maxHeight,
                                    ),
                                    child: SingleChildScrollView(
                                      child: widget.child,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
        child: TapRegion(
          groupId: this,
          onTapOutside: _open ? _onTapOutside : null,
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.escape): () =>
                  _toggle(false),
            },
            child: TextButton(
              focusNode: _trigger,
              onPressed: widget.enabled ? () => _toggle() : null,
              style: TextButton.styleFrom(
                minimumSize: const Size(48, 48),
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                constraints: const BoxConstraints(maxWidth: 260),
                decoration: BoxDecoration(
                  color: context.conduitTheme.surfaceChrome,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: context.conduitTheme.borderChrome),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        widget.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    const SizedBox(width: 4),
                    AnimatedRotation(
                      turns: _open ? .5 : 0,
                      duration: MediaQuery.disableAnimationsOf(context)
                          ? Duration.zero
                          : const Duration(milliseconds: 180),
                      child: const Icon(Icons.expand_more_rounded, size: 16),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
}

/// Fades without resizing the composer or moving the transcript during a drag.
class CompactModelReveal extends StatelessWidget {
  const CompactModelReveal({
    super.key,
    required this.visible,
    required this.child,
  });
  final bool visible;
  final Widget child;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween<double>(end: visible ? 1 : 0),
    duration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 200),
    curve: Curves.easeOutCubic,
    child: IgnorePointer(
      ignoring: !visible,
      child: ExcludeFocus(
        excluding: !visible,
        child: ExcludeSemantics(excluding: !visible, child: child),
      ),
    ),
    builder: (context, value, child) => Transform.translate(
      offset: Offset(0, (1 - value) * 6),
      child: Opacity(opacity: value, child: child),
    ),
  );
}
