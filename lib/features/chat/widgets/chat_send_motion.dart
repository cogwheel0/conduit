import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../../../shared/theme/theme_extensions.dart';
import 'chat_motion_spring.dart';
import 'chat_timeline_viewport.dart' show ChatScrollDestination;

/// Tells the place a message was sent from (the composer) how the message's
/// words are leaving it. [onLiftOff] hears when they start to rise, so it can
/// close up behind them on the same spring; until then it keeps its shape
/// around them. The departure itself ([depart]) comes once they have risen
/// clear of it, so it can show what belongs there (its placeholder) without
/// the two ever being drawn over each other. Each is called at most once,
/// lift-off first, and always eventually: as the flying words move, when
/// they cannot fly at all, or when the flight ends early.
class ChatSendDeparture {
  ChatSendDeparture(VoidCallback onDeparted, {VoidCallback? onLiftOff})
    : _onDeparted = onDeparted,
      _onLiftOff = onLiftOff;

  VoidCallback? _onDeparted;
  VoidCallback? _onLiftOff;

  /// Whether [depart] has run.
  bool get departed => _onDeparted == null;

  /// Whether [liftOff] (or [depart]) has run.
  bool get liftedOff => _onLiftOff == null;

  /// Reports that the words have started to rise, once. Changes the
  /// source's state, so never call it from inside layout or paint (see
  /// [liftOffAfterFrame]).
  void liftOff() {
    final onLiftOff = _onLiftOff;
    _onLiftOff = null;
    onLiftOff?.call();
  }

  /// Reports the departure, once, and the lift-off with it if that has not
  /// been reported. Changes the source's state, so never call it from inside
  /// layout or paint (see [departAfterFrame]).
  void depart() {
    liftOff();
    final onDeparted = _onDeparted;
    _onDeparted = null;
    onDeparted?.call();
  }

  bool _scheduled = false;
  bool _liftOffScheduled = false;

  /// [depart] after the current frame, for callers inside layout or paint.
  void departAfterFrame() {
    if (departed || _scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => depart());
    WidgetsBinding.instance.scheduleFrame();
  }

  /// [liftOff] after the current frame, for callers inside layout or paint.
  void liftOffAfterFrame() {
    if (liftedOff || _liftOffScheduled) return;
    _liftOffScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => liftOff());
    WidgetsBinding.instance.scheduleFrame();
  }
}

/// One line of glyphs in the text a message was sent from, in global
/// coordinates: the top of its first line or the bottom of its last. The
/// flying message puts the same line of its own text exactly there, so its
/// first frame draws the words where they were, whatever the line heights.
typedef ChatSendTextLine = ({double y, bool last});

/// The words a message was typed as, wrapped the way their field showed
/// them: one entry per line on screen, set in the field's own style. The
/// flying message starts as exactly these lines and flows into its bubble's
/// own wrap only once it is on its way, so the text never re-wraps while it
/// is still where it was written.
///
/// [left] is the field's text start on screen (global x), so the words can
/// start there while the bubble around them keeps to its own column; [room]
/// is where a fill around them may reach at first without crossing the
/// composer's edge, relative to that start and the top of the first line of
/// letters. Either is null when unknown.
typedef ChatSendTypedText = ({
  List<String> lines,
  TextStyle style,
  TextScaler textScaler,
  double? left,
  Rect? room,
});

/// Where the text of the message being sent was on screen: the composer's
/// field, or the follow-up row that was tapped. The new bubble rises from
/// here, so the message visibly travels from where it was written.
class ChatSendOrigin {
  ChatSendOrigin._();

  static Rect? _rect;
  static DateTime? _recordedAt;
  static ChatSendTextLine? _line;
  static double? _clearanceTop;
  static ChatSendDeparture? _departure;
  static ChatSendTypedText? _typed;

  /// The box the words follow if it has moved since recording (the keyboard
  /// going down carries the composer with it), and its bottom-left then.
  static RenderBox? _box;
  static Offset? _boxBottomLeft;

  /// How long a recorded origin stays usable. The bubble mounts within a
  /// frame or two of the send; anything later is not this send's bubble.
  static const Duration maxAge = Duration(milliseconds: 1500);

  /// Records [globalRect] (logical pixels in the view) as the next bubble's
  /// origin. With a [line], the flying words line up on it; with a
  /// [clearanceTop] (the composer's top edge), [departure] is told once the
  /// words have risen above it. With [typed], they start as those lines.
  static void record(
    Rect globalRect, {
    ChatSendTextLine? line,
    double? clearanceTop,
    ChatSendDeparture? departure,
    ChatSendTypedText? typed,
  }) {
    // A newer send replaces one whose words never left: let it go.
    final replaced = _departure;
    _rect = globalRect;
    _recordedAt = DateTime.now();
    _line = line;
    _clearanceTop = clearanceTop;
    _departure = departure;
    _typed = typed;
    _box = null;
    _boxBottomLeft = null;
    if (replaced != null && !identical(replaced, departure)) replaced.depart();
  }

  /// Records the on-screen rect of [context]'s render box, if laid out. A
  /// bubble that only gets to leave a few frames later (its row was off
  /// screen) leaves from where that box is then, moved as the box moved, so
  /// it never appears where the composer used to be.
  ///
  /// The flying words line up with the first line of the text inside that
  /// box, or with its last line when [alignLastLine] is set (a composer that
  /// may have scrolled, or that wraps wider than the bubble: the words then
  /// grow upwards, the way they are about to travel, never down over the
  /// composer's buttons). With [clearOf], [departure] hears when the words
  /// have risen above that box's top edge, and the words follow that box
  /// rather than [context]'s: the composer may re-lay its rows out the moment
  /// the words leave (the field moving into a one-line row), but only the
  /// keyboard moves the composer itself. With [carryTypedLines], the words
  /// start wrapped as the field inside the box wraps them (see
  /// [ChatSendTypedText]) when it shows them all, lined up on its first
  /// line, which both wraps begin alike: the bubble's extra lines then only
  /// come in below once the words have risen. When nothing can be recorded,
  /// [departure] is told at once.
  static void recordFrom(
    BuildContext? context, {
    bool alignLastLine = false,
    BuildContext? clearOf,
    ChatSendDeparture? departure,
    bool carryTypedLines = false,
  }) {
    final box = context?.findRenderObject();
    if (box is! RenderBox || !box.hasSize || !box.attached) {
      departure?.depart();
      return;
    }
    final rect = box.localToGlobal(Offset.zero) & box.size;
    final clearObject = clearOf?.findRenderObject();
    final clearBox =
        clearObject is RenderBox && clearObject.hasSize && clearObject.attached
        ? clearObject
        : null;
    final carried = carryTypedLines ? chatSendTypedTextOf(box) : null;
    final typed = carried == null
        ? null
        : _placeTypedText(carried, box, clearBox);
    final last = typed == null && alignLastLine;
    final extent = chatTextLineExtent(box, last: last);
    record(
      rect,
      line: extent == null
          ? null
          : (
              y: box
                  .localToGlobal(Offset(0, last ? extent.bottom : extent.top))
                  .dy,
              last: last,
            ),
      clearanceTop: clearBox?.localToGlobal(Offset.zero).dy,
      departure: departure,
      typed: typed,
    );
    final followed = clearBox ?? box;
    _box = followed;
    _boxBottomLeft = followed.localToGlobal(Offset(0, followed.size.height));
  }

  /// Whether a fresh origin is waiting, without spending it.
  static bool get hasFresh {
    final at = _recordedAt;
    return _rect != null &&
        at != null &&
        DateTime.now().difference(at) <= maxAge;
  }

  /// The typed lines of the fresh origin, without spending it.
  static ChatSendTypedText? get freshTypedText => hasFresh ? _typed : null;

  /// Whether [departure]'s origin is still waiting for a message to take it.
  static bool isWaiting(ChatSendDeparture departure) =>
      identical(_departure, departure) && _rect != null;

  /// Returns the recorded origin once, if it is still fresh, moved as the
  /// recorded box has moved since (the keyboard going down carries the
  /// composer with it). Measures that box, so call it from paint or later.
  /// The words leave in place, so its departure is reported at once.
  static Rect? take({DateTime? now}) {
    final taken = takeFollowing(now: now);
    taken?.departure?.departAfterFrame();
    return taken?.rect.shift(taken.drift());
  }

  /// Returns the recorded origin once, if it is still fresh, as recorded,
  /// with how far its box has moved since recording (zero once it is gone).
  /// Measures nothing until [drift] is called, so it is safe during layout;
  /// a bubble still waiting to leave stays with the composer through it.
  /// The taker owns the departure and must report it.
  static ChatSendTakenOrigin? takeFollowing({DateTime? now}) {
    final rect = _rect;
    final at = _recordedAt;
    final box = _box;
    final recorded = _boxBottomLeft;
    final line = _line;
    final clearanceTop = _clearanceTop;
    final departure = _departure;
    _rect = null;
    _recordedAt = null;
    _box = null;
    _boxBottomLeft = null;
    _line = null;
    _clearanceTop = null;
    _departure = null;
    _typed = null;
    if (rect == null || at == null) return null;
    if ((now ?? DateTime.now()).difference(at) > maxAge) {
      departure?.departAfterFrame();
      return null;
    }
    return (
      rect: rect,
      drift: () {
        if (box == null || recorded == null || !box.attached || !box.hasSize) {
          return Offset.zero;
        }
        final current = box.localToGlobal(Offset(0, box.size.height));
        return current.isFinite ? current - recorded : Offset.zero;
      },
      line: line,
      clearanceTop: clearanceTop,
      departure: departure,
    );
  }

  @visibleForTesting
  static void debugReset() {
    _rect = null;
    _recordedAt = null;
    _box = null;
    _boxBottomLeft = null;
    _line = null;
    _clearanceTop = null;
    _departure = null;
    _typed = null;
  }
}

/// A send origin as taken: where the words were, how far their box has moved
/// since, the line of glyphs to start on, the edge the words must clear, and
/// whom to tell once they have.
typedef ChatSendTakenOrigin = ({
  Rect rect,
  Offset Function() drift,
  ChatSendTextLine? line,
  double? clearanceTop,
  ChatSendDeparture? departure,
});

/// The first text under [root] (a paragraph or an editable field), if laid
/// out.
RenderBox? _firstTextBox(RenderObject root) {
  RenderBox? found;
  void visit(RenderObject node) {
    if (found != null) return;
    if (node is RenderParagraph || node is RenderEditable) {
      found = node as RenderBox;
      return;
    }
    node.visitChildren(visit);
  }

  visit(root);
  final box = found;
  return box != null && box.hasSize ? box : null;
}

/// The vertical extent, in [root]'s coordinates, of the glyphs of the first
/// text under [root]: its first visible character's line, or its last one's
/// when [last] is set. Tight glyph boxes, so two texts set with different
/// line heights still line up on their letters. Null when there is no laid
/// out text with a visible character.
({double top, double bottom})? chatTextLineExtent(
  RenderObject root, {
  required bool last,
}) {
  final text = _firstTextBox(root);
  if (text == null) return null;
  final String plain;
  if (text is RenderParagraph) {
    plain = text.text.toPlainText(includeSemanticsLabels: false);
  } else if (text is RenderEditable) {
    plain = text.text?.toPlainText(includeSemanticsLabels: false) ?? '';
  } else {
    return null;
  }
  var index = -1;
  if (last) {
    for (var i = plain.length - 1; i >= 0; i--) {
      if (plain[i].trim().isNotEmpty) {
        index = i;
        break;
      }
    }
  } else {
    for (var i = 0; i < plain.length; i++) {
      if (plain[i].trim().isNotEmpty) {
        index = i;
        break;
      }
    }
  }
  if (index < 0) return null;
  final selection = TextSelection(baseOffset: index, extentOffset: index + 1);
  final List<TextBox> boxes = text is RenderParagraph
      ? text.getBoxesForSelection(selection)
      : (text as RenderEditable).getBoxesForSelection(selection);
  if (boxes.isEmpty) return null;
  final glyph = last ? boxes.last : boxes.first;
  final transform = text.getTransformTo(root);
  final top = MatrixUtils.transformPoint(transform, Offset(0, glyph.top)).dy;
  final bottom = MatrixUtils.transformPoint(
    transform,
    Offset(0, glyph.bottom),
  ).dy;
  if (!top.isFinite || !bottom.isFinite) return null;
  return (top: top, bottom: bottom);
}

/// The lines of the editable text under [root] as they are wrapped on
/// screen, with its style, or null when they cannot stand in for it exactly:
/// no laid out left-to-right field, hidden or embedded content, or more
/// lines than it shows (it has scrolled). Blank lines before the first and
/// after the last words are left out, as a sent message leaves them out.
ChatSendTypedText? chatSendTypedTextOf(RenderObject root) {
  RenderEditable? editable;
  void visit(RenderObject node) {
    if (editable != null) return;
    if (node is RenderEditable) {
      editable = node;
      return;
    }
    node.visitChildren(visit);
  }

  visit(root);
  final field = editable;
  if (field == null ||
      !field.hasSize ||
      field.obscureText ||
      field.textDirection != TextDirection.ltr) {
    return null;
  }
  final style = field.text?.style;
  final plain = field.plainText;
  // An embedded widget (U+FFFC) has no glyphs to copy.
  if (style == null || plain.trim().isEmpty || plain.contains('\uFFFC')) {
    return null;
  }
  final lines = <String>[];
  var start = 0;
  while (start < plain.length) {
    if (plain[start] == '\n') {
      lines.add('');
      start++;
      continue;
    }
    final line = field.getLineAtOffset(TextPosition(offset: start));
    if (line.start > start || line.end <= start) {
      // Whitespace the line boundaries leave out sits at the end of the
      // line before it, where it draws nothing.
      start++;
      continue;
    }
    lines.add(plain.substring(start, line.end).trimRight());
    start = line.end;
    if (start < plain.length && plain[start] == '\n') {
      // The break ends this line; a line follows it, even an empty last one.
      start++;
      if (start == plain.length) lines.add('');
    }
  }
  final maxLines = field.maxLines;
  if (maxLines != null && lines.length > maxLines) return null;
  while (lines.isNotEmpty && lines.first.trim().isEmpty) {
    lines.removeAt(0);
  }
  while (lines.isNotEmpty && lines.last.trim().isEmpty) {
    lines.removeLast();
  }
  if (lines.isEmpty) return null;
  return (
    lines: List<String>.unmodifiable(lines),
    style: style,
    textScaler: field.textScaler,
    left: null,
    room: null,
  );
}

/// [typed] with where its words start on screen and the room a fill around
/// them may take inside [shell] (the composer), from the field under [root].
ChatSendTypedText _placeTypedText(
  ChatSendTypedText typed,
  RenderBox root,
  RenderBox? shell,
) {
  final text = _firstTextBox(root);
  final glyphs = chatTextLineExtent(root, last: false);
  if (text == null || glyphs == null) return typed;
  final start = text.localToGlobal(Offset.zero);
  final glyphTop = root.localToGlobal(Offset(0, glyphs.top)).dy;
  if (!start.isFinite || !glyphTop.isFinite) return typed;
  Rect? room;
  if (shell != null) {
    // Inside the composer's edge, with a point to spare for its hairline;
    // down to the bottom of the field, never over the buttons below it.
    final edge = shell.localToGlobal(Offset.zero) & shell.size;
    final fieldBottom = text.localToGlobal(Offset(0, text.size.height)).dy;
    room = Rect.fromLTRB(
      edge.left + _composerEdgeInset - start.dx,
      edge.top + _composerEdgeInset - glyphTop,
      edge.right - _composerEdgeInset - start.dx,
      math.min(edge.bottom - _composerEdgeInset, fieldBottom + 4) - glyphTop,
    );
  }
  return (
    lines: typed.lines,
    style: typed.style,
    textScaler: typed.textScaler,
    left: start.dx,
    room: room,
  );
}

/// How far inside the composer's edge a fill around the sent words keeps
/// while it is still within the composer.
const double _composerEdgeInset = 2;

/// Messages whose entrance has been decided, so a remount (scrolling away
/// and back, a rebuilt timeline) never replays it.
final LinkedHashSet<String> _enteredMessageIds = LinkedHashSet<String>();
const int _enteredMessageIdCapacity = 512;

@visibleForTesting
void debugResetChatSendEntrances() {
  _enteredMessageIds.clear();
  _flightsInAir.clear();
  ChatSendFlights._inAir.value = false;
}

/// Sent messages flying to their rows now, by message. The transcript may
/// build a row again while its message is in the air (a new chat's first
/// turn moving between the timeline's slivers as it settles); the new row
/// takes the flight over where it is, instead of the message jumping to its
/// place.
final Map<String, _SendFlight> _flightsInAir = <String, _SendFlight>{};

/// Whether a sent message is flying above the transcript.
///
/// Native views in the transcript (a reply's More button) step aside while
/// one is: Flutter draws what passes over such a view in a layer of its own,
/// and a bubble crossing one that scrolls with the transcript showed a hole
/// for a frame where the view was. A view that stands aside keeps its native
/// state and comes back as the message lands.
class ChatSendFlights {
  ChatSendFlights._();

  static final ValueNotifier<bool> _inAir = ValueNotifier<bool>(false);

  /// True from the frame after a message takes off until the frame after
  /// the last one in the air lands.
  static ValueListenable<bool> get inAir => _inAir;

  static bool _syncScheduled = false;

  /// Updates [inAir] after this frame: never inside a build or layout.
  static void _sync() {
    if (_syncScheduled) return;
    _syncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncScheduled = false;
      _inAir.value = _flightsInAir.values.any((flight) => !flight.ended);
    });
    WidgetsBinding.instance.scheduleFrame();
  }
}

/// How long a new reply's placeholder (model label, "Thinking…") waits
/// before fading in, at the least (see [startChatReplyEntrance]).
const Duration chatReplyEntranceDelay = Duration(milliseconds: 260);

/// Calls [enter] once a new reply's placeholder may fade in: after
/// [chatReplyEntranceDelay], and never while a sent message is still flying
/// to its row ([ChatSendFlights.inAir]), since the words rise through the
/// space where the reply starts. Returns the delay's timer for its owner to
/// cancel; [enter] may still run after the owner has gone, so it checks.
Timer startChatReplyEntrance(VoidCallback enter) {
  return Timer(chatReplyEntranceDelay, () {
    final inAir = ChatSendFlights._inAir;
    if (!inAir.value) {
      enter();
      return;
    }
    void landed() {
      if (inAir.value) return;
      inAir.removeListener(landed);
      enter();
    }

    inAir.addListener(landed);
  });
}

/// Content created this long ago or less still animates in; anything older
/// is history and appears in place.
const Duration chatEntranceFreshness = Duration(seconds: 3);

/// Whether a message stamped [timestamp] is new enough to animate in.
bool isFreshChatContent(DateTime timestamp, {DateTime? now}) {
  final age = (now ?? DateTime.now()).difference(timestamp);
  return age.abs() <= chatEntranceFreshness;
}

/// Whether [key]'s one entrance is still to be shown. A row can mount and be
/// replaced before it is ever painted (the timeline stays hidden while a new
/// turn's position settles), so this only asks; [markChatEntranceShown]
/// spends the entrance once it is actually on screen.
bool isChatEntranceAvailable(String key) =>
    key.isNotEmpty && !_enteredMessageIds.contains(key);

/// Records that [key]'s entrance was shown, so remounts stay still.
void markChatEntranceShown(String key) {
  if (key.isEmpty) return;
  _enteredMessageIds.add(key);
  while (_enteredMessageIds.length > _enteredMessageIdCapacity) {
    _enteredMessageIds.remove(_enteredMessageIds.first);
  }
}

/// Claims the one entrance [key] may ever play, at once. Returns false when
/// it already played, so a remount stays still.
bool claimChatEntrance(String key) {
  if (!isChatEntranceAvailable(key)) return false;
  markChatEntranceShown(key);
  return true;
}

/// Calls [onFirstPaint] after the first frame in which [child] is actually
/// painted: not while an ancestor hides it (the timeline's settle cover, a
/// zero opacity), and only once per element.
class ChatFirstPaintListener extends SingleChildRenderObjectWidget {
  const ChatFirstPaintListener({
    super.key,
    required this.onFirstPaint,
    required super.child,
  });

  final VoidCallback onFirstPaint;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderFirstPaintListener(onFirstPaint);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderFirstPaintListener).onFirstPaint = onFirstPaint;
  }
}

class _RenderFirstPaintListener extends RenderProxyBox {
  _RenderFirstPaintListener(this.onFirstPaint);

  VoidCallback onFirstPaint;
  bool _painted = false;

  @override
  void paint(PaintingContext context, Offset offset) {
    if (!_painted) {
      _painted = true;
      // Never change state from inside paint.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (attached) onFirstPaint();
      });
    }
    super.paint(context, offset);
  }
}

/// The new-chat greeting leaving as the first message is sent: it fades out
/// where it stands over [duration], opacity only, on the beat of the message
/// rising from the composer and the composer closing behind it. The fade is
/// front-loaded ([curve]), so the greeting is all but gone before the rising
/// message reaches its line. Its first [child] is kept as it was, so the
/// keyboard going down or the composer shrinking meanwhile never moves it.
/// Reduce Motion makes the same fade the cross-fade. It never takes touches
/// or VoiceOver focus, and calls [onDone] once it has gone.
class ChatGreetingExit extends StatefulWidget {
  const ChatGreetingExit({
    super.key,
    required this.child,
    required this.onDone,
  });

  final Widget child;
  final VoidCallback onDone;

  /// Quick: the greeting has cleared the stage before the rising message's
  /// top can reach its line, whatever the wait between the tap and the
  /// message leaving the composer.
  static const Duration duration = Duration(milliseconds: 150);

  /// Front-loaded: a quarter of the way through, a third of the greeting is
  /// left; halfway, an eighth.
  static const Curve curve = Curves.easeOutCubic;

  @override
  State<ChatGreetingExit> createState() => _ChatGreetingExitState();
}

class _ChatGreetingExitState extends State<ChatGreetingExit>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: ChatGreetingExit.duration,
  );
  late final Animation<double> _opacity = ReverseAnimation(
    CurvedAnimation(parent: _controller, curve: ChatGreetingExit.curve),
  );

  /// The greeting as it stood when the send began. Rebuilds of the page
  /// (a new composer height) would re-centre a fresh copy; the leaving one
  /// holds still.
  late final Widget _frozenChild = widget.child;

  @override
  void initState() {
    super.initState();
    // Start the clock after the first frame that shows the greeting leaving,
    // as the rising message does: a slow first frame (the new chat's
    // transcript mounting) then delays both together instead of spending
    // the fade before the message has moved.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _controller.forward().whenCompleteOrCancel(() {
        if (mounted) widget.onDone();
      });
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ExcludeSemantics(
        child: FadeTransition(
          opacity: _opacity,
          // The page grows as the keyboard goes down; laid out as it first
          // was, the greeting stays on its line instead of sliding with it.
          child: _FirstLayoutHold(child: _frozenChild),
        ),
      ),
    );
  }
}

/// Content that a send makes obsolete (the last reply's follow-up
/// suggestions) dissolving instead of vanishing. When [child] becomes null,
/// its last appearance stays drawn where it was and fades out over
/// [duration], opacity only, while taking no room: layout moves on at once,
/// so the new turn takes its place and the transcript's scroll is unchanged,
/// but nothing pops out of view. The fade is front-loaded, as the leaving
/// greeting's is, so it is all but gone before the rising message crosses
/// its lines. Reduce Motion keeps the same fade, as a cross-fade. A leaving
/// child never takes touches or VoiceOver focus.
class ChatLeavingContent extends StatefulWidget {
  const ChatLeavingContent({super.key, required this.child});

  /// What shows now, or null once it has gone.
  final Widget? child;

  static const Duration duration = Duration(milliseconds: 150);

  @override
  State<ChatLeavingContent> createState() => _ChatLeavingContentState();
}

class _ChatLeavingContentState extends State<ChatLeavingContent>
    with SingleTickerProviderStateMixin {
  /// How far the leaving child has gone: 0 while it shows, 1 once gone.
  late final AnimationController _exit = AnimationController(
    vsync: this,
    duration: ChatLeavingContent.duration,
  );
  late final Animation<double> _opacity = ReverseAnimation(
    CurvedAnimation(parent: _exit, curve: Curves.easeOutCubic),
  );

  /// The child that is leaving, kept to draw it fading.
  Widget? _leaving;

  @override
  void didUpdateWidget(covariant ChatLeavingContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    final previous = oldWidget.child;
    if (widget.child != null) {
      _leaving = null;
      _exit.value = 0;
    } else if (previous != null) {
      _leaving = previous;
      _exit.forward(from: 0).whenCompleteOrCancel(() {
        if (mounted && widget.child == null && _leaving != null) {
          setState(() => _leaving = null);
        }
      });
    }
  }

  @override
  void dispose() {
    _exit.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final child = widget.child ?? _leaving;
    if (child == null) return const SizedBox.shrink();
    final leaving = widget.child == null;
    // One shape whether it shows or leaves, so the child is not rebuilt
    // from scratch the moment it starts to go.
    return _LeavingLayout(
      leaving: leaving,
      child: IgnorePointer(
        ignoring: leaving,
        child: ExcludeSemantics(
          excluding: leaving,
          child: FadeTransition(opacity: _opacity, child: child),
        ),
      ),
    );
  }
}

/// Lays its child out as usual and takes its size, or no height at all while
/// [leaving], still painting it where it was.
class _LeavingLayout extends SingleChildRenderObjectWidget {
  const _LeavingLayout({required this.leaving, required super.child});

  final bool leaving;

  @override
  _RenderLeavingLayout createRenderObject(BuildContext context) =>
      _RenderLeavingLayout(leaving);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderLeavingLayout renderObject,
  ) {
    renderObject.leaving = leaving;
  }
}

class _RenderLeavingLayout extends RenderProxyBox {
  _RenderLeavingLayout(this._leaving);

  bool _leaving;
  set leaving(bool value) {
    if (value == _leaving) return;
    _leaving = value;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(constraints.copyWith(minHeight: 0), parentUsesSize: true);
    size = constraints.constrain(
      Size(child.size.width, _leaving ? 0 : child.size.height),
    );
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final childSize =
        child?.getDryLayout(constraints.copyWith(minHeight: 0)) ?? Size.zero;
    return constraints.constrain(
      Size(childSize.width, _leaving ? 0 : childSize.height),
    );
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) =>
      !_leaving && super.hitTest(result, position: position);
}

/// Builds the stand-in that flies up from where a message was written. It
/// lays out exactly like the message's row and draws a bubble around the
/// words as they were written at [morph] 0 and the finished bubble at 1.
/// With [typed], the words at 0 are those lines, as the field wrapped them,
/// and give way to the bubble's own wrap as [morph] runs. [morph] is how far
/// the stand-in has travelled (see [ChatSendEntrance.shapeAt]), so nothing
/// about the words changes while they still sit where they were written;
/// read it at paint time.
typedef ChatSendFlightBuilder = Widget Function(
  BuildContext context,
  Animation<double> morph,
  ChatSendTypedText? typed,
);

/// Lays its child out with the constraints it first had, at the top-left,
/// whatever its parent offers later.
class _FirstLayoutHold extends SingleChildRenderObjectWidget {
  const _FirstLayoutHold({required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderFirstLayoutHold();
}

class _RenderFirstLayoutHold extends RenderProxyBox {
  BoxConstraints? _first;

  @override
  void performLayout() {
    final first = _first ??= constraints;
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(first, parentUsesSize: true);
    size = constraints.constrain(child.size);
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.constrain(
    child?.getDryLayout(_first ?? constraints) ?? Size.zero,
  );
}

/// How much higher a row in [position]'s transcript will rest once the
/// programmatic scroll it is running settles (the transcript bringing a sent
/// turn up to the top), in points; zero when nothing is scrolling it to a
/// destination. A message flying to its row aims this much above the row, so
/// it heads for where the row will be, on the same spring as the scroll, and
/// the two close their gap instead of the message chasing a moving target
/// across the text above it.
double chatRestingRise(ScrollPosition? position) {
  if (position == null ||
      !position.hasPixels ||
      position.axisDirection != AxisDirection.down) {
    return 0;
  }
  final Object destination = position;
  if (destination is! ChatScrollDestination) return 0;
  final resting = destination.restingPixels;
  return resting == null ? 0 : resting - position.pixels;
}

/// A just-sent message rising into place from where it was written.
///
/// It moves on a critically damped spring (0.4 s response, damping 1.0, so
/// no overshoot) from the send origin to its place in the thread. The
/// spring chases that place live, keeping its own position and velocity, so
/// whatever the timeline does meanwhile (a new chat settling its first turn)
/// folds into one continuous motion with no jump. While the transcript
/// scrolls the turn up to the top, the message aims at where its row will
/// come to rest (see [chatRestingRise]). It runs on a [ChatMotionClock], as
/// the scroll and the composer closing behind it do, so a slow frame delays
/// the motion instead of spending the spring in one step.
///
/// With a [flightBuilder] (a plain text message), the message leaves from
/// the words themselves, as one object: a stand-in drawn above everything,
/// the composer and the transcript included, starts with its text exactly
/// where the typed text was and its bubble's fill already around it. It is
/// never drawn over the transcript: it waits in the composer until its row
/// has come up level with it (a reply that ran on below the screen scrolls
/// past first), then rises behind its row into the space the turn leaves,
/// never above the row while the transcript brings the turn up, and never
/// faster than [maxFlightSpeed]. Its shape (the fill, the words' wrap)
/// changes as it sets off (see [reshapeSeconds]), so it is never anything
/// but a bubble. The row in the thread stays hidden until the stand-in
/// lands on it, then takes its place in the same frame. Without one it
/// rises from the origin and fades the rest of the way in. Without an
/// origin (a message from elsewhere) it rises a short way instead. Only a
/// message created in the last few seconds, mounting for the first time,
/// animates; Reduce Motion fades it in where it lands.
class ChatSendEntrance extends StatefulWidget {
  const ChatSendEntrance({
    super.key,
    required this.messageId,
    required this.timestamp,
    required this.child,
    this.useSendOrigin = true,
    this.flightBuilder,
  });

  final String messageId;
  final DateTime timestamp;
  final Widget child;

  /// Whether to rise from [ChatSendOrigin]; false rises a short way.
  final bool useSendOrigin;

  /// The stand-in that flies from the origin above the composer, or null to
  /// move the row itself.
  final ChatSendFlightBuilder? flightBuilder;

  /// Spring response in seconds (critically damped: damping ratio 1.0): the
  /// pace Apple gives moving something to a new place on screen.
  static const double springResponse = 0.4;

  /// The message's spring. The transcript bringing a sent turn up to the top
  /// and the composer closing up behind the message move on it too, so the
  /// send reads as one motion.
  static const CriticallyDampedSpring spring = CriticallyDampedSpring(
    springResponse,
  );

  /// Upper bound on the motion, in the ticker's time. A full-screen travel
  /// settles within half a pixel in about 0.64 s of motion; the rest is
  /// headroom for a target that keeps moving for a while (a scroll bringing
  /// the turn into place) and for slow frames, which hold the motion back
  /// (see [ChatMotionClock]).
  static const Duration settleDuration = Duration(milliseconds: 2400);

  /// The bubble starts this opaque, so its first frame already shows the
  /// message, and reaches full opacity over [fadeDuration].
  static const double initialOpacity = 0.45;
  static const Duration fadeDuration = Duration(milliseconds: 150);

  /// Reduce Motion: no travel, a plain fade in place.
  static const Duration reducedMotionFadeDuration = Duration(milliseconds: 200);

  /// The rise without a known origin.
  static const double fallbackRise = 14;

  /// Within this many points and points per second of its place, at rest.
  static const double restDistance = 0.25;
  static const double restSpeed = 6;

  /// The fastest a flying message moves, in points per second: at 30 frames
  /// a second, no frame moves it more than about 38 pt, so a long way up
  /// reads as travel rather than a jump. A long way is flown at this pace,
  /// and [spring] brings it in to land (see [limitedStep]).
  static const double maxFlightSpeed = 1150;

  /// Advances a flying message [dt] seconds from [position] towards
  /// [target] at [velocity] on [spring], never faster than [maxFlightSpeed]:
  /// over a long way it accelerates as the spring does, travels at that
  /// pace, and comes in to land on the spring, its velocity continuous
  /// throughout.
  static ({Offset position, Offset velocity}) limitedStep({
    required Offset position,
    required Offset velocity,
    required Offset target,
    required double dt,
  }) {
    final x = spring.step(
      displacement: position.dx - target.dx,
      velocity: velocity.dx,
      dt: dt,
    );
    final y = spring.step(
      displacement: position.dy - target.dy,
      velocity: velocity.dy,
      dt: dt,
    );
    final next = Offset(x.velocity, y.velocity);
    final springPlace = target + Offset(x.displacement, y.displacement);
    if (next.distance <= maxFlightSpeed) {
      return (position: springPlace, velocity: next);
    }
    // Too fast: go the spring's way, but no further than the top speed
    // allows, and carry on at that speed.
    final way = target - position;
    final distance = way.distance;
    if (distance <= restDistance) return (position: target, velocity: next);
    final direction = way / distance;
    final travel = math.min(
      math.min(distance, (springPlace - position).distance),
      maxFlightSpeed * dt,
    );
    return (
      position: position + direction * travel,
      velocity: direction * maxFlightSpeed,
    );
  }

  /// How long, at most, a flying message takes to become its bubble (the
  /// typed lines flowing into its wrap) after it sets off, in the motion's
  /// time.
  static const double reshapeSeconds = 0.3;

  /// The longest sent words wait at the composer for their row to come up
  /// to them (the transcript bringing the turn up from below the screen).
  /// A row that never comes (the user took the scroll over) ends the flight:
  /// the row shows where it is, and nothing is drawn over the transcript.
  static const double maxWaitSeconds = 0.8;

  /// Displacement left at [t] seconds for a critically damped spring with
  /// [springResponse] released at rest, as a fraction of the starting
  /// distance.
  static double remainingAt(double t) => spring.remainingAt(t);

  /// How far a flying message has taken its bubble's shape when it is at
  /// [position] on its way from [start] to [target]: the share of the way
  /// it has come, so its shape and its place change on the one spring.
  static double shapeAt({
    required Offset start,
    required Offset position,
    required Offset target,
  }) {
    final way = (target - start).distance;
    if (way <= restDistance) return 1;
    return (1 - (target - position).distance / way).clamp(0.0, 1.0);
  }

  /// Advances the spring [dt] seconds from [displacement] (points from its
  /// target) moving at [velocity] (points per second).
  static ({double displacement, double velocity}) step({
    required double displacement,
    required double velocity,
    required double dt,
  }) => spring.step(displacement: displacement, velocity: velocity, dt: dt);

  @override
  State<ChatSendEntrance> createState() => _ChatSendEntranceState();
}

class _ChatSendEntranceState extends State<ChatSendEntrance>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;
  ChatSendTakenOrigin? _origin;
  bool _decided = false;
  bool _fadeOnly = false;

  /// The stand-in's flight, when this message leaves from its words.
  _SendFlight? _flight;
  Animation<double>? _morph;
  ChatSendTypedText? _typed;
  final OverlayPortalController _portal = OverlayPortalController();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_decided) return;
    _decided = true;
    final inAir = _flightsInAir[widget.messageId];
    // A row built again mid-flight takes the flight over with the stand-in
    // the flight set off with, even if this build of the row would not fly
    // one (its message caught between two states), so the message never
    // jumps to its place.
    final takesOver =
        inAir != null &&
        !inAir.ended &&
        (widget.flightBuilder ?? inAir.builder) != null &&
        Overlay.maybeOf(context) != null;
    if (!takesOver &&
        (!isChatEntranceAvailable(widget.messageId) ||
            !isFreshChatContent(widget.timestamp))) {
      return;
    }
    _fadeOnly = !takesOver && context.reduceMotion;
    final controller = _controller = AnimationController(
      vsync: this,
      duration: _fadeOnly
          ? ChatSendEntrance.reducedMotionFadeDuration
          : ChatSendEntrance.settleDuration,
    );
    if (takesOver) {
      _takeOver(inAir, controller);
      return;
    }
    if (!_fadeOnly &&
        widget.useSendOrigin &&
        widget.flightBuilder != null &&
        ChatSendOrigin.hasFresh &&
        Overlay.maybeOf(context) != null) {
      final flight = _flight = _SendFlight(onEnd: _endFlight)
        ..owner = this
        ..builder = widget.flightBuilder;
      _morph = _FlightShape(controller, flight);
      // The words this send was typed as, if the field could say; the
      // origin itself is taken when the row is first laid out.
      _typed = flight.typed = ChatSendOrigin.freshTypedText;
      _flightsInAir[widget.messageId] = flight;
      ChatSendFlights._sync();
      // Shown from the first frame, so the stand-in is laid out and ready
      // the moment the row is first painted.
      _portal.show();
      // A stand-in that never got to paint must not keep the row hidden.
      controller.addStatusListener((status) {
        if (status == AnimationStatus.completed) _endFlight();
      });
    }
  }

  /// This row was built again while its message was in the air: it carries
  /// the flight on from where it is (place, speed, shape and clock), and the
  /// stand-in heads for this row once it is laid out.
  void _takeOver(_SendFlight flight, AnimationController controller) {
    _flight = flight
      ..onEnd = _endFlight
      ..owner = this
      ..row = null;
    // The clock runs on from this frame, a frame ahead, so the message
    // never holds still where it was handed over.
    flight.clock.restartTicker(lead: 1 / 60);
    _morph = _FlightShape(controller, flight);
    _typed = flight.typed;
    _portal.show();
    controller.addStatusListener((status) {
      if (status == AnimationStatus.completed) _endFlight();
    });
    controller.forward();
  }

  /// The stand-in landed (or could not fly): the row shows itself in the
  /// next frame and the stand-in goes.
  void _endFlight() {
    final flight = _flight;
    if (flight == null || flight.ended) return;
    flight.ended = true;
    _letGo(widget.messageId, flight);
    // Whatever happened, the words are no longer in the composer.
    flight.departure?.depart();
    if (!mounted) return;
    _portal.hide();
    final controller = _controller;
    if (controller != null) {
      controller.stop();
      // Completing the clock repaints the row, now at rest in its place.
      controller.value = 1;
    }
  }

  /// The first frame that shows the bubble (or, for a stand-in, lays out its
  /// row) spends its entrance and takes the send origin; a mount replaced
  /// before that leaves both.
  ChatSendTakenOrigin? _beginOnScreen() {
    markChatEntranceShown(widget.messageId);
    if (_fadeOnly) {
      // The origin belongs to this send either way; spend it. Nothing
      // flies, so the composer may close up at once.
      ChatSendOrigin.takeFollowing()?.departure?.departAfterFrame();
      return null;
    }
    final origin = _origin ??= widget.useSendOrigin
        ? ChatSendOrigin.takeFollowing()
        : null;
    if (_flight == null) {
      // The row itself rises inside the transcript, under the composer:
      // nothing is drawn over the composer, so it may close up at once.
      origin?.departure?.departAfterFrame();
    }
    return origin;
  }

  /// The spring came to rest before the clock ran out; stop asking for
  /// frames.
  void _settled() {
    final controller = _controller;
    if (controller == null || !controller.isAnimating) return;
    controller.value = 1;
  }

  @override
  void dispose() {
    final flight = _flight;
    if (flight != null && identical(flight.owner, this)) {
      // A row gone mid-flight takes its stand-in with it, unless the row is
      // built again within a frame and takes the flight over.
      flight.owner = null;
      _endOrphanedFlight(widget.messageId, flight);
    }
    _controller?.dispose();
    super.dispose();
  }

  /// Ends [flight] after the next frame if no row has taken it over by
  /// then.
  static void _endOrphanedFlight(String messageId, _SendFlight flight) {
    void check(int framesLeft) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (flight.owner != null || flight.ended) return;
        if (framesLeft > 0) {
          check(framesLeft - 1);
          WidgetsBinding.instance.scheduleFrame();
          return;
        }
        flight.ended = true;
        _letGo(messageId, flight);
        flight.departure?.depart();
      });
    }

    check(1);
    WidgetsBinding.instance.scheduleFrame();
  }

  static void _letGo(String messageId, _SendFlight flight) {
    if (identical(_flightsInAir[messageId], flight)) {
      _flightsInAir.remove(messageId);
    }
    ChatSendFlights._sync();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) return widget.child;
    final flight = _flight;
    final scroll = Scrollable.maybeOf(context)?.position;
    flight?.scroll = scroll;
    final motion = _SendEntranceMotion(
      controller: controller,
      fadeOnly: _fadeOnly,
      beginOnScreen: _beginOnScreen,
      onSettled: _settled,
      flight: flight,
      scroll: scroll,
      child: widget.child,
    );
    final flightBuilder = widget.flightBuilder ?? flight?.builder;
    final morph = _morph;
    if (flight == null || flightBuilder == null || morph == null) {
      return motion;
    }
    return OverlayPortal.overlayChildLayoutBuilder(
      controller: _portal,
      overlayChildBuilder: (context, info) => IgnorePointer(
        child: ExcludeSemantics(
          child: _SendFlightLayer(
            flight: flight,
            controller: controller,
            rowWidth: info.childSize.width,
            child: flightBuilder(context, morph, _typed),
          ),
        ),
      ),
      child: motion,
    );
  }
}

/// How far a flying stand-in has taken its bubble's shape ([_SendFlight.shape],
/// set as its layer paints), ticking with the entrance's clock.
class _FlightShape extends Animation<double>
    with AnimationWithParentMixin<double> {
  _FlightShape(this.parent, this._flight);

  @override
  final Animation<double> parent;
  final _SendFlight _flight;

  @override
  double get value => _flight.shape;
}

/// The state a flying stand-in shares with the row it lands on.
class _SendFlight {
  _SendFlight({required this.onEnd});

  /// Ends the flight; never called from inside paint. The row flying it
  /// now; a row built again mid-flight takes it over.
  VoidCallback onEnd;

  /// The entrance flying this now, or null between one row going and the
  /// row built in its place taking over.
  Object? owner;

  /// The words as typed, and the stand-in, for a row that takes the
  /// flight over.
  ChatSendTypedText? typed;
  ChatSendFlightBuilder? builder;

  /// Where the typed text was, in global coordinates; null until the row is
  /// first laid out (or for good, if this send had none).
  Rect? origin;

  /// How far the composer the words left has moved since [origin] was
  /// taken: a stand-in still waiting for its row stays with it. Frozen once
  /// the words have left the composer, which may then re-lay itself out.
  Offset Function()? originDrift;

  /// The line of glyphs the words start on, if the origin knew it.
  ChatSendTextLine? line;

  /// The composer's top edge (global) the words must rise above before it
  /// may close up behind them, and whom to tell.
  double? clearanceTop;
  ChatSendDeparture? departure;

  /// Tells the composer the words have left it, from inside paint.
  void departFromPaint() {
    final departure = this.departure;
    if (departure == null || departure.departed) return;
    // The composer re-lays itself out from the next frame; the stand-in
    // keeps the drift it had.
    final drift = originDrift?.call() ?? Offset.zero;
    originDrift = () => drift;
    departure.departAfterFrame();
  }

  /// Repaints the stand-in's layer, once the flight is decided.
  VoidCallback? repaint;

  /// The row in the thread the stand-in flies to.
  RenderBox? row;

  /// The transcript's scroll position, to aim where the row will rest.
  ScrollPosition? scroll;

  /// Whether the row's first paint has decided the flight.
  bool decided = false;

  /// Whether the row shows itself again.
  bool ended = false;

  /// The spring's top-left for the stand-in in its layer, and its velocity.
  Offset? position;
  Offset velocity = Offset.zero;

  /// Where the words were typed, in the layer, before the composer moved:
  /// the stand-in waits there, carried by the composer, until it rises.
  Offset? written;

  /// Whether the words have set off for their row, and the motion's time
  /// when the stand-in was first painted and when they set off.
  bool rising = false;
  double? waitedSince;
  double? roseAt;

  /// Whether the stand-in keeps to its row's column and lets the words move
  /// across inside it (typed words that know where they started), rather
  /// than moving sideways as a whole.
  bool keepsColumn = false;

  /// Where the stand-in set off from (the typed words' place when they
  /// started to rise), and where it is painted.
  Offset? start;
  Offset? painted;

  /// The bottom of the stand-in's words inside it.
  double? textBottom;

  /// The time the spring runs on: one display frame's worth at most per
  /// frame drawn, so a frame that comes late (a busy first send) slows the
  /// message for a moment rather than moving it two frames' way at once.
  /// At the display's own pace it is the ticker's time exactly.
  final ChatMotionClock clock = ChatMotionClock(maxStep: 1 / 60);

  /// How far the stand-in has taken its bubble's shape, 0 to 1: the share
  /// of its way it has come (see [ChatSendEntrance.shapeAt]). Never goes
  /// back.
  double shape = 0;

  bool _endScheduled = false;

  bool get flying => origin != null && !ended;

  void scheduleEnd() {
    if (_endScheduled || ended) return;
    _endScheduled = true;
    // Never change state from inside paint.
    WidgetsBinding.instance.addPostFrameCallback((_) => onEnd());
    WidgetsBinding.instance.scheduleFrame();
  }
}

class _SendFlightLayer extends SingleChildRenderObjectWidget {
  const _SendFlightLayer({
    required this.flight,
    required this.controller,
    required this.rowWidth,
    required super.child,
  });

  final _SendFlight flight;
  final AnimationController controller;
  final double rowWidth;

  @override
  _RenderSendFlightLayer createRenderObject(BuildContext context) =>
      _RenderSendFlightLayer(
        flight: flight,
        controller: controller,
        rowWidth: rowWidth,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderSendFlightLayer renderObject,
  ) {
    renderObject
      ..flight = flight
      ..controller = controller
      ..rowWidth = rowWidth;
  }
}

/// Fills the overlay and paints the stand-in where its spring has carried it,
/// aiming each frame at the row's live place in the thread. It starts with
/// its text's top-left on the typed text's, and settles on the row exactly,
/// so the row can take over in the next frame.
class _RenderSendFlightLayer extends RenderProxyBox {
  _RenderSendFlightLayer({
    required _SendFlight flight,
    required AnimationController controller,
    required double rowWidth,
  }) : _flight = flight,
       _controller = controller,
       _rowWidth = rowWidth;

  _SendFlight _flight;
  set flight(_SendFlight value) {
    if (identical(value, _flight)) return;
    _flight = value;
    if (attached) _flight.repaint = markNeedsPaint;
    markNeedsPaint();
  }

  AnimationController _controller;
  set controller(AnimationController value) {
    if (identical(value, _controller)) return;
    if (attached) _controller.removeListener(markNeedsPaint);
    _controller = value;
    if (attached) _controller.addListener(markNeedsPaint);
  }

  double _rowWidth;
  set rowWidth(double value) {
    if (value == _rowWidth) return;
    _rowWidth = value;
    markNeedsLayout();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _controller.addListener(markNeedsPaint);
    _flight.repaint = markNeedsPaint;
  }

  @override
  void detach() {
    _controller.removeListener(markNeedsPaint);
    if (_flight.repaint == markNeedsPaint) _flight.repaint = null;
    super.detach();
  }

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  void performLayout() {
    final width = _rowWidth.isFinite && _rowWidth > 0
        ? _rowWidth
        : constraints.maxWidth;
    child?.layout(
      BoxConstraints(minWidth: width, maxWidth: width),
      parentUsesSize: true,
    );
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      false;

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    final position = _flight.painted ?? _flight.position ?? Offset.zero;
    transform.translateByDouble(position.dx, position.dy, 0, 1);
  }

  double get _clockSeconds {
    final duration = _controller.duration ?? Duration.zero;
    return _controller.value *
        duration.inMicroseconds /
        Duration.microsecondsPerSecond;
  }

  /// The stand-in's words inside it: its first paragraph's frame.
  static Rect? _textRectIn(RenderBox root) {
    final paragraph = _firstTextBox(root);
    if (paragraph == null) return null;
    return paragraph.localToGlobal(Offset.zero, ancestor: root) &
        paragraph.size;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    final flight = _flight;
    final origin = flight.origin;
    final row = flight.row;
    if (child == null ||
        !flight.flying ||
        origin == null ||
        row == null ||
        !row.attached ||
        !row.hasSize) {
      return;
    }
    final live = globalToLocal(row.localToGlobal(Offset.zero));
    // Where the row will be once the transcript has scrolled the turn up:
    // the stand-in heads straight there, so the two arrive together.
    final rise = chatRestingRise(flight.scroll);
    final bringingUp = rise.abs() >= ChatSendEntrance.restDistance;
    final target = live.translate(0, -rise);
    final step = flight.clock.advanceTo(_clockSeconds);
    var written = flight.written;
    if (written == null) {
      // The words leave from where they were typed: their first (or last)
      // line of letters on the typed one, and their leading edge on the
      // typed text's. Typed words that know where they started keep the
      // bubble in its own column and move across inside it as they flow
      // into its wrap, so its trailing edge never leaves the margin. The
      // bubble wraps narrower than the composer, so lining up the last
      // lines grows the extra line upwards, the way the words travel, never
      // down over the composer's buttons.
      final textRect = _textRectIn(child) ?? Rect.zero;
      final line = flight.line;
      final glyphs = line == null
          ? null
          : chatTextLineExtent(child, last: line.last);
      final originTopLeft = globalToLocal(origin.topLeft);
      final double startY;
      if (line != null && glyphs != null) {
        final lineY = globalToLocal(Offset(0, line.y)).dy;
        startY = lineY - (line.last ? glyphs.bottom : glyphs.top);
      } else {
        startY = originTopLeft.dy - textRect.top;
      }
      flight.keepsColumn = flight.typed?.left != null;
      written = flight.written = Offset(
        flight.keepsColumn ? target.dx : originTopLeft.dx - textRect.left,
        startY,
      );
      flight.textBottom = textRect.bottom;
      flight.velocity = Offset.zero;
      flight.waitedSince = flight.clock.seconds;
    }
    var position = flight.position;
    if (!flight.rising) {
      // The words wait where they were typed, carried by the composer, until
      // their row has come up level with them: the transcript bringing the
      // turn up from below the screen scrolls the reply above it past the
      // composer first, so the words never cross it. A row already level
      // with them or above (a new chat, a transcript at its end) lets them
      // go at once.
      final drift = flight.originDrift?.call() ?? Offset.zero;
      position = flight.keepsColumn
          ? Offset(target.dx, written.dy + drift.dy)
          : written + drift;
      if (live.dy <= position.dy + ChatSendEntrance.restDistance) {
        flight
          ..rising = true
          ..roseAt = flight.clock.seconds
          ..start = position
          ..velocity = Offset.zero;
        // The composer closes up behind them from the next frame, as they
        // rise.
        flight.departure?.liftOffAfterFrame();
      } else if (flight.clock.seconds - (flight.waitedSince ?? 0) >
          ChatSendEntrance.maxWaitSeconds) {
        flight.scheduleEnd();
      }
    } else if (position != null && step > 0) {
      final next = ChatSendEntrance.limitedStep(
        position: flight.keepsColumn
            ? Offset(target.dx, position.dy)
            : position,
        velocity: flight.velocity,
        target: target,
        dt: step,
      );
      position = next.position;
      flight.velocity = next.velocity;
    }
    position ??= written;
    if (flight.rising && bringingUp && position.dy < live.dy) {
      // Never above its row while the transcript brings the turn up: the
      // reply above the row is the transcript's, and the words stay clear
      // of it, coming up behind it into the space the turn leaves.
      position = Offset(position.dx, live.dy);
      flight.velocity = Offset(flight.velocity.dx, 0);
    }
    final start = flight.start ?? position;
    // Its shape follows how far it has come, and is done within
    // [ChatSendEntrance.reshapeSeconds] of setting off whatever the way
    // left, so the bubble flies most of the way as itself.
    final roseAt = flight.roseAt;
    final shape = math.max(
      ChatSendEntrance.shapeAt(
        start: start,
        position: position,
        target: target,
      ),
      roseAt == null
          ? 0.0
          : ((flight.clock.seconds - roseAt) / ChatSendEntrance.reshapeSeconds)
                .clamp(0.0, 1.0),
    );
    if (shape > flight.shape) flight.shape = shape;
    _reportDeparture(position);
    // It hands over only on the row itself, once the scroll has landed too.
    final settled =
        (position - target).distance < ChatSendEntrance.restDistance &&
        (target - live).distance < ChatSendEntrance.restDistance &&
        flight.velocity.distance < ChatSendEntrance.restSpeed;
    if (settled) {
      position = target;
      flight.shape = 1;
      flight.scheduleEnd();
    }
    flight.position = position;
    flight.painted = position;
    context.paintChild(child, offset + position);
  }

  /// Tells the composer once the words (their last line of letters) are
  /// above its top edge, wherever the keyboard has carried it: from then on
  /// it may close up and show its placeholder without the two ever being
  /// drawn over each other.
  void _reportDeparture(Offset painted) {
    final flight = _flight;
    final clearance = flight.clearanceTop;
    final departure = flight.departure;
    if (departure == null || departure.departed) return;
    if (clearance == null) {
      flight.departFromPaint();
      return;
    }
    final textBottom = flight.textBottom;
    if (textBottom == null) return;
    final drift = flight.originDrift?.call() ?? Offset.zero;
    final edge = globalToLocal(Offset(0, clearance + drift.dy)).dy;
    if (painted.dy + textBottom <= edge) flight.departFromPaint();
  }
}

class _SendEntranceMotion extends SingleChildRenderObjectWidget {
  const _SendEntranceMotion({
    required this.controller,
    required this.fadeOnly,
    required this.beginOnScreen,
    required this.onSettled,
    required this.flight,
    required this.scroll,
    required super.child,
  });

  final AnimationController controller;
  final bool fadeOnly;
  final _SendFlight? flight;
  final ScrollPosition? scroll;

  /// Called at the first paint; returns the send origin, if any.
  final ChatSendTakenOrigin? Function() beginOnScreen;
  final VoidCallback onSettled;

  @override
  _RenderSendEntrance createRenderObject(BuildContext context) =>
      _RenderSendEntrance(
        controller: controller,
        fadeOnly: fadeOnly,
        beginOnScreen: beginOnScreen,
        onSettled: onSettled,
        flight: flight,
        scroll: scroll,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderSendEntrance renderObject,
  ) {
    renderObject
      ..controller = controller
      ..fadeOnly = fadeOnly
      ..beginOnScreen = beginOnScreen
      ..onSettled = onSettled
      ..flight = flight
      ..scroll = scroll;
  }
}

/// Paints its child displaced towards where the spring has carried it. The
/// spring's state is its painted global top and velocity; each paint aims
/// it at the child's live laid-out top, which only paint knows. A target
/// that jumps (the timeline settling) changes where the spring is heading,
/// never where it is, so the bubble moves continuously. The first paint
/// starts the clock, so a row laid out but not yet shown still enters fully.
class _RenderSendEntrance extends RenderProxyBox {
  _RenderSendEntrance({
    required AnimationController controller,
    required this.fadeOnly,
    required this.beginOnScreen,
    required this.onSettled,
    required this.flight,
    required this.scroll,
  }) : _controller = controller;

  bool fadeOnly;
  ChatSendTakenOrigin? Function() beginOnScreen;
  VoidCallback onSettled;

  /// The transcript's scroll position, to aim where the row will rest.
  ScrollPosition? scroll;

  /// A stand-in flying to this row; while it flies, the row paints nothing.
  _SendFlight? flight;

  AnimationController _controller;
  set controller(AnimationController value) {
    if (identical(value, _controller)) return;
    if (attached) _controller.removeListener(markNeedsPaint);
    _controller = value;
    if (attached) _controller.addListener(markNeedsPaint);
  }

  /// Global top the spring has carried the child to, and its velocity.
  double? _visualTop;
  double _velocity = 0;

  /// Where it started, and whether the transcript has been bringing the turn
  /// up to a destination: from then on the row, which moves inside the
  /// transcript, never shows above where it is laid out, so it never covers
  /// the reply above it.
  double? _startTop;
  bool _ridesTurn = false;

  /// The time the spring and the fade run on, and its reading the spring
  /// was last advanced to.
  final ChatMotionClock _clock = ChatMotionClock();
  double _springAt = 0;
  double _offsetY = 0;
  double _opacity = 1;
  bool _started = false;
  bool _settled = false;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _controller.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _controller.removeListener(markNeedsPaint);
    super.detach();
  }

  bool get _finished =>
      _settled ||
      (_started && _controller.isCompleted) ||
      (flight?.ended ?? false);

  double get _clockSeconds {
    final duration = _controller.duration ?? Duration.zero;
    return _controller.value *
        duration.inMicroseconds /
        Duration.microsecondsPerSecond;
  }

  double _secondsOf(Duration duration) =>
      duration.inMicroseconds / Duration.microsecondsPerSecond;

  void _resolveFrame() {
    if (_finished) {
      _offsetY = 0;
      _opacity = 1;
      return;
    }
    _clock.advanceTo(_clockSeconds);
    final elapsed = _clock.seconds;
    if (fadeOnly) {
      _offsetY = 0;
      final t =
          (elapsed / _secondsOf(ChatSendEntrance.reducedMotionFadeDuration))
              .clamp(0.0, 1.0);
      _opacity = Curves.easeOut.transform(t);
      return;
    }
    final layoutTop = localToGlobal(Offset.zero).dy;
    // Where the row will be once the transcript has scrolled the turn up.
    final rise = chatRestingRise(scroll);
    if (rise.abs() >= ChatSendEntrance.restDistance) _ridesTurn = true;
    final targetTop = layoutTop - rise;
    var visualTop = _visualTop;
    if (visualTop == null) {
      final taken = beginOnScreen();
      final origin = taken?.rect.shift(taken.drift());
      visualTop = origin == null
          ? layoutTop + ChatSendEntrance.fallbackRise
          // The message's last line starts where the field's last line was.
          : origin.bottom - size.height;
      _startTop = visualTop;
      _velocity = 0;
      _springAt = elapsed;
    } else if (elapsed > _springAt) {
      final next = ChatSendEntrance.step(
        displacement: visualTop - targetTop,
        velocity: _velocity,
        dt: elapsed - _springAt,
      );
      visualTop = targetTop + next.displacement;
      _velocity = next.velocity;
      _springAt = elapsed;
    }
    _visualTop = visualTop;
    var paintedTop = visualTop;
    final startTop = _startTop;
    if (_ridesTurn && startTop != null) {
      // Never above where its row is while the turn is brought up.
      paintedTop = math.max(paintedTop, math.min(layoutTop, startTop));
    }
    _offsetY = paintedTop - layoutTop;
    final fade = (elapsed / _secondsOf(ChatSendEntrance.fadeDuration)).clamp(
      0.0,
      1.0,
    );
    _opacity =
        ChatSendEntrance.initialOpacity +
        (1 - ChatSendEntrance.initialOpacity) * Curves.easeOut.transform(fade);
    if (fade >= 1 &&
        _offsetY.abs() < ChatSendEntrance.restDistance &&
        _velocity.abs() < ChatSendEntrance.restSpeed) {
      _settled = true;
      _offsetY = 0;
      _opacity = 1;
      // Never change state from inside paint.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (attached) onSettled();
      });
    }
  }

  /// Starts the clock after this frame, once.
  void _startClock() {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (attached && !_controller.isAnimating && !_settled) {
        _controller.forward();
      }
    });
  }

  @override
  void performLayout() {
    super.performLayout();
    final flight = this.flight;
    if (flight == null) return;
    if (flight.decided) {
      // Built again mid-flight: the stand-in now heads for this row.
      if (!flight.ended && flight.row == null && flight.origin != null) {
        flight.row = this;
        _startClock();
        flight.repaint?.call();
      }
      return;
    }
    // The first layout of the row decides whether the stand-in flies: it
    // needs the send origin, which this spends. Deciding here rather than
    // at the first paint lets the words leave in the frame of the send even
    // when the row is still below the screen (a reply that ran on under the
    // composer); the stand-in then waits with the composer for the row.
    flight.decided = true;
    final taken = beginOnScreen();
    if (taken != null) {
      flight
        ..origin = taken.rect
        ..originDrift = taken.drift
        ..line = taken.line
        ..clearanceTop = taken.clearanceTop
        ..departure = taken.departure
        ..row = this;
      _startClock();
      flight.repaint?.call();
    } else {
      flight.scheduleEnd();
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) return;
    if (!_started) {
      if (fadeOnly) beginOnScreen();
      // The clock starts with the first frame that shows the row.
      _startClock();
    }
    final flight = this.flight;
    if (flight != null && flight.flying) {
      // The stand-in above the composer is this row until it lands.
      _opacityLayer.layer = null;
      return;
    }
    _resolveFrame();
    if (_finished || (_offsetY.abs() < 0.25 && _opacity >= 1)) {
      _opacityLayer.layer = null;
      context.paintChild(child, offset);
      return;
    }
    if (_opacity <= 0) {
      _opacityLayer.layer = null;
      return;
    }
    if (_opacity >= 1) {
      _opacityLayer.layer = null;
      context.paintChild(child, offset + Offset(0, _offsetY));
      return;
    }
    _opacityLayer.layer = context.pushOpacity(
      offset,
      (_opacity * 255).round(),
      (context, layerOffset) =>
          context.paintChild(child, layerOffset + Offset(0, _offsetY)),
      oldLayer: _opacityLayer.layer,
    );
  }

  final LayerHandle<OpacityLayer> _opacityLayer = LayerHandle<OpacityLayer>();

  @override
  void dispose() {
    _opacityLayer.layer = null;
    super.dispose();
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    transform.translateByDouble(0, _finished ? 0 : _offsetY, 0, 1);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    return result.addWithPaintOffset(
      offset: Offset(0, _finished ? 0 : _offsetY),
      position: position,
      hitTest: (result, transformed) =>
          super.hitTestChildren(result, position: transformed),
    );
  }
}
