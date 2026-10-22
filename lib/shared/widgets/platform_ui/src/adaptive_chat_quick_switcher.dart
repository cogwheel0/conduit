import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../../../core/services/haptic_service.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../theme/theme_extensions.dart';
import 'chat_switcher_gesture.dart';

@immutable
class ChatSwitcherChat {
  const ChatSwitcherChat({required this.id, required this.title});

  final String id;
  final String title;
}

enum _Phase { idle, pressing, holding, selecting, cancel, cancelled }

/// A tap creates a chat; a held pointer previews recent chats until release.
/// Owns only the gesture and presentation, never conversation state or drafts.
class ChatQuickSwitcher extends StatefulWidget {
  const ChatQuickSwitcher({
    super.key,
    required this.chats,
    required this.onNewChat,
    required this.onSelected,
    required this.bottomOffset,
    this.enabled = true,
    this.alignLeft = false,
    this.scope,
  });

  final List<ChatSwitcherChat> chats;
  final VoidCallback onNewChat;
  final ValueChanged<ChatSwitcherChat> onSelected;
  final double bottomOffset;
  final bool enabled;
  final bool alignLeft;

  /// Invalidates previews when the host switches accounts or connections.
  final Object? scope;

  @override
  State<ChatQuickSwitcher> createState() => ChatQuickSwitcherState();
}

class ChatQuickSwitcherState extends State<ChatQuickSwitcher>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  static const _holdDuration = Duration(milliseconds: 320);
  final _surfaceKey = GlobalKey();
  final _focusNode = FocusNode();
  final _hapticClock = Stopwatch()..start();
  late final AnimationController _pressAnimation;
  late final AnimationController _dismissAnimation;
  Timer? _resetTimer;
  _Phase _phase = _Phase.idle;
  List<ChatSwitcherChat> _snapshot = const [];
  int _selected = -1;
  int _lastHapticMs = -100;
  int _capacity = 6;
  bool _hasSelected = false;
  Offset? _pointer;
  Offset _buttonCenter = Offset.zero;
  Size _size = Size.zero;

  bool get _choosing => switch (_phase) {
    _Phase.holding || _Phase.selecting || _Phase.cancel => true,
    _ => false,
  };

  bool get _showPicker =>
      _choosing || (_phase == _Phase.cancelled && _dismissAnimation.value < 1);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pressAnimation = AnimationController(vsync: this, duration: _holdDuration);
    _dismissAnimation = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
      value: 1,
    );
  }

  @override
  void didUpdateWidget(ChatQuickSwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled ||
        widget.scope != oldWidget.scope ||
        widget.alignLeft != oldWidget.alignLeft ||
        (_choosing && widget.bottomOffset != oldWidget.bottomOffset) ||
        !listEquals(
          widget.chats.map((chat) => chat.id).toList(),
          oldWidget.chats.map((chat) => chat.id).toList(),
        )) {
      // Never commit a stale preview after an account/list change.
      _reset();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) dismiss();
  }

  @override
  void didChangeMetrics() {
    // Keyboard and rotation changes must not turn a stationary thumb into
    // a different selection as the button moves beneath it.
    dismiss();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _resetTimer?.cancel();
    _pressAnimation.dispose();
    _dismissAnimation.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  /// Lets Android Back close the picker before the chat page handles exit.
  bool dismiss() {
    if (!_choosing && _phase != _Phase.pressing) return false;
    _cancel();
    return true;
  }

  void _reset() {
    _resetTimer?.cancel();
    _pressAnimation.reset();
    _dismissAnimation.value = 1;
    _phase = _Phase.idle;
    _selected = -1;
    _snapshot = const [];
    _pointer = null;
    _hasSelected = false;
  }

  void _press() {
    if (!widget.enabled) return;
    setState(() {
      _reset();
      _phase = _Phase.pressing;
    });
    if (!context.reduceMotion) _pressAnimation.forward();
  }

  void _hold([Offset? globalPosition]) {
    if (!widget.enabled) return;
    setState(() {
      _resetTimer?.cancel();
      _snapshot = widget.chats.take(_capacity).toList(growable: false);
      _phase = _Phase.holding;
      _selected = -1;
      _hasSelected = false;
    });
    _focusNode.requestFocus();
    unawaited(ConduitHaptics.lightImpact());
    if (globalPosition != null) _move(globalPosition);
  }

  void _move(Offset globalPosition) {
    if (!_choosing) return;
    final box = _surfaceKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final pointer = box.globalToLocal(globalPosition);
    final index = chatSwitcherIndex(
      x: pointer.dx,
      y: pointer.dy,
      centerX: _buttonCenter.dx,
      centerY: _buttonCenter.dy,
      midpoint: _size.height / 2,
      count: _snapshot.length,
      alignLeft: widget.alignLeft,
    );
    if (index >= 0 && index != _selected) {
      final now = _hapticClock.elapsedMilliseconds;
      if (now - _lastHapticMs >= 75) {
        _lastHapticMs = now;
        unawaited(ConduitHaptics.selectionClick());
      }
    }
    final outward =
        (pointer.dx - _buttonCenter.dx) * (widget.alignLeft ? -1 : 1) >= 28;
    setState(() {
      _pointer = pointer;
      _selected = index;
      if (index >= 0) _hasSelected = true;
      _phase = index >= 0
          ? _Phase.selecting
          : (_hasSelected || outward ? _Phase.cancel : _Phase.holding);
    });
  }

  void _release(Offset globalPosition) {
    if (!_choosing) return;
    _move(globalPosition);
    if (_selected >= 0) {
      _open(_selected);
    } else {
      _cancel();
    }
  }

  void _newChat() {
    if (!widget.enabled) return;
    setState(_reset);
    unawaited(ConduitHaptics.lightImpact());
    widget.onNewChat();
  }

  void _open(int index) {
    final chat = _snapshot[index];
    setState(_reset);
    unawaited(ConduitHaptics.lightImpact());
    widget.onSelected(chat);
  }

  void _cancel() {
    _resetTimer?.cancel();
    _pressAnimation.stop();
    final animate = _choosing && !context.reduceMotion;
    setState(() {
      _phase = _Phase.cancelled;
      _pointer = null;
      _selected = -1;
    });
    if (animate) {
      _dismissAnimation.forward(from: 0);
    } else {
      _dismissAnimation.value = 1;
    }
    _resetTimer = Timer(const Duration(milliseconds: 850), () {
      if (mounted) setState(_reset);
    });
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape && dismiss()) {
      return KeyEventResult.handled;
    }
    if (_choosing &&
        (key == LogicalKeyboardKey.arrowUp ||
            key == LogicalKeyboardKey.arrowDown)) {
      setState(() {
        if (_snapshot.isNotEmpty) {
          _selected = (_selected + (key == LogicalKeyboardKey.arrowUp ? -1 : 1))
              .clamp(0, _snapshot.length - 1);
          _phase = _Phase.selecting;
        }
      });
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.space) {
      if (_choosing) {
        _selected >= 0 ? _open(_selected) : _cancel();
      } else {
        _newChat();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final cancelling = _phase == _Phase.cancel || _phase == _Phase.cancelled;
    final color = cancelling ? theme.error : theme.buttonPrimary;
    final foreground = cancelling
        ? theme.statusPalette.destructive.onBase
        : theme.buttonPrimaryText;
    final caption = switch (_phase) {
      _Phase.idle => l10n.chatSwitcherReady,
      _Phase.pressing => l10n.chatSwitcherPress,
      _Phase.holding => l10n.chatSwitcherHold,
      _Phase.selecting => l10n.chatSwitcherRelease,
      _Phase.cancel => l10n.chatSwitcherCancel,
      _Phase.cancelled => l10n.chatSwitcherCancelled,
    };

    return Focus(
      focusNode: _focusNode,
      onKeyEvent: _handleKey,
      child: LayoutBuilder(
        builder: (context, constraints) {
          _size = constraints.biggest;
          final bottom = widget.bottomOffset
              .clamp(16.0, math.max(16.0, _size.height - 96))
              .toDouble();
          _buttonCenter = Offset(
            widget.alignLeft ? 54 : _size.width - 54,
            _size.height - bottom - 30,
          );
          final top = MediaQuery.paddingOf(context).top + kToolbarHeight + 16;
          final width = math.min(390.0, math.max(0.0, _size.width - 32));
          final card = Rect.fromLTWH(
            widget.alignLeft ? 16 : _size.width - width - 16,
            top,
            width,
            math.max(100.0, _buttonCenter.dy - 66 - top),
          );
          final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
          _capacity = ((card.height - 80) / (56 * textScale)).floor().clamp(
            1,
            6,
          );

          return AnimatedBuilder(
            animation: Listenable.merge([_pressAnimation, _dismissAnimation]),
            builder: (context, _) {
              final closing = _phase == _Phase.cancelled
                  ? _dismissAnimation.value
                  : 0.0;
              return Stack(
                key: _surfaceKey,
                clipBehavior: Clip.none,
                children: [
                  if (_choosing)
                    Positioned.fill(
                      key: const ValueKey('chat-switcher-barrier-position'),
                      child: GestureDetector(
                        onTap: _cancel,
                        child: ColoredBox(
                          color: theme.surfaceBackground.withValues(alpha: .72),
                        ),
                      ),
                    ),
                  if (_showPicker)
                    Positioned.fromRect(
                      key: const ValueKey('chat-switcher-picker-position'),
                      rect: card,
                      child: IgnorePointer(
                        ignoring: !_choosing,
                        child: Opacity(
                          opacity:
                              (1 - closing) *
                              (_phase == _Phase.cancel ? .55 : 1),
                          child: Transform.translate(
                            offset: (_buttonCenter - card.center) * closing,
                            child: Transform.scale(
                              scale: 1 - closing * .92,
                              child: _buildPicker(l10n, color),
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (_pointer != null &&
                      _choosing &&
                      (_pointer! - _buttonCenter).distance > 44)
                    Positioned(
                      left: _pointer!.dx - 9,
                      top: _pointer!.dy - 9,
                      child: IgnorePointer(
                        child: Container(
                          width: 18,
                          height: 18,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: color,
                            border: Border.all(
                              color: theme.surfaceBackground,
                              width: 3,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: color.withValues(alpha: .18),
                                spreadRadius: 6,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  if (_phase != _Phase.idle)
                    Positioned(
                      key: const ValueKey('chat-switcher-caption-position'),
                      left: widget.alignLeft ? 16 : null,
                      right: widget.alignLeft ? null : 16,
                      bottom: bottom + 74,
                      child: Semantics(
                        liveRegion: true,
                        child: AnimatedContainer(
                          duration: context.motionDuration(
                            const Duration(milliseconds: 130),
                          ),
                          constraints: BoxConstraints(
                            maxWidth: math.min(260, _size.width - 32),
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 7,
                          ),
                          decoration: BoxDecoration(
                            color: theme.surfaceContainer,
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(
                              color: color.withValues(alpha: .2),
                            ),
                          ),
                          child: Text(
                            caption,
                            key: const ValueKey('chat-switcher-caption'),
                            style: TextStyle(color: color, fontSize: 12),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ),
                  Positioned(
                    key: const ValueKey('chat-switcher-fab-position'),
                    left: widget.alignLeft ? 24 : null,
                    right: widget.alignLeft ? null : 24,
                    bottom: bottom,
                    child: Semantics(
                      container: true,
                      button: true,
                      label: l10n.newChat,
                      hint: l10n.chatSwitcherHint,
                      onTap: _newChat,
                      onLongPress: _hold,
                      excludeSemantics: true,
                      child: Listener(
                        onPointerCancel: (_) => dismiss(),
                        child: RawGestureDetector(
                          key: const ValueKey('chat-switcher-button'),
                          excludeFromSemantics: true,
                          gestures: {
                            TapGestureRecognizer:
                                GestureRecognizerFactoryWithHandlers<
                                  TapGestureRecognizer
                                >(
                                  TapGestureRecognizer.new,
                                  (recognizer) => recognizer.onTap = _newChat,
                                ),
                            LongPressGestureRecognizer:
                                GestureRecognizerFactoryWithHandlers<
                                  LongPressGestureRecognizer
                                >(
                                  () => LongPressGestureRecognizer(
                                    duration: _holdDuration,
                                  ),
                                  (recognizer) {
                                    recognizer.onLongPressDown = (_) {
                                      _press();
                                    };
                                    recognizer.onLongPressCancel = () {
                                      if (_phase == _Phase.pressing) {
                                        setState(_reset);
                                      }
                                    };
                                    recognizer.onLongPressStart = (details) {
                                      _hold(details.globalPosition);
                                    };
                                    recognizer.onLongPressMoveUpdate =
                                        (details) {
                                          _move(details.globalPosition);
                                        };
                                    recognizer.onLongPressEnd = (details) {
                                      _release(details.globalPosition);
                                    };
                                  },
                                ),
                          },
                          child: AnimatedScale(
                            scale: _phase == _Phase.pressing ? .9 : 1,
                            duration: context.motionDuration(
                              const Duration(milliseconds: 160),
                            ),
                            curve: Curves.easeOutBack,
                            child: AnimatedContainer(
                              duration: context.motionDuration(
                                const Duration(milliseconds: 130),
                              ),
                              width: 60,
                              height: 60,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: color,
                                boxShadow: [
                                  BoxShadow(
                                    color: color.withValues(alpha: .16),
                                    blurRadius: 16,
                                    spreadRadius: _choosing ? 7 : 0,
                                  ),
                                ],
                              ),
                              child: Stack(
                                alignment: Alignment.center,
                                children: [
                                  if (_phase == _Phase.pressing)
                                    Positioned.fill(
                                      child: Padding(
                                        padding: const EdgeInsets.all(3),
                                        child: CustomPaint(
                                          painter: _HoldRingPainter(
                                            progress: _pressAnimation.value,
                                            color: foreground.withValues(
                                              alpha: .6,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  AnimatedSwitcher(
                                    duration: context.motionDuration(
                                      const Duration(milliseconds: 130),
                                    ),
                                    child: Icon(
                                      cancelling
                                          ? Icons.close_rounded
                                          : _choosing
                                          ? Icons.chat_bubble_outline_rounded
                                          : Icons.add_rounded,
                                      key: ValueKey(
                                        cancelling
                                            ? 'cancel'
                                            : _choosing
                                            ? 'hold'
                                            : 'new',
                                      ),
                                      color: foreground,
                                      size: 28,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildPicker(AppLocalizations l10n, Color color) {
    final theme = context.conduitTheme;
    return Material(
      key: const ValueKey('chat-switcher-picker'),
      color: theme.surfaceContainer,
      elevation: 6,
      shadowColor: theme.cardShadow,
      borderRadius: BorderRadius.circular(24),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 12),
              child: Text(
                l10n.recent,
                style: TextStyle(
                  color: theme.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (_snapshot.isEmpty)
              Expanded(
                child: Center(
                  child: Text(
                    l10n.noConversationsYet,
                    style: TextStyle(color: theme.textSecondary),
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            else
              for (var i = 0; i < _snapshot.length; i++)
                Expanded(
                  child: Semantics(
                    selected: _selected == i,
                    child: InkWell(
                      onTap: _choosing ? () => _open(i) : null,
                      borderRadius: BorderRadius.circular(14),
                      child: AnimatedContainer(
                        key: ValueKey('chat-switcher-row-${_snapshot[i].id}'),
                        duration: context.motionDuration(
                          const Duration(milliseconds: 70),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(
                          color: _selected == i
                              ? color.withValues(alpha: .12)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: _selected == i
                                ? color.withValues(alpha: .5)
                                : Colors.transparent,
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.chat_bubble_outline_rounded,
                              size: 20,
                              color: _selected == i
                                  ? color
                                  : theme.textSecondary,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                _snapshot[i].title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: theme.textPrimary,
                                  fontSize: 14,
                                ),
                              ),
                            ),
                            Icon(Icons.chevron_right, size: 18, color: color),
                          ],
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

class _HoldRingPainter extends CustomPainter {
  const _HoldRingPainter({required this.progress, required this.color});
  final double progress;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) => canvas.drawArc(
    (Offset.zero & size).deflate(1),
    -math.pi / 2,
    math.pi * 2 * progress,
    false,
    Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round,
  );
  @override
  bool shouldRepaint(_HoldRingPainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.color != color;
}
