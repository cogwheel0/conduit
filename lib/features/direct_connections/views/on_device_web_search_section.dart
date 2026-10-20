import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit_core/features/web_search/web_search.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/adaptive_selection_sheet.dart';
import '../../../shared/widgets/utility_components.dart';

/// Engine, safe-search and region settings for the web search Conduit runs
/// on the device for Direct models without a provider-hosted search tool.
class OnDeviceWebSearchSettingsSection extends ConsumerWidget {
  const OnDeviceWebSearchSettingsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final settings = ref.watch(appSettingsProvider);
    final region = ref.watch(webSearchRegionProvider);
    final engine = settings.webSearchEngine.engine;
    final regionName = _regionName(l10n, region);
    final titleWeight = PlatformInfo.isIOS ? FontWeight.w400 : null;

    return InsetGroupedList(
      title: l10n.webSearch,
      footer: engine == null
          ? l10n.webSearchSettingsFooterAuto
          : l10n.webSearchSettingsFooterEngine(engine.displayName),
      useNativeSurface: PlatformInfo.isIOS,
      children: [
        UtilityRow(
          key: const ValueKey<String>('web-search-engine'),
          title: l10n.webSearchEngineLabel,
          subtitle: _engineLabel(l10n, settings.webSearchEngine),
          titleFontWeight: titleWeight,
          showChevron: true,
          onTap: () => _pickEngine(context, ref, settings.webSearchEngine),
        ),
        UtilityRow(
          key: const ValueKey<String>('web-search-safe-search'),
          title: l10n.webSearchSafeSearchLabel,
          subtitle: _safeSearchLabel(l10n, settings.webSearchSafeSearch),
          titleFontWeight: titleWeight,
          showChevron: true,
          onTap: () =>
              _pickSafeSearch(context, ref, settings.webSearchSafeSearch),
        ),
        UtilityRow(
          key: const ValueKey<String>('web-search-region'),
          title: l10n.webSearchRegionLabel,
          subtitle: settings.webSearchRegion == null
              ? '${l10n.webSearchRegionAuto} ($regionName)'
              : regionName,
          titleFontWeight: titleWeight,
          showChevron: true,
          onTap: () => _pickRegion(context, ref, settings.webSearchRegion),
        ),
      ],
    );
  }

  Future<void> _pickEngine(
    BuildContext context,
    WidgetRef ref,
    WebSearchEngineChoice current,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    const choices = WebSearchEngineChoice.values;
    final selected = await showAdaptiveSelectionSheet<WebSearchEngineChoice>(
      context: context,
      builder: (sheetContext) => AdaptiveSelectionSheet(
        title: l10n.webSearchEngineLabel,
        itemCount: choices.length,
        itemBuilder: (context, index) {
          final choice = choices[index];
          return AdaptiveSelectionTile(
            title: _engineLabel(l10n, choice),
            selected: choice == current,
            onTap: () => Navigator.of(sheetContext).pop(choice),
          );
        },
      ),
    );
    if (selected != null) {
      await ref.read(appSettingsProvider.notifier).setWebSearchEngine(selected);
    }
  }

  Future<void> _pickSafeSearch(
    BuildContext context,
    WidgetRef ref,
    SafeSearch current,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    const levels = SafeSearch.values;
    final selected = await showAdaptiveSelectionSheet<SafeSearch>(
      context: context,
      builder: (sheetContext) => AdaptiveSelectionSheet(
        title: l10n.webSearchSafeSearchLabel,
        itemCount: levels.length,
        itemBuilder: (context, index) {
          final level = levels[index];
          return AdaptiveSelectionTile(
            title: _safeSearchLabel(l10n, level),
            selected: level == current,
            onTap: () => Navigator.of(sheetContext).pop(level),
          );
        },
      ),
    );
    if (selected != null) {
      await ref
          .read(appSettingsProvider.notifier)
          .setWebSearchSafeSearch(selected);
    }
  }

  Future<void> _pickRegion(
    BuildContext context,
    WidgetRef ref,
    String? current,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final codes = [
      kWebSearchRegionAuto,
      SearchRegion.worldwide.code,
      for (final option in kWebSearchRegions) option.code,
    ];
    final currentCode = current ?? kWebSearchRegionAuto;
    final selected = await showAdaptiveSelectionSheet<String>(
      context: context,
      builder: (sheetContext) => AdaptiveSelectionSheet(
        title: l10n.webSearchRegionLabel,
        initialChildSize: 0.7,
        itemCount: codes.length,
        itemBuilder: (context, index) {
          final code = codes[index];
          return AdaptiveSelectionTile(
            title: code == kWebSearchRegionAuto
                ? l10n.webSearchRegionAuto
                : _regionName(l10n, SearchRegion(code)),
            selected: code == currentCode,
            onTap: () => Navigator.of(sheetContext).pop(code),
          );
        },
      ),
    );
    if (selected != null) {
      await ref.read(appSettingsProvider.notifier).setWebSearchRegion(selected);
    }
  }
}

String _engineLabel(AppLocalizations l10n, WebSearchEngineChoice choice) =>
    choice.engine?.displayName ?? l10n.webSearchEngineAuto;

String _safeSearchLabel(AppLocalizations l10n, SafeSearch level) =>
    switch (level) {
      SafeSearch.strict => l10n.webSearchSafeSearchStrict,
      SafeSearch.moderate => l10n.webSearchSafeSearchModerate,
      SafeSearch.off => l10n.webSearchSafeSearchOff,
    };

String _regionName(AppLocalizations l10n, SearchRegion region) {
  if (region.isWorldwide) return l10n.webSearchRegionWorldwide;
  for (final option in kWebSearchRegions) {
    if (option.code == region.code) return option.name;
  }
  return region.code;
}
