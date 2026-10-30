import 'dart:async';

import '../providers/composer_draft_provider.dart';
import '../widgets/mention_text_controller.dart';

/// Binds one input to its account/chat without letting a late read replace an
/// edit, prefill, or another chat's input. Temporary inputs stay in memory.
class ComposerDraftBinding {
  ComposerDraftBinding(this._controller, {required this.onFailure}) {
    _observed = _controller.snapshotDraft();
    _controller.addListener(_changed);
  }

  final MentionTextEditingController _controller;
  final void Function(bool loading, void Function() retry) onFailure;
  final _memory = <ComposerDraftKey, String>{};
  ComposerDraftContext? _context;
  ComposerDraftContext? _requested;
  String _observed = '';
  String? _queued;
  int _version = 0;
  int _revision = 0;
  bool _restoring = false;
  bool _scheduled = false;
  bool _disposed = false;
  bool _loading = false;
  bool _loadFailed = false;
  bool _edited = false;
  bool _failureShown = false;

  void _changed() {
    if (_disposed || _restoring) return;
    final snapshot = _controller.snapshotDraft();
    if (snapshot != _observed) {
      _observed = snapshot;
      _revision++;
      _edited = true;
    }
    if (_scheduled) return;
    _scheduled = true;
    // Text, mention registration, and selection may change in one input event.
    scheduleMicrotask(() {
      _scheduled = false;
      if (!_disposed) unawaited(_save());
    });
  }

  bool _current(ComposerDraftContext context, int version) =>
      !_disposed && version == _version && context == _requested;

  bool _restore(String snapshot) {
    _restoring = true;
    try {
      final restored = _controller.restoreDraft(snapshot);
      _observed = _controller.snapshotDraft();
      return restored;
    } finally {
      _restoring = false;
    }
  }

  Future<void> bind(
    ComposerDraftContext next, {
    bool reload = false,
    bool preserveInput = false,
    bool remapped = false,
  }) async {
    _requested = next;
    final version = ++_version;
    // Provider changes can arrive while Flutter is building the input.
    await Future<void>.value();
    if (!_current(next, version)) return;
    final previous = _context;
    final sameKey =
        previous != null &&
        composerDraftKey(previous) == composerDraftKey(next);
    final ready = !_loading && !_loadFailed;
    final edited = _edited;
    final snapshot = _controller.snapshotDraft();
    if (previous != null) {
      unawaited(_save());
      if (sameKey && !previous.temporary && next.temporary) {
        unawaited(_write(previous, ''));
      }
    }
    _context = next;
    _queued = null;
    _loading = false;
    _loadFailed = false;
    _failureShown = false;
    if (remapped &&
        previous != null &&
        previous.owner == next.owner &&
        previous.scope == next.scope &&
        identical(previous.store, next.store)) {
      _loading = true;
      _edited = false;
      final revision = _revision;
      try {
        await next.store?.remap(next.scope, previous.chatId, next.chatId);
        final saved = next.store == null
            ? snapshot
            : await next.store!.read(next.scope, next.chatId);
        if (!_current(next, version)) return;
        _memory.remove(composerDraftKey(previous));
        if (revision == _revision && !edited) {
          if (!_restore(saved ?? '')) {
            throw const FormatException('Invalid local draft');
          }
          _queued = saved ?? '';
        }
      } catch (_) {
        if (_current(next, version)) {
          _loadFailed = true;
          _report(next, loading: true);
        }
      } finally {
        if (_current(next, version)) {
          _loading = false;
          _edited = _edited || edited;
          if (_edited) await _save();
        }
      }
      return;
    }
    // The host supplies an exact send handle when a new comparison receives
    // its stored identity. Keep that input until admission returns.
    if (preserveInput && previous?.owner == next.owner) {
      _edited = edited;
      return;
    }
    final modeChanged = sameKey && previous.temporary != next.temporary;
    if (!reload &&
        ((previous == null && snapshot.isNotEmpty) ||
            (sameKey &&
                (edited ||
                    modeChanged ||
                    (previous.store != null && ready))))) {
      _edited = edited || snapshot.isNotEmpty;
      await _save();
      return;
    }
    _edited = false;
    _restore('');
    _loading = true;
    final revision = _revision;
    final cached = reload ? null : _memory[composerDraftKey(next)];
    try {
      final saved = cached ?? await next.store?.read(next.scope, next.chatId);
      if (!_current(next, version)) return;
      if (revision == _revision) {
        if (!_restore(saved ?? '')) {
          throw const FormatException('Invalid local draft');
        }
        _queued = cached == null ? saved ?? '' : null;
      }
    } catch (_) {
      if (_current(next, version)) {
        _loadFailed = true;
        _report(next, loading: true);
      }
    } finally {
      if (_current(next, version)) {
        _loading = false;
        if (_edited || (cached != null && !_loadFailed)) {
          await _save();
        }
      }
    }
  }

  Future<void> _save() async {
    final context = _context;
    if (_disposed ||
        context == null ||
        _restoring ||
        ((_loading || _loadFailed) && !_edited)) {
      return;
    }
    final snapshot = _controller.snapshotDraft();
    if (snapshot == _queued) return;
    _memory[composerDraftKey(context)] = snapshot;
    _queued = snapshot;
    if (context.store != null) await _write(context, snapshot);
  }

  Future<void> _write(ComposerDraftContext context, String snapshot) async {
    try {
      await context.store?.save(context.scope, context.chatId, snapshot);
      if (context == _context) _failureShown = false;
    } catch (_) {
      if (!_disposed && context == _context && context == _requested) {
        _queued = null;
        _report(context, loading: false);
      }
    }
  }

  void _report(ComposerDraftContext context, {required bool loading}) {
    if (_failureShown) return;
    _failureShown = true;
    onFailure(loading, () {
      if (_disposed || context != _context || context != _requested) return;
      _failureShown = false;
      if (loading && !_edited) {
        unawaited(bind(context, reload: true));
      } else {
        unawaited(_save());
      }
    });
  }

  /// A late dictation result belongs to the input that started it. Keep a
  /// newer edit, and never insert an older chat's words into the visible chat.
  Future<bool> applyDictation(
    ComposerDraftContext origin,
    String expectedSnapshot,
    String nextSnapshot,
  ) async {
    // Let a pending provider bind finish its outgoing input snapshot first.
    await Future<void>.value();
    if (_disposed) return false;
    final key = composerDraftKey(origin);
    final current = _context;
    var sameChat = current != null && composerDraftKey(current) == key;
    if (!sameChat &&
        current != null &&
        current.owner == origin.owner &&
        current.scope == origin.scope &&
        identical(current.store, origin.store) &&
        origin.store != null &&
        !origin.temporary &&
        !current.temporary) {
      sameChat =
          await origin.store!.resolveChatId(origin.scope, origin.chatId) ==
          current.chatId;
    }
    if (current != null && current == _context && sameChat) {
      if (current.temporary != origin.temporary) return false;
      if (_requested == current) {
        if (_controller.snapshotDraft() != expectedSnapshot) return false;
        if (!_restore(nextSnapshot)) return false;
        _revision++;
        _edited = true;
        _memory[key] = nextSnapshot;
        await _save();
        return true;
      }
    }
    if ((_memory[key] ?? expectedSnapshot) != expectedSnapshot) return false;
    _memory[key] = nextSnapshot;
    if (!origin.temporary) await _write(origin, nextSnapshot);
    return true;
  }

  Future<void> markSent(
    ComposerDraftContext origin,
    String sentSnapshot,
  ) async {
    if (_disposed) return;
    if (_context != null &&
        composerDraftKey(_context!) == composerDraftKey(origin)) {
      await _save();
    }
    final key = composerDraftKey(origin);
    if (_memory[key] != sentSnapshot) return;
    _memory[key] = '';
    await _write(origin, '');
  }

  Future<void> flush() async {
    if (_disposed) return;
    final context = _context;
    await _save();
    await context?.store?.flush();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    final write = flush();
    _disposed = true;
    _version++;
    _controller.removeListener(_changed);
    await write;
    _memory.clear();
  }
}
