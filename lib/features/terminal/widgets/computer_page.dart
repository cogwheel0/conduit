import 'dart:async';

import 'package:conduit_core/features/terminal/models/computer_models.dart';
import 'package:conduit_core/features/terminal/providers/computer_providers.dart';
import 'package:conduit_core/features/terminal/services/computer_service.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/widgets.dart';

import '../../../shared/widgets/platform_ui/vocabulary.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/platform_ui/platform_ui.dart';
import 'computer_surface.dart';
import 'computer_mode_selector.dart';
import 'computer_browser_tabs.dart';

class ComputerPage extends ConsumerStatefulWidget {
  const ComputerPage({
    super.key,
    required this.service,
    required this.capabilities,
    this.initialConnection,
    this.initialSurface,
  });
  final ComputerService service;
  final ComputerCapabilities capabilities;
  final ComputerConnection? initialConnection;
  final ComputerSurface? initialSurface;

  @override
  ConsumerState<ComputerPage> createState() => _ComputerPageState();
}

class _ComputerPageState extends ConsumerState<ComputerPage>
    with WidgetsBindingObserver {
  final _surface = ComputerSurfaceController();
  GlobalKey _surfaceKey = GlobalKey();
  ComputerConnection? _connection;
  late ComputerSurface _selected;
  String _status = 'connecting', _url = '';
  bool _controlling = false, _stopping = false, _zoomed = false;
  bool _canBack = false, _canForward = false, _stopFailed = false;
  bool _vnc = false, _hasTakenControl = false;
  bool _inputFailed = false;
  bool _audioAvailable = false, _audioEnabled = false, _audioFailed = false;
  bool _desktopSite = false;
  bool _tabsOpen = false;
  String _quality = 'crisp';
  bool _active = true, _scopeValid = true;
  int _generation = 0;
  Timer? _heartbeat;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _selected =
        widget.initialConnection?.surface ??
        widget.initialSurface ??
        widget.capabilities.preferred;
    _connection = widget.initialConnection;
    _vnc = _connection?.transport == 'vnc';
    if (_connection == null) unawaited(_open());
    _heartbeat = Timer.periodic(const Duration(seconds: 45), (_) async {
      final connection = _connection;
      if (!_active || !_scopeValid || connection == null) return;
      try {
        await widget.service.keepAlive(connection);
      } catch (_) {
        /* Stream reports connectivity. */
      }
    });
    ref.listenManual(computerServiceProvider, (_, next) {
      if (identical(next.value, widget.service)) return;
      _scopeValid = false;
      _generation++;
      unawaited(_surface.visibility(false));
      if (mounted) {
        setState(() {
          _connection = null;
          _controlling = false;
        });
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_tabsOpen) Navigator.of(context).pop();
        final route = ModalRoute.of(context);
        if (route != null) Navigator.of(context).removeRoute(route);
      });
    });
    ref.listenManual(chatMessagesProvider, (_, messages) {
      if ((_controlling || _hasTakenControl) &&
          messages.any((message) => message.isStreaming)) {
        _hasTakenControl = false;
        _watch();
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _active = state == AppLifecycleState.resumed;
    if (!_active && _tabsOpen) Navigator.of(context).pop();
    _generation++;
    setState(() {
      _controlling = false;
      _stopping = false;
      _status = 'connecting';
    });
    unawaited(_surface.visibility(_active && _scopeValid));
    if (_active && _scopeValid && _connection == null) unawaited(_open());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _generation++;
    _heartbeat?.cancel();
    super.dispose();
  }

  Future<void> _open({Future<ComputerConnection?> Function()? connect}) async {
    final generation = ++_generation;
    setState(() {
      _status = 'connecting';
      _connection = null;
      _surfaceKey = GlobalKey();
      _controlling = false;
      _zoomed = false;
      _canBack = false;
      _canForward = false;
      _url = '';
      _stopFailed = false;
      _inputFailed = false;
      _audioAvailable = _audioEnabled = _audioFailed = false;
      _desktopSite = false;
      _quality = 'crisp';
      _stopping = false;
    });
    try {
      final connection =
          await (connect?.call() ?? widget.service.open(_selected));
      if (!mounted || generation != _generation || !_active || !_scopeValid) {
        return;
      }
      setState(() {
        _connection = connection;
        _vnc = connection?.transport == 'vnc';
        _url = connection?.browserSession?.url ?? '';
        if (connection == null) _status = 'empty';
      });
    } on ComputerBrowserUnavailable {
      if (mounted && generation == _generation) {
        setState(() => _status = 'browserUnavailable');
      }
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() => _status = 'unavailable');
      }
    }
  }

  void _onState(Map<String, dynamic> message) {
    if (!mounted || !_scopeValid || !_active) return;
    setState(() {
      final status = message['status'];
      if (status == 'audio') {
        if (message['available'] is bool) {
          _audioAvailable = message['available'] == true;
        }
        _audioEnabled = message['enabled'] == true;
        _audioFailed = message['failed'] == true;
      } else if (status == 'state') {
        _url = message['url'] as String? ?? '';
        _canBack = message['canGoBack'] == true;
        _canForward = message['canGoForward'] == true;
        _vnc = message['transport'] == 'vnc';
      } else if (status == 'watching') {
        _controlling = false;
      } else if (status is String) {
        _status = status;
        if (status != 'live') {
          _controlling = false;
          _zoomed = false;
          _stopping = false;
          _generation++;
        }
      }
    });
  }

  Future<void> _takeControl() async {
    final generation = ++_generation;
    setState(() {
      _stopping = true;
      _stopFailed = false;
    });
    bool accepted = false;
    try {
      accepted = await ref.read(computerTakeControlProvider)();
    } catch (_) {
      /* Remain read-only. */
    }
    if (!mounted || generation != _generation || !_active || !_scopeValid) {
      return;
    }
    setState(() {
      _stopping = false;
      _controlling = accepted && (_status == 'live' || _status == 'empty');
      _hasTakenControl = _hasTakenControl || _controlling;
      _stopFailed = !_controlling;
    });
    await _surface.control(_controlling);
  }

  void _watch() {
    _generation++;
    setState(() {
      _controlling = false;
      _stopping = false;
      _stopFailed = false;
    });
    unawaited(_surface.control(false));
  }

  Future<void> _showTabs() async {
    if (_tabsOpen) return;
    final connection = _connection;
    final hadControl = _controlling;
    _tabsOpen = true;
    final choice = await showComputerBrowserTabs(
      context,
      service: widget.service,
      currentId: connection?.browserSession?.id,
      controlling: hadControl,
    );
    _tabsOpen = false;
    if (!mounted ||
        !_active ||
        !_scopeValid ||
        _selected != ComputerSurface.browser ||
        !identical(connection, _connection) ||
        choice == null) {
      return;
    }
    if (choice.action == ComputerTabAction.control) {
      await _takeControl();
      if (mounted && _controlling) await _showTabs();
      return;
    }
    // A native sheet may blur the viewer. Reapply the cancellation gate before
    // the requested mutation, including if a response started while it was open.
    if (!_controlling && hadControl) await _takeControl();
    if (!mounted || !_controlling) return;
    switch (choice.action) {
      case ComputerTabAction.select:
        if (choice.id != connection?.browserSession?.id) {
          await _open(
            connect: () => widget.service.selectBrowserTab(choice.id!),
          );
        }
      case ComputerTabAction.create:
        await _open(connect: widget.service.createBrowserTab);
      case ComputerTabAction.close:
        await _open(
          connect: () async {
            await widget.service.closeBrowserTab(choice.id!);
            final tabs = await widget.service.browserTabs();
            if (tabs.isEmpty) return null;
            final selected =
                tabs.where((tab) => tab.selected).firstOrNull ?? tabs.first;
            return widget.service.selectBrowserTab(selected.id);
          },
        );
      case ComputerTabAction.control:
        break;
    }
  }

  Future<void> _textInput({
    bool navigate = false,
    bool shortcut = false,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    final connection = _connection;
    setState(() => _inputFailed = false);
    final result = await AdaptiveAlertDialog.inputShow(
      context: context,
      title: shortcut
          ? l10n.computerShortcut
          : navigate
          ? l10n.computerAddress
          : l10n.computerTypeText,
      input: AdaptiveAlertDialogInput(
        placeholder: shortcut
            ? 'Ctrl+A, Alt+Tab, Cmd+C'
            : navigate
            ? l10n.computerAddress
            : l10n.computerTypeText,
        initialValue: navigate ? _url : '',
        keyboardType: navigate ? TextInputType.url : TextInputType.multiline,
      ),
      actions: [
        AlertAction(
          title: l10n.cancel,
          style: AlertActionStyle.cancel,
          onPressed: () {},
        ),
        AlertAction(
          title: l10n.computerSend,
          style: AlertActionStyle.primary,
          onPressed: () {},
        ),
      ],
    );
    // The keyboard can blur the WebView, which deliberately returns to Watch.
    // Do not re-enable input without the same explicit control gate.
    if (mounted &&
        result != null &&
        result.isNotEmpty &&
        _active &&
        _scopeValid &&
        connection != null &&
        identical(connection, _connection)) {
      await _takeControl();
      if (_controlling) {
        try {
          if (shortcut) {
            await widget.service.sendShortcut(connection, result.trim());
          } else {
            await _surface.command({
              'type': navigate ? 'navigate' : 'paste',
              navigate ? 'url' : 'text': result,
            });
          }
        } catch (_) {
          if (mounted && identical(connection, _connection)) {
            setState(() => _inputFailed = true);
          }
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final live = _status == 'live';
    final empty = _status == 'empty';
    final failed = _status == 'unavailable' || _status == 'browserUnavailable';
    final statusLabel = live
        ? (_controlling ? l10n.computerYouControl : l10n.computerWatching)
        : empty
        ? l10n.computerNoTabs
        : _status == 'reconnecting'
        ? l10n.computerReconnecting
        : failed
        ? l10n.computerDisconnected
        : l10n.computerConnecting;
    final host = Uri.tryParse(_url)?.host ?? '';
    final connection = _connection;
    final size = MediaQuery.sizeOf(context);
    final landscape = size.width > size.height && size.height < 600;
    final modes = widget.capabilities.desktop && widget.capabilities.browser
        ? Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: SizedBox(
              width: double.infinity,
              child: ComputerModeSelector(
                capabilities: widget.capabilities,
                selected: _selected,
                onChanged: (value) {
                  _selected = value;
                  unawaited(_open());
                },
              ),
            ),
          )
        : const SizedBox.shrink();
    final status = Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Row(
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: live
                  ? (_controlling
                        ? theme.buttonPrimary
                        : const Color(0xff28ad7a))
                  : theme.textSecondary,
            ),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(statusLabel, style: const TextStyle(fontSize: 13)),
                Text(
                  _selected == ComputerSurface.desktop
                      ? l10n.computerDesktopDescription
                      : l10n.computerBrowserDescription,
                  style: TextStyle(color: theme.textSecondary, fontSize: 12),
                ),
              ],
            ),
          ),
          if (_selected == ComputerSurface.browser)
            AdaptivePopupMenuButton.icon<String>(
              icon: Icons.tune_rounded,
              semanticLabel: l10n.computerDisplay,
              buttonStyle: PopupButtonStyle.plain,
              enabled: live,
              items: [
                for (final entry in {
                  'low': l10n.computerQualityLow,
                  'balanced': l10n.computerQualityBalanced,
                  'crisp': l10n.computerQualitySharp,
                }.entries)
                  AdaptivePopupMenuItem<String>(
                    value: entry.key,
                    label: entry.value,
                    checked: _quality == entry.key,
                  ),
                const AdaptivePopupMenuDivider(),
                AdaptivePopupMenuItem<String>(
                  value: 'desktop',
                  label: l10n.computerDesktopSite,
                  checked: _desktopSite,
                ),
              ],
              onSelected: (_, entry) {
                setState(() {
                  if (entry.value == 'desktop') {
                    _desktopSite = !_desktopSite;
                  } else {
                    _quality = entry.value!;
                  }
                });
                unawaited(_surface.display(_quality, _desktopSite));
              },
            ),
        ],
      ),
    );
    final navigation = _selected == ComputerSurface.browser
        ? Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 12, 8),
            child: Row(
              children: [
                AdaptiveButton.icon(
                  style: AdaptiveButtonStyle.plain,
                  semanticLabel: l10n.back,
                  onPressed: _controlling && _canBack
                      ? () => _surface.command({'type': 'back'})
                      : null,
                  icon: Icons.arrow_back_rounded,
                  iconSize: 20,
                ),
                AdaptiveButton.icon(
                  style: AdaptiveButtonStyle.plain,
                  semanticLabel: l10n.computerForward,
                  onPressed: _controlling && _canForward
                      ? () => _surface.command({'type': 'forward'})
                      : null,
                  icon: Icons.arrow_forward_rounded,
                  iconSize: 20,
                ),
                Expanded(
                  child: AdaptiveButton.child(
                    style: AdaptiveButtonStyle.plain,
                    padding: EdgeInsets.zero,
                    onPressed: _controlling
                        ? () => _textInput(navigate: true)
                        : null,
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: theme.inputBackground,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        host.isEmpty ? l10n.computerBrowser : host,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  ),
                ),
                AdaptiveButton.icon(
                  style: AdaptiveButtonStyle.plain,
                  semanticLabel: l10n.computerReload,
                  onPressed: _controlling
                      ? () => _surface.command({'type': 'reload'})
                      : null,
                  icon: Icons.refresh_rounded,
                  iconSize: 20,
                ),
                AdaptiveButton.icon(
                  style: AdaptiveButtonStyle.plain,
                  semanticLabel: l10n.computerTabs,
                  onPressed: (live || failed || empty) && !_stopping
                      ? _showTabs
                      : null,
                  icon: Icons.tab_rounded,
                  iconSize: 20,
                ),
              ],
            ),
          )
        : const SizedBox.shrink();
    final screen = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: ColoredBox(
          color: const Color(0xff111318),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (connection != null && _scopeValid)
                ComputerSurfaceView(
                  key: _surfaceKey,
                  connection: connection,
                  controller: _surface,
                  onState: (message) {
                    if (identical(connection, _connection)) _onState(message);
                  },
                ),
              if (!live)
                ColoredBox(
                  color: const Color(0xff111318),
                  child: Center(
                    child: SingleChildScrollView(
                      child: Padding(
                        padding: const EdgeInsets.all(28),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (failed || empty)
                              const Icon(
                                Icons.desktop_access_disabled_outlined,
                                size: 34,
                                color: Color(0x99ffffff),
                              )
                            else
                              const SizedBox(
                                width: 24,
                                height: 24,
                                child: AdaptiveProgressIndicator(
                                  strokeWidth: 2,
                                  color: Color(0xb3ffffff),
                                ),
                              ),
                            const SizedBox(height: 16),
                            Text(
                              _status == 'browserUnavailable'
                                  ? l10n.computerBrowserUnavailable
                                  : statusLabel,
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Color(0xb3ffffff)),
                            ),
                            if (failed)
                              Padding(
                                padding: const EdgeInsets.only(top: 12),
                                child: AdaptiveButton.child(
                                  style: AdaptiveButtonStyle.plain,
                                  onPressed: () => unawaited(_open()),
                                  child: Text(
                                    l10n.retry,
                                    style: const TextStyle(
                                      color: Color(0xff68b5ff),
                                    ),
                                  ),
                                ),
                              ),
                            if (empty)
                              AdaptiveButton.child(
                                style: AdaptiveButtonStyle.plain,
                                onPressed: _showTabs,
                                child: Text(
                                  l10n.computerTabs,
                                  style: const TextStyle(
                                    color: Color(0xff68b5ff),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    final controls = Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      child: Column(
        children: [
          Text(
            _audioFailed
                ? l10n.computerAudioUnavailable
                : _inputFailed
                ? l10n.computerInputFailed
                : _stopFailed
                ? l10n.computerStopFailed
                : _controlling
                ? _vnc
                      ? l10n.computerDesktopGestures
                      : l10n.computerControlHint
                : _hasTakenControl
                ? l10n.computerContinueHint
                : l10n.computerWatchHint,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              color: _stopFailed ? theme.inputError : theme.textSecondary,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              if (_controlling && live && !landscape) ...[
                AdaptiveButton.icon(
                  style: AdaptiveButtonStyle.plain,
                  semanticLabel: l10n.computerTypeText,
                  onPressed: () => _textInput(),
                  icon: Icons.keyboard_outlined,
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: AdaptiveButton(
                  onPressed: (!live && !empty) || _stopping
                      ? null
                      : _controlling
                      ? _watch
                      : _takeControl,
                  label: _stopping
                      ? l10n.computerStopping
                      : _controlling
                      ? l10n.computerWatch
                      : l10n.computerTakeControl,
                  sfSymbol: SFSymbol(_controlling ? 'eye' : 'hand.tap'),
                  size: AdaptiveButtonSize.large,
                ),
              ),
            ],
          ),
          if (_controlling && live)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: <Widget>[
                  if (landscape)
                    AdaptiveButton.icon(
                      style: AdaptiveButtonStyle.plain,
                      semanticLabel: l10n.computerTypeText,
                      onPressed: () => _textInput(),
                      icon: Icons.keyboard_outlined,
                    ),
                  ...[
                    'Escape',
                    'Tab',
                    'Enter',
                    'Backspace',
                    'ArrowUp',
                    'ArrowDown',
                    'ArrowLeft',
                    'ArrowRight',
                  ].map(
                    (key) => AdaptiveButton.child(
                      style: AdaptiveButtonStyle.plain,
                      onPressed: () =>
                          _surface.command({'type': 'shortcut', 'key': key}),
                      child: Text(
                        {
                              'Escape': 'Esc',
                              'Backspace': '⌫',
                              'ArrowUp': '↑',
                              'ArrowDown': '↓',
                              'ArrowLeft': '←',
                              'ArrowRight': '→',
                            }[key] ??
                            key,
                      ),
                    ),
                  ),
                  AdaptiveButton.icon(
                    style: AdaptiveButtonStyle.plain,
                    semanticLabel: l10n.computerShortcut,
                    onPressed: () => _textInput(shortcut: true),
                    icon: Icons.keyboard_command_key,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
    return AdaptiveScaffold(
      appBar: AdaptiveAppBar(
        title: _selected == ComputerSurface.desktop
            ? l10n.computerDesktop
            : l10n.computerBrowser,
        actions: [
          if (_audioAvailable && _selected == ComputerSurface.desktop)
            AdaptiveAppBarAction(
              semanticLabel: _audioEnabled
                  ? l10n.computerMute
                  : l10n.computerUnmute,
              iosSymbol: _audioEnabled ? 'speaker.wave.2' : 'speaker.slash',
              icon: _audioEnabled
                  ? Icons.volume_up_outlined
                  : Icons.volume_off_outlined,
              onPressed: live
                  ? () => unawaited(_surface.audio(!_audioEnabled))
                  : null,
            ),
          AdaptiveAppBarAction(
            semanticLabel: _zoomed ? l10n.computerFit : l10n.computerZoom,
            iosSymbol: _zoomed
                ? 'arrow.down.right.and.arrow.up.left'
                : 'plus.magnifyingglass',
            icon: _zoomed ? Icons.fit_screen_rounded : Icons.zoom_in_rounded,
            onPressed: live
                ? () {
                    setState(() => _zoomed = !_zoomed);
                    unawaited(_surface.zoom(_zoomed));
                  }
                : null,
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            // A side panel leaves the full height available for a landscape desktop.
            if (constraints.maxWidth > constraints.maxHeight &&
                constraints.maxHeight < 600) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: 240,
                    child: SingleChildScrollView(
                      child: Column(children: [modes, status, controls]),
                    ),
                  ),
                  Expanded(
                    child: Column(
                      children: [
                        navigation,
                        Expanded(child: screen),
                      ],
                    ),
                  ),
                ],
              );
            }
            if (MediaQuery.textScalerOf(context).scale(14) > 20) {
              return SingleChildScrollView(
                child: Column(
                  children: [
                    modes,
                    status,
                    navigation,
                    SizedBox(
                      height: constraints.maxHeight * .65,
                      child: screen,
                    ),
                    controls,
                  ],
                ),
              );
            }
            return Column(
              children: [
                modes,
                status,
                navigation,
                Expanded(child: screen),
                controls,
              ],
            );
          },
        ),
      ),
    );
  }
}
