import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:xterm/xterm.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/adaptive_glass.dart';
import '../../../shared/utils/platform_page_route.dart';
import '../../../shared/utils/platform_scroll_physics.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/utils/utf16_sanitizer.dart';
import '../../../shared/widgets/adaptive_toolbar_components.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/responsive_drawer_layout.dart';
import '../../../shared/widgets/themed_dialogs.dart';
import '../../navigation/providers/sidebar_providers.dart';
import '../../tools/providers/tools_providers.dart';
import '../models/terminal_models.dart';
import '../providers/terminal_providers.dart';
import '../services/terminal_service.dart';
import 'terminal_connection_badge.dart';
import 'terminal_console_surface.dart';
import 'terminal_fullscreen_page.dart';

class TerminalTab extends ConsumerStatefulWidget {
  const TerminalTab({super.key, this.isActive = true});

  final bool isActive;

  @override
  ConsumerState<TerminalTab> createState() => _TerminalTabState();
}

class _TerminalTabState extends ConsumerState<TerminalTab>
    with AutomaticKeepAliveClientMixin {
  final Terminal _terminal = Terminal(maxLines: 5000);
  final TerminalController _terminalController = TerminalController();

  ProviderSubscription<int>? _refreshSubscription;
  ProviderSubscription<String>? _sessionScopeSubscription;
  ProviderSubscription<AsyncValue<TerminalServerInfo?>>?
  _selectedServerSubscription;
  ProviderSubscription<AsyncValue<List<TerminalServerInfo>>>?
  _singleServerDefaultPanelSubscription;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _channelSubscription;
  Timer? _pingTimer;

  bool _didAutoSelectFallback = false;
  bool _loadingFiles = false;
  bool _loadingPorts = false;
  bool _terminalSupported = true;
  bool _fullscreen = false;
  bool _portsCollapsed = true;
  String? _syncKey;
  int _syncGeneration = 0;
  int _connectionGeneration = 0;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _terminal.onOutput = _handleTerminalOutput;
    _terminal.onResize = _handleTerminalResize;

    _refreshSubscription = ref.listenManual<int>(
      terminalBrowserRefreshTokenProvider,
      (previous, next) {
        if (previous == next) {
          return;
        }
        if (widget.isActive) {
          unawaited(_reloadBrowserState());
        }
      },
    );
    _sessionScopeSubscription = ref.listenManual<String>(
      terminalSessionScopeIdProvider,
      (previous, next) {
        if (widget.isActive) {
          unawaited(_syncTerminalState(force: true));
        }
      },
    );
    _selectedServerSubscription = ref
        .listenManual<AsyncValue<TerminalServerInfo?>>(
          terminalSelectedServerProvider,
          (_, next) => next.whenData((_) {
            if (widget.isActive) {
              unawaited(_syncTerminalState(force: true));
            }
          }),
        );

    _singleServerDefaultPanelSubscription = ref.listenManual(
      terminalAvailableServersProvider,
      (previous, next) => _handleSingleServerDefaultPanel(next),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _handleSingleServerDefaultPanel(
        ref.read(terminalAvailableServersProvider),
      );
      if (widget.isActive) {
        unawaited(_syncTerminalState(force: true));
      }
    });
  }

  @override
  void didUpdateWidget(covariant TerminalTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isActive == widget.isActive) {
      return;
    }

    if (widget.isActive) {
      unawaited(_syncTerminalState(force: true));
      return;
    }

    _syncKey = null;
    _syncGeneration++;
    unawaited(_disconnect(showClosedBanner: false));
    if (mounted) {
      setState(() {
        _loadingFiles = false;
        _loadingPorts = false;
      });
    }
  }

  void _handleSingleServerDefaultPanel(
    AsyncValue<List<TerminalServerInfo>> next,
  ) {
    if (!next.hasValue) {
      return;
    }

    final shouldShowFiles = next.requireValue.length == 1;
    _singleServerDefaultPanelSubscription?.close();
    _singleServerDefaultPanelSubscription = null;
    if (!shouldShowFiles) {
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      ref
          .read(terminalSidebarPanelProvider.notifier)
          .setPanel(TerminalSidebarPanel.files);
    });
  }

  @override
  void dispose() {
    _refreshSubscription?.close();
    _sessionScopeSubscription?.close();
    _selectedServerSubscription?.close();
    _singleServerDefaultPanelSubscription?.close();
    _pingTimer?.cancel();
    _pingTimer = null;
    unawaited(_channelSubscription?.cancel() ?? Future<void>.value());
    unawaited(_channel?.sink.close() ?? Future<void>.value());
    _channelSubscription = null;
    _channel = null;
    super.dispose();
  }

  Future<void> _reloadBrowserState() async {
    if (!widget.isActive) {
      return;
    }

    final service = ref.read(terminalServiceProvider);
    final selectedServer = ref
        .read(terminalSelectedServerProvider)
        .asData
        ?.value;
    if (service == null || selectedServer == null) {
      return;
    }

    final currentPath = ref.read(terminalCurrentPathProvider);
    await _loadDirectory(
      service,
      selectedServer,
      path: currentPath,
      updateServerCwd: false,
    );
    await _loadPorts(service, selectedServer);
  }

  bool _isCurrentTerminalContext(
    TerminalServerInfo server,
    String sessionScopeId,
  ) {
    if (!mounted || !widget.isActive) {
      return false;
    }
    final currentServer = ref
        .read(terminalSelectedServerProvider)
        .asData
        ?.value;
    return currentServer?.selectionId == server.selectionId &&
        ref.read(terminalSessionScopeIdProvider) == sessionScopeId;
  }

  bool _isCurrentSync(
    int syncGeneration,
    TerminalServerInfo server,
    String sessionScopeId,
  ) {
    return syncGeneration == _syncGeneration &&
        _isCurrentTerminalContext(server, sessionScopeId);
  }

  Future<void> _syncTerminalState({required bool force}) async {
    final service = ref.read(terminalServiceProvider);
    if (service == null) {
      return;
    }

    if (!widget.isActive) {
      _syncKey = null;
      await _disconnect(showClosedBanner: false);
      if (mounted) {
        setState(() {
          _loadingFiles = false;
          _loadingPorts = false;
        });
      }
      return;
    }

    final availableServers =
        ref.read(terminalAvailableServersProvider).asData?.value ??
        const <TerminalServerInfo>[];
    final selectedTerminalId = ref.read(selectedTerminalIdProvider);
    final selectedServer = ref
        .read(terminalSelectedServerProvider)
        .asData
        ?.value;
    if (!_didAutoSelectFallback &&
        selectedTerminalId == null &&
        selectedServer != null) {
      _didAutoSelectFallback = true;
      await ref
          .read(terminalSelectionControllerProvider)
          .select(selectedServer);
      return;
    }
    if (selectedServer == null) {
      if (!_didAutoSelectFallback &&
          selectedTerminalId == null &&
          availableServers.isNotEmpty) {
        _didAutoSelectFallback = true;
        await ref
            .read(terminalSelectionControllerProvider)
            .select(availableServers.first);
      } else {
        await _disconnect(showClosedBanner: false);
        if (mounted) {
          setState(() {
            _loadingFiles = false;
            _loadingPorts = false;
          });
        }
      }
      return;
    }

    final sessionScopeId = ref.read(terminalSessionScopeIdProvider);
    final nextSyncKey = '${selectedServer.selectionId}::$sessionScopeId';
    if (!force && _syncKey == nextSyncKey) {
      return;
    }
    _syncKey = nextSyncKey;
    final syncGeneration = ++_syncGeneration;

    await _disconnect(showClosedBanner: false);
    if (!_isCurrentSync(syncGeneration, selectedServer, sessionScopeId)) {
      return;
    }
    _terminal.buffer.clear();
    _terminal.buffer.setCursor(0, 0);
    ref
        .read(terminalConnectionStateProvider.notifier)
        .set(const TerminalConnectionState.disconnected());

    try {
      final terminalEnabled = await service.isTerminalFeatureEnabled(
        selectedServer,
        sessionScopeId: sessionScopeId,
      );
      if (!_isCurrentSync(syncGeneration, selectedServer, sessionScopeId)) {
        return;
      }
      setState(() => _terminalSupported = terminalEnabled);

      final cwd = await service.getCwd(
        selectedServer,
        sessionScopeId: sessionScopeId,
      );
      if (!_isCurrentSync(syncGeneration, selectedServer, sessionScopeId)) {
        return;
      }
      final initialPath = ensureTerminalDirectoryPath(cwd ?? '/');
      ref.read(terminalCurrentPathProvider.notifier).set(initialPath);

      await _loadDirectory(
        service,
        selectedServer,
        path: initialPath,
        updateServerCwd: false,
      );
      if (!_isCurrentSync(syncGeneration, selectedServer, sessionScopeId)) {
        return;
      }
      await _loadPorts(service, selectedServer);
      if (!_isCurrentSync(syncGeneration, selectedServer, sessionScopeId)) {
        return;
      }

      final autoConnect = ref.read(terminalAutoConnectProvider);
      if (autoConnect && _terminalSupported) {
        await _connect(service, selectedServer, sessionScopeId: sessionScopeId);
      }
    } catch (_) {
      if (!mounted) {
        return;
      }
      _showSnackBar(AppLocalizations.of(context)!.terminalFailedToLoadFiles);
    }
  }

  Future<void> _connect(
    TerminalService service,
    TerminalServerInfo server, {
    required String sessionScopeId,
  }) async {
    if (ref.read(terminalConnectionStateProvider).isConnecting) {
      return;
    }
    if (!_isCurrentTerminalContext(server, sessionScopeId)) {
      return;
    }

    final token = service.authTokenForServer(server);
    if (token == null || token.isEmpty) {
      ref
          .read(terminalConnectionStateProvider.notifier)
          .set(const TerminalConnectionState.error());
      if (mounted) {
        _showSnackBar(AppLocalizations.of(context)!.terminalFailedToConnect);
      }
      return;
    }

    final connectionGeneration = ++_connectionGeneration;
    ref
        .read(terminalConnectionStateProvider.notifier)
        .set(const TerminalConnectionState.connecting());

    try {
      final session = await service.createSession(
        server,
        sessionScopeId: sessionScopeId,
      );
      if (!_isCurrentTerminalContext(server, sessionScopeId) ||
          connectionGeneration != _connectionGeneration) {
        return;
      }
      final channel = ref.read(terminalChannelConnectorProvider)(
        service.buildWebSocketUri(server, session.sessionId),
      );
      await channel.ready;

      if (!_isCurrentTerminalContext(server, sessionScopeId) ||
          connectionGeneration != _connectionGeneration) {
        await channel.sink.close();
        return;
      }

      _channel = channel;
      _channelSubscription = channel.stream.listen(
        _handleTerminalEvent,
        onDone: () => _handleTerminalDisconnect(
          connectionGeneration: connectionGeneration,
          showClosedBanner: true,
        ),
        onError: (_) => _handleTerminalDisconnect(
          connectionGeneration: connectionGeneration,
          showClosedBanner: false,
        ),
      );

      ref.read(terminalActiveSessionProvider.notifier).set(session);
      ref
          .read(terminalConnectionStateProvider.notifier)
          .set(const TerminalConnectionState.connected());

      channel.sink.add(
        jsonEncode(<String, dynamic>{'type': 'auth', 'token': token}),
      );
      _sendResizeEvent();
      _pingTimer = Timer.periodic(
        const Duration(seconds: 25),
        (_) => _sendPingEvent(),
      );
    } catch (_) {
      if (!_isCurrentTerminalContext(server, sessionScopeId) ||
          connectionGeneration != _connectionGeneration) {
        return;
      }
      ref.read(terminalActiveSessionProvider.notifier).clear();
      ref
          .read(terminalConnectionStateProvider.notifier)
          .set(const TerminalConnectionState.error());
      if (mounted) {
        _showSnackBar(AppLocalizations.of(context)!.terminalFailedToConnect);
      }
    }
  }

  Future<void> _disconnect({
    required bool showClosedBanner,
    int? expectedConnectionGeneration,
  }) async {
    if (expectedConnectionGeneration != null &&
        expectedConnectionGeneration != _connectionGeneration) {
      return;
    }

    final disconnectedLabel = AppLocalizations.of(
      context,
    )!.terminalDisconnectedStatus;
    final pingTimer = _pingTimer;
    final channelSubscription = _channelSubscription;
    final channel = _channel;
    final disconnectGeneration = ++_connectionGeneration;

    _pingTimer = null;
    _channelSubscription = null;
    _channel = null;

    pingTimer?.cancel();
    try {
      await channelSubscription?.cancel();
    } catch (_) {}
    try {
      await channel?.sink.close();
    } catch (_) {}
    if (disconnectGeneration != _connectionGeneration) {
      return;
    }

    ref.read(terminalActiveSessionProvider.notifier).clear();
    ref
        .read(terminalConnectionStateProvider.notifier)
        .set(const TerminalConnectionState.disconnected());
    if (showClosedBanner) {
      _terminal.write('\r\n[$disconnectedLabel]\r\n');
    }
  }

  void _handleTerminalEvent(dynamic event) {
    if (event is String) {
      _terminal.write(sanitizeUtf16(event));
      return;
    }
    if (event is List<int>) {
      _terminal.write(sanitizeUtf16(utf8.decode(event, allowMalformed: true)));
      return;
    }
    if (event is ByteBuffer) {
      _terminal.write(
        sanitizeUtf16(utf8.decode(event.asUint8List(), allowMalformed: true)),
      );
    }
  }

  void _handleTerminalDisconnect({
    required int connectionGeneration,
    required bool showClosedBanner,
  }) {
    if (!mounted) {
      return;
    }
    unawaited(
      _disconnect(
        showClosedBanner: showClosedBanner,
        expectedConnectionGeneration: connectionGeneration,
      ),
    );
  }

  void _handleTerminalOutput(String data) {
    final channel = _channel;
    if (channel == null) {
      return;
    }

    channel.sink.add(utf8.encode(data));
  }

  void _handleTerminalResize(
    int width,
    int height,
    int pixelWidth,
    int pixelHeight,
  ) {
    _sendResizeEvent();
  }

  void _sendResizeEvent() {
    final channel = _channel;
    if (channel == null) {
      return;
    }
    channel.sink.add(
      jsonEncode(<String, dynamic>{
        'type': 'resize',
        'cols': _terminal.viewWidth,
        'rows': _terminal.viewHeight,
      }),
    );
  }

  void _sendPingEvent() {
    final channel = _channel;
    if (channel == null) {
      return;
    }
    channel.sink.add(jsonEncode(const <String, dynamic>{'type': 'ping'}));
  }

  Future<void> _openFullscreen() async {
    if (_fullscreen) {
      return;
    }
    setState(() => _fullscreen = true);
    try {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) {
        return;
      }
      await Navigator.of(context, rootNavigator: true).push(
        buildPlatformPageRoute<void>(
          fullscreenDialog: true,
          builder: (_) => TerminalFullscreenPage(
            terminal: _terminal,
            controller: _terminalController,
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _fullscreen = false);
      }
    }
  }

  Future<void> _loadDirectory(
    TerminalService service,
    TerminalServerInfo server, {
    required String path,
    required bool updateServerCwd,
  }) async {
    final sessionScopeId = ref.read(terminalSessionScopeIdProvider);
    final normalizedPath = ensureTerminalDirectoryPath(path);
    final failedToLoadFilesMessage = AppLocalizations.of(
      context,
    )!.terminalFailedToLoadFiles;

    if (mounted) {
      setState(() => _loadingFiles = true);
    }
    try {
      final entries = await service.listFiles(
        server,
        normalizedPath,
        sessionScopeId: sessionScopeId,
      );
      if (!_isCurrentTerminalContext(server, sessionScopeId)) {
        return;
      }

      ref.read(terminalCurrentPathProvider.notifier).set(normalizedPath);
      ref.read(terminalEntriesProvider.notifier).set(entries);

      if (updateServerCwd) {
        unawaited(
          service.setCwd(
            server,
            normalizedPath,
            sessionScopeId: sessionScopeId,
          ),
        );
      }
    } catch (_) {
      if (_isCurrentTerminalContext(server, sessionScopeId)) {
        _showSnackBar(failedToLoadFilesMessage);
      }
    } finally {
      if (_isCurrentTerminalContext(server, sessionScopeId)) {
        setState(() => _loadingFiles = false);
      }
    }
  }

  Future<void> _loadPorts(
    TerminalService service,
    TerminalServerInfo server,
  ) async {
    final sessionScopeId = ref.read(terminalSessionScopeIdProvider);
    final failedToLoadPortsMessage = AppLocalizations.of(
      context,
    )!.terminalFailedToLoadPorts;
    if (mounted) {
      setState(() => _loadingPorts = true);
    }
    try {
      final ports = await service.getListeningPorts(
        server,
        sessionScopeId: sessionScopeId,
      );
      if (!_isCurrentTerminalContext(server, sessionScopeId)) {
        return;
      }
      ref.read(terminalListeningPortsProvider.notifier).set(ports);
    } catch (_) {
      if (_isCurrentTerminalContext(server, sessionScopeId)) {
        _showSnackBar(failedToLoadPortsMessage);
      }
    } finally {
      if (_isCurrentTerminalContext(server, sessionScopeId)) {
        setState(() => _loadingPorts = false);
      }
    }
  }

  Future<void> _navigateTo(String path) async {
    final service = ref.read(terminalServiceProvider);
    final server = ref.read(terminalSelectedServerProvider).asData?.value;
    if (service == null || server == null) {
      return;
    }
    await _loadDirectory(service, server, path: path, updateServerCwd: true);
  }

  Future<void> _openEntry(TerminalFileEntry entry) async {
    if (entry.isDirectory) {
      await _navigateTo(entry.path);
      return;
    }

    final l10n = AppLocalizations.of(context)!;
    final service = ref.read(terminalServiceProvider);
    final server = ref.read(terminalSelectedServerProvider).asData?.value;
    if (service == null || server == null) {
      return;
    }

    final sessionScopeId = ref.read(terminalSessionScopeIdProvider);
    try {
      final preview = await service.readFile(
        server,
        entry.path,
        sessionScopeId: sessionScopeId,
      );
      if (!mounted) {
        return;
      }

      await ThemedDialogs.show<void>(
        context,
        title: sanitizeUtf16(entry.displayName),
        content: _buildPreviewContent(l10n: l10n, preview: preview),
        actions: [
          ConduitTextButton(
            text: l10n.close,
            onPressed: () => Navigator.of(context).pop(),
          ),
          ConduitTextButton(
            text: l10n.download,
            onPressed: () async {
              Navigator.of(context).pop();
              await _downloadEntry(entry);
            },
            isPrimary: true,
          ),
        ],
      );
    } catch (_) {
      if (mounted) {
        _showSnackBar(l10n.terminalFailedToLoadFiles);
      }
    }
  }

  Widget _buildPreviewContent({
    required AppLocalizations l10n,
    required TerminalFileReadResult preview,
  }) {
    final theme = context.conduitTheme;
    if (preview.isText) {
      return SizedBox(
        width: 520,
        height: 360,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: theme.codeBackground,
            borderRadius: BorderRadius.circular(AppBorderRadius.standard),
            border: Border.all(color: theme.codeBorder),
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(Spacing.md),
            child: SelectableText(
              sanitizeUtf16(preview.text ?? ''),
              style: AppTypography.codeStyle.copyWith(color: theme.codeText),
            ),
          ),
        ),
      );
    }

    if (preview.isImage && preview.bytes != null) {
      return SizedBox(
        width: 520,
        height: 360,
        child: InteractiveViewer(
          child: Image.memory(preview.bytes!, fit: BoxFit.contain),
        ),
      );
    }

    return SizedBox(
      width: 420,
      child: Text(
        l10n.terminalPreviewUnavailable,
        style: AppTypography.bodyMediumStyle.copyWith(
          color: theme.textSecondary,
        ),
      ),
    );
  }

  Future<void> _downloadEntry(TerminalFileEntry entry) async {
    final service = ref.read(terminalServiceProvider);
    final server = ref.read(terminalSelectedServerProvider).asData?.value;
    if (service == null || server == null) {
      return;
    }

    final l10n = AppLocalizations.of(context)!;
    try {
      final downloaded = await service.downloadFile(
        server,
        entry.path,
        sessionScopeId: ref.read(terminalSessionScopeIdProvider),
      );
      final file = await _materializeTempFile(
        downloaded.fileName,
        downloaded.bytes,
      );
      await SharePlus.instance.share(
        ShareParams(
          files: <XFile>[XFile(file.path, name: downloaded.fileName)],
        ),
      );
    } catch (_) {
      if (mounted) {
        _showSnackBar(l10n.terminalDownloadFailed);
      }
    }
  }

  Future<void> _renameEntry(TerminalFileEntry entry) async {
    final service = ref.read(terminalServiceProvider);
    final server = ref.read(terminalSelectedServerProvider).asData?.value;
    if (service == null || server == null) {
      return;
    }

    final l10n = AppLocalizations.of(context)!;
    final newName = await ThemedDialogs.promptTextInput(
      context,
      title: l10n.rename,
      hintText: l10n.rename,
      initialValue: sanitizeUtf16(entry.name),
    );
    if (newName == null || !mounted) {
      return;
    }

    try {
      await service.moveEntry(
        server,
        _entryPathWithoutTrailingSlash(entry.path),
        _entryPathWithoutTrailingSlash(
          joinTerminalPath(
            ref.read(terminalCurrentPathProvider),
            newName,
            directoryResult: entry.isDirectory,
          ),
        ),
        sessionScopeId: ref.read(terminalSessionScopeIdProvider),
      );
      await _reloadBrowserState();
    } catch (_) {
      if (mounted) {
        _showSnackBar(l10n.terminalRenameFailed);
      }
    }
  }

  Future<void> _deleteEntry(TerminalFileEntry entry) async {
    final service = ref.read(terminalServiceProvider);
    final server = ref.read(terminalSelectedServerProvider).asData?.value;
    if (service == null || server == null) {
      return;
    }

    final l10n = AppLocalizations.of(context)!;
    final confirmed = await ThemedDialogs.confirm(
      context,
      title: l10n.delete,
      message: sanitizeUtf16(entry.displayName),
      isDestructive: true,
    );
    if (!confirmed || !mounted) {
      return;
    }

    try {
      await service.deleteEntry(
        server,
        _entryPathWithoutTrailingSlash(entry.path),
        sessionScopeId: ref.read(terminalSessionScopeIdProvider),
      );
      await _reloadBrowserState();
    } catch (_) {
      if (mounted) {
        _showSnackBar(l10n.terminalDeleteFailed);
      }
    }
  }

  Future<void> _pickAndUploadFile() async {
    final service = ref.read(terminalServiceProvider);
    final server = ref.read(terminalSelectedServerProvider).asData?.value;
    if (service == null || server == null) {
      return;
    }

    final l10n = AppLocalizations.of(context)!;
    try {
      final pickedFile = await FilePicker.pickFile();
      if (pickedFile == null) {
        return;
      }

      final localFile = await _materializePickedFile(pickedFile);
      if (localFile == null) {
        return;
      }

      await service.uploadFile(
        server,
        ref.read(terminalCurrentPathProvider),
        localFile.path,
        pickedFile.name,
        sessionScopeId: ref.read(terminalSessionScopeIdProvider),
      );
      await _reloadBrowserState();
    } catch (_) {
      if (mounted) {
        _showSnackBar(l10n.terminalUploadFailed);
      }
    }
  }

  Future<void> _createFolder() async {
    final service = ref.read(terminalServiceProvider);
    final server = ref.read(terminalSelectedServerProvider).asData?.value;
    if (service == null || server == null) {
      return;
    }

    final l10n = AppLocalizations.of(context)!;
    final folderName = await ThemedDialogs.promptTextInput(
      context,
      title: l10n.newFolder,
      hintText: l10n.terminalFolderNameHint,
    );
    if (folderName == null || !mounted) {
      return;
    }

    try {
      await service.createDirectory(
        server,
        joinTerminalPath(ref.read(terminalCurrentPathProvider), folderName),
        sessionScopeId: ref.read(terminalSessionScopeIdProvider),
      );
      ref.read(terminalSelectionControllerProvider).requestTerminalRefresh();
      await _reloadBrowserState();
    } catch (_) {
      if (mounted) {
        _showSnackBar(l10n.terminalFolderCreateFailed);
      }
    }
  }

  Future<void> _openPortInBrowser(TerminalListeningPort port) async {
    final service = ref.read(terminalServiceProvider);
    final server = ref.read(terminalSelectedServerProvider).asData?.value;
    if (service == null || server == null) {
      return;
    }

    final url = service.buildPortProxyUri(server, port.port);
    final authToken = server.isSystem
        ? service.authTokenForServer(server)
        : null;
    final launched = await launchUrl(
      url,
      mode: authToken == null || authToken.isEmpty
          ? LaunchMode.externalApplication
          : LaunchMode.inAppWebView,
      webViewConfiguration: WebViewConfiguration(
        headers: authToken == null || authToken.isEmpty
            ? const <String, String>{}
            : <String, String>{'Authorization': 'Bearer $authToken'},
      ),
    );
    if (!launched && mounted) {
      _showSnackBar(AppLocalizations.of(context)!.errorMessage);
    }
  }

  Future<File?> _materializePickedFile(PlatformFile pickedFile) async {
    if (pickedFile.path != null && pickedFile.path!.isNotEmpty) {
      return File(pickedFile.path!);
    }

    try {
      final bytes = await pickedFile.readAsBytes();
      return _materializeTempFile(pickedFile.name, bytes);
    } catch (_) {
      return null;
    }
  }

  Future<File> _materializeTempFile(String fileName, List<int> bytes) async {
    final tempDir = await getTemporaryDirectory();
    final safeName = fileName.isEmpty
        ? 'terminal_file_${DateTime.now().millisecondsSinceEpoch}'
        : fileName.replaceAll(RegExp(r'[^\w\.\-]'), '_');
    final file = File(p.join(tempDir.path, safeName));
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  String _entryPathWithoutTrailingSlash(String path) {
    if (path == '/' || RegExp(r'^[A-Za-z]:/$').hasMatch(path)) {
      return path;
    }
    return path.endsWith('/') ? path.substring(0, path.length - 1) : path;
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(sanitizeUtf16(message))));
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final selectedServerAsync = ref.watch(terminalSelectedServerProvider);
    final serversAsync = ref.watch(terminalAvailableServersProvider);
    final connectionState = ref.watch(terminalConnectionStateProvider);
    final currentPath = ref.watch(terminalCurrentPathProvider);
    final entries = ref.watch(terminalEntriesProvider);
    final ports = ref.watch(terminalListeningPortsProvider);
    final searchController = ref.watch(sidebarSearchFieldControllerProvider);

    final selectedServer = selectedServerAsync.asData?.value;
    final noServersConfigured =
        !serversAsync.isLoading &&
        !serversAsync.hasError &&
        (serversAsync.asData?.value.isEmpty ?? false);

    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: searchController,
      builder: (context, value, _) {
        final query = value.text.trim().toLowerCase();
        final filteredEntries = query.isEmpty
            ? entries
            : entries
                  .where(
                    (entry) => sanitizeUtf16(
                      entry.displayName,
                    ).toLowerCase().contains(query),
                  )
                  .toList(growable: false);

        final sidebarPanel = ref.watch(terminalSidebarPanelProvider);

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: sidebarPanel == TerminalSidebarPanel.console
                    ? _buildConsoleSection(
                        l10n: l10n,
                        selectedServer: selectedServer,
                        connectionState: connectionState,
                        ports: ports,
                        noServersConfigured: noServersConfigured,
                      )
                    : _buildFilesSection(
                        l10n: l10n,
                        theme: theme,
                        selectedServer: selectedServer,
                        currentPath: currentPath,
                        filteredEntries: filteredEntries,
                        noServersConfigured: noServersConfigured,
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildConsoleSection({
    required AppLocalizations l10n,
    required TerminalServerInfo? selectedServer,
    required TerminalConnectionState connectionState,
    required List<TerminalListeningPort> ports,
    required bool noServersConfigured,
  }) {
    final theme = context.conduitTheme;
    return Padding(
      padding: EdgeInsets.only(
        top: sidebarTabContentTopPadding(context),
        bottom: sidebarTabContentBottomPadding(context),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: _buildTerminalPane(
              l10n: l10n,
              selectedServer: selectedServer,
              connectionState: connectionState,
              noServersConfigured: noServersConfigured,
            ),
          ),
          const SizedBox(height: Spacing.md),
          _buildPortsToggleHeader(l10n: l10n, theme: theme, ports: ports),
          if (!_portsCollapsed) ...[
            const SizedBox(height: Spacing.xs),
            _buildPortsSection(l10n: l10n, ports: ports),
          ],
        ],
      ),
    );
  }

  Widget _buildPortsToggleHeader({
    required AppLocalizations l10n,
    required ConduitThemeExtension theme,
    required List<TerminalListeningPort> ports,
  }) {
    final labelStyle = AppTypography.labelStyle.copyWith(
      color: theme.textSecondary,
      fontWeight: FontWeight.w700,
    );

    return Semantics(
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _portsCollapsed = !_portsCollapsed),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: Spacing.xxs),
          child: Row(
            children: [
              Icon(
                _portsCollapsed
                    ? Icons.chevron_right_rounded
                    : Icons.expand_more_rounded,
                size: IconSize.medium,
                color: theme.iconSecondary,
              ),
              const SizedBox(width: Spacing.xs),
              Text(l10n.terminalPortsToggle, style: labelStyle),
              if (ports.isNotEmpty) ...[
                const SizedBox(width: Spacing.xs),
                Text(
                  '(${ports.length})',
                  style: labelStyle.copyWith(fontWeight: FontWeight.w500),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFilesSection({
    required AppLocalizations l10n,
    required ConduitThemeExtension theme,
    required TerminalServerInfo? selectedServer,
    required String currentPath,
    required List<TerminalFileEntry> filteredEntries,
    required bool noServersConfigured,
  }) {
    final topPad = sidebarTabContentTopPadding(context);
    final bottomPad = sidebarTabContentBottomPadding(context);

    final filesLabelStyle = AppTypography.labelStyle.copyWith(
      color: theme.textSecondary,
      fontWeight: FontWeight.w700,
    );

    final slivers = <Widget>[
      SliverToBoxAdapter(child: SizedBox(height: topPad)),
      SliverToBoxAdapter(
        child: _buildPathCard(
          l10n: l10n,
          currentPath: currentPath,
          selectedServer: selectedServer,
        ),
      ),
      const SliverToBoxAdapter(child: SizedBox(height: Spacing.md)),
      SliverToBoxAdapter(child: Text(l10n.files, style: filesLabelStyle)),
      const SliverToBoxAdapter(child: SizedBox(height: Spacing.xs)),
      if (_loadingFiles)
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: Spacing.sm),
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ),
        )
      else if (selectedServer == null)
        SliverToBoxAdapter(
          child: _buildInfoCard(
            noServersConfigured
                ? l10n.terminalNoServersConfigured
                : l10n.terminalSelectServer,
          ),
        )
      else if (filteredEntries.isEmpty)
        SliverToBoxAdapter(child: _buildInfoCard(l10n.terminalNoFiles))
      else
        SliverList(
          delegate: SliverChildBuilderDelegate((context, index) {
            return Padding(
              padding: const EdgeInsets.only(bottom: Spacing.xxs),
              child: _buildEntryTile(filteredEntries[index]),
            );
          }, childCount: filteredEntries.length),
        ),
      SliverToBoxAdapter(child: SizedBox(height: bottomPad)),
    ];

    return CustomScrollView(
      key: const PageStorageKey<String>('terminal_tab_files_scroll'),
      physics: platformAlwaysScrollablePhysics(context),
      slivers: slivers,
    );
  }

  Widget _buildPortsSection({
    required AppLocalizations l10n,
    required List<TerminalListeningPort> ports,
  }) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 180),
      child: CustomScrollView(
        key: const PageStorageKey<String>('terminal_tab_ports_scroll'),
        shrinkWrap: true,
        physics: platformAlwaysScrollablePhysics(context),
        slivers: [
          if (_loadingPorts)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: Spacing.sm),
                child: Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
            )
          else if (ports.isEmpty)
            SliverToBoxAdapter(child: _buildInfoCard(l10n.terminalNoPorts))
          else
            SliverList(
              delegate: SliverChildBuilderDelegate((context, index) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: Spacing.xxs),
                  child: _buildPortTile(l10n: l10n, port: ports[index]),
                );
              }, childCount: ports.length),
            ),
        ],
      ),
    );
  }

  Widget _buildTerminalPane({
    required AppLocalizations l10n,
    required TerminalServerInfo? selectedServer,
    required TerminalConnectionState connectionState,
    required bool noServersConfigured,
  }) {
    final theme = context.conduitTheme;
    final terminalService = ref.read(terminalServiceProvider);

    return ConduitCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Spacing.md,
              Spacing.sm,
              Spacing.md,
              Spacing.md,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.terminal,
                    style: AppTypography.labelStyle.copyWith(
                      color: theme.textSecondary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                TerminalConnectionBadge(state: connectionState),
                if (selectedServer != null) ...[
                  const SizedBox(width: Spacing.xs),
                  if (connectionState.isConnected ||
                      connectionState.isConnecting)
                    _buildAdaptiveIconActionButton(
                      tooltip: l10n.terminalDisconnectAction,
                      iosIcon: Icons.link_off_rounded,
                      materialIcon: Icons.link_off_rounded,
                      compact: true,
                      onPressed: () =>
                          unawaited(_disconnect(showClosedBanner: false)),
                    )
                  else
                    _buildAdaptiveIconActionButton(
                      tooltip: l10n.terminalConnectAction,
                      iosIcon: CupertinoIcons.link,
                      materialIcon: Icons.link_rounded,
                      compact: true,
                      onPressed: terminalService == null
                          ? null
                          : () => unawaited(
                              _connect(
                                terminalService,
                                selectedServer,
                                sessionScopeId: ref.read(
                                  terminalSessionScopeIdProvider,
                                ),
                              ),
                            ),
                    ),
                  const SizedBox(width: Spacing.xs),
                  _buildAdaptiveIconActionButton(
                    tooltip: l10n.terminalExpandAction,
                    iosIcon: CupertinoIcons.fullscreen,
                    materialIcon: Icons.fullscreen_rounded,
                    compact: true,
                    onPressed: _terminalSupported
                        ? () => unawaited(_openFullscreen())
                        : null,
                  ),
                ],
              ],
            ),
          ),
          Expanded(
            child: _fullscreen
                ? _buildFullscreenPlaceholder(l10n)
                : TerminalConsoleSurface(
                    terminal: _terminal,
                    controller: _terminalController,
                    connected: connectionState.isConnected,
                    overlayMessage: noServersConfigured
                        ? l10n.terminalNoServersConfigured
                        : selectedServer == null
                        ? l10n.terminalSelectServer
                        : !_terminalSupported
                        ? l10n.terminalFeatureDisabled
                        : null,
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildFullscreenPlaceholder(AppLocalizations l10n) {
    final theme = context.conduitTheme;

    return ClipRRect(
      borderRadius: const BorderRadius.vertical(
        bottom: Radius.circular(AppBorderRadius.standard),
      ),
      child: SizedBox.expand(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => unawaited(_openFullscreen()),
          child: ColoredBox(
            color: theme.codeBackground,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(Spacing.lg),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      UiUtils.platformIcon(
                        ios: CupertinoIcons.fullscreen,
                        android: Icons.fullscreen_rounded,
                      ),
                      color: theme.codeText,
                      size: IconSize.medium,
                    ),
                    const SizedBox(height: Spacing.sm),
                    Text(
                      l10n.terminalReopenFullscreen,
                      textAlign: TextAlign.center,
                      style: AppTypography.bodyMediumStyle.copyWith(
                        color: theme.codeText,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPathCard({
    required AppLocalizations l10n,
    required String currentPath,
    required TerminalServerInfo? selectedServer,
  }) {
    final theme = context.conduitTheme;
    final canInteract = selectedServer != null;
    final parentPath = parentTerminalPath(currentPath);
    final canGoUp = canInteract && parentPath != currentPath;

    return ConduitCard(
      padding: const EdgeInsets.all(Spacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _buildAdaptiveIconActionButton(
            tooltip: l10n.back,
            iosIcon: CupertinoIcons.arrow_up,
            materialIcon: Icons.arrow_upward_rounded,
            onPressed: canGoUp ? () => _navigateTo(parentPath) : null,
          ),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.terminalCurrentPathLabel,
                  style: AppTypography.labelStyle.copyWith(
                    color: theme.textSecondary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: Spacing.xs),
                SelectableText(
                  sanitizeUtf16(currentPath),
                  style: AppTypography.codeStyle.copyWith(
                    color: theme.codeText,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: Spacing.xs),
          if (canInteract)
            AdaptiveTooltip(
              message: l10n.more,
              child: AdaptivePopupMenuButton.icon<String>(
                icon: conduitAdaptivePopupMenuIcon(
                  iosSymbol: 'ellipsis',
                  materialIcon: Icons.more_horiz_rounded,
                ),
                items: _buildPathDirectoryMenuItems(l10n: l10n),
                onSelected: (_, selected) async {
                  if (!canInteract) {
                    return;
                  }
                  switch (selected.value) {
                    case 'upload':
                      await _pickAndUploadFile();
                      break;
                    case 'new-folder':
                      await _createFolder();
                      break;
                    case 'home':
                      await _navigateTo('/');
                      break;
                    case 'refresh':
                      await _reloadBrowserState();
                      break;
                    case null:
                      return;
                  }
                },
                buttonStyle: conduitSupportsNativeGlass()
                    ? PopupButtonStyle.glass
                    : PopupButtonStyle.plain,
                tint: theme.iconSecondary,
                size: TouchTarget.medium,
              ),
            )
          else
            SizedBox(width: TouchTarget.medium, height: TouchTarget.medium),
        ],
      ),
    );
  }

  List<AdaptivePopupMenuEntry> _buildPathDirectoryMenuItems({
    required AppLocalizations l10n,
  }) {
    return [
      AdaptivePopupMenuItem<String>(
        value: 'upload',
        label: l10n.terminalUploadAction,
        icon: conduitAdaptivePopupMenuIcon(
          iosSymbol: 'arrow.up.doc',
          materialIcon: Icons.upload_file_rounded,
        ),
      ),
      AdaptivePopupMenuItem<String>(
        value: 'new-folder',
        label: l10n.newFolder,
        icon: conduitAdaptivePopupMenuIcon(
          iosSymbol: 'folder.badge.plus',
          materialIcon: Icons.create_new_folder_outlined,
        ),
      ),
      AdaptivePopupMenuItem<String>(
        value: 'home',
        label: l10n.terminalHomeAction,
        icon: conduitAdaptivePopupMenuIcon(
          iosSymbol: 'house',
          materialIcon: Icons.home_outlined,
        ),
      ),
      AdaptivePopupMenuItem<String>(
        value: 'refresh',
        label: l10n.retry,
        icon: conduitAdaptivePopupMenuIcon(
          iosSymbol: 'arrow.clockwise',
          materialIcon: Icons.refresh_rounded,
        ),
      ),
    ];
  }

  Widget _buildEntryTile(TerminalFileEntry entry) {
    final l10n = AppLocalizations.of(context)!;
    final subtitle = entry.isDirectory
        ? entry.path
        : [
            if (entry.size != null) '${entry.size} B',
            if (entry.modifiedAt != null)
              MaterialLocalizations.of(
                context,
              ).formatShortDate(entry.modifiedAt!),
          ].join(' • ');

    return ConduitCard(
      padding: EdgeInsets.zero,
      child: Material(
        type: MaterialType.transparency,
        child: AdaptiveListTile(
          hideBottomDivider: true,
          backgroundColor: Colors.transparent,
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.md,
            vertical: Spacing.sm,
          ),
          onTap: () => _openEntry(entry),
          leading: Icon(
            entry.isDirectory
                ? UiUtils.folderIcon
                : UiUtils.platformIcon(
                    ios: CupertinoIcons.doc,
                    android: Icons.insert_drive_file_outlined,
                  ),
          ),
          title: Text(
            sanitizeUtf16(entry.displayName),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: subtitle.isEmpty
              ? null
              : Text(
                  sanitizeUtf16(subtitle),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
          trailing: AdaptiveTooltip(
            message: l10n.more,
            child: AdaptivePopupMenuButton.icon<String>(
              icon: conduitAdaptivePopupMenuIcon(
                iosSymbol: 'ellipsis',
                materialIcon: Icons.more_horiz_rounded,
              ),
              items: _buildEntryMenuItems(l10n: l10n, entry: entry),
              onSelected: (_, selected) async {
                switch (selected.value) {
                  case 'download':
                    await _downloadEntry(entry);
                    break;
                  case 'rename':
                    await _renameEntry(entry);
                    break;
                  case 'delete':
                    await _deleteEntry(entry);
                    break;
                  case null:
                    return;
                }
              },
              buttonStyle: conduitSupportsNativeGlass()
                  ? PopupButtonStyle.glass
                  : PopupButtonStyle.plain,
              size: TouchTarget.medium,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPortTile({
    required AppLocalizations l10n,
    required TerminalListeningPort port,
  }) {
    final subtitleParts = <String>[
      if (port.process != null && port.process!.trim().isNotEmpty)
        port.process!,
      if (port.pid != null) 'PID ${port.pid}',
    ];
    return ConduitCard(
      padding: EdgeInsets.zero,
      child: Material(
        type: MaterialType.transparency,
        child: AdaptiveListTile(
          hideBottomDivider: true,
          backgroundColor: Colors.transparent,
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.md,
            vertical: Spacing.sm,
          ),
          onTap: () => _openPortInBrowser(port),
          leading: Icon(
            UiUtils.platformIcon(
              ios: CupertinoIcons.globe,
              android: Icons.lan_outlined,
            ),
          ),
          title: Text('localhost:${port.port}'),
          subtitle: subtitleParts.isEmpty
              ? null
              : Text(sanitizeUtf16(subtitleParts.join(' • '))),
          trailing: _buildAdaptiveIconActionButton(
            tooltip: l10n.terminalOpenInBrowserAction,
            iosIcon: CupertinoIcons.arrow_up_right,
            materialIcon: Icons.open_in_new_rounded,
            onPressed: () => _openPortInBrowser(port),
          ),
        ),
      ),
    );
  }

  List<AdaptivePopupMenuEntry> _buildEntryMenuItems({
    required AppLocalizations l10n,
    required TerminalFileEntry entry,
  }) {
    return [
      if (!entry.isDirectory)
        AdaptivePopupMenuItem<String>(
          value: 'download',
          label: l10n.download,
          icon: conduitAdaptivePopupMenuIcon(
            iosSymbol: 'square.and.arrow.down',
            materialIcon: Icons.download_outlined,
          ),
        ),
      AdaptivePopupMenuItem<String>(
        value: 'rename',
        label: l10n.rename,
        icon: conduitAdaptivePopupMenuIcon(
          iosSymbol: 'pencil',
          materialIcon: Icons.edit_outlined,
        ),
      ),
      AdaptivePopupMenuItem<String>(
        value: 'delete',
        label: l10n.delete,
        icon: conduitAdaptivePopupMenuIcon(
          iosSymbol: 'trash',
          materialIcon: Icons.delete_outline,
        ),
      ),
    ];
  }

  Widget _buildAdaptiveIconActionButton({
    required String tooltip,
    required IconData iosIcon,
    required IconData materialIcon,
    required VoidCallback? onPressed,
    bool compact = false,
  }) {
    final theme = context.conduitTheme;
    final iconSize = compact ? IconSize.sm : IconSize.medium;
    final minSide = compact ? TouchTarget.micro : TouchTarget.medium;
    final usesOpaqueFallback = conduitUsesOpaqueGlassFallback();
    return AdaptiveTooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        enabled: onPressed != null,
        label: tooltip,
        child: AdaptiveButton.child(
          onPressed: onPressed,
          enabled: onPressed != null,
          style: usesOpaqueFallback
              ? AdaptiveButtonStyle.filled
              : AdaptiveButtonStyle.glass,
          color: usesOpaqueFallback ? theme.surfaceContainerHighest : null,
          size: compact ? AdaptiveButtonSize.small : AdaptiveButtonSize.medium,
          minSize: Size(minSide, minSide),
          padding: compact
              ? const EdgeInsets.all(Spacing.xxs)
              : EdgeInsets.zero,
          borderRadius: BorderRadius.circular(AppBorderRadius.circular),
          useSmoothRectangleBorder: false,
          child: Icon(
            UiUtils.platformIcon(ios: iosIcon, android: materialIcon),
            size: iconSize,
            color: onPressed != null ? theme.iconSecondary : theme.iconDisabled,
          ),
        ),
      ),
    );
  }

  Widget _buildInfoCard(String message) {
    final theme = context.conduitTheme;
    return ConduitCard(
      padding: const EdgeInsets.all(Spacing.md),
      child: Text(
        sanitizeUtf16(message),
        style: AppTypography.bodyMediumStyle.copyWith(
          color: theme.textSecondary,
        ),
      ),
    );
  }
}
