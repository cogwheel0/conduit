import 'dart:async';

import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/terminal/models/computer_models.dart';
import 'package:conduit_core/features/terminal/providers/computer_providers.dart';
import 'package:conduit_core/features/terminal/services/computer_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/utils/adaptive_glass.dart';
import '../../../shared/widgets/adaptive_toolbar_components.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/platform_ui/platform_ui.dart';
import '../../../shared/widgets/platform_ui/vocabulary.dart';
import '../../../shared/widgets/themed_sheets.dart';
import 'computer_browser_tabs.dart';
import 'computer_surface.dart';

/// Opens the Computer viewer for the chat's terminal. Availability alone never
/// starts a desktop; only this explicit open connects.
Future<void> openComputerWorkspace(BuildContext context, WidgetRef ref) async {
  if (!ref.read(computerAvailableProvider)) return;
  final service = ref.read(computerServiceProvider).value;
  final capabilities = ref.read(computerCapabilitiesProvider).value;
  if (service == null || capabilities == null) return;
  await ThemedSheets.showFullscreenPage<void>(
    context: context,
    builder: (_) => ComputerPage(service: service, capabilities: capabilities),
  );
}

/// What the address dialog navigates to: typed text without a scheme, such
/// as `example.com` or `localhost:3000`, is an https address, as in a
/// browser's address bar. A host and port is not a scheme.
String computerAddressUrl(String typed) {
  final address = typed.trim();
  final hasScheme =
      RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(address) ||
      RegExp(
        r'^(about|data|blob|view-source|mailto):',
        caseSensitive: false,
      ).hasMatch(address);
  return hasScheme ? address : 'https://$address';
}

/// Menu commands of the Computer viewer's More button.
abstract final class ComputerMenuAction {
  static const back = 'back';
  static const forward = 'forward';
  static const reload = 'reload';
  static const address = 'address';
  static const trackpad = 'trackpad';
  static const paste = 'paste';
  static const recenter = 'recenter';
  static const click = 'click';
  static const rightClick = 'rightClick';
  static const doubleClick = 'doubleClick';
  static const startDrag = 'startDrag';
  static const endDrag = 'endDrag';
  static const tabs = 'tabs';
  static const zoom = 'zoom';
  static const audio = 'audio';
  static const desktopSite = 'desktopSite';
  static const dataSaver = 'dataSaver';
}

/// Keys the software keyboard cannot type, sent from the row above it.
const computerKeyRow = <(String key, String label)>[
  ('Escape', 'esc'),
  ('Tab', 'tab'),
  ('ArrowLeft', '←'),
  ('ArrowUp', '↑'),
  ('ArrowDown', '↓'),
  ('ArrowRight', '→'),
];

/// The live Desktop or Browser of the chat's terminal.
///
/// The user controls the screen whenever the chat's response is idle. While a
/// response runs the agent drives, the screen is watch-only, and Take control
/// stops the response first.
class ComputerPage extends ConsumerStatefulWidget {
  const ComputerPage({
    super.key,
    required this.service,
    required this.capabilities,
    this.initialSurface,
  });
  final ComputerService service;
  final ComputerCapabilities capabilities;
  final ComputerSurface? initialSurface;

  @override
  ConsumerState<ComputerPage> createState() => _ComputerPageState();
}

class _ComputerPageState extends ConsumerState<ComputerPage>
    with WidgetsBindingObserver {
  // A hidden field carries the software keyboard. Its text keeps a few
  // invisible characters in front of what is typed, so Backspace always has
  // something to delete and reaches the remote screen.
  static var _trackpadHintShown = false;
  static const _padding = '\u200b\u200b\u200b\u200b\u200b\u200b\u200b\u200b';

  final _surface = ComputerSurfaceController();
  GlobalKey _surfaceKey = GlobalKey();
  ComputerConnection? _connection;
  late ComputerSurface _selected;
  String _status = 'connecting', _url = '';
  bool _controlling = false, _stopping = false, _zoomed = false;
  bool _canBack = false, _canForward = false;
  bool _activating = false;
  bool _audioAvailable = false, _audioEnabled = false, _audioFailed = false;
  bool _desktopSite = false, _dataSaver = false;
  bool _tabsOpen = false;
  ModalRoute<dynamic>? _tabsRoute;
  bool _trackpad = false, _dragging = false;
  bool _active = true, _scopeValid = true;
  int _generation = 0;
  Timer? _heartbeat, _waitingRefresh;
  bool _refreshingBrowser = false;

  final _keyboardFocus = FocusNode(debugLabel: 'computer-keyboard');
  final _keyboardText = TextEditingController();
  String _keyboardLast = _padding;
  String? _keyboardBeforeReset;
  Future<void> _keystrokes = Future<void>.value();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _selected = widget.initialSurface ?? widget.capabilities.preferred;
    _resetKeyboardText();
    _keyboardFocus.addListener(_onKeyboardFocus);
    unawaited(_open());
    _heartbeat = Timer.periodic(const Duration(seconds: 45), (_) async {
      final connection = _connection;
      if (!_active ||
          !_scopeValid ||
          connection == null ||
          connection.requiresBrowserActivation) {
        return;
      }
      try {
        await widget.service.keepAlive(connection);
      } catch (_) {
        /* Stream reports connectivity. */
      }
    });
    _waitingRefresh = Timer.periodic(const Duration(seconds: 3), (_) {
      unawaited(_refreshWaitingBrowser());
    });
    ref.listenManual(computerServiceProvider, (_, next) {
      if (!next.isLoading &&
          !next.hasError &&
          identical(next.value, widget.service)) {
        return;
      }
      _scopeValid = false;
      _activating = false;
      _generation++;
      _keyboardFocus.unfocus();
      unawaited(_surface.visibility(false));
      if (mounted) {
        setState(() {
          _connection = null;
          _controlling = false;
        });
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _dismissTabs();
        final route = ModalRoute.of(context);
        if (route != null) Navigator.of(context).removeRoute(route);
      });
    });
    ref.listenManual(
      chatMessagesProvider.select(
        (messages) => messages.any((message) => message.isStreaming),
      ),
      (_, working) {
        if (!working) {
          _syncControl();
          _activateWhenIdle();
          return;
        }
        // The agent drives again: hand the screen back and drop anything that
        // would change it on the user's behalf.
        final activating = _activating && _connection == null;
        _activating = false;
        // A tab sheet still on its way up must not appear for the agent.
        if (_controlling || _tabsOpen) _generation++;
        _keyboardFocus.unfocus();
        _dismissTabs();
        _syncControl();
        // The pending activation is stale; rediscover its surface in Watch.
        if (activating) unawaited(_open());
      },
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _active = state == AppLifecycleState.resumed;
    if (!_active) {
      _dismissTabs();
      _keyboardFocus.unfocus();
    }
    _generation++;
    final wasWaiting = _status == 'empty' || _status == 'inactive';
    setState(() {
      _activating = false;
      _controlling = false;
      _stopping = false;
      if (!wasWaiting) _status = 'connecting';
    });
    unawaited(_surface.visibility(_active && _scopeValid));
    if (_active && _scopeValid && _connection == null && !wasWaiting) {
      unawaited(_open());
    }
    if (_active && wasWaiting) {
      _syncControl();
      _activateWhenIdle();
      unawaited(_refreshWaitingBrowser());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _generation++;
    _heartbeat?.cancel();
    _waitingRefresh?.cancel();
    _keyboardFocus.dispose();
    _keyboardText.dispose();
    super.dispose();
  }

  bool get _agentWorking =>
      ref.read(chatMessagesProvider).any((message) => message.isStreaming);

  /// The user controls whenever the chat's response is idle and there is a
  /// screen, or an empty browser to open a tab in.
  void _syncControl() {
    if (!mounted) return;
    final control =
        _active &&
        _scopeValid &&
        !_stopping &&
        !_agentWorking &&
        (_status == 'live' || _status == 'empty');
    if (control == _controlling) return;
    setState(() {
      _controlling = control;
      if (!control) _dragging = false;
    });
    if (!control) _keyboardFocus.unfocus();
    unawaited(_surface.control(control));
  }

  /// An idle chat starts a waiting browser tab's live view without asking.
  void _activateWhenIdle() {
    final session = _connection?.browserSession;
    if (!mounted ||
        _status != 'inactive' ||
        session == null ||
        _activating ||
        _tabsOpen ||
        !_active ||
        !_scopeValid ||
        _agentWorking) {
      return;
    }
    _activating = true;
    unawaited(
      _open(connect: () => widget.service.selectBrowserTab(session.id)),
    );
  }

  Future<void> _refreshWaitingBrowser() async {
    if (!_active ||
        !_scopeValid ||
        (_status != 'empty' && _status != 'inactive') ||
        _tabsOpen ||
        _stopping ||
        _activating ||
        _refreshingBrowser ||
        _selected != ComputerSurface.browser) {
      return;
    }
    _refreshingBrowser = true;
    final generation = _generation;
    try {
      final connection = await widget.service.open(ComputerSurface.browser);
      if (!mounted ||
          generation != _generation ||
          !_active ||
          !_scopeValid ||
          _tabsOpen) {
        return;
      }
      if (connection == null) {
        if (_status == 'inactive') {
          setState(() {
            _connection = null;
            _status = 'empty';
          });
          _syncControl();
        }
        return;
      }
      setState(() {
        _connection = connection;
        _url = connection.browserSession?.url ?? '';
        _status = connection.requiresBrowserActivation
            ? 'inactive'
            : 'connecting';
        _surfaceKey = GlobalKey();
      });
      _syncControl();
      _activateWhenIdle();
    } catch (_) {
      // An agent may be between closing and creating tabs. Keep watching.
    } finally {
      _refreshingBrowser = false;
    }
  }

  Future<void> _open({Future<ComputerConnection?> Function()? connect}) async {
    final generation = ++_generation;
    _activating = _activating && connect != null;
    setState(() {
      _status = 'connecting';
      _connection = null;
      _surfaceKey = GlobalKey();
      _controlling = false;
      _zoomed = false;
      _canBack = false;
      _canForward = false;
      _url = '';
      _audioAvailable = _audioEnabled = _audioFailed = false;
      _dragging = false;
      _stopping = false;
    });
    try {
      final connection =
          await (connect?.call() ?? widget.service.open(_selected));
      if (!mounted || generation != _generation || !_active || !_scopeValid) {
        return;
      }
      _activating = false;
      setState(() {
        _connection = connection;
        _url = connection?.browserSession?.url ?? '';
        if (connection == null) _status = 'empty';
        if (connection?.requiresBrowserActivation == true) _status = 'inactive';
      });
      _syncControl();
      _activateWhenIdle();
    } on ComputerBrowserUnavailable {
      if (mounted && generation == _generation) {
        _activating = false;
        setState(() => _status = 'browserUnavailable');
      }
    } catch (_) {
      if (mounted && generation == _generation) {
        _activating = false;
        setState(() => _status = 'unavailable');
      }
    }
  }

  void _onState(Map<String, dynamic> message) {
    if (!mounted || !_scopeValid || !_active) return;
    final status = message['status'];
    // Trackpad drag state, never a change of connection.
    if (status == 'pointer') {
      setState(() => _dragging = message['dragging'] == true);
      return;
    }
    if (status == 'audio' &&
        message['failed'] == true &&
        !_audioFailed &&
        _audioEnabled) {
      _notify(AppLocalizations.of(context)!.computerAudioUnavailable);
    }
    setState(() {
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
      } else if (status == 'watching') {
        _controlling = false;
      } else if (status is String) {
        _status = status;
        if (status != 'live') {
          _controlling = false;
          _zoomed = false;
          _stopping = false;
          _dragging = false;
          _generation++;
        }
      }
    });
    if (status == 'live') {
      // Input preferences outlive a reconnect or a switch of surface.
      if (_trackpad) unawaited(_surface.trackpad(true));
      if (_selected == ComputerSurface.browser &&
          (_dataSaver || _desktopSite)) {
        unawaited(_surface.display(_quality, _desktopSite));
      }
      _syncControl();
    }
  }

  String get _quality => _dataSaver ? 'low' : 'crisp';

  /// Stops the chat's response so the user can drive. Control follows once
  /// the response has ended.
  Future<void> _takeControl() async {
    if (_stopping) return;
    final generation = ++_generation;
    setState(() => _stopping = true);
    var accepted = false;
    try {
      accepted = await ref.read(computerTakeControlProvider)();
    } catch (_) {
      /* Remain read-only. */
    }
    if (!mounted) return;
    setState(() => _stopping = false);
    if (generation != _generation || !_active || !_scopeValid) return;
    if (!accepted) {
      _notify(AppLocalizations.of(context)!.computerStopFailed, error: true);
      return;
    }
    _syncControl();
    _activateWhenIdle();
  }

  void _notify(String message, {bool error = false}) {
    if (!mounted) return;
    AdaptiveSnackBar.show(
      context,
      message: message,
      type: error ? AdaptiveSnackBarType.error : AdaptiveSnackBarType.warning,
    );
  }

  void _dismissTabs() {
    final route = _tabsRoute;
    if (route != null && route.isActive) route.navigator?.removeRoute(route);
  }

  Future<void> _showTabs() async {
    if (_tabsOpen) return;
    _keyboardFocus.unfocus();
    final generation = _generation;
    final connection = _connection;
    bool canPresent() =>
        mounted && generation == _generation && _active && _scopeValid;
    var awaitingChoice = true;
    _tabsOpen = true;
    final choice = await showComputerBrowserTabs(
      context,
      service: widget.service,
      currentId: connection?.browserSession?.id,
      controlling: _controlling,
      canPresent: canPresent,
      onPresented: (route) {
        if (!awaitingChoice) return;
        _tabsRoute = route;
        if (!canPresent()) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (identical(_tabsRoute, route)) _dismissTabs();
          });
        }
      },
    );
    awaitingChoice = false;
    _tabsOpen = false;
    _tabsRoute = null;
    if (!mounted ||
        generation != _generation ||
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
    // A response that started meanwhile dismissed the sheet and took the
    // screen back; never change tabs on the user's behalf after that.
    if (!_controlling) return;
    switch (choice.action) {
      case ComputerTabAction.select:
        if (choice.id != connection?.browserSession?.id ||
            connection?.requiresBrowserActivation == true) {
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

  Future<void> _createTab() async {
    if (!_controlling) return;
    await _open(connect: widget.service.createBrowserTab);
  }

  /// The address or a named key combination, typed in a dialog.
  Future<void> _dialogInput({required bool shortcut}) async {
    final generation = _generation;
    final l10n = AppLocalizations.of(context)!;
    final connection = _connection;
    final keyboardWasOpen = _keyboardFocus.hasFocus;
    final result = await AdaptiveAlertDialog.inputShow(
      context: context,
      title: shortcut ? l10n.computerShortcut : l10n.computerAddress,
      input: AdaptiveAlertDialogInput(
        placeholder: shortcut ? 'Ctrl+A, Alt+Tab, Cmd+C' : l10n.computerAddress,
        initialValue: shortcut ? '' : _url,
        autocorrect: false,
        keyboardType: shortcut ? TextInputType.text : TextInputType.url,
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
    // A response may have taken the screen back while the dialog was up.
    if (!mounted ||
        generation != _generation ||
        result == null ||
        result.trim().isEmpty ||
        !_controlling ||
        connection == null ||
        !identical(connection, _connection)) {
      return;
    }
    try {
      if (shortcut) {
        await widget.service.sendShortcut(connection, result.trim());
      } else {
        await _surface.command({
          'type': 'navigate',
          'url': computerAddressUrl(result),
        });
      }
    } catch (_) {
      if (mounted && identical(connection, _connection)) {
        _notify(l10n.computerInputFailed, error: true);
      }
    }
    if (mounted && keyboardWasOpen && _controlling) {
      _keyboardFocus.requestFocus();
    }
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (!mounted || text == null || text.isEmpty || !_controlling) return;
    await _surface.command({'type': 'paste', 'text': text});
  }

  Future<void> _onMenu(String action) async {
    switch (action) {
      case ComputerMenuAction.back:
        await _surface.command({'type': 'back'});
      case ComputerMenuAction.forward:
        await _surface.command({'type': 'forward'});
      case ComputerMenuAction.reload:
        await _surface.command({'type': 'reload'});
      case ComputerMenuAction.address:
        await _dialogInput(shortcut: false);
      case ComputerMenuAction.trackpad:
        setState(() {
          _trackpad = !_trackpad;
          _dragging = false;
        });
        // The gestures have no other place on screen to be learned; once a
        // session is enough.
        if (_trackpad && !_trackpadHintShown) {
          _trackpadHintShown = true;
          AdaptiveSnackBar.show(
            context,
            message: AppLocalizations.of(context)!.computerTrackpadHint,
            type: AdaptiveSnackBarType.info,
          );
        }
        await _surface.trackpad(_trackpad);
      case ComputerMenuAction.paste:
        await _paste();
      case ComputerMenuAction.recenter ||
          ComputerMenuAction.click ||
          ComputerMenuAction.rightClick ||
          ComputerMenuAction.doubleClick ||
          ComputerMenuAction.startDrag ||
          ComputerMenuAction.endDrag:
        await _surface.command({'type': action});
      case ComputerMenuAction.tabs:
        await _showTabs();
      case ComputerMenuAction.zoom:
        setState(() => _zoomed = !_zoomed);
        await _surface.zoom(_zoomed);
      case ComputerMenuAction.audio:
        await _surface.audio(!_audioEnabled);
      case ComputerMenuAction.desktopSite:
        setState(() => _desktopSite = !_desktopSite);
        await _surface.display(_quality, _desktopSite);
      case ComputerMenuAction.dataSaver:
        setState(() => _dataSaver = !_dataSaver);
        await _surface.display(_quality, _desktopSite);
    }
  }

  void _select(ComputerSurface surface) {
    if (surface == _selected) return;
    _keyboardFocus.unfocus();
    setState(() => _selected = surface);
    unawaited(_open());
  }

  // Keyboard ------------------------------------------------------------------

  void _onKeyboardFocus() {
    if (!mounted) return;
    if (_keyboardFocus.hasFocus) _resetKeyboardText();
    setState(() {});
  }

  void _toggleKeyboard() {
    if (_keyboardFocus.hasFocus) {
      _keyboardFocus.unfocus();
    } else if (_controlling) {
      _keyboardFocus.requestFocus();
    }
  }

  void _resetKeyboardText() {
    _keyboardBeforeReset = _keyboardLast;
    _keyboardLast = _padding;
    _keyboardText.value = const TextEditingValue(
      text: _padding,
      selection: TextSelection.collapsed(offset: _padding.length),
    );
  }

  /// Sends what changed in the hidden field as keystrokes: Backspace for each
  /// removed character, then the inserted text, with Return for newlines.
  void _onKeyboardChanged(String text) {
    final value = _keyboardText.value;
    // An input method is still composing; send its text once committed.
    if (value.composing.isValid && !value.composing.isCollapsed) return;
    final current = text.characters;
    int common(String base) {
      final a = current.iterator, b = base.characters.iterator;
      var count = 0;
      while (a.moveNext() && b.moveNext() && a.current == b.current) {
        count++;
      }
      return count;
    }

    // The platform can report an edit made before the last reset reached it.
    var base = _keyboardLast;
    final stale = _keyboardBeforeReset;
    _keyboardBeforeReset = null;
    if (stale != null && common(stale) > common(base)) base = stale;
    final prefix = common(base);
    final deleted = base.characters.length - prefix;
    final typed = current.skip(prefix).string.replaceAll('\u200b', '');
    _keyboardLast = text;
    if (deleted > 0 || typed.isNotEmpty) _sendKeystrokes(deleted, typed);
    // Refill the padding before Backspace runs out of it, and keep the field
    // short; either way the next edit compares against the new value.
    if (!text.startsWith(_padding.substring(_padding.length ~/ 2)) ||
        text.length > 256) {
      _resetKeyboardText();
    }
  }

  void _sendKeystrokes(int deleted, String typed) {
    if (!_controlling) return;
    final commands = <Map<String, Object?>>[
      for (var i = 0; i < deleted; i++)
        {'type': 'shortcut', 'key': 'Backspace'},
      for (final (index, line)
          in typed
              .replaceAll('\r\n', '\n')
              .replaceAll('\r', '\n')
              .split('\n')
              .indexed) ...[
        if (index > 0) {'type': 'shortcut', 'key': 'Enter'},
        if (line.isNotEmpty) {'type': 'paste', 'text': line},
      ],
    ];
    _enqueue(() async {
      for (final command in commands) {
        if (!mounted || !_controlling) return;
        await _surface.command(command);
      }
    });
  }

  void _sendKey(String key) {
    if (!_controlling) return;
    _enqueue(() async {
      if (mounted && _controlling) {
        await _surface.command({'type': 'shortcut', 'key': key});
      }
    });
  }

  /// One queue keeps keystrokes in typing order across quick edits. A send
  /// that fails, as when the viewer is replaced mid-send, drops only itself;
  /// later keystrokes still go out.
  void _enqueue(Future<void> Function() send) {
    _keystrokes = _keystrokes.then((_) => send()).catchError((Object _) {});
  }

  // Build ---------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final agentWorking = ref.watch(
      chatMessagesProvider.select(
        (messages) => messages.any((message) => message.isStreaming),
      ),
    );
    final live = _status == 'live';
    final keyboardOpen = _keyboardFocus.hasFocus;
    final tint = theme.textPrimary;

    final keyboardEnabled = keyboardOpen || (_controlling && live);
    final keyboardButton = ConduitAdaptiveAppBarIconButton(
      key: const ValueKey('computer-keyboard-button'),
      icon: Icons.keyboard_outlined,
      iosSymbol: keyboardOpen ? 'keyboard.chevron.compact.down' : 'keyboard',
      semanticLabel: keyboardOpen
          ? l10n.computerHideKeyboard
          : l10n.computerShowKeyboard,
      // A pre-coloured symbol skips UIKit's disabled dimming.
      iconColor: keyboardEnabled ? tint : tint.withValues(alpha: tint.a * .35),
      onPressed: keyboardEnabled ? _toggleKeyboard : null,
    );
    final moreButton = KeyedSubtree(
      key: const ValueKey('computer-more-button'),
      child: ConduitAdaptiveToolbarOverflowButton<String>(
        tintColor: tint,
        items: _menuItems(l10n),
        onSelected: (action) => unawaited(_onMenu(action)),
      ),
    );
    final actions = buildConduitAdaptiveToolbarActionWidgets([
      keyboardButton,
      moreButton,
    ]);
    // On iOS 26 Keyboard and More share one glass capsule, as an iOS bar
    // groups them.
    final nativeMenu = conduitSupportsNativeGlass()
        ? ConduitNativeToolbarAction(
            iosSymbol: 'ellipsis',
            accessibilityLabel: MaterialLocalizations.of(context)
                .moreButtonTooltip,
            tintColor: tint,
            // Its sections and palette row, as the separate button shows.
            menuEntries: _menuItems(l10n),
            onMenuEntrySelected: (entry) {
              if (entry.value case final String action) {
                unawaited(_onMenu(action));
              }
            },
          )
        : null;

    return AdaptiveScaffold(
      // The screen moves up above the keyboard; the browser keeps its
      // viewport and scales instead (see [ComputerSurfaceView.holdViewport]).
      resizeToAvoidBottomInset: true,
      appBar: buildConduitCenteredAdaptiveAppBar(
        context: context,
        tintColor: tint,
        centerTitle: false,
        leading: ConduitAdaptiveAppBarIconButton(
          key: const ValueKey('computer-back-button'),
          icon: UiUtils.backIcon,
          iosSymbol: 'chevron.left',
          semanticLabel: l10n.back,
          iconColor: tint,
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: _ComputerTitle(
          capabilities: widget.capabilities,
          selected: _selected,
          host: _selected == ComputerSurface.browser
              ? Uri.tryParse(_url)?.host ?? ''
              : '',
          onSelected: _select,
        ),
        actions: actions,
        cupertinoTrailing: nativeMenu != null
            ? ConduitNativeToolbarActionGroup(
                key: const ValueKey('computer-toolbar-actions'),
                actions: [
                  ConduitNativeToolbarAction(
                    iosSymbol: keyboardOpen
                        ? 'keyboard.chevron.compact.down'
                        : 'keyboard',
                    accessibilityLabel: keyboardOpen
                        ? l10n.computerHideKeyboard
                        : l10n.computerShowKeyboard,
                    tintColor: tint,
                    onPressed: keyboardEnabled ? _toggleKeyboard : null,
                    enabled: keyboardEnabled,
                  ),
                  nativeMenu,
                ],
              )
            : Row(mainAxisSize: MainAxisSize.min, children: actions),
      ),
      body: SafeArea(
        bottom: !keyboardOpen,
        child: Column(
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _screen(context, keyboardOpen: keyboardOpen),
                  if (!live) _statusView(context),
                  // Carries the software keyboard; it is never seen.
                  Positioned(
                    left: 0,
                    bottom: 0,
                    width: 1,
                    height: 1,
                    child: _keyboardField(context),
                  ),
                  if (agentWorking || _stopping)
                    Positioned(
                      left: 16,
                      right: 16,
                      bottom: 16,
                      child: Center(
                        child: _AgentWorkingPill(
                          stopping: _stopping,
                          onTakeControl:
                              _stopping ||
                                  (!live &&
                                      _status != 'empty' &&
                                      _status != 'inactive')
                              ? null
                              : () => unawaited(_takeControl()),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (keyboardOpen) _keyRow(context),
          ],
        ),
      ),
    );
  }

  List<AdaptivePopupMenuEntry> _menuItems(AppLocalizations l10n) {
    final live = _status == 'live';
    final input = live && _controlling;
    final browser = _selected == ComputerSurface.browser;
    AdaptivePopupMenuItem<String> item(
      String value,
      String label, {
      required String symbol,
      required IconData icon,
      bool enabled = true,
      bool checked = false,
    }) => AdaptivePopupMenuItem<String>(
      value: value,
      label: label,
      icon: conduitAdaptivePopupMenuIcon(iosSymbol: symbol, materialIcon: icon),
      enabled: enabled,
      checked: checked,
    );

    return [
      if (browser)
        AdaptivePopupMenuSection<String>(
          style: AdaptivePopupMenuSectionStyle.palette,
          items: [
            item(
              ComputerMenuAction.back,
              l10n.back,
              symbol: 'chevron.left',
              icon: Icons.arrow_back_rounded,
              enabled: input && _canBack,
            ),
            item(
              ComputerMenuAction.forward,
              l10n.computerForward,
              symbol: 'chevron.right',
              icon: Icons.arrow_forward_rounded,
              enabled: input && _canForward,
            ),
            item(
              ComputerMenuAction.reload,
              l10n.computerReload,
              symbol: 'arrow.clockwise',
              icon: Icons.refresh_rounded,
              enabled: input,
            ),
            item(
              ComputerMenuAction.address,
              l10n.computerAddress,
              symbol: 'link',
              icon: Icons.link_rounded,
              enabled: input,
            ),
          ],
        ),
      AdaptivePopupMenuSection<String>(
        items: [
          item(
            ComputerMenuAction.trackpad,
            l10n.computerTrackpadMode,
            symbol: 'cursorarrow.motionlines',
            icon: Icons.mouse_outlined,
            enabled: input,
            checked: _trackpad,
          ),
          item(
            ComputerMenuAction.paste,
            l10n.terminalPasteAction,
            symbol: 'doc.on.clipboard',
            icon: Icons.content_paste_rounded,
            enabled: input,
          ),
          if (_trackpad)
            item(
              ComputerMenuAction.recenter,
              l10n.computerRecenterPointer,
              symbol: 'scope',
              icon: Icons.center_focus_strong_outlined,
              enabled: input,
            ),
        ],
      ),
      // Precise trackpad work without covering the pointer with a finger.
      if (_trackpad)
        AdaptivePopupMenuSection<String>(
          items: [
            item(
              ComputerMenuAction.click,
              l10n.computerClick,
              symbol: 'cursorarrow.click',
              icon: Icons.ads_click_rounded,
              enabled: input,
            ),
            item(
              ComputerMenuAction.rightClick,
              l10n.computerRightClick,
              symbol: 'contextualmenu.and.cursorarrow',
              icon: Icons.menu_open_rounded,
              enabled: input,
            ),
            item(
              ComputerMenuAction.doubleClick,
              l10n.computerDoubleClick,
              symbol: 'cursorarrow.click.2',
              icon: Icons.touch_app_outlined,
              enabled: input,
            ),
            item(
              _dragging
                  ? ComputerMenuAction.endDrag
                  : ComputerMenuAction.startDrag,
              _dragging ? l10n.computerEndDrag : l10n.computerStartDrag,
              symbol: 'hand.draw',
              icon: Icons.open_with_rounded,
              enabled: input,
              checked: _dragging,
            ),
          ],
        ),
      AdaptivePopupMenuSection<String>(
        items: [
          if (browser)
            item(
              ComputerMenuAction.tabs,
              l10n.computerTabs,
              symbol: 'square.on.square',
              icon: Icons.tab_rounded,
              enabled:
                  !_stopping &&
                  const {
                    'live',
                    'empty',
                    'inactive',
                    'unavailable',
                    'browserUnavailable',
                  }.contains(_status),
            ),
          item(
            ComputerMenuAction.zoom,
            l10n.computerZoom,
            symbol: 'plus.magnifyingglass',
            icon: Icons.zoom_in_rounded,
            enabled: live,
            checked: _zoomed,
          ),
          if (!browser && _audioAvailable)
            item(
              ComputerMenuAction.audio,
              l10n.computerSound,
              symbol: _audioEnabled ? 'speaker.wave.2' : 'speaker.slash',
              icon: _audioEnabled
                  ? Icons.volume_up_outlined
                  : Icons.volume_off_outlined,
              enabled: live,
              checked: _audioEnabled,
            ),
          if (browser) ...[
            item(
              ComputerMenuAction.desktopSite,
              l10n.computerDesktopSite,
              symbol: 'desktopcomputer',
              icon: Icons.desktop_windows_outlined,
              enabled: live,
              checked: _desktopSite,
            ),
            item(
              ComputerMenuAction.dataSaver,
              l10n.computerQualityLow,
              symbol: 'leaf',
              icon: Icons.data_saver_on_outlined,
              enabled: live,
              checked: _dataSaver,
            ),
          ],
        ],
      ),
    ];
  }

  Widget _screen(BuildContext context, {required bool keyboardOpen}) {
    final connection = _connection;
    if (connection == null || _status == 'inactive' || !_scopeValid) {
      return const SizedBox.expand();
    }
    return ComputerSurfaceView(
      key: _surfaceKey,
      connection: connection,
      controller: _surface,
      // Any keyboard, this page's or a dialog's, only covers the page for a
      // moment; the remote browser keeps its size.
      holdViewport: keyboardOpen || MediaQuery.viewInsetsOf(context).bottom > 0,
      onState: (message) {
        if (identical(connection, _connection)) _onState(message);
      },
    );
  }

  Widget _statusView(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final empty = _status == 'empty';
    final inactive = _status == 'inactive';
    final failed = _status == 'unavailable' || _status == 'browserUnavailable';
    final message = switch (_status) {
      'empty' => l10n.computerNoTabs,
      'inactive' => l10n.computerBrowserStartHint,
      'reconnecting' => l10n.computerReconnecting,
      'browserUnavailable' => l10n.computerBrowserUnavailable,
      'unavailable' => l10n.computerDisconnected,
      _ => l10n.computerConnecting,
    };
    return ColoredBox(
      color: theme.surfaceBackground,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (failed || empty || (inactive && _agentWorking))
                Icon(
                  _selected == ComputerSurface.browser
                      ? Icons.public_off_rounded
                      : Icons.desktop_access_disabled_outlined,
                  size: 34,
                  color: theme.textSecondary,
                )
              else
                const AdaptiveProgressIndicator.activity(radius: 11),
              const SizedBox(height: 16),
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(color: theme.textPrimary, fontSize: 17),
              ),
              if (failed)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: AdaptiveButton(
                    style: AdaptiveButtonStyle.glass,
                    label: l10n.retry,
                    onPressed: () => unawaited(_open()),
                  ),
                ),
              if (empty && _controlling)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: AdaptiveButton(
                    style: AdaptiveButtonStyle.glass,
                    label: l10n.computerNewTab,
                    onPressed: () => unawaited(_createTab()),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _keyboardField(BuildContext context) {
    return Semantics(
      label: AppLocalizations.of(context)!.computerTypeText,
      child: EditableText(
        key: const ValueKey('computer-keyboard-field'),
        controller: _keyboardText,
        focusNode: _keyboardFocus,
        style: const TextStyle(fontSize: 1, color: Color(0x00000000)),
        cursorColor: const Color(0x00000000),
        backgroundCursorColor: const Color(0x00000000),
        keyboardType: TextInputType.multiline,
        textInputAction: TextInputAction.newline,
        maxLines: null,
        autocorrect: false,
        enableSuggestions: false,
        smartDashesType: SmartDashesType.disabled,
        smartQuotesType: SmartQuotesType.disabled,
        enableInteractiveSelection: false,
        keyboardAppearance: Theme.of(context).brightness,
        selectionColor: const Color(0x00000000),
        showCursor: false,
        onChanged: _onKeyboardChanged,
        rendererIgnoresPointer: true,
        cursorOpacityAnimates: false,
        textScaler: TextScaler.noScaling,
        strutStyle: StrutStyle.disabled,
        textAlign: TextAlign.start,
      ),
    );
  }

  Widget _keyRow(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    Widget key(String label, VoidCallback onPressed, {String? semantics}) =>
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3),
          child: Semantics(
            button: true,
            label: semantics ?? label,
            excludeSemantics: true,
            child: AdaptiveButton.child(
              style: AdaptiveButtonStyle.plain,
              padding: EdgeInsets.zero,
              minSize: const Size(44, 36),
              onPressed: _controlling ? onPressed : null,
              child: Container(
                constraints: const BoxConstraints(minWidth: 44),
                height: 36,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: theme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  label,
                  style: TextStyle(color: theme.textPrimary, fontSize: 15),
                ),
              ),
            ),
          ),
        );
    return SizedBox(
      key: const ValueKey('computer-key-row'),
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        children: [
          for (final (name, label) in computerKeyRow)
            key(label, () => _sendKey(name), semantics: name),
          key(
            '⌘',
            () => unawaited(_dialogInput(shortcut: true)),
            semantics: l10n.computerShortcut,
          ),
        ],
      ),
    );
  }
}

/// Desktop or Browser, a menu to switch when the terminal offers both.
class _ComputerTitle extends StatelessWidget {
  const _ComputerTitle({
    required this.capabilities,
    required this.selected,
    required this.host,
    required this.onSelected,
  });

  final ComputerCapabilities capabilities;
  final ComputerSurface selected;
  final String host;
  final ValueChanged<ComputerSurface> onSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final both = capabilities.desktop && capabilities.browser;
    final desktop = selected == ComputerSurface.desktop;
    final label = desktop ? l10n.computerDesktop : l10n.computerBrowser;
    final title = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AdaptiveSymbolIcon(
          symbol: desktop ? 'display' : 'globe',
          fallbackIcon: desktop
              ? Icons.desktop_windows_outlined
              : Icons.public_rounded,
          size: 20,
          color: theme.buttonPrimary,
        ),
        const SizedBox(width: 10),
        Flexible(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: theme.textPrimary,
                  fontSize: 17,
                  height: 1.15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (host.isNotEmpty)
                Text(
                  host,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: theme.textSecondary,
                    fontSize: 12,
                    height: 1.15,
                  ),
                ),
            ],
          ),
        ),
        if (both) ...[
          const SizedBox(width: 4),
          Icon(
            Icons.keyboard_arrow_down_rounded,
            size: 20,
            color: theme.textSecondary,
          ),
        ],
      ],
    );
    if (!both) return Semantics(header: true, child: title);
    final items = [
      AdaptivePopupMenuItem<ComputerSurface>(
        value: ComputerSurface.desktop,
        label: l10n.computerDesktop,
        icon: conduitAdaptivePopupMenuIcon(
          iosSymbol: 'display',
          materialIcon: Icons.desktop_windows_outlined,
        ),
        checked: desktop,
      ),
      AdaptivePopupMenuItem<ComputerSurface>(
        value: ComputerSurface.browser,
        label: l10n.computerBrowser,
        icon: conduitAdaptivePopupMenuIcon(
          iosSymbol: 'globe',
          materialIcon: Icons.public_rounded,
        ),
        checked: !desktop,
      ),
    ];
    // The whole toolbar height is the target, with the title centred in it.
    final padded = SizedBox(
      height: conduitScaledControlExtent(context),
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        widthFactor: 1,
        child: title,
      ),
    );
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      // The system pull-down menu, as the toolbar's other menus, on iOS 26.
      child: PlatformUiCapabilities.usesNativeIOS26
          ? Builder(
              key: const ValueKey('computer-surface-menu'),
              builder: (anchor) => GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () async {
                  if (!AdaptiveAnchoredMenu.canShow(anchor)) return;
                  final choice = await AdaptiveAnchoredMenu.show(
                    anchorContext: anchor,
                    items: [
                      for (final item in items)
                        AdaptiveAnchoredMenuItem(
                          id: item.value!.name,
                          label: item.label,
                          sfSymbol: item.icon as String,
                          checked: item.checked,
                        ),
                    ],
                  );
                  for (final surface in ComputerSurface.values) {
                    if (surface.name == choice) onSelected(surface);
                  }
                },
                child: padded,
              ),
            )
          : AdaptivePopupMenuButton.widget<ComputerSurface>(
              key: const ValueKey('computer-surface-menu'),
              items: items,
              onSelected: (_, entry) {
                final value = entry.value;
                if (value != null) onSelected(value);
              },
              child: padded,
            ),
    );
  }
}

/// The agent drives while the chat's response runs; this stops it.
class _AgentWorkingPill extends StatelessWidget {
  const _AgentWorkingPill({
    required this.stopping,
    required this.onTakeControl,
  });

  final bool stopping;
  final VoidCallback? onTakeControl;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    return ThemedSheets.hideNativeChromeWhileCovered(
      child: FloatingAppBarPill(
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(16, 6, 6, 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const AdaptiveProgressIndicator.activity(radius: 7),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  stopping ? l10n.computerStopping : l10n.computerAgentWorking,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: theme.textPrimary, fontSize: 15),
                ),
              ),
              const SizedBox(width: 12),
              AdaptiveButton(
                key: const ValueKey('computer-take-control'),
                style: AdaptiveButtonStyle.prominentGlass,
                size: AdaptiveButtonSize.small,
                label: l10n.computerTakeControl,
                onPressed: onTakeControl,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
