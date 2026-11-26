import 'package:conduit_core/features/deepseek_harness/deepseek_harness.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../shared/theme/theme_extensions.dart';
import '../../shared/widgets/adaptive_route_shell.dart';
import '../../shared/widgets/adaptive_toolbar_components.dart';
import '../../shared/widgets/platform_ui/platform_ui.dart';
import '../../shared/widgets/platform_ui/vocabulary.dart';
import '../../shared/widgets/themed_dialogs.dart';
import 'deepseek_harness_browser_data.dart';
import 'deepseek_harness_chats.dart';

class DeepSeekHarnessPage extends ConsumerStatefulWidget {
  const DeepSeekHarnessPage({
    super.key,
    this.editConnection = false,
    required this.onOpenWorkspace,
    required this.onExit,
    required this.onConnected,
    required this.onDisconnected,
  });

  final bool editConnection;

  /// True when the workspace asks the native form to renew its sign-in.
  final Future<bool?> Function(String? sessionTitle) onOpenWorkspace;
  final VoidCallback onExit;
  final Future<void> Function() onConnected;
  final Future<void> Function() onDisconnected;

  @override
  ConsumerState<DeepSeekHarnessPage> createState() => _HarnessPageState();
}

class _HarnessPageState extends ConsumerState<DeepSeekHarnessPage> {
  late bool _editing = widget.editConnection;
  bool _busy = false;
  bool _announced = false;
  DeepSeekHarnessFailure? _error;
  bool _cleanupFailed = false;

  Future<void> _ready() async {
    if (_announced || !mounted) return;
    _announced = true;
    await widget.onConnected();
  }

  void _edit() => setState(() {
    _error = null;
    _cleanupFailed = false;
    _editing = true;
  });

  void _back(DeepSeekHarnessConnection? saved) {
    if (_busy) return;
    if (_editing &&
        !widget.editConnection &&
        saved != null &&
        !saved.isExpired) {
      setState(() {
        _editing = false;
        _error = null;
        _cleanupFailed = false;
      });
    } else {
      widget.onExit();
    }
  }

  Future<void> _connect(
    String launch,
    DeepSeekHarnessConnection? previous,
  ) async {
    if (_busy) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _busy = true;
      _error = null;
      _cleanupFailed = false;
    });
    try {
      final connections = ref.read(deepSeekHarnessConnectionProvider.notifier);
      final browserData = ref.read(deepSeekHarnessBrowserDataProvider);
      await connections.connect(
        launch,
        beforeSave: previous == null
            ? null
            : () => browserData.forget(previous),
      );
      if (!mounted) return;
      setState(() {
        _editing = false;
      });
      _announced = false;
      await _ready();
    } on HarnessCleanupException {
      if (mounted) setState(() => _cleanupFailed = true);
    } on DeepSeekHarnessException catch (error) {
      if (mounted) setState(() => _error = error.reason);
    } catch (_) {
      if (mounted) setState(() => _error = DeepSeekHarnessFailure.unavailable);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _forget(DeepSeekHarnessConnection saved) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await ThemedDialogs.confirm(
      context,
      title: l10n.deepSeekHarnessForget,
      message: l10n.deepSeekHarnessForgetMessage,
      confirmText: l10n.deepSeekHarnessForget,
      isDestructive: true,
    );
    if (!confirmed || !mounted || _busy) return;
    setState(() {
      _busy = true;
      _cleanupFailed = false;
      _error = null;
    });
    try {
      final connections = ref.read(deepSeekHarnessConnectionProvider.notifier);
      await ref.read(deepSeekHarnessBrowserDataProvider).forget(saved);
      await connections.disconnect();
      if (mounted) await widget.onDisconnected();
    } on HarnessCleanupException {
      if (mounted) setState(() => _cleanupFailed = true);
    } catch (_) {
      if (mounted) setState(() => _error = DeepSeekHarnessFailure.unavailable);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final connection = ref.watch(deepSeekHarnessConnectionProvider);
    final saved = connection.value;
    if (!_editing && saved != null && !saved.isExpired) {
      return DeepSeekHarnessChats(
        key: ObjectKey(saved),
        connection: saved,
        onEditConnection: _edit,
        onExit: widget.onExit,
        onReady: _ready,
        onOpenWorkspace: (sessionTitle) async {
          final reconnect = await widget.onOpenWorkspace(sessionTitle);
          if (mounted && reconnect == true) _edit();
        },
      );
    }
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back(saved);
      },
      child: AdaptiveRouteShell(
        bodySafeArea: true,
        safeAreaTop: false,
        appBar: AdaptiveAppBar(
          title: l10n.deepSeekHarnessTitle,
          leading: ConduitAdaptiveAppBarIconButton(
            icon: Icons.arrow_back,
            iosSymbol: 'chevron.backward',
            semanticLabel: _editing && !widget.editConnection && saved != null
                ? l10n.cancel
                : l10n.deepSeekHarnessBack,
            onPressed: _busy ? null : () => _back(saved),
          ),
        ),
        body: connection.when(
          data: (saved) => _ConnectionForm(
            key: ValueKey(saved?.root),
            initialAddress: saved?.root.toString() ?? '',
            busy: _busy,
            cleanupFailed: _cleanupFailed,
            failure:
                _error ??
                (saved?.isExpired == true
                    ? DeepSeekHarnessFailure.unauthorized
                    : null),
            onConnect: (launch) => _connect(launch, saved),
            onForget: saved == null ? null : () => _forget(saved),
            onCancel: () => _back(saved),
          ),
          loading: () => const Center(child: AdaptiveProgressIndicator()),
          error: (_, _) => Center(
            child: AdaptiveButton(
              label: l10n.retry,
              onPressed: () =>
                  ref.invalidate(deepSeekHarnessConnectionProvider),
            ),
          ),
        ),
      ),
    );
  }
}

class _ConnectionForm extends StatefulWidget {
  const _ConnectionForm({
    super.key,
    required this.initialAddress,
    required this.busy,
    required this.cleanupFailed,
    required this.failure,
    required this.onConnect,
    required this.onCancel,
    required this.onForget,
  });

  final String initialAddress;
  final bool busy;
  final bool cleanupFailed;
  final DeepSeekHarnessFailure? failure;
  final ValueChanged<String> onConnect;
  final VoidCallback onCancel;
  final VoidCallback? onForget;

  @override
  State<_ConnectionForm> createState() => _ConnectionFormState();
}

class _ConnectionFormState extends State<_ConnectionForm> {
  late final _address = TextEditingController(text: widget.initialAddress);
  final _token = TextEditingController();
  final _tokenFocus = FocusNode();
  bool _badLink = false;

  @override
  void dispose() {
    _address.dispose();
    _token.dispose();
    _tokenFocus.dispose();
    super.dispose();
  }

  // Split launch links before the address field renders, so a pasted token
  // goes directly into the concealed field and never appears in the URL.
  TextEditingValue _splitLink(TextEditingValue old, TextEditingValue update) {
    final value = update.text.trim();
    final separator = value.indexOf(RegExp('[?#]'));
    final authority = RegExp(r'^(?:[a-zA-Z][a-zA-Z0-9+.-]*://)?[^/?#]*@');
    if (authority.hasMatch(value)) {
      _token.clear();
      setState(() => _badLink = true);
      return TextEditingValue.empty;
    }
    if (separator < 0) {
      if (value != old.text.trim()) _token.clear();
      if (_badLink) setState(() => _badLink = false);
      return update;
    }
    final base = value.substring(0, separator);
    String? token;
    try {
      final uri = Uri.parse(value);
      final query = uri.queryParametersAll;
      final values = query['token'];
      if (!uri.hasFragment &&
          query.length == 1 &&
          values != null &&
          values.length == 1 &&
          values.single.isNotEmpty) {
        token = values.single;
      }
    } on FormatException {
      // Never put the rejected query back in the address field.
    }
    _token.text = token ?? '';
    setState(() => _badLink = token == null);
    return TextEditingValue(
      text: base,
      selection: TextSelection.collapsed(offset: base.length),
    );
  }

  void _submit() {
    if (widget.busy) return;
    final address = _address.text.trim();
    final token = _token.text.trim();
    final root = Uri.tryParse(address);
    if (root == null ||
        !root.hasAuthority ||
        token.isEmpty ||
        root.hasQuery ||
        root.hasFragment) {
      setState(() => _badLink = true);
      return;
    }
    if (_badLink) setState(() => _badLink = false);
    widget.onConnect(
      root.replace(queryParameters: {'token': token}).toString(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final failure = _badLink
        ? DeepSeekHarnessFailure.invalidUrl
        : widget.failure;
    final error = widget.cleanupFailed
        ? l10n.deepSeekHarnessCleanupFailed
        : switch (failure) {
            DeepSeekHarnessFailure.invalidUrl =>
              l10n.deepSeekHarnessInvalidAddress,
            DeepSeekHarnessFailure.unauthorized =>
              l10n.deepSeekHarnessUnauthorized,
            DeepSeekHarnessFailure.untrustedHost =>
              l10n.deepSeekHarnessUntrustedHost,
            DeepSeekHarnessFailure.unavailable ||
            DeepSeekHarnessFailure.invalidResponse =>
              l10n.deepSeekHarnessUnavailable,
            null => null,
          };
    return ListView(
      padding: const EdgeInsets.all(Spacing.pagePadding),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  l10n.deepSeekHarnessConnectionHelp,
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: Spacing.lg),
                Text(l10n.serverUrl, style: theme.textTheme.titleSmall),
                const SizedBox(height: Spacing.sm),
                Semantics(
                  label: l10n.serverUrl,
                  child: AdaptiveTextField(
                    controller: _address,
                    enabled: !widget.busy,
                    keyboardType: TextInputType.url,
                    textInputAction: TextInputAction.next,
                    autocorrect: false,
                    enableSuggestions: false,
                    autofillHints: null,
                    padding: const EdgeInsets.all(Spacing.inputPadding),
                    inputFormatters: [
                      TextInputFormatter.withFunction(_splitLink),
                    ],
                    onSubmitted: (_) => _tokenFocus.requestFocus(),
                  ),
                ),
                const SizedBox(height: Spacing.md),
                Text(
                  l10n.deepSeekHarnessToken,
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: Spacing.sm),
                Semantics(
                  label: l10n.deepSeekHarnessToken,
                  child: AdaptiveTextField(
                    controller: _token,
                    focusNode: _tokenFocus,
                    enabled: !widget.busy,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    autofillHints: null,
                    padding: const EdgeInsets.all(Spacing.inputPadding),
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _submit(),
                  ),
                ),
                if (error != null) ...[
                  const SizedBox(height: Spacing.md),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      error,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ),
                ],
                const SizedBox(height: Spacing.lg),
                if (widget.busy)
                  const Center(child: AdaptiveProgressIndicator())
                else
                  AdaptiveButton(
                    label: l10n.connectToServerButton,
                    size: AdaptiveButtonSize.large,
                    onPressed: _submit,
                  ),
                const SizedBox(height: Spacing.sm),
                AdaptiveButton(
                  label: l10n.cancel,
                  style: AdaptiveButtonStyle.plain,
                  onPressed: widget.busy ? null : widget.onCancel,
                ),
                if (widget.onForget != null)
                  AdaptiveButton(
                    label: l10n.deepSeekHarnessForget,
                    style: AdaptiveButtonStyle.plain,
                    textColor: theme.colorScheme.error,
                    onPressed: widget.busy ? null : widget.onForget,
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
