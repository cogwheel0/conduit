import 'dart:async';
import 'dart:typed_data';

import 'package:conduit_core/features/terminal/models/computer_models.dart';
import 'package:conduit_core/features/terminal/providers/computer_providers.dart';
import 'package:conduit_core/features/terminal/services/computer_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/widgets.dart';

import '../../../shared/widgets/platform_ui/vocabulary.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/platform_ui/platform_ui.dart';
import '../../../shared/utils/platform_page_route.dart';
import 'computer_page.dart';

/// A chat-scoped, on-demand entry. No pixels are fetched while collapsed.
class ComputerLauncher extends ConsumerWidget {
  const ComputerLauncher({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final service = ref.watch(computerServiceProvider).value;
    final capabilities = ref.watch(computerCapabilitiesProvider).value;
    if (service == null || capabilities == null || !capabilities.available) {
      return const SizedBox.shrink();
    }
    return _ComputerCard(
      key: ObjectKey(service),
      service: service,
      capabilities: capabilities,
    );
  }
}

class _ComputerCard extends StatefulWidget {
  const _ComputerCard({
    super.key,
    required this.service,
    required this.capabilities,
  });
  final ComputerService service;
  final ComputerCapabilities capabilities;

  @override
  State<_ComputerCard> createState() => _ComputerCardState();
}

class _ComputerCardState extends State<_ComputerCard>
    with WidgetsBindingObserver {
  bool _expanded = false, _loading = false, _failed = false;
  int _generation = 0;
  Uint8List? _preview;
  ComputerConnection? _connection;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  void _forgetPreview() {
    final bytes = _preview;
    _preview = null;
    _connection = null;
    if (bytes != null) unawaited(MemoryImage(bytes).evict());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _generation++;
      setState(() {
        _forgetPreview();
        _expanded = false;
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    _generation++;
    WidgetsBinding.instance.removeObserver(this);
    _forgetPreview();
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _failed = false;
      _forgetPreview();
    });
    try {
      final connection = await widget.service.openPreferred(
        widget.capabilities,
      );
      if (!mounted || generation != _generation) return;
      _connection = connection;
      final bytes = await widget.service.screenshot(connection);
      if (!mounted || generation != _generation) return;
      setState(() => _preview = bytes);
    } catch (_) {
      if (mounted && generation == _generation) setState(() => _failed = true);
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _open() async {
    await Navigator.of(context).push(
      buildPlatformPageRoute<void>(
        builder: (_) => ComputerPage(
          service: widget.service,
          capabilities: widget.capabilities,
          initialConnection: _connection,
        ),
      ),
    );
    if (mounted && _expanded) unawaited(_load());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        decoration: BoxDecoration(
          color: theme.inputBackground,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: theme.inputBorder.withValues(alpha: .6)),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AdaptiveButton.child(
              style: AdaptiveButtonStyle.plain,
              padding: EdgeInsets.zero,
              onPressed: () {
                setState(() => _expanded = !_expanded);
                if (_expanded) {
                  unawaited(_load());
                } else {
                  _generation++;
                  _forgetPreview();
                  _loading = false;
                }
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.desktop_windows_outlined,
                      size: 19,
                      color: theme.textSecondary,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 2,
                      child: Text(
                        l10n.computerTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    Flexible(
                      child: Text(
                        _expanded
                            ? l10n.computerPreview
                            : l10n.computerShowPreview,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.textSecondary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                      size: 18,
                    ),
                  ],
                ),
              ),
            ),
            if (_expanded) ...[
              GestureDetector(
                onTap: _loading ? null : _open,
                child: Semantics(
                  button: true,
                  label: l10n.computerOpenLive,
                  child: Container(
                    height: 152,
                    width: double.infinity,
                    margin: const EdgeInsets.symmetric(horizontal: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xff111318),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: _preview != null
                        ? Image.memory(
                            _preview!,
                            fit: BoxFit.contain,
                            gaplessPlayback: false,
                            errorBuilder: (_, _, _) => const Icon(
                              Icons.desktop_windows_outlined,
                              color: Color(0x8affffff),
                            ),
                          )
                        : Center(
                            child: _loading
                                ? const SizedBox(
                                    width: 22,
                                    height: 22,
                                    child: AdaptiveProgressIndicator(
                                      strokeWidth: 2,
                                      color: Color(0xb3ffffff),
                                    ),
                                  )
                                : Padding(
                                    padding: const EdgeInsets.all(16),
                                    child: Text(
                                      _failed
                                          ? l10n.computerPreviewUnavailable
                                          : l10n.computerWatchHint,
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                        color: Color(0xb3ffffff),
                                      ),
                                    ),
                                  ),
                          ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 4, 8, 4),
                child: Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.visibility_outlined,
                          size: 15,
                          color: theme.textSecondary,
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            l10n.computerReadOnly,
                            style: TextStyle(
                              fontSize: 12,
                              color: theme.textSecondary,
                            ),
                          ),
                        ),
                      ],
                    ),
                    AdaptiveButton(
                      onPressed: _loading ? null : _open,
                      style: AdaptiveButtonStyle.plain,
                      label: l10n.computerOpenLive,
                      sfSymbol: const SFSymbol(
                        'arrow.up.left.and.arrow.down.right',
                        size: 14,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
