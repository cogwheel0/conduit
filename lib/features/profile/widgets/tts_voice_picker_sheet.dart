import 'package:flutter/widgets.dart';

import '../../../core/utils/tts_voice_utils.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/adaptive_selection_sheet.dart';
import '../../../shared/widgets/platform_ui/platform_ui.dart';

/// Voice search and language filtering are local to an open picker.
class TtsVoicePickerSheet extends StatefulWidget {
  const TtsVoicePickerSheet({
    super.key,
    required this.voices,
    required this.selectedId,
  });

  final List<TtsVoiceOptionData> voices;
  final String selectedId;

  @override
  State<TtsVoicePickerSheet> createState() => _TtsVoicePickerSheetState();
}

class _TtsVoicePickerSheetState extends State<TtsVoicePickerSheet> {
  String? _language;
  String _query = '';

  /// Language filtering retains the selected unknown-language voice; search always applies.
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final languages = widget.voices
        .map((voice) => ttsVoiceLanguageLabel(voice.voice))
        .whereType<String>()
        .toSet()
        .toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    bool matchesSearch(String value) => value.toLowerCase().contains(_query);
    final showsDefault = matchesSearch(l10n.ttsSystemDefault);
    final voices = widget.voices.where((voice) {
      final language = ttsVoiceLanguageLabel(voice.voice);
      return (_language == null ||
              language == _language ||
              (language == null && voice.id == widget.selectedId)) &&
          (matchesSearch(voice.label) ||
              matchesSearch(voice.id) ||
              matchesSearch(voice.subtitle ?? ''));
    }).toList();

    final languageItems = [
      AdaptivePopupMenuItem<String?>(
        label: l10n.ttsAllLanguages,
        value: null,
        checked: _language == null,
      ),
      for (final language in languages)
        AdaptivePopupMenuItem<String?>(
          label: language,
          value: language,
          checked: _language == language,
        ),
    ];
    void selectLanguage(int _, AdaptivePopupMenuItem<String?> item) =>
        setState(() => _language = item.value);

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: AdaptiveSelectionSheet(
        title: l10n.ttsSelectVoice,
        initialChildSize: 0.68,
        minChildSize: 0.42,
        maxChildSize: 0.9,
        itemCount: voices.length + (showsDefault ? 1 : 0),
        itemBuilder: (context, index) {
          final voice = showsDefault && index == 0
              ? null
              : voices[index - (showsDefault ? 1 : 0)];
          final id = voice?.id ?? ttsSystemDefaultVoiceId;
          return AdaptiveSelectionTile(
            title: voice?.label ?? l10n.ttsSystemDefault,
            subtitle: voice?.subtitle,
            selected: widget.selectedId == id,
            onTap: () => Navigator.of(context).pop(id),
          );
        },
        bottom: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: Spacing.sm),
            Semantics(
              label: l10n.language,
              button: true,
              child: PlatformUiCapabilities.isIOS
                  ? AdaptivePopupMenuButton.text<String?>(
                      key: const Key('tts-voice-language-filter'),
                      label: _language ?? l10n.ttsAllLanguages,
                      buttonStyle: PopupButtonStyle.glass,
                      shrinkWrap: true,
                      items: languageItems,
                      onSelected: selectLanguage,
                    )
                  : AdaptivePopupMenuButton.widget<String?>(
                      key: const Key('tts-voice-language-filter'),
                      items: languageItems,
                      onSelected: selectLanguage,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: ShapeDecoration(
                          color: context.conduitTheme.inputBackground,
                          shape: const StadiumBorder(),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(_language ?? l10n.ttsAllLanguages),
                            const SizedBox(width: 6),
                            Icon(
                              cupertinoIconForSFSymbol('chevron.down'),
                              size: 14,
                            ),
                          ],
                        ),
                      ),
                    ),
            ),
            const SizedBox(height: Spacing.xs),
            AdaptiveTextField(
              key: const Key('tts-voice-search'),
              placeholder: l10n.ttsSearchVoices,
              prefixIcon: Icon(cupertinoIconForSFSymbol('magnifyingglass')),
              onChanged: (value) =>
                  setState(() => _query = value.trim().toLowerCase()),
            ),
          ],
        ),
      ),
    );
  }
}
