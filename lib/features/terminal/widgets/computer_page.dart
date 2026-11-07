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

class ComputerPage extends ConsumerStatefulWidget {
  const ComputerPage({
    super.key,
    required this.service,
    required this.capabilities,
    this.initialConnection,
  });
  final ComputerService service;
  final ComputerCapabilities capabilities;
  final ComputerConnection? initialConnection;

  @override
  ConsumerState<ComputerPage> createState() => _ComputerPageState();
}

class _ComputerPageState extends ConsumerState<ComputerPage>
    with WidgetsBindingObserver {
  final _surface = ComputerSurfaceController();
  ComputerConnection? _connection;
  late ComputerSurface _selected;
  String _status = 'connecting', _url = '';
  bool _controlling = false, _stopping = false, _zoomed = false;
  bool _canBack = false, _canForward = false, _stopFailed = false;
  bool _active = true, _scopeValid = true;
  int _generation = 0;
  Timer? _heartbeat;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _selected =
        widget.initialConnection?.surface ?? widget.capabilities.preferred;
    _connection = widget.initialConnection;
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
        final route = ModalRoute.of(context);
        if (route != null) Navigator.of(context).removeRoute(route);
      });
    });
    ref.listenManual(chatMessagesProvider, (_, messages) {
      if (_controlling && messages.any((message) => message.isStreaming)) {
        _watch();
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _active = state == AppLifecycleState.resumed;
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

  Future<void> _open() async {
    final generation = ++_generation;
    setState(() {
      _status = 'connecting';
      _connection = null;
      _controlling = false;
      _zoomed = false;
    });
    try {
      final connection = await widget.service.open(_selected);
      if (!mounted || generation != _generation || !_active || !_scopeValid) {
        return;
      }
      setState(() {
        _connection = connection;
        _url = connection.browserSession?.url ?? '';
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
      if (status == 'state') {
        _url = message['url'] as String? ?? '';
        _canBack = message['canGoBack'] == true;
        _canForward = message['canGoForward'] == true;
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
      _controlling = accepted && _status == 'live';
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

  Future<void> _textInput({bool navigate = false}) async {
    final l10n = AppLocalizations.of(context)!;
    final result = await AdaptiveAlertDialog.inputShow(
      context: context,
      title: navigate ? l10n.computerAddress : l10n.computerTypeText,
      input: AdaptiveAlertDialogInput(
        placeholder: navigate ? l10n.computerAddress : l10n.computerTypeText,
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
        _scopeValid) {
      await _takeControl();
      if (_controlling) {
        await _surface.command({
          'type': navigate ? 'navigate' : 'paste',
          navigate ? 'url' : 'text': result,
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final live = _status == 'live';
    final failed = _status == 'unavailable' || _status == 'browserUnavailable';
    final statusLabel = live
        ? (_controlling ? l10n.computerYouControl : l10n.computerWatching)
        : _status == 'reconnecting'
        ? l10n.computerReconnecting
        : failed
        ? l10n.computerDisconnected
        : l10n.computerConnecting;
    final host = Uri.tryParse(_url)?.host ?? '';
    return AdaptiveScaffold(
      appBar: AdaptiveAppBar(
        title: l10n.computerTitle,
        actions: [
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
        child: Column(
          children: [
            Padding(
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
                    child: Text(
                      statusLabel,
                      style: TextStyle(
                        color: theme.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  if (widget.capabilities.browser &&
                      widget.capabilities.desktop)
                    AdaptiveValueSegmentedControl<ComputerSurface>(
                      value: _selected,
                      segments: [
                        AdaptiveSegment(
                          value: ComputerSurface.desktop,
                          label: Text(l10n.computerDesktop),
                        ),
                        AdaptiveSegment(
                          value: ComputerSurface.browser,
                          label: Text(l10n.computerBrowser),
                        ),
                      ],
                      onChanged: (value) {
                        _selected = value;
                        unawaited(_open());
                      },
                    ),
                ],
              ),
            ),
            if (_selected == ComputerSurface.browser)
              Padding(
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
                  ],
                ),
              ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: ColoredBox(
                    color: const Color(0xff111318),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (_connection != null && _scopeValid)
                          ComputerSurfaceView(
                            key: ObjectKey(_connection),
                            connection: _connection!,
                            controller: _surface,
                            onState: _onState,
                          ),
                        if (!live)
                          ColoredBox(
                            color: const Color(0xff111318),
                            child: Center(
                              child: Padding(
                                padding: const EdgeInsets.all(28),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (failed)
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
                                      style: const TextStyle(
                                        color: Color(0xb3ffffff),
                                      ),
                                    ),
                                    if (failed)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 12),
                                        child: AdaptiveButton.child(
                                          style: AdaptiveButtonStyle.plain,
                                          onPressed: () => unawaited(_open()),
                                          child: Text(l10n.retry),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: Column(
                children: [
                  Text(
                    _stopFailed
                        ? l10n.computerStopFailed
                        : _controlling
                        ? l10n.computerControlHint
                        : l10n.computerWatchHint,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      color: _stopFailed
                          ? theme.inputError
                          : theme.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      if (_controlling) ...[
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
                          onPressed: !live || _stopping
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
                  if (_controlling)
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children:
                            [
                                  'Escape',
                                  'Tab',
                                  'Enter',
                                  'Backspace',
                                  'ArrowUp',
                                  'ArrowDown',
                                ]
                                .map(
                                  (key) => AdaptiveButton.child(
                                    style: AdaptiveButtonStyle.plain,
                                    onPressed: () => _surface.command({
                                      'type': 'shortcut',
                                      'key': key,
                                    }),
                                    child: Text(
                                      {
                                            'Escape': 'Esc',
                                            'Backspace': '⌫',
                                            'ArrowUp': '↑',
                                            'ArrowDown': '↓',
                                          }[key] ??
                                          key,
                                    ),
                                  ),
                                )
                                .toList(),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
