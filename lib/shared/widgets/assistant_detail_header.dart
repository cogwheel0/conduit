import 'package:material_ui/material_ui.dart';

import '../theme/theme_extensions.dart';

/// A minimal expandable header used for assistant-side detail rows.
///
/// This keeps reasoning, tool calls, and execution entries visually aligned.
class AssistantDetailHeader extends StatefulWidget {
  const AssistantDetailHeader({
    super.key,
    required this.title,
    required this.showShimmer,
    this.showChevron = true,
    this.allowWrap = false,
    this.useInlineChevron = false,
    this.isExpanded = false,
    this.compact = false,
  });

  final String title;
  final bool showShimmer;
  final bool showChevron;
  final bool allowWrap;
  final bool useInlineChevron;
  final bool isExpanded;
  final bool compact;

  @override
  State<AssistantDetailHeader> createState() => _AssistantDetailHeaderState();
}

class _AssistantDetailHeaderState extends State<AssistantDetailHeader>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _shimmerController;
  var _disableAnimations = false;
  var _foreground = true;
  var _tickerEnabled = true;

  @override
  void initState() {
    super.initState();
    _shimmerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _disableAnimations = context.reduceMotion;
    _tickerEnabled = TickerMode.valuesOf(context).enabled;
    _syncShimmerController();
  }

  @override
  void didUpdateWidget(covariant AssistantDetailHeader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.showShimmer != widget.showShimmer) {
      _syncShimmerController();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _shimmerController.dispose();
    super.dispose();
  }

  void _syncShimmerController() {
    if (_shouldAnimateShimmer) {
      if (!_shimmerController.isAnimating) {
        _shimmerController.repeat();
      }
      return;
    }

    if (_shimmerController.isAnimating) {
      _shimmerController.stop();
    }
  }

  bool get _shouldAnimateShimmer =>
      widget.showShimmer &&
      !_disableAnimations &&
      _foreground &&
      _tickerEnabled;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground =
        state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
    _syncShimmerController();
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final textTheme = Theme.of(context).textTheme;
    final header = Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Flexible(
          child: Text(
            widget.title,
            overflow: widget.allowWrap ? null : TextOverflow.ellipsis,
            maxLines: widget.allowWrap ? null : 1,
            style: widget.compact
                ? AppTypography.bodySmallStyle.copyWith(
                    fontSize: 13,
                    height: 1.4,
                    color: theme.textSecondary,
                  )
                : textTheme.bodyLarge?.copyWith(
                        color: theme.textPrimary.withValues(alpha: 0.6),
                      ) ??
                      AppTypography.chatMessageStyle.copyWith(
                        color: theme.textPrimary.withValues(alpha: 0.6),
                      ),
          ),
        ),
        if (widget.showChevron) ...[
          const SizedBox(width: 4),
          AnimatedRotation(
            turns: widget.useInlineChevron
                ? (widget.isExpanded ? 0 : -0.25)
                : 0,
            duration: context.motionDuration(
              widget.compact
                  ? AnimationDuration.assistantDisclosure
                  : const Duration(milliseconds: 180),
            ),
            curve: widget.compact ? Curves.fastOutSlowIn : Curves.easeOutCubic,
            child: Icon(
              widget.useInlineChevron
                  ? Icons.expand_more_rounded
                  : Icons.chevron_right_rounded,
              size: widget.compact ? 12 : 16,
              color: widget.compact
                  ? theme.textSecondary
                  : theme.textPrimary.withValues(alpha: 0.6),
            ),
          ),
        ],
      ],
    );

    if (!_shouldAnimateShimmer) {
      return header;
    }

    return Stack(
      fit: StackFit.passthrough,
      children: [
        header,
        Positioned.fill(
          child: IgnorePointer(
            child: ExcludeSemantics(
              child: AnimatedBuilder(
                animation: _shimmerController,
                child: header,
                builder: (context, child) {
                  final value = _shimmerController.value;
                  return ShaderMask(
                    blendMode: BlendMode.srcATop,
                    shaderCallback: (bounds) {
                      return LinearGradient(
                        begin: Alignment(-1.2 + value * 2.4, 0),
                        end: Alignment(-0.2 + value * 2.4, 0),
                        colors: [
                          Colors.transparent,
                          theme.shimmerHighlight.withValues(alpha: 0.6),
                          Colors.transparent,
                        ],
                        stops: const [0.25, 0.5, 0.75],
                      ).createShader(bounds);
                    },
                    child: child,
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}
