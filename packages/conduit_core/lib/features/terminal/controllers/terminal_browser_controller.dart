import 'dart:async';

import 'package:meta/meta.dart';

import 'package:conduit_core/utils/debug_logger.dart';

import '../models/terminal_models.dart';
import '../services/terminal_port_preview.dart';
import '../services/terminal_service.dart';
import 'terminal_change_notifier.dart';
import 'terminal_controller_gateways.dart';
import 'terminal_events_watcher.dart';
import 'terminal_session_controller.dart';

enum TerminalBrowserFailure {
  loadFiles,
  loadPorts,
  download,
  rename,
  delete,
  upload,
  createFolder,
  openPort,
}

@immutable
final class TerminalBrowserOperationContext {
  const TerminalBrowserOperationContext({
    required this.service,
    required this.server,
    required this.sessionScopeId,
    required this.currentPath,
  });

  final TerminalService service;
  final TerminalServerInfo server;
  final String sessionScopeId;
  final String currentPath;
}

/// Coordinates terminal file-browser queries and mutations.
///
/// The controller keeps network and filesystem work out of the tab widget and
/// rejects results that no longer belong to the selected terminal context.
class TerminalBrowserController with TerminalChangeNotifier {
  TerminalBrowserController({
    required TerminalBrowserGateway gateway,
    required TerminalBrowserPlatformGateway platformGateway,
    required TerminalContextValidator isCurrentContext,
    required void Function(TerminalBrowserFailure failure) onFailure,
  }) : _gateway = gateway,
       _platformGateway = platformGateway,
       _isCurrentContext = isCurrentContext,
       _onFailure = onFailure;

  final TerminalBrowserGateway _gateway;
  final TerminalBrowserPlatformGateway _platformGateway;
  final TerminalContextValidator _isCurrentContext;
  final void Function(TerminalBrowserFailure failure) _onFailure;

  bool _loadingFiles = false;
  int _directoryLoadGeneration = 0;
  int _loadSequence = 0;
  int _loadingSequence = 0;
  int _publishedSequence = 0;
  String? _publishedPath;
  bool _loadingPorts = false;
  bool _disposed = false;
  ({String selectionId, String sessionScopeId, TerminalServerFeatures value})?
  _features;
  TerminalEventsWatcher? _fileEvents;
  TerminalEventsWatcher? _portEvents;

  /// Counts port lists the server pushed, so a fetch that started before one
  /// does not replace it with what it read earlier.
  int _pushedPorts = 0;

  /// Each start of the live updates is a run of its own, so a listing an
  /// earlier run left waiting, as for the terminal the user left, does not
  /// hold up the changes the next one reports.
  int _liveRun = 0;
  int? _liveRefreshRun;
  bool _liveRefreshPending = false;

  bool get loadingFiles => _loadingFiles;

  bool get loadingPorts => _loadingPorts;

  /// Whether a socket keeps the files or the ports current, rather than only
  /// the refreshes the user and the app ask for.
  bool get liveUpdates =>
      (_fileEvents?.active ?? false) || (_portEvents?.active ?? false);

  TerminalBrowserOperationContext? captureOperationContext() {
    if (_disposed) return null;
    final service = _gateway.service;
    final server = _selectedServer;
    if (service == null || server == null || !_isCurrentServer(server)) {
      return null;
    }
    return TerminalBrowserOperationContext(
      service: service,
      server: server,
      sessionScopeId: _gateway.sessionScopeId,
      currentPath: _gateway.currentPath,
    );
  }

  Future<void> reload() async {
    if (_disposed) {
      return;
    }
    final service = _gateway.service;
    final server = _selectedServer;
    if (service == null || server == null || !_isCurrentServer(server)) {
      return;
    }

    final currentPath = _gateway.currentPath;
    await Future.wait([
      loadDirectory(
        service,
        server,
        path: currentPath,
        updateServerCwd: false,
        refresh: true,
      ),
      loadPorts(service, server),
    ]);
  }

  /// Lists [path] and makes it the current directory.
  ///
  /// A navigation supersedes the listings requested before it, so only the
  /// newest can publish. A [refresh] lists the directory that is current
  /// instead. It never supersedes a navigation, and it publishes only while
  /// that directory is still current: a refresh that answers after the context
  /// chose another path must not put the old one back. Two listings of the
  /// same directory, a refresh among them, publish in the order they were
  /// requested, whatever order they answer in.
  ///
  /// A [quiet] listing is one nobody asked for, such as a live update: it
  /// shows no spinner and reports no failure.
  Future<void> loadDirectory(
    TerminalService service,
    TerminalServerInfo server, {
    required String path,
    required bool updateServerCwd,
    bool refresh = false,
    bool quiet = false,
  }) async {
    final sessionScopeId = _gateway.sessionScopeId;
    if (!_isCurrentContext(server, sessionScopeId)) return;
    final normalizedPath = ensureTerminalDirectoryPath(path);
    final sequence = ++_loadSequence;
    final generation = refresh
        ? _directoryLoadGeneration
        : ++_directoryLoadGeneration;
    bool isCurrentLoad() =>
        generation == _directoryLoadGeneration &&
        _isCurrentContext(server, sessionScopeId) &&
        (!refresh || _gateway.currentPath == normalizedPath);

    if (!quiet) {
      _loadingSequence = sequence;
      _setLoadingFiles(true);
    }
    try {
      final entries = await service.listFiles(
        server,
        normalizedPath,
        sessionScopeId: sessionScopeId,
      );
      if (!isCurrentLoad()) {
        return;
      }
      if (_publishedPath == normalizedPath && sequence < _publishedSequence) {
        return;
      }
      _publishedPath = normalizedPath;
      _publishedSequence = sequence;

      _gateway.setCurrentPath(normalizedPath);
      _gateway.setEntries(entries);
      _fileEvents?.watchPath(normalizedPath);

      if (updateServerCwd) {
        // Best effort: the listing already shows, and an older server
        // without the endpoint, or a dropped connection, must not escape.
        unawaited(
          service
              .setCwd(server, normalizedPath, sessionScopeId: sessionScopeId)
              .catchError((Object error, StackTrace stackTrace) {
                DebugLogger.error(
                  'set-cwd-failed',
                  scope: 'terminal/browser',
                  error: error,
                  stackTrace: stackTrace,
                );
              }),
        );
      }
    } catch (_) {
      if (!quiet && isCurrentLoad()) {
        _onFailure(TerminalBrowserFailure.loadFiles);
      }
    } finally {
      // Loading ends with the newest request that showed it, not with
      // whichever answers last.
      if (sequence == _loadingSequence &&
          _isCurrentContext(server, sessionScopeId)) {
        _setLoadingFiles(false);
      }
    }
  }

  /// Records what [server] can do in [sessionScopeId], for live updates and
  /// port previews.
  void setFeatures(
    TerminalServerInfo server,
    String sessionScopeId,
    TerminalServerFeatures features,
  ) {
    _features = (
      selectionId: server.selectionId,
      sessionScopeId: sessionScopeId,
      value: features,
    );
  }

  /// Keeps [server]'s files and ports current through its events socket,
  /// when the terminal and the server relaying it have one. Otherwise the
  /// browser refreshes on demand, as before.
  void startLiveUpdates(TerminalService service, TerminalServerInfo server) {
    stopLiveUpdates();
    final sessionScopeId = _gateway.sessionScopeId;
    if (_disposed || !_isCurrentContext(server, sessionScopeId)) return;
    if (_featuresFor(server, sessionScopeId)?.events != true) return;
    if (server.isSystem && !_gateway.systemTerminalLiveFeatures) return;
    final token = service.authTokenForServer(server);
    // A direct terminal without a key accepts an empty one; Open WebUI
    // always needs the account's.
    if (server.isSystem && token == null) return;

    TerminalEventsWatcher watch({String? path, bool ports = false}) =>
        TerminalEventsWatcher(
          openChannel: _gateway.openChannel,
          uri: service.buildEventsWebSocketUri(server),
          kind: server.kind,
          authPayload: buildTerminalWebSocketAuthPayload(
            server,
            token: token ?? '',
            sessionScopeId: sessionScopeId,
          ),
          path: path,
          ports: ports,
          onEvent: (event) {
            if (_disposed || !_isCurrentContext(server, sessionScopeId)) {
              return;
            }
            switch (event) {
              case TerminalFilesChanged():
                _refreshLive();
              case TerminalPortsChanged(:final ports):
                _pushedPorts++;
                _gateway.setListeningPorts(ports);
                _setLoadingPorts(false);
            }
          },
        );
    final files = watch(path: ensureTerminalDirectoryPath(_gateway.currentPath));
    final ports = watch(ports: true);
    _fileEvents = files;
    _portEvents = ports;
    files.start();
    ports.start();
  }

  /// Starts or stops the live updates of the selected Open WebUI terminal
  /// once Open WebUI says whether it relays them. Its version arrives with
  /// its config, which can come after the terminal loaded, so the terminal
  /// would otherwise stay on demand until it is opened again. The console
  /// stays connected.
  void liveFeaturesChanged() {
    if (_disposed) return;
    final service = _gateway.service;
    final server = _selectedServer;
    if (service == null || server == null || !server.isSystem) return;
    if (!_isCurrentServer(server)) return;
    // A terminal still loading starts them itself once it has loaded.
    if (_featuresFor(server, _gateway.sessionScopeId) == null) return;
    startLiveUpdates(service, server);
  }

  void stopLiveUpdates() {
    final files = _fileEvents;
    final ports = _portEvents;
    _fileEvents = null;
    _portEvents = null;
    files?.stop();
    ports?.stop();
    _liveRun++;
    _liveRefreshPending = false;
  }

  /// Lists the current directory again after the server reported a change.
  /// A change reported while a listing is under way lists once more after
  /// it, so the listing never ends older than the last change.
  void _refreshLive() {
    if (_liveRefreshRun == _liveRun) {
      _liveRefreshPending = true;
      return;
    }
    unawaited(_runLiveRefresh(_liveRun));
  }

  Future<void> _runLiveRefresh(int run) async {
    _liveRefreshRun = run;
    try {
      do {
        _liveRefreshPending = false;
        final service = _gateway.service;
        final server = _selectedServer;
        if (_disposed || service == null || server == null) return;
        await loadDirectory(
          service,
          server,
          path: _gateway.currentPath,
          updateServerCwd: false,
          refresh: true,
          quiet: true,
        );
      } while (_liveRefreshPending && run == _liveRun && !_disposed);
    } finally {
      if (_liveRefreshRun == run) _liveRefreshRun = null;
    }
  }

  TerminalServerFeatures? _featuresFor(
    TerminalServerInfo server,
    String sessionScopeId,
  ) {
    final features = _features;
    if (features == null ||
        features.selectionId != server.selectionId ||
        features.sessionScopeId != sessionScopeId) {
      return null;
    }
    return features.value;
  }

  Future<void> loadPorts(
    TerminalService service,
    TerminalServerInfo server,
  ) async {
    final sessionScopeId = _gateway.sessionScopeId;
    final pushedBefore = _pushedPorts;
    _setLoadingPorts(true);
    try {
      final ports = await service.getListeningPorts(
        server,
        sessionScopeId: sessionScopeId,
      );
      if (!_isCurrentContext(server, sessionScopeId)) {
        return;
      }
      // The server pushed a newer list while this one was on its way.
      if (_pushedPorts != pushedBefore) return;
      _gateway.setListeningPorts(ports);
    } catch (_) {
      if (_isCurrentContext(server, sessionScopeId)) {
        _onFailure(TerminalBrowserFailure.loadPorts);
      }
    } finally {
      if (_isCurrentContext(server, sessionScopeId)) {
        _setLoadingPorts(false);
      }
    }
  }

  Future<void> navigateTo(String path) async {
    if (_disposed) {
      return;
    }
    final service = _gateway.service;
    final server = _selectedServer;
    if (service == null || server == null) {
      return;
    }
    await loadDirectory(service, server, path: path, updateServerCwd: true);
  }

  Future<TerminalFileReadResult?> readEntry(
    TerminalBrowserOperationContext operationContext,
    TerminalFileEntry entry,
  ) async {
    if (!_isCurrentOperationContext(operationContext)) {
      return null;
    }
    try {
      final preview = await operationContext.service.readFile(
        operationContext.server,
        entry.path,
        sessionScopeId: operationContext.sessionScopeId,
      );
      return _isCurrentOperationContext(operationContext) ? preview : null;
    } catch (_) {
      if (_isCurrentOperationContext(operationContext)) {
        _onFailure(TerminalBrowserFailure.loadFiles);
      }
      return null;
    }
  }

  Future<void> downloadEntry(
    TerminalBrowserOperationContext operationContext,
    TerminalFileEntry entry,
  ) async {
    await _runMutation(
      operationContext,
      failure: TerminalBrowserFailure.download,
      reloadAfterward: false,
      mutate: () async {
        final downloaded = await operationContext.service.downloadFile(
          operationContext.server,
          entry.path,
          sessionScopeId: operationContext.sessionScopeId,
        );
        if (_isCurrentOperationContext(operationContext)) {
          await _platformGateway.saveDownload(downloaded);
        }
      },
    );
  }

  Future<void> renameEntry(
    TerminalBrowserOperationContext operationContext,
    TerminalFileEntry entry,
    String newName,
  ) async {
    await _runMutation(
      operationContext,
      failure: TerminalBrowserFailure.rename,
      mutate: () => operationContext.service.moveEntry(
        operationContext.server,
        _pathWithoutTrailingSlash(entry.path),
        _pathWithoutTrailingSlash(
          joinTerminalPath(
            operationContext.currentPath,
            newName,
            directoryResult: entry.isDirectory,
          ),
        ),
        sessionScopeId: operationContext.sessionScopeId,
      ),
    );
  }

  Future<void> deleteEntry(
    TerminalBrowserOperationContext operationContext,
    TerminalFileEntry entry,
  ) async {
    await _runMutation(
      operationContext,
      failure: TerminalBrowserFailure.delete,
      mutate: () => operationContext.service.deleteEntry(
        operationContext.server,
        _pathWithoutTrailingSlash(entry.path),
        sessionScopeId: operationContext.sessionScopeId,
      ),
    );
  }

  Future<void> pickAndUploadFile(
    TerminalBrowserOperationContext operationContext,
  ) async {
    if (!_isCurrentOperationContext(operationContext)) return;
    TerminalUploadFile? pickedFile;
    try {
      pickedFile = await _platformGateway.pickUploadFile();
    } catch (_) {
      if (_isCurrentOperationContext(operationContext)) {
        _onFailure(TerminalBrowserFailure.upload);
      }
      return;
    }
    if (pickedFile == null) return;
    final upload = pickedFile;
    await _runMutation(
      operationContext,
      failure: TerminalBrowserFailure.upload,
      mutate: () => operationContext.service.uploadFile(
        operationContext.server,
        operationContext.currentPath,
        upload.path,
        upload.name,
        sessionScopeId: operationContext.sessionScopeId,
      ),
    );
  }

  Future<void> createFolder(
    TerminalBrowserOperationContext operationContext,
    String folderName,
  ) async {
    await _runMutation(
      operationContext,
      failure: TerminalBrowserFailure.createFolder,
      requestRefresh: true,
      mutate: () => operationContext.service.createDirectory(
        operationContext.server,
        joinTerminalPath(operationContext.currentPath, folderName),
        sessionScopeId: operationContext.sessionScopeId,
      ),
    );
  }

  /// Shows [port] in the app's preview. A terminal that opens browser
  /// sessions shows it through one, for Open WebUI's own terminals only on
  /// a server that relays them (0.13); any other shows it through the port
  /// proxy, as before. The proxy needs the terminal's credential, Open
  /// WebUI's token or a direct terminal's key, which goes only with the
  /// page loads the app makes.
  Future<void> openPort(TerminalListeningPort port) async {
    if (_disposed) {
      return;
    }
    final service = _gateway.service;
    final server = _selectedServer;
    if (service == null || server == null) {
      return;
    }

    final sessionScopeId = _gateway.sessionScopeId;
    final sessions =
        _featuresFor(server, sessionScopeId)?.browser == true &&
        (server.isDirect || _gateway.systemTerminalLiveFeatures);
    final preview = TerminalPortPreview(
      port: port.port,
      terminalBaseUri: server.baseUrl,
      bearerToken: service.authTokenForServer(server),
      proxyCookies: service.proxyCookiesForServer(server),
      openSession: sessions
          ? () => service.createBrowserSession(
              server,
              url: 'http://localhost:${port.port}/',
              sessionScopeId: sessionScopeId,
            )
          : null,
      closeSession: sessions
          ? (session) => _sessionCloser(service, server).closeBrowserSession(
              server,
              session.id,
              sessionScopeId: sessionScopeId,
            )
          : null,
    );
    final launched = await _platformGateway.openPort(preview);
    if (!launched) {
      _onFailure(TerminalBrowserFailure.openPort);
    }
  }

  /// The service that closes a browser session [opened] opened on [server].
  ///
  /// Open WebUI's own terminals go through the account's client, which the
  /// app replaces and closes whenever the account's token changes, as a
  /// silent sign-in does. A close sent through the old one never leaves, and
  /// the terminal keeps the session for a day, counting it against the
  /// user's 16 browser tabs. So the current client closes it while it is
  /// the same saved server's: the session answers only the user who opened
  /// it, so another user's client could not close it anyway, and another
  /// server's must not hear of it. A direct terminal's requests make a
  /// client of their own.
  TerminalService _sessionCloser(
    TerminalService opened,
    TerminalServerInfo server,
  ) {
    // The tab that owns the gateway is gone with this controller.
    if (_disposed || !server.isSystem) return opened;
    final current = _gateway.service;
    if (current == null || identical(current, opened)) return opened;
    return current.api.serverConfig.id == opened.api.serverConfig.id
        ? current
        : opened;
  }

  void resetLoading() {
    if (!_loadingFiles && !_loadingPorts) {
      return;
    }
    _loadingFiles = false;
    _loadingPorts = false;
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    stopLiveUpdates();
    super.dispose();
  }

  TerminalServerInfo? get _selectedServer => _gateway.selectedServer;

  bool _isCurrentServer(TerminalServerInfo server) =>
      _isCurrentContext(server, _gateway.sessionScopeId);

  bool _isCurrentOperationContext(
    TerminalBrowserOperationContext operationContext,
  ) =>
      !_disposed &&
      identical(_gateway.service, operationContext.service) &&
      _gateway.currentPath == operationContext.currentPath &&
      _isCurrentContext(
        operationContext.server,
        operationContext.sessionScopeId,
      );

  Future<void> _runMutation(
    TerminalBrowserOperationContext operationContext, {
    required TerminalBrowserFailure failure,
    required Future<void> Function() mutate,
    bool reloadAfterward = true,
    bool requestRefresh = false,
  }) async {
    if (!_isCurrentOperationContext(operationContext)) return;
    try {
      await mutate();
      if (!_isCurrentOperationContext(operationContext)) return;
      if (requestRefresh) _gateway.requestRefresh();
      if (reloadAfterward) await reload();
    } catch (_) {
      if (_isCurrentOperationContext(operationContext)) {
        _onFailure(failure);
      }
    }
  }

  void _setLoadingFiles(bool value) {
    if (_loadingFiles == value) {
      return;
    }
    _loadingFiles = value;
    if (!_disposed) {
      notifyListeners();
    }
  }

  void _setLoadingPorts(bool value) {
    if (_loadingPorts == value) {
      return;
    }
    _loadingPorts = value;
    if (!_disposed) {
      notifyListeners();
    }
  }

  String _pathWithoutTrailingSlash(String path) {
    if (path == '/' || RegExp(r'^[A-Za-z]:/$').hasMatch(path)) {
      return path;
    }
    return path.endsWith('/') ? path.substring(0, path.length - 1) : path;
  }
}
