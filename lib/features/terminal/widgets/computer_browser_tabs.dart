import 'package:flutter/widgets.dart';
import 'package:conduit_core/features/terminal/models/computer_models.dart';
import 'package:conduit_core/features/terminal/services/computer_service.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/platform_ui/platform_ui.dart';
import '../../../shared/widgets/platform_ui/vocabulary.dart';
import '../../../shared/widgets/themed_sheets.dart';

enum ComputerTabAction { select, create, close, control }

typedef ComputerTabChoice = ({ComputerTabAction action, String? id});

Future<ComputerTabChoice?> showComputerBrowserTabs(
  BuildContext context, {
  required ComputerService service,
  required String? currentId,
  required bool controlling,
}) => ThemedSheets.showAdaptive<ComputerTabChoice>(
  context: context,
  builder: (_) => ConstrainedBox(
    constraints: BoxConstraints(
      maxHeight: MediaQuery.sizeOf(context).height * .75,
    ),
    child: DefaultTextStyle(
      style: Theme.of(context).textTheme.bodyMedium!,
      child: ConduitAdaptiveSheetSurface(
        child: ComputerBrowserTabs(
          service: service,
          currentId: currentId,
          controlling: controlling,
        ),
      ),
    ),
  ),
);

class ComputerBrowserTabs extends StatefulWidget {
  const ComputerBrowserTabs({
    super.key,
    required this.service,
    required this.currentId,
    required this.controlling,
  });
  final ComputerService service;
  final String? currentId;
  final bool controlling;

  @override
  State<ComputerBrowserTabs> createState() => _ComputerBrowserTabsState();
}

class _ComputerBrowserTabsState extends State<ComputerBrowserTabs> {
  late Future<List<ComputerBrowserTab>> _tabs = widget.service.browserTabs();

  void _choose(ComputerTabAction action, [String? id]) =>
      Navigator.of(context).pop((action: action, id: id));

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.computerTabs,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                AdaptiveButton.icon(
                  useNative: false,
                  style: AdaptiveButtonStyle.plain,
                  semanticLabel: l10n.computerRefreshTabs,
                  icon: Icons.refresh_rounded,
                  onPressed: () => setState(() {
                    _tabs = widget.service.browserTabs();
                  }),
                ),
                AdaptiveButton.icon(
                  useNative: false,
                  style: AdaptiveButtonStyle.plain,
                  semanticLabel: l10n.computerNewTab,
                  icon: Icons.add_rounded,
                  onPressed: widget.controlling
                      ? () => _choose(ComputerTabAction.create)
                      : null,
                ),
                AdaptiveButton.icon(
                  useNative: false,
                  style: AdaptiveButtonStyle.plain,
                  semanticLabel: l10n.close,
                  icon: Icons.close_rounded,
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            if (!widget.controlling) ...[
              Text(
                l10n.computerTabsWatchHint,
                style: TextStyle(color: theme.textSecondary),
              ),
              AdaptiveButton(
                useNative: false,
                label: l10n.computerTakeControl,
                onPressed: () => _choose(ComputerTabAction.control),
              ),
            ],
            const SizedBox(height: 12),
            FutureBuilder<List<ComputerBrowserTab>>(
              future: _tabs,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      l10n.computerTabsUnavailable,
                      textAlign: TextAlign.center,
                    ),
                  );
                }
                if (!snapshot.hasData) {
                  return const Padding(
                    padding: EdgeInsets.all(24),
                    child: AdaptiveProgressIndicator(),
                  );
                }
                final tabs = snapshot.requireData;
                if (tabs.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(l10n.computerNoTabs),
                  );
                }
                return ListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: tabs.length,
                  itemBuilder: (context, index) {
                    final tab = tabs[index];
                    final host = Uri.tryParse(tab.url)?.host ?? '';
                    final title = tab.title.isNotEmpty
                        ? tab.title
                        : host.isNotEmpty
                        ? host
                        : l10n.computerNewTab;
                    return Row(
                      children: [
                        Expanded(
                          child: AdaptiveButton.child(
                            style: AdaptiveButtonStyle.plain,
                            onPressed: widget.controlling
                                ? () =>
                                      _choose(ComputerTabAction.select, tab.id)
                                : null,
                            child: Row(
                              children: [
                                Icon(
                                  tab.id == widget.currentId
                                      ? Icons.check_circle_outline
                                      : Icons.language,
                                  size: 20,
                                  color: theme.textSecondary,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        title,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      if (host.isNotEmpty)
                                        Text(
                                          host,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: theme.textSecondary,
                                            fontSize: 12,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        AdaptiveButton.icon(
                          useNative: false,
                          style: AdaptiveButtonStyle.plain,
                          semanticLabel: '${l10n.computerCloseTab}: $title',
                          icon: Icons.close_rounded,
                          onPressed: widget.controlling
                              ? () => _choose(ComputerTabAction.close, tab.id)
                              : null,
                        ),
                      ],
                    );
                  },
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
