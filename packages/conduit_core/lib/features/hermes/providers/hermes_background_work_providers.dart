import 'dart:async';

import 'package:clock/clock.dart' show clock;
import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/features/hermes/models/hermes_background_work.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/providers/hermes_todo_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/ports/app_lifecycle.dart';
import 'package:conduit_core/providers/host_ports.dart';

/// How often running work is listed again while its chat is open.
const Duration kHermesBackgroundWorkPollInterval = Duration(seconds: 4);

/// How long after a subagent or process event the lists are polled, even
/// before anything shows as running.
const Duration kHermesBackgroundWorkHintWindow = Duration(seconds: 20);

/// How often an open subagent's output is read again.
const Duration kHermesSubagentTailPollInterval = Duration(seconds: 2);

/// Events arriving together are listed once.
const Duration _kHintDebounce = Duration(milliseconds: 300);

/// Failed reads in a row after which retries back off, each wait twice the
/// last, up to [kHermesBackgroundWorkMaxRetryInterval].
const int _kMaxFailures = 3;

/// The longest wait between reads that keep failing: a service that
/// recovers is read again within it, though no event says so.
const Duration kHermesBackgroundWorkMaxRetryInterval = Duration(minutes: 1);

/// The wait before the read after [failures] failed ones in a row: every
/// [interval] at first, then doubling up to the cap.
Duration _retryDelay(Duration interval, int failures) {
  if (failures < _kMaxFailures) return interval;
  final delay = interval * (1 << (failures - _kMaxFailures + 1).clamp(1, 8));
  return delay < kHermesBackgroundWorkMaxRetryInterval
      ? delay
      : kHermesBackgroundWorkMaxRetryInterval;
}

/// Reads made while the chat is not attached yet, before giving up.
const int _kMaxUnattachedReads = 5;

/// The Hermes session the open chat continues: a Hermes chat's own, or the
/// one this app bound a Hermes turn inside an OpenWebUI chat to, resolved as
/// for its plan.
final _openHermesSessionProvider = Provider.autoDispose<String?>(
  (ref) => ref.watch(hermesOpenChatSessionProvider),
);

/// The open chat's subagents and background processes, while it is on
/// screen: only a Desktop Gateway reports them. Null when the chat is not
/// a Desktop Gateway chat or nothing was read yet.
///
/// Lists once when the chat opens and whenever a subagent or process event
/// arrives, then again every [kHermesBackgroundWorkPollInterval] while
/// anything runs (or shortly after such an event). Never in the background.
/// Reads that fail are tried again while the chat is open, less often the
/// longer they keep failing.
final hermesBackgroundWorkProvider =
    NotifierProvider.autoDispose<
      HermesBackgroundWorkController,
      HermesBackgroundWork?
    >(HermesBackgroundWorkController.new);

class HermesBackgroundWorkController extends Notifier<HermesBackgroundWork?> {
  HermesDesktopApiService? _service;
  String? _storedId;
  Timer? _timer;
  DateTime? _hintUntil;
  bool _refreshing = false;
  bool _refreshAgain = false;
  bool _paused = false;
  int _failures = 0;
  int _unattachedReads = 0;
  int _generation = 0;

  @override
  HermesBackgroundWork? build() {
    final service = ref.watch(hermesApiServiceProvider);
    final storedId = ref.watch(_openHermesSessionProvider);
    final generation = ++_generation;
    _timer?.cancel();
    _timer = null;
    _hintUntil = null;
    _refreshing = false;
    _refreshAgain = false;
    _failures = 0;
    _unattachedReads = 0;
    ref.onDispose(() {
      _timer?.cancel();
      _timer = null;
    });
    if (service is! HermesDesktopApiService || storedId == null) {
      _service = null;
      _storedId = null;
      return null;
    }
    _service = service;
    _storedId = storedId;
    final lifecycle = ref.read(appLifecycleProvider);
    _paused = lifecycle.current?.isBackground ?? false;
    final hints = service.backgroundWorkHints.listen((id) {
      if (generation == _generation && service.isSameChat(storedId, id)) {
        _hint();
      }
    });
    final phases = lifecycle.changes.listen((phase) {
      if (generation != _generation) return;
      final paused = phase.isBackground;
      if (paused == _paused) return;
      _paused = paused;
      if (paused) {
        _timer?.cancel();
        _timer = null;
      } else {
        _failures = 0;
        _unattachedReads = 0;
        _schedule(Duration.zero);
      }
    });
    // The chat attaching (a send or a resume reattaches it) or its turn
    // starting or ending: list again if polling had stopped, as it does
    // after reads that found the chat not attached yet, or slowed down
    // after reads that failed.
    final turns = service.turnStatesFor(storedId).listen((_) {
      if (generation != _generation || _refreshing) return;
      if (_timer != null && _failures < _kMaxFailures) return;
      _failures = 0;
      _unattachedReads = 0;
      _schedule(_kHintDebounce);
    });
    ref.onDispose(hints.cancel);
    ref.onDispose(phases.cancel);
    ref.onDispose(turns.cancel);
    _schedule(Duration.zero);
    return null;
  }

  /// A subagent or process event: list now, and keep listing for a while.
  /// A read already due sooner is kept: events arriving faster than the
  /// debounce must not push every read back, the regular poll's included.
  void _hint() {
    _hintUntil = clock.now().add(kHermesBackgroundWorkHintWindow);
    _failures = 0;
    _unattachedReads = 0;
    final due = _due;
    if (_timer != null &&
        due != null &&
        !due.isAfter(clock.now().add(_kHintDebounce))) {
      return;
    }
    _schedule(_kHintDebounce);
  }

  /// When the read [_timer] waits for is due.
  DateTime? _due;

  void _schedule(Duration delay) {
    _timer?.cancel();
    _timer = null;
    if (_paused || _service == null) return;
    final generation = _generation;
    _due = clock.now().add(delay);
    _timer = Timer(delay, () {
      _timer = null;
      if (generation == _generation) unawaited(_refresh(generation));
    });
  }

  /// Lists the work again now.
  Future<void> refresh() => _refresh(_generation);

  Future<void> _refresh(int generation) async {
    final service = _service;
    final storedId = _storedId;
    if (service == null || storedId == null || _paused) return;
    if (_refreshing) {
      _refreshAgain = true;
      return;
    }
    _refreshing = true;
    bool stale() => generation != _generation || !ref.mounted;
    try {
      final work = await service.backgroundWorkFor(storedId);
      if (stale()) return;
      _failures = 0;
      if (work == null) {
        // Opening the chat attaches it; read again once it has.
        if (++_unattachedReads <= _kMaxUnattachedReads) {
          _schedule(kHermesBackgroundWorkPollInterval);
        }
        return;
      }
      _unattachedReads = 0;
      state = work;
      final hinted = _hintUntil?.isAfter(clock.now()) ?? false;
      if (work.active || hinted) {
        _schedule(kHermesBackgroundWorkPollInterval);
      }
    } catch (_) {
      if (stale()) return;
      // Keeps the last list and tries again while the chat is open, less
      // often the longer reads keep failing; an event tries sooner.
      _schedule(_retryDelay(kHermesBackgroundWorkPollInterval, ++_failures));
    } finally {
      if (!stale()) {
        _refreshing = false;
        if (_refreshAgain) {
          _refreshAgain = false;
          _schedule(Duration.zero);
        }
      }
    }
  }

  HermesDesktopApiService get _requireService =>
      _service ?? (throw StateError('No Hermes Desktop Gateway chat is open.'));
  String get _requireStoredId =>
      _storedId ?? (throw StateError('No Hermes chat is open.'));

  /// Sends [text] to [subagentId]; true when Hermes queued it.
  Future<bool> steer(String subagentId, String text) =>
      _requireService.steerSubagent(_requireStoredId, subagentId, text);

  /// Stops [subagentId]; false when it had already finished.
  Future<bool> stop(String subagentId) async {
    final found = await _requireService.stopSubagent(
      _requireStoredId,
      subagentId,
    );
    if (ref.mounted) _hint();
    return found;
  }

  /// Kills the background process [processId].
  Future<HermesProcessKillResult> kill(String processId) async {
    final result = await _requireService.killBackgroundProcess(
      _requireStoredId,
      processId,
    );
    if (ref.mounted) _hint();
    return result;
  }
}

/// A subagent of the open chat, for [hermesSubagentTailProvider].
typedef HermesSubagentRef = ({String storedId, String subagentId});

/// The open chat's Hermes session id, for a [HermesSubagentRef].
final hermesOpenSessionIdProvider = Provider.autoDispose<String?>(
  (ref) => ref.watch(_openHermesSessionProvider),
);

/// What is known of a subagent's live output.
final class HermesSubagentTailView {
  const HermesSubagentTailView({this.tail, this.failed = false});

  /// The latest output read; null until the first read answers. Kept once
  /// the subagent finishes and its transcript is gone.
  final HermesSubagentTail? tail;

  /// Whether reading it failed, with no output to show.
  final bool failed;
}

/// A subagent's live output, read every [kHermesSubagentTailPollInterval]
/// while shown, and never in the background.
final hermesSubagentTailProvider = NotifierProvider.autoDispose
    .family<
      HermesSubagentTailController,
      HermesSubagentTailView,
      HermesSubagentRef
    >(HermesSubagentTailController.new);

class HermesSubagentTailController extends Notifier<HermesSubagentTailView> {
  HermesSubagentTailController(this.subagent);

  final HermesSubagentRef subagent;
  Timer? _timer;
  bool _paused = false;
  bool _finished = false;
  int _failures = 0;
  int _generation = 0;

  /// The newest read started: an older one answering late is stale.
  int _reads = 0;

  @override
  HermesSubagentTailView build() {
    final service = ref.watch(hermesApiServiceProvider);
    final generation = ++_generation;
    _timer?.cancel();
    _timer = null;
    _failures = 0;
    _finished = false;
    ref.onDispose(() {
      _timer?.cancel();
      _timer = null;
    });
    if (service is! HermesDesktopApiService) {
      return const HermesSubagentTailView(failed: true);
    }
    final lifecycle = ref.read(appLifecycleProvider);
    _paused = lifecycle.current?.isBackground ?? false;
    final phases = lifecycle.changes.listen((phase) {
      if (generation != _generation) return;
      _paused = phase.isBackground;
      _timer?.cancel();
      _timer = null;
      if (!_paused) _schedule(service, generation, Duration.zero);
    });
    ref.onDispose(phases.cancel);
    // Once the chat's list no longer runs it, read a last time and stop;
    // that includes one already finished when its output is opened.
    ref.listen(hermesBackgroundWorkProvider, (_, work) {
      if (generation != _generation || work == null || _finished) return;
      if (work.subagent(subagent.subagentId)?.running ?? false) return;
      _finished = true;
      _schedule(service, generation, Duration.zero);
    }, fireImmediately: true);
    _schedule(service, generation, Duration.zero);
    return const HermesSubagentTailView();
  }

  void _schedule(
    HermesDesktopApiService service,
    int generation,
    Duration delay,
  ) {
    _timer?.cancel();
    _timer = null;
    if (_paused) return;
    _timer = Timer(delay, () {
      _timer = null;
      if (generation == _generation) unawaited(_read(service, generation));
    });
  }

  Future<void> _read(HermesDesktopApiService service, int generation) async {
    // A read a resume or the finish started while another was waiting:
    // only the newest one's answer counts, and it schedules the next.
    final read = ++_reads;
    bool stale() =>
        generation != _generation || !ref.mounted || read != _reads;
    final finished = _finished;
    try {
      final tail = await service.subagentTail(
        subagent.storedId,
        subagent.subagentId,
      );
      if (stale()) return;
      _failures = 0;
      final kept = state.tail;
      // Null while the chat is not attached: keep what was read. A
      // finished child's transcript is cleaned up: keep what was read.
      if (tail != null &&
          (tail.available || kept == null || !kept.available)) {
        state = HermesSubagentTailView(tail: tail);
      }
    } catch (_) {
      if (stale()) return;
      if (++_failures >= _kMaxFailures) {
        if (state.tail == null) {
          state = const HermesSubagentTailView(failed: true);
        }
        // A finished child's last read has had its tries.
        if (_finished) return;
      }
      // Tried again, less often the longer reads keep failing: a running
      // child's output would otherwise stay stale once the service
      // recovers, and a finished child's would wait for an answer no read
      // is asking for.
      _schedule(
        service,
        generation,
        _retryDelay(kHermesSubagentTailPollInterval, _failures),
      );
      return;
    }
    if (!finished) {
      _schedule(service, generation, kHermesSubagentTailPollInterval);
    }
  }
}
