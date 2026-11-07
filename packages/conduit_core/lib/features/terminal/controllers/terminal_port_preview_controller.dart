import 'dart:async';

import '../services/terminal_port_preview.dart';
import 'terminal_change_notifier.dart';

/// The state behind a port preview page, apart from the web view itself.
///
/// It opens the browser session the preview prefers, falls back to the
/// port proxy when the terminal cannot open one, closes the session when
/// the page goes away, and tracks the address and title the page shows.
final class TerminalPortPreviewController with TerminalChangeNotifier {
  TerminalPortPreviewController(this.preview);

  final TerminalPortPreview preview;

  TerminalPreviewNavigator? _navigator;
  TerminalBrowserSession? _session;
  Uri? _address;
  String _title = '';
  Uri? _reissued;
  bool _started = false;
  bool _disposed = false;

  /// How pages load: null while the session is being opened.
  TerminalPreviewNavigator? get navigator => _navigator;

  /// The address on the terminal's machine the page shows.
  Uri get address => _address ?? preview.startUri;

  /// The page's title, or empty while it has none.
  String get title => _title;

  /// The page to load first, with what to send with it.
  ({Uri uri, Map<String, String> headers})? get initialRequest {
    final navigator = _navigator;
    if (navigator == null) return null;
    final uri = navigator.pageUri(preview.startUri);
    return (uri: uri, headers: navigator.headers);
  }

  /// The page as it can be opened outside the app, or null when it needs a
  /// credential the app does not hand out.
  Uri? get externalUri {
    final navigator = _navigator;
    if (navigator == null || !navigator.pagesOpenElsewhere) return null;
    return navigator.pageUri(address);
  }

  /// Opens the browser session, or settles on the port proxy.
  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
    final open = preview.openSession;
    if (open != null) {
      try {
        final session = await open();
        if (_disposed) {
          _close(session);
          return;
        }
        _session = session;
        _navigator = preview.sessionNavigator(session);
      } catch (_) {
        // An older terminal, one without browser support, or a refusal:
        // the proxy still shows the port.
        if (_disposed) return;
      }
    }
    _navigator ??= preview.proxyNavigator();
    _expectLoad(_navigator!.pageUri(preview.startUri));
    notifyListeners();
  }

  /// What to do with a navigation of the main frame to [target]. [history]
  /// for back, forward and reload, which load as they are.
  TerminalPreviewDecision decide(Uri target, {bool history = false}) {
    final navigator = _navigator;
    if (navigator == null) return const TerminalPreviewBlock();
    final reissued = _reissued != null && target == _reissued;
    _reissued = null;
    final decision = navigator.decide(
      target,
      history: history,
      reissued: reissued,
    );
    if (decision is TerminalPreviewLoad) _expectLoad(decision.uri);
    return decision;
  }

  /// Checks a page the main frame started to load. Android loads a form
  /// post without asking [decide] first, so a post can take the preview to
  /// a page it does not show, under the address it showed before. Null
  /// when the preview may show [page]. Otherwise the load is to be stopped
  /// for the decision returned: a page on the terminal's machine loads
  /// through the preview instead; any other returns to [address], and a
  /// page outside the terminal is offered outside the app.
  TerminalPreviewDecision? checkStartedLoad(Uri? page) {
    final navigator = _navigator;
    if (navigator == null || page == null) return null;
    final decision = navigator.decide(page, history: true);
    if (decision is TerminalPreviewAllow) return null;
    if (decision is TerminalPreviewLoad) _expectLoad(decision.uri);
    return decision;
  }

  /// The load that takes the page back to [address].
  TerminalPreviewLoad? returnToAddress() {
    final navigator = _navigator;
    if (navigator == null) return null;
    final uri = navigator.pageUri(address);
    _expectLoad(uri);
    return TerminalPreviewLoad(uri, navigator.headers);
  }

  /// The web view now shows [page], after a load or a history change.
  void pageChanged(Uri? page) {
    final navigator = _navigator;
    if (navigator == null || page == null) return;
    final remote = navigator.remoteUri(page);
    if (remote == null || remote == _address) return;
    _address = remote;
    notifyListeners();
  }

  /// The page finished loading: a load the app made has arrived, so a
  /// later navigation to the same address is the page's own again.
  void pageLoaded(Uri? page) {
    _reissued = null;
    pageChanged(page);
  }

  void titleChanged(String? title) {
    final next = title?.trim() ?? '';
    if (next == _title) return;
    _title = next;
    notifyListeners();
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final session = _session;
    _session = null;
    if (session != null) _close(session);
    super.dispose();
  }

  void _expectLoad(Uri uri) => _reissued = uri;

  void _close(TerminalBrowserSession session) {
    final close = preview.closeSession;
    if (close == null) return;
    unawaited(
      Future<void>.sync(() => close(session)).catchError((Object _) {}),
    );
  }
}
