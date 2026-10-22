import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:clock/clock.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import 'assistant_detail_header.dart';
import 'hermes_tool_summary.dart';

bool isHermesActivityStatus(ChatStatusUpdate status) =>
    status.hidden != true &&
    (status.action == 'reasoning' ||
        (status.action?.startsWith('hermes_tool_') ?? false));

typedef _EntryKey = (int, String?);

/// Reasoning records update in place; receipt times distinguish a new thought
/// from an earlier one that preceded a completed tool.
bool hasPendingHermesActivity(
  List<ChatStatusUpdate> updates, {
  required bool hasReplyText,
}) {
  ChatStatusUpdate? reasoning;
  ChatStatusUpdate? lastTool;
  for (final update in updates) {
    if (!isHermesActivityStatus(update)) continue;
    if (update.action == 'reasoning') {
      reasoning = update;
    } else {
      if (update.done != true) return true;
      lastTool = update;
    }
  }
  if (hasReplyText || reasoning == null || reasoning.done == true) return false;
  return lastTool == null ||
      (reasoning.occurredAt != null &&
          lastTool.occurredAt != null &&
          reasoning.occurredAt!.isAfter(lastTool.occurredAt!));
}

class _Expansion {
  bool open = false;
  bool payload = false;
}

class _ActivityExpansion {
  bool group = false;
  bool thinking = false;
  bool thinkingTouched = false;
  final entries = <_EntryKey, _Expansion>{};
}

/// One native Hermes turn's activity. Presentation reads only the transport's
/// bounded, sanitized status records; opening details never issues a request.
class HermesInlineActivity extends StatefulWidget {
  const HermesInlineActivity({
    super.key,
    required this.updates,
    required this.isStreaming,
    required this.stateId,
    this.hasReplyText = false,
  });

  final List<ChatStatusUpdate> updates;
  final bool isStreaming;
  final String stateId;
  final bool hasReplyText;

  @override
  State<HermesInlineActivity> createState() => _HermesInlineActivityState();
}

class _HermesInlineActivityState extends State<HermesInlineActivity> {
  _ActivityExpansion _expansion = _ActivityExpansion();
  final _starts = <_EntryKey, DateTime>{};
  final _ends = <_EntryKey, DateTime>{};
  String? _restored;

  void _restore() {
    if (_restored == widget.stateId) return;
    final saved = PageStorage.maybeOf(context)
        ?.readState(context, identifier: 'hermes-activity:${widget.stateId}');
    _expansion = saved is _ActivityExpansion ? saved : _ActivityExpansion();
    _starts.clear();
    _ends.clear();
    _restored = widget.stateId;
  }

  void _change(VoidCallback change) {
    setState(change);
    PageStorage.maybeOf(context)?.writeState(
      context,
      _expansion,
      identifier: 'hermes-activity:${widget.stateId}',
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _restore();
  }

  @override
  void didUpdateWidget(covariant HermesInlineActivity oldWidget) {
    super.didUpdateWidget(oldWidget);
    _restore();
  }

  bool _pending(ChatStatusUpdate status) =>
      widget.isStreaming && status.done != true;

  @override
  Widget build(BuildContext context) {
    final tools = <(_EntryKey, ChatStatusUpdate, _ToolContent)>[];
    ChatStatusUpdate? reasoning;
    for (var index = 0; index < widget.updates.length; index++) {
      final update = widget.updates[index];
      if (!isHermesActivityStatus(update)) continue;
      if (update.action == 'reasoning') {
        reasoning = update;
        continue;
      }
      // Timestamp changes on completion. List position and action identify the
      // same operation, including successive calls to the same named tool.
      final key = (index, update.action);
      if (_pending(update)) {
        _starts.putIfAbsent(key, () => update.occurredAt ?? clock.now());
      } else if (_starts.containsKey(key)) {
        _ends.putIfAbsent(key, () => update.occurredAt ?? clock.now());
      }
      tools.add((key, update, _ToolContent(update)));
    }
    final pending = tools.any((entry) => _pending(entry.$2));
    final reasoningPending =
        reasoning != null &&
        widget.isStreaming &&
        !pending &&
        hasPendingHermesActivity(
          widget.updates,
          hasReplyText: widget.hasReplyText,
        );
    final reasoningText = (reasoning?.description ?? '')
        .replaceFirst(
          RegExp(r'^Thinking(?:…|\.{3})?\s*', caseSensitive: false),
          '',
        )
        .trim();
    if (reasoningPending && !_expansion.thinkingTouched) {
      _expansion.thinking = true;
    }
    final l10n = AppLocalizations.of(context)!;
    return Column(
      key: const ValueKey('hermes-inline-activity'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (reasoning != null) ...[
          _Disclosure(
            key: const ValueKey('hermes-thinking-toggle'),
            title: reasoningPending ? l10n.thinking : l10n.thoughts,
            pending: reasoningPending,
            expanded: _expansion.thinking,
            height: 24,
            onTap: reasoningText.isEmpty
                ? null
                : () => _change(() {
                    _expansion.thinkingTouched = true;
                    _expansion.thinking = !_expansion.thinking;
                  }),
          ),
          if (_expansion.thinking && reasoningText.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 160),
                child: SingleChildScrollView(
                  child: SelectableText(
                    reasoningText,
                    style: AppTypography.bodySmallStyle.copyWith(
                      color: context.conduitTheme.textSecondary,
                    ),
                  ),
                ),
              ),
            ),
          if (tools.isNotEmpty) const SizedBox(height: 1),
        ],
        if (tools.isNotEmpty) ...[
          _Disclosure(
            key: const ValueKey('hermes-tool-group-toggle'),
            title: _groupTitle(tools),
            pending: pending,
            expanded: _expansion.group,
            height: 24,
            onTap: () => _change(() => _expansion.group = !_expansion.group),
          ),
          if (!_expansion.group && pending)
            _ToolTicker(entry: tools.lastWhere((entry) => _pending(entry.$2))),
          _ActivityGroupExpansion(
            expanded: _expansion.group,
            child: _expansion.group
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final entry in tools) _buildEntry(context, entry),
                    ],
                  )
                : const SizedBox(width: double.infinity, height: 0),
          ),
        ],
      ],
    );
  }

  Widget _buildEntry(
    BuildContext context,
    (_EntryKey, ChatStatusUpdate, _ToolContent) entry,
  ) {
    final (key, update, content) = entry;
    final state = _expansion.entries.putIfAbsent(key, _Expansion.new);
    final pending = _pending(update);
    final unfinished = !widget.isStreaming && update.done != true;
    final theme = context.conduitTheme;
    final icon = pending
        ? const HermesBreatheIndicator()
        : content.failed || unfinished
        ? Icon(
            content.failed ? Icons.error_outline : Icons.stop_circle_outlined,
            size: 14,
            color: content.failed ? theme.error : theme.textSecondary,
          )
        : content.summary.kind == HermesToolKind.skill
        ? null
        : Icon(
            _toolIcon(content.summary.kind),
            size: 14,
            color: theme.textSecondary,
          );
    return Container(
      key: ValueKey<Object>(('hermes-tool-entry', key)),
      decoration: state.open
          ? BoxDecoration(
              border: Border.all(color: theme.borderMessage),
              borderRadius: BorderRadius.circular(9),
            )
          : null,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.symmetric(horizontal: state.open ? 8 : 0),
            child: _Disclosure(
              title: content.title(pending: pending, unfinished: unfinished),
              leading: icon,
              pending: pending,
              expanded: state.open,
              height: 32,
              metadata: _starts[key] == null
                  ? null
                  : _Elapsed(
                      start: _starts[key]!,
                      end: _ends[key],
                      running: pending,
                    ),
              onTap: () => _change(() => state.open = !state.open),
            ),
          ),
          if (state.open)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (content.command case final command?)
                    _CodePreview(text: command, maxLines: 4),
                  if (content.description case final description?)
                    Padding(
                      padding: const EdgeInsets.only(top: 4, bottom: 8),
                      child: Text(
                        description,
                        style: AppTypography.bodySmallStyle.copyWith(
                          color: theme.textSecondary,
                        ),
                      ),
                    ),
                  if (content.output case final output?)
                    _CodePreview(text: output, maxLines: 4),
                  if (content.failed && content.error != null)
                    Text(
                      content.error!,
                      style: AppTypography.bodySmallStyle.copyWith(
                        color: theme.error,
                      ),
                    ),
                  _Disclosure(
                    key: ValueKey<Object>(('hermes-tool-payload-toggle', key)),
                    title: 'Tool payload',
                    expanded: state.payload,
                    height: 32,
                    onTap: () => _change(() => state.payload = !state.payload),
                  ),
                  if (state.payload)
                    _PayloadBox(
                      key: ValueKey<Object>(('hermes-tool-payload', key)),
                      text: content.payload,
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  String _groupTitle(List<(_EntryKey, ChatStatusUpdate, _ToolContent)> tools) {
    final commands = tools
        .where(
          (e) =>
              e.$3.summary.kind == HermesToolKind.terminal ||
              e.$3.summary.kind == HermesToolKind.code,
        )
        .toList();
    final skills = tools
        .where((e) => e.$3.summary.kind == HermesToolKind.skill)
        .toList();
    final otherTools = tools
        .where((entry) => !commands.contains(entry) && !skills.contains(entry))
        .toList();
    final other = otherTools.length;
    String label(
      List<(_EntryKey, ChatStatusUpdate, _ToolContent)> group,
      String noun,
      String active,
      String complete,
    ) {
      if (group.any(
        (e) => e.$3.failed || (!widget.isStreaming && e.$2.done != true),
      )) {
        return '${group.length} $noun${group.length == 1 ? '' : 's'}';
      }
      final pending = group.any((e) => _pending(e.$2));
      return '${pending ? active : complete} ${group.length} $noun${group.length == 1 ? '' : 's'}';
    }

    final failed = tools.where((e) => e.$3.failed).length;
    final unfinished = tools
        .where((e) => !widget.isStreaming && e.$2.done != true)
        .length;
    return [
      if (skills.isNotEmpty) label(skills, 'skill', 'Loading', 'Loaded'),
      if (commands.isNotEmpty) label(commands, 'command', 'Running', 'Ran'),
      if (other > 0) label(otherTools, 'tool', 'Using', 'Used'),
      if (failed > 0) '$failed failed',
      if (unfinished > 0) '$unfinished unfinished',
    ].join(' · ');
  }
}

class _ToolContent {
  _ToolContent(this.update) : summary = HermesToolSummary.fromUpdate(update) {
    for (final item in update.items) {
      if (item.presentation != ChatStatusItemPresentation.detail) continue;
      final raw = item.snippet?.trim();
      if (raw == null || raw.isEmpty) continue;
      details.add('${item.title ?? 'Details'}:\n$raw');
      Object? decoded;
      try {
        decoded = jsonDecode(raw);
      } on FormatException {
        decoded = raw;
      }
      if (item.title?.toLowerCase() == 'arguments' && decoded is Map) {
        final value = decoded['command'] ?? decoded['cmd'] ?? decoded['code'];
        if (value is String && value.isNotEmpty) command = value;
      } else if (item.title?.toLowerCase() == 'result') {
        if (decoded is Map) {
          final value = decoded['output'] ?? decoded['stdout'];
          if (value is String && value.isNotEmpty) output = value;
          final info = decoded['description'];
          if (summary.kind == HermesToolKind.skill &&
              info is String &&
              info.isNotEmpty) {
            description = info;
          }
          final failure = decoded['error'];
          final exitCode = decoded['exit_code'];
          if (decoded['success'] == false ||
              (exitCode is num && exitCode != 0) ||
              (failure != null &&
                  failure != false &&
                  failure.toString().trim().isNotEmpty)) {
            failed = true;
            error = failure?.toString() ?? 'Command exited with code $exitCode';
          }
        } else if (summary.kind != HermesToolKind.skill) {
          output = raw;
        }
      } else if (item.title?.toLowerCase() == 'error') {
        failed = true;
        error = raw;
      }
    }
    failed = failed || summary.failed;
  }
  final ChatStatusUpdate update;
  final HermesToolSummary summary;
  final details = <String>[];
  String? command;
  String? output;
  String? description;
  String? error;
  bool failed = false;
  String get payload => details.isEmpty
      ? update.description ?? summary.title
      : details.join('\n\n');

  String title({required bool pending, bool unfinished = false}) {
    final name = summary.preview;
    if (failed) return '${summary.title} · Failed';
    if (unfinished) return '${summary.title} · Unfinished';
    return switch (summary.kind) {
      HermesToolKind.skill =>
        name == null
            ? summary.title
            : '${pending ? 'Loading skill' : 'Loaded skill'}: $name',
      HermesToolKind.terminal => pending ? 'Running command' : 'Ran command',
      HermesToolKind.code => pending ? 'Running code' : 'Ran code',
      _ => summary.title,
    };
  }
}

IconData _toolIcon(HermesToolKind kind) => switch (kind) {
  HermesToolKind.terminal => Icons.terminal,
  HermesToolKind.code => Icons.code,
  HermesToolKind.search => Icons.search,
  HermesToolKind.web => Icons.public,
  HermesToolKind.read => Icons.description_outlined,
  HermesToolKind.write => Icons.edit_note,
  HermesToolKind.image => Icons.image_outlined,
  _ => Icons.settings_outlined,
};

class _Disclosure extends StatelessWidget {
  const _Disclosure({
    super.key,
    required this.title,
    this.pending = false,
    required this.expanded,
    required this.height,
    this.onTap,
    this.leading,
    this.metadata,
  });
  final String title;
  final bool pending;
  final bool expanded;
  final double height;
  final VoidCallback? onTap;
  final Widget? leading;
  final Widget? metadata;

  @override
  Widget build(BuildContext context) => Semantics(
    button: onTap != null,
    expanded: onTap == null ? null : expanded,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: height),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (leading != null) ...[leading!, const SizedBox(width: 6)],
            Flexible(
              child: AssistantDetailHeader(
                title: title,
                compact: true,
                showShimmer: pending,
                showChevron: onTap != null,
                useInlineChevron: true,
                isExpanded: expanded,
              ),
            ),
            if (metadata != null) ...[const SizedBox(width: 6), metadata!],
          ],
        ),
      ),
    ),
  );
}

class _ToolTicker extends StatelessWidget {
  const _ToolTicker({required this.entry});
  final (_EntryKey, ChatStatusUpdate, _ToolContent) entry;
  @override
  Widget build(BuildContext context) => ClipRect(
    child: AnimatedSwitcher(
      duration: context.motionDuration(AnimationDuration.assistantToolTicker),
      switchInCurve: AnimationCurves.assistantToolTicker,
      switchOutCurve: AnimationCurves.assistantToolTicker,
      layoutBuilder: (current, previous) => Stack(
        alignment: Alignment.topLeft,
        children: [...previous, ?current],
      ),
      transitionBuilder: (child, animation) => SlideTransition(
        position: Tween(
          begin: child.key == ValueKey(entry.$1)
              ? const Offset(0, 1)
              : const Offset(0, -1),
          end: Offset.zero,
        ).animate(animation),
        child: child,
      ),
      child: SizedBox(
        key: ValueKey(entry.$1),
        height: 24,
        child: _Disclosure(
          title: entry.$3.title(pending: true),
          pending: true,
          expanded: false,
          height: 24,
          leading: const HermesBreatheIndicator(),
        ),
      ),
    ),
  );
}

class _CodePreview extends StatelessWidget {
  const _CodePreview({required this.text, required this.maxLines});
  final String text;
  final int maxLines;
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    margin: const EdgeInsets.only(top: 4),
    padding: const EdgeInsets.all(8),
    decoration: BoxDecoration(
      color: context.conduitTheme.codeBackground,
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      text,
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
      style: AppTypography.codeStyle.copyWith(
        fontSize: 12,
        color: context.conduitTheme.codeText,
      ),
    ),
  );
}

class _PayloadBox extends StatelessWidget {
  const _PayloadBox({super.key, required this.text});
  final String text;
  @override
  Widget build(BuildContext context) => Stack(
    children: [
      Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(12, 12, 52, 12),
        decoration: BoxDecoration(
          color: context.conduitTheme.codeBackground,
          borderRadius: BorderRadius.circular(6),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 160),
          child: SingleChildScrollView(
            child: SelectableText(
              text,
              style: AppTypography.codeStyle.copyWith(
                fontSize: 12,
                color: context.conduitTheme.codeText,
              ),
            ),
          ),
        ),
      ),
      Positioned(top: 0, right: 0, child: _CopyPayload(text: text)),
    ],
  );
}

class _CopyPayload extends StatefulWidget {
  const _CopyPayload({required this.text});
  final String text;
  @override
  State<_CopyPayload> createState() => _CopyPayloadState();
}

class _CopyPayloadState extends State<_CopyPayload> {
  bool _copied = false;
  Timer? _reset;
  @override
  void didUpdateWidget(covariant _CopyPayload oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      _reset?.cancel();
      _copied = false;
    }
  }

  @override
  void dispose() {
    _reset?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return IconButton(
      constraints: const BoxConstraints.tightFor(width: 48, height: 48),
      padding: EdgeInsets.zero,
      tooltip: _copied ? l10n.copiedToClipboard : l10n.copy,
      color: context.conduitTheme.textSecondary,
      icon: Icon(_copied ? Icons.check : Icons.content_copy, size: 16),
      onPressed: () async {
        final text = widget.text;
        await Clipboard.setData(ClipboardData(text: text));
        if (!mounted || text != widget.text) return;
        _reset?.cancel();
        setState(() => _copied = true);
        _reset = Timer(const Duration(milliseconds: 1200), () {
          if (mounted) setState(() => _copied = false);
        });
      },
    );
  }
}

/// The desktop breathe mark repaints its own 14px slot; it never rebuilds the
/// message or changes its extent. Background and hidden rows stop the clock.
class HermesBreatheIndicator extends StatefulWidget {
  const HermesBreatheIndicator({super.key});
  @override
  State<HermesBreatheIndicator> createState() => _HermesBreatheIndicatorState();
}

class _HermesBreatheIndicatorState extends State<HermesBreatheIndicator>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _clock;
  bool _foreground = true;
  bool _tickers = true;
  bool _reduce = false;
  @override
  void initState() {
    super.initState();
    _clock = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1700),
    );
    WidgetsBinding.instance.addObserver(this);
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.inactive;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduce = context.reduceMotion;
    _tickers = TickerMode.valuesOf(context).enabled;
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground =
        state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
    _sync();
  }

  void _sync() {
    if (!_reduce && _tickers && _foreground) {
      if (!_clock.isAnimating) _clock.repeat();
    } else {
      _clock.stop();
      if (_reduce) _clock.value = 8 / 17;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: SizedBox(
      width: 14,
      height: 18,
      child: CustomPaint(
        painter: _BreathePainter(_clock, context.conduitTheme.textSecondary),
      ),
    ),
  );
}

class _BreathePainter extends CustomPainter {
  _BreathePainter(this.progress, this.color) : super(repaint: progress);
  final Animation<double> progress;
  final Color color;
  static const frames = [
    0,
    2,
    12,
    81,
    149,
    157,
    235,
    223,
    255,
    223,
    235,
    157,
    149,
    81,
    12,
    2,
    0,
  ];
  static const bits = [
    [1, 8],
    [2, 16],
    [4, 32],
    [64, 128],
  ];
  @override
  void paint(Canvas canvas, Size size) {
    final frame = frames[(progress.value * 17).floor().clamp(0, 16)];
    final paint = Paint()..color = color;
    for (var row = 0; row < 4; row++) {
      for (var col = 0; col < 2; col++) {
        if (frame & bits[row][col] != 0) {
          canvas.drawCircle(
            Offset(
              size.width / 2 + (col - .5) * 3,
              size.height / 2 + (row - 1.5) * 3,
            ),
            .85,
            paint,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(_BreathePainter old) =>
      old.color != color || old.progress != progress;
}

class _Elapsed extends StatefulWidget {
  const _Elapsed({
    required this.start,
    required this.end,
    required this.running,
  });
  final DateTime start;
  final DateTime? end;
  final bool running;
  @override
  State<_Elapsed> createState() => _ElapsedState();
}

class _ElapsedState extends State<_Elapsed> with WidgetsBindingObserver {
  Timer? _timer;
  bool _foreground = true;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(covariant _Elapsed oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground =
        state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
    _sync();
  }

  void _sync() {
    _timer?.cancel();
    if (widget.running && _foreground && TickerMode.valuesOf(context).enabled) {
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Text(
    '${math.max(0, (widget.end ?? clock.now()).difference(widget.start).inSeconds)} s',
    style: AppTypography.captionStyle.copyWith(
      fontSize: 11,
      color: context.conduitTheme.textSecondary,
    ),
  );
}

/// State changes start outside layout. A closing group loses input/semantics
/// immediately, while its last displayed child can finish the reverse motion.
class _ActivityGroupExpansion extends StatefulWidget {
  const _ActivityGroupExpansion({required this.expanded, required this.child});
  final bool expanded;
  final Widget child;
  @override
  State<_ActivityGroupExpansion> createState() =>
      _ActivityGroupExpansionState();
}

class _ActivityGroupExpansionState extends State<_ActivityGroupExpansion>
    with SingleTickerProviderStateMixin {
  late final AnimationController _clock;
  late final Animation<double> _extent;
  Widget? _displayed;
  bool _reduce = false;
  @override
  void initState() {
    super.initState();
    _displayed = widget.expanded ? widget.child : null;
    _clock = AnimationController(
      vsync: this,
      duration: AnimationDuration.assistantToolGroup,
      value: widget.expanded ? 1 : 0,
    );
    _extent = CurvedAnimation(parent: _clock, curve: Curves.easeInOut);
    _clock.addStatusListener((status) {
      if (status == AnimationStatus.dismissed &&
          !widget.expanded &&
          _displayed != null &&
          mounted) {
        setState(() => _displayed = null);
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduce = context.reduceMotion;
    if (_reduce) _clock.value = widget.expanded ? 1 : 0;
  }

  @override
  void didUpdateWidget(covariant _ActivityGroupExpansion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.expanded) _displayed = widget.child;
    if (oldWidget.expanded != widget.expanded) {
      if (_reduce) {
        _clock.value = widget.expanded ? 1 : 0;
        if (!widget.expanded) _displayed = null;
      } else if (widget.expanded) {
        _clock.forward();
      } else {
        _clock.reverse();
      }
    }
  }

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ClipRect(
    child: SizeTransition(
      sizeFactor: _extent,
      alignment: AlignmentDirectional.topStart,
      child: IgnorePointer(
        ignoring: !widget.expanded,
        child: ExcludeSemantics(
          excluding: !widget.expanded,
          child: TickerMode(
            enabled: widget.expanded,
            child:
                _displayed ?? const SizedBox(width: double.infinity, height: 0),
          ),
        ),
      ),
    ),
  );
}
