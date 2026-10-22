import 'package:conduit_core/models/response_animation.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/adaptive_selection_sheet.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/platform_ui/platform_ui.dart';
import '../../../shared/widgets/utility_components.dart';
import '../../chat/widgets/response_activity_indicator.dart';
import 'response_finish_preview.dart';

class ResponseAnimationSettings extends ConsumerWidget {
  const ResponseAnimationSettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final settings = ref.watch(appSettingsProvider);
    final notifier = ref.read(appSettingsProvider.notifier);
    return InsetGroupedList(
      title: l10n.responseAnimationsTitle,
      children: [
        _styleRow(
          context,
          settings,
          title: l10n.responseAnimationThinking,
          style: settings.thinkingIndicatorStyle,
          choices: ResponseIndicatorStyle.thinkingChoices,
          onSelected: notifier.setThinkingIndicatorStyle,
        ),
        _styleRow(
          context,
          settings,
          title: l10n.responseAnimationSkill,
          style: settings.skillIndicatorStyle,
          choices: ResponseIndicatorStyle.skillChoices,
          onSelected: notifier.setSkillIndicatorStyle,
        ),
        UtilityRow(
          title: l10n.responseAnimationFinishes,
          subtitle: _finishLabel(l10n, settings.responseFinishStyle),
          showChevron: true,
          leading: _finishPreview(
            context,
            settings,
            settings.responseFinishStyle,
          ),
          onTap: () async {
            final choice =
                await showCompactConfigurationSheet<ResponseFinishStyle>(
                  context,
                  (context) => _AnimationChoiceSheet<ResponseFinishStyle>(
                    title: l10n.responseAnimationFinishes,
                    initial: settings.responseFinishStyle,
                    choices: ResponseFinishStyle.values,
                    label: (value) => _finishLabel(l10n, value),
                    preview: (context, value, replay) => _finishPreview(
                      context,
                      settings,
                      value,
                      size: 48,
                      replayToken: replay,
                    ),
                  ),
                );
            if (choice != null &&
                choice != settings.responseFinishStyle &&
                context.mounted) {
              await notifier.setResponseFinishStyle(choice);
            }
          },
        ),
      ],
    );
  }

  Widget _styleRow(
    BuildContext context,
    AppSettings settings, {
    required String title,
    required ResponseIndicatorStyle style,
    required List<ResponseIndicatorStyle> choices,
    required Future<void> Function(ResponseIndicatorStyle) onSelected,
  }) => UtilityRow(
    title: title,
    subtitle: style.label,
    showChevron: true,
    leading: _preview(context, settings, style),
    onTap: () async {
      final choice =
          await showCompactConfigurationSheet<ResponseIndicatorStyle>(
            context,
            (context) => _AnimationChoiceSheet<ResponseIndicatorStyle>(
              title: title,
              initial: style,
              choices: choices,
              label: (value) => value.label,
              preview: (context, value, replay) => _preview(
                context,
                settings,
                value,
                size: 48,
                key: ValueKey(replay),
              ),
            ),
          );
      if (choice != null && choice != style && context.mounted) {
        await onSelected(choice);
      }
    },
  );

  Widget _preview(
    BuildContext context,
    AppSettings settings,
    ResponseIndicatorStyle style, {
    double size = 28,
    Key? key,
  }) => ExcludeSemantics(
    child: ResponseActivityIndicator(
      key: key,
      style: style,
      size: size,
      color: context.conduitTheme.iconPrimary,
      animate: !context.reduceMotion && !settings.reduceMotion,
      speed: settings.animationSpeed,
    ),
  );

  Widget _finishPreview(
    BuildContext context,
    AppSettings settings,
    ResponseFinishStyle style, {
    double size = 28,
    int replayToken = 0,
  }) => ResponseFinishPreview(
    style: style,
    size: size,
    replayToken: replayToken,
    indicatorStyle: settings.thinkingIndicatorStyle,
    color: context.conduitTheme.iconPrimary,
    animate: !context.reduceMotion && !settings.reduceMotion,
    speed: settings.animationSpeed,
  );
}

class _AnimationChoiceSheet<T> extends StatefulWidget {
  const _AnimationChoiceSheet({
    required this.title,
    required this.initial,
    required this.choices,
    required this.label,
    required this.preview,
  });

  final String title;
  final T initial;
  final List<T> choices;
  final String Function(T) label;
  final Widget Function(BuildContext, T, int) preview;

  @override
  State<_AnimationChoiceSheet<T>> createState() =>
      _AnimationChoiceSheetState<T>();
}

class _AnimationChoiceSheetState<T> extends State<_AnimationChoiceSheet<T>> {
  late T _selected = widget.initial;
  int _replay = 0;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .72,
        ),
        child: Column(
          key: const ValueKey('animation-choice-sheet'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                SizedBox.square(
                  key: const ValueKey('animation-choice-preview'),
                  dimension: 56,
                  child: Center(
                    child: widget.preview(context, _selected, _replay),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    widget.title,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final value in widget.choices)
                      ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 48),
                        child: AdaptiveSelectionTile(
                          title: widget.label(value),
                          selected: _selected == value,
                          onTap: () => setState(() {
                            _selected = value;
                            _replay++;
                          }),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  key: const ValueKey('animation-choice-cancel'),
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(l10n.cancel),
                ),
                const SizedBox(width: 12),
                ConduitButton(
                  key: const ValueKey('animation-choice-save'),
                  text: l10n.save,
                  isCompact: true,
                  onPressed: () => Navigator.of(context).pop(_selected),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

String _finishLabel(AppLocalizations l10n, ResponseFinishStyle style) =>
    switch (style) {
      ResponseFinishStyle.fade => l10n.responseAnimationFade,
      ResponseFinishStyle.shrink => l10n.responseAnimationShrink,
      ResponseFinishStyle.clear => l10n.responseAnimationClear,
    };
