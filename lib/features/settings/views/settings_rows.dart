import 'package:conduit_core/utils/profile_avatar.dart'
    show extractAvatarInitials;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';

import '../../../core/services/native_sheet_bridge.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/platform_ui/platform_ui.dart';
import '../../../shared/widgets/adaptive_date_time_picker.dart';
import '../../../shared/widgets/markdown/renderer/code_syntax_theme.dart';
import '../../../shared/widgets/platform_ui/vocabulary.dart';
import '../../../shared/widgets/user_avatar.dart';
import '../../../shared/widgets/utility_components.dart';
import 'settings_symbols.dart';

/// The leading glyph of a Settings row: its picture, its asset icon, or
/// the Material icon for its SF Symbol, in one fixed box so every title
/// starts at the same edge.
class SettingsRowGlyph extends StatelessWidget {
  const SettingsRowGlyph({super.key, required this.item, this.size});

  final NativeSheetItemConfig item;

  /// The glyph's side; the account card draws its picture larger.
  final double? size;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final side = size ?? IconSize.xl;
    final bytes = item.avatarBytes;
    if (bytes != null) {
      return ClipOval(
        child: Image.memory(
          bytes,
          width: side,
          height: side,
          fit: BoxFit.cover,
          gaplessPlayback: true,
        ),
      );
    }
    final avatarName = item.avatarName;
    if (avatarName != null) {
      // Its initials, as the native sheet draws them; the whole name does
      // not fit the circle.
      return UserAvatar(
        size: side,
        imageUrl: null,
        fallbackText: extractAvatarInitials(avatarName),
      );
    }
    final symbolColor = item.symbolColor;
    final color = item.destructive
        ? theme.error
        : symbolColor != null
        ? Color(symbolColor)
        : item.accent
        ? theme.buttonPrimary
        : theme.iconSecondary;
    final asset = item.iconAsset;
    return SizedBox.square(
      dimension: side,
      child: Center(
        child: asset != null
            ? Image.asset(
                asset,
                width: item.iconSize ?? IconSize.medium,
                height: item.iconSize ?? IconSize.medium,
                color: _assetTinted(asset) ? color : null,
              )
            : Icon(
                settingsMaterialIcon(item.sfSymbol),
                color: color,
                size: IconSize.medium,
              ),
      ),
    );
  }

  /// Monochrome marks take the row's tint; logos keep their colours.
  static bool _assetTinted(String asset) => asset.contains('hermes_agent');
}

/// What a row that opens, chooses or toggles something does. The page
/// decides: the same row may push a page, open a picker, or send a change.
typedef SettingsRowSelected = void Function(NativeSheetItemConfig item);

/// A row's control changed to [value].
typedef SettingsRowChanged = void Function(
  NativeSheetItemConfig item,
  Object? value,
);

/// One of a row's other actions was chosen from its menu.
typedef SettingsRowAction = void Function(NativeSheetRowAction action);

/// One Settings row, drawn for its [NativeSheetItemConfig.kind].
///
/// [value] is the row's value as the person last set it on this page, which
/// overrides the value the definition came with until the page is described
/// again -- as a switch keeps the position it was flipped to.
class SettingsRow extends StatelessWidget {
  const SettingsRow({
    super.key,
    required this.item,
    required this.navigable,
    required this.onSelected,
    required this.onChanged,
    this.value,
    this.textValue,
    this.onTextChanged,
    this.onTextSubmitted,
    this.leading,
    this.onAction,
    this.inactive = false,
  });

  final NativeSheetItemConfig item;

  /// Drawn in place of the row's own glyph, for a picture the definition
  /// cannot carry, such as the account card's photo.
  final Widget? leading;

  /// Whether a page with this row's id is known, so selecting it opens one.
  final bool navigable;
  final SettingsRowSelected onSelected;
  final SettingsRowChanged onChanged;
  final Object? value;
  final String? textValue;
  final ValueChanged<String>? onTextChanged;
  final VoidCallback? onTextSubmitted;

  /// Acts on one of the row's other actions ([NativeSheetItemConfig.rowActions]).
  final SettingsRowAction? onAction;

  /// Takes no taps, as while the page's Done is working.
  final bool inactive;

  Object? get _value => value ?? item.value;

  @override
  Widget build(BuildContext context) {
    final row = _buildRow(context);
    if (!item.disabled && !inactive) return row;
    // Waiting on another row's action, or on the page's Done, the row takes
    // no taps; one disabled outright is dimmed and read out as unavailable.
    return Semantics(
      enabled: !item.disabled,
      child: IgnorePointer(
        child: item.disabled ? Opacity(opacity: 0.4, child: row) : row,
      ),
    );
  }

  /// The row's other actions, in a menu at its trailing edge.
  Widget? _actionsMenu(BuildContext context) {
    final onAction = this.onAction;
    if (item.rowActions.isEmpty || onAction == null) return null;
    final l10n = AppLocalizations.of(context)!;
    return AdaptivePopupMenuButton.icon<String>(
      key: ValueKey<String>('settings-row-actions-${item.id}'),
      icon: Icons.more_vert,
      semanticLabel: l10n.more,
      iconColor: context.conduitTheme.iconSecondary,
      buttonStyle: PopupButtonStyle.plain,
      size: 40,
      items: [
        for (final action in item.rowActions)
          AdaptivePopupMenuItem<String>(
            label: action.label,
            icon: action.sfSymbol == null
                ? null
                : settingsMaterialIcon(action.sfSymbol!),
            isDestructive: action.destructive,
            value: action.id,
          ),
      ],
      onSelected: (index, _) => onAction(item.rowActions[index]),
    );
  }

  /// A small turning mark while the row's action runs.
  Widget? _pendingMark() => item.pending == true
      ? const SizedBox.square(
          dimension: 18,
          child: AdaptiveProgressIndicator(strokeWidth: 2),
        )
      : null;

  Widget _buildRow(BuildContext context) {
    return switch (item.kind) {
      NativeSheetItemKind.toggle => _buildToggle(context),
      NativeSheetItemKind.segment ||
      NativeSheetItemKind.dropdown ||
      NativeSheetItemKind.searchablePicker => _buildChoice(context),
      NativeSheetItemKind.slider => _SettingsSliderRow(
        item: item,
        value: _value,
        onChanged: onChanged,
      ),
      NativeSheetItemKind.textField ||
      NativeSheetItemKind.secureTextField ||
      NativeSheetItemKind.multilineTextField ||
      NativeSheetItemKind.code => _SettingsTextRow(
        item: item,
        value: textValue ?? (item.value is String ? item.value as String : ''),
        onChanged: onTextChanged,
        onSubmitted: onTextSubmitted,
      ),
      NativeSheetItemKind.info => _buildInfo(context),
      NativeSheetItemKind.readOnlyText => _buildReadOnlyText(context),
      NativeSheetItemKind.diffLine => _buildDiffLine(context),
      NativeSheetItemKind.appearanceTiles => _SettingsAppearanceTiles(
        item: item,
        selectedId: _value is String ? _value as String : null,
        onChanged: (id) => onChanged(item, id),
      ),
      NativeSheetItemKind.date ||
      NativeSheetItemKind.time => _buildDate(context),
      _ => _buildNavigation(context),
    };
  }

  /// A day or a time of day. Its value reads under the title, as a Material
  /// setting puts it; tapping opens the picker, and the choice goes back as
  /// the iOS row sends it.
  Widget _buildDate(BuildContext context) {
    final raw = _value is String ? _value as String : null;
    final current = raw == null ? null : DateTime.tryParse(raw);
    final time = item.kind == NativeSheetItemKind.time;
    final locale = Localizations.localeOf(context).toString();
    final format = time
        ? (MediaQuery.alwaysUse24HourFormatOf(context)
              ? DateFormat.Hm(locale)
              : DateFormat.jm(locale))
        : DateFormat.yMMMd(locale);
    final note = item.subtitle?.trim();
    final subtitle = [
      if (current != null) format.format(current),
      if (note != null && note.isNotEmpty) note,
    ].join('\n');
    return UtilityRow(
      key: ValueKey<String>('settings-row-${item.id}'),
      leading: SettingsRowGlyph(item: item),
      title: item.title,
      subtitle: subtitle.isEmpty ? null : subtitle,
      subtitleMaxLines: 6,
      showChevron: true,
      onTap: () => _pickDate(context, current ?? DateTime.now(), time: time),
    );
  }

  Future<void> _pickDate(
    BuildContext context,
    DateTime current, {
    required bool time,
  }) async {
    DateTime? bound(double? millis) => millis == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(millis.round());
    final DateTime? picked;
    if (time) {
      picked = await showAdaptiveTimeOfDayPicker(
        context,
        initial: current,
        title: item.title,
      );
    } else {
      final day = await showAdaptiveDatePicker(
        context,
        initial: current,
        first: bound(item.min) ?? DateTime(1900),
        last: bound(item.max) ?? DateTime(2100),
        title: item.title,
      );
      // A new day keeps the time of day the row held.
      picked = day == null
          ? null
          : DateTime(
              day.year,
              day.month,
              day.day,
              current.hour,
              current.minute,
            );
    }
    // The page may have closed while the picker was open.
    if (picked != null && context.mounted) {
      onChanged(item, nativeSheetDateValue(picked));
    }
  }

  Widget _buildNavigation(BuildContext context) {
    final theme = context.conduitTheme;
    final chevron =
        item.showsDisclosure ??
        (item.url != null || item.dismissOnSelect || navigable);
    final Widget? mark = item.checked
        ? Icon(Icons.check, color: theme.buttonPrimary, size: IconSize.medium)
        : item.url != null && item.showsDisclosure != true
        ? Icon(
            Icons.open_in_new,
            color: theme.iconSecondary,
            size: IconSize.small,
          )
        : null;
    final status = _pendingMark() ?? mark;
    final menu = _actionsMenu(context);
    // A row that opens a page and has a menu shows both: the chevron says
    // what a tap does, the menu what else the row offers.
    final trailing = _trailing([
      status,
      if (chevron && status == null && menu != null)
        Icon(
          context.usesCupertinoChrome
              ? CupertinoIcons.chevron_right
              : Icons.chevron_right,
          color: theme.iconSecondary,
          size: IconSize.small,
        ),
      menu,
    ]);
    return UtilityRow(
      key: ValueKey<String>('settings-row-${item.id}'),
      leading: leading ?? SettingsRowGlyph(item: item),
      title: item.title,
      subtitle: item.subtitle,
      destructive: item.destructive,
      titleFontWeight: item.usesProfileAvatar ? FontWeight.w600 : null,
      foregroundColor: item.accent && !item.destructive
          ? theme.buttonPrimary
          : null,
      selected: item.checked,
      trailing: trailing,
      preserveTrailingSemantics: item.rowActions.isNotEmpty,
      showChevron: chevron && trailing == null,
      onTap: () => onSelected(item),
    );
  }

  Widget _buildInfo(BuildContext context) {
    final theme = context.conduitTheme;
    return UtilityRow(
      key: ValueKey<String>('settings-row-${item.id}'),
      leading: SettingsRowGlyph(item: item),
      title: item.title,
      subtitle: item.subtitle,
      subtitleMaxLines: 12,
      destructive: item.destructive,
      hapticType: null,
      // The choice in use, as iOS marks it: a row with nothing to do.
      selected: item.checked,
      trailing: _trailing([
        _pendingMark() ??
            (item.checked
                ? Icon(
                    Icons.check,
                    color: theme.buttonPrimary,
                    size: IconSize.medium,
                  )
                : null),
        _actionsMenu(context),
      ]),
      preserveTrailingSemantics: item.rowActions.isNotEmpty,
    );
  }

  /// [parts] side by side at the row's trailing edge, or nothing.
  static Widget? _trailing(List<Widget?> parts) {
    final shown = parts.nonNulls.toList();
    if (shown.isEmpty) return null;
    if (shown.length == 1) return shown.single;
    return Row(mainAxisSize: MainAxisSize.min, children: shown);
  }

  Widget _buildToggle(BuildContext context) {
    final on = _value is bool ? _value as bool : false;
    void flip(bool next) => onChanged(item, next);
    return UtilityRow(
      key: ValueKey<String>('settings-row-${item.id}'),
      leading: SettingsRowGlyph(item: item),
      title: item.title,
      subtitle: item.subtitle,
      subtitleMaxLines: 8,
      toggled: on,
      trailing: AdaptiveSwitch(
        value: on,
        semanticLabel: item.title,
        onChanged: flip,
      ),
      onTap: () => flip(!on),
    );
  }

  /// A row that holds one of a few values. On Android its value reads under
  /// the title, as Material settings put it; choosing opens the picker.
  Widget _buildChoice(BuildContext context) {
    final selectedId = _value is String ? _value as String : null;
    final selected = item.options
        .where((option) => option.id == selectedId)
        .firstOrNull;
    // A picker row's subtitle often names the value too; say it once.
    final value = selected?.label;
    final note = item.subtitle?.trim();
    final subtitle = [
      ?value,
      if (note != null && note.isNotEmpty && note != value) note,
    ].join('\n');
    return UtilityRow(
      key: ValueKey<String>('settings-row-${item.id}'),
      leading: SettingsRowGlyph(item: item),
      title: item.title,
      subtitle: subtitle.isEmpty ? null : subtitle,
      subtitleMaxLines: 6,
      showChevron: item.kind == NativeSheetItemKind.searchablePicker,
      onTap: item.options.isEmpty ? null : () => onSelected(item),
    );
  }

  /// One line of a comparison: monospaced, a − or + in front, and a tinted
  /// band for a line removed or added. Screen readers read the row's
  /// subtitle, which says what happened to the line.
  Widget _buildDiffLine(BuildContext context) {
    final theme = context.conduitTheme;
    final change = item.value;
    final Color? tint = switch (change) {
      'added' => theme.success,
      'removed' => theme.error,
      _ => null,
    };
    final glyph = switch (change) {
      'added' => '+',
      'removed' => '\u2212',
      _ => ' ',
    };
    final style = (theme.code ?? AppTypography.bodyMediumStyle).copyWith(
      color: change == 'context' ? theme.textSecondary : theme.textPrimary,
    );
    return Semantics(
      key: ValueKey<String>('settings-row-${item.id}'),
      container: true,
      label: item.subtitle ?? item.title,
      excludeSemantics: true,
      child: ColoredBox(
        color: tint?.withValues(alpha: 0.14) ?? const Color(0x00000000),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.md,
            vertical: Spacing.xs,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                glyph,
                style: style.copyWith(color: tint ?? theme.textSecondary),
              ),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: Text(
                  item.title.isEmpty ? ' ' : item.title,
                  style: style,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildReadOnlyText(BuildContext context) {
    final theme = context.conduitTheme;
    final text = item.value is String && (item.value as String).isNotEmpty
        ? item.value as String
        : item.subtitle ?? '';
    return Padding(
      key: ValueKey<String>('settings-row-${item.id}'),
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.md,
        vertical: Spacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (item.title.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: Spacing.xs),
              child: Text(
                item.title,
                style: AppTypography.bodySmallStyle.copyWith(
                  color: theme.textSecondary,
                ),
              ),
            ),
          Text(
            text,
            style: AppTypography.bodyMediumStyle.copyWith(
              color: theme.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingsSliderRow extends StatefulWidget {
  const _SettingsSliderRow({
    required this.item,
    required this.value,
    required this.onChanged,
  });

  final NativeSheetItemConfig item;
  final Object? value;
  final SettingsRowChanged onChanged;

  @override
  State<_SettingsSliderRow> createState() => _SettingsSliderRowState();
}

class _SettingsSliderRowState extends State<_SettingsSliderRow> {
  double? _dragging;

  double get _min => widget.item.min ?? 0;
  double get _max => widget.item.max ?? 1;

  double get _committed {
    final raw = widget.value;
    final number = raw is num ? raw.toDouble() : double.tryParse('$raw');
    return (number ?? _min).clamp(_min, _max);
  }

  /// The value as the native slider labels it: seconds for the silence
  /// wait, two decimals otherwise.
  String _label(double value) => widget.item.id == 'stt-silence-duration'
      ? '${(value / 1000).toStringAsFixed(1)}s'
      : value.toStringAsFixed(2);

  double _snapped(double value) {
    final divisions = widget.item.divisions;
    if (divisions == null || divisions <= 0) return value;
    final step = (_max - _min) / divisions;
    return (_min + ((value - _min) / step).round() * step).clamp(_min, _max);
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final value = _dragging ?? _committed;
    final divisions = widget.item.divisions;
    return Padding(
      key: ValueKey<String>('settings-row-${widget.item.id}'),
      padding: const EdgeInsets.fromLTRB(
        Spacing.md,
        Spacing.sm,
        Spacing.md,
        Spacing.xs,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.item.title,
                  style: AppTypography.bodyLargeStyle.copyWith(
                    color: theme.textPrimary,
                  ),
                ),
              ),
              Text(
                _label(value),
                style: AppTypography.bodyMediumStyle.copyWith(
                  color: theme.textSecondary,
                ),
              ),
            ],
          ),
          if (widget.item.subtitle != null)
            Text(
              widget.item.subtitle!,
              style: AppTypography.bodySmallStyle.copyWith(
                color: theme.textSecondary,
              ),
            ),
          AdaptiveSlider(
            value: value,
            min: _min,
            max: _max,
            divisions: divisions != null && divisions > 0 ? divisions : null,
            semanticLabel: widget.item.title,
            semanticValue: _label(value),
            onChanged: (next) => setState(() => _dragging = next),
            onChangeEnd: (next) {
              final snapped = _snapped(next);
              setState(() => _dragging = null);
              widget.onChanged(widget.item, snapped);
            },
          ),
        ],
      ),
    );
  }
}

/// A text row. Its text is a draft until the page commits it, as the native
/// sheet keeps one until Done.
class _SettingsTextRow extends StatefulWidget {
  const _SettingsTextRow({
    required this.item,
    required this.value,
    this.onChanged,
    this.onSubmitted,
  });

  final NativeSheetItemConfig item;
  final String value;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onSubmitted;

  @override
  State<_SettingsTextRow> createState() => _SettingsTextRowState();
}

class _SettingsTextRowState extends State<_SettingsTextRow> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.value,
  );
  bool _obscured = true;

  @override
  void didUpdateWidget(covariant _SettingsTextRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != _controller.text) {
      _controller.value = TextEditingValue(
        text: widget.value,
        selection: TextSelection.collapsed(offset: widget.value.length),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final item = widget.item;
    final secure = item.kind == NativeSheetItemKind.secureTextField;
    final code = item.kind == NativeSheetItemKind.code;
    final multiline =
        code || item.kind == NativeSheetItemKind.multilineTextField;
    final keyboard = item.keyboard;
    // Code fills the room the page has above the keyboard, a line at a time.
    final codeLines = code
        ? ((MediaQuery.sizeOf(context).height -
                      MediaQuery.viewInsetsOf(context).bottom -
                      220) /
                  CodeSyntaxTheme.lineHeight)
              .floor()
              .clamp(8, 400)
        : 0;
    return Padding(
      key: ValueKey<String>('settings-row-${item.id}'),
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.md,
        vertical: Spacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (item.title.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: Spacing.xs),
              child: Text(
                item.title,
                style: AppTypography.bodySmallStyle.copyWith(
                  color: theme.textSecondary,
                ),
              ),
            ),
          AdaptiveTextField(
            controller: _controller,
            placeholder: item.placeholder ?? item.title,
            obscureText: secure && _obscured,
            // Code is typed as is.
            autocorrect: !code && !secure && keyboard == null,
            enableSuggestions: !code && !secure && keyboard == null,
            // The account's own password is AutoFill's to fill and save;
            // any other secret (a key, a token) is kept out of it, and an
            // ordinary field is left for the platform to judge.
            autofillHints: switch (item.passwordRole) {
              NativeSheetPasswordRole.current => const [AutofillHints.password],
              NativeSheetPasswordRole.newPassword => const [
                AutofillHints.newPassword,
              ],
              null when secure => null,
              null => const <String>[],
            },
            readOnly: code && item.disabled,
            style: code
                ? CodeSyntaxTheme.monospace(
                    AppTypography.bodyMediumStyle.copyWith(
                      fontSize: CodeSyntaxTheme.fontSize,
                      height:
                          CodeSyntaxTheme.lineHeight / CodeSyntaxTheme.fontSize,
                      color: theme.textPrimary,
                    ),
                    Theme.of(context).platform,
                  )
                : null,
            minLines: code
                ? codeLines
                : multiline
                ? 3
                : 1,
            maxLines: code
                ? null
                : multiline
                ? 12
                : 1,
            keyboardType: multiline
                ? TextInputType.multiline
                : switch (keyboard) {
                    NativeSheetKeyboard.url => TextInputType.url,
                    NativeSheetKeyboard.email => TextInputType.emailAddress,
                    NativeSheetKeyboard.number => TextInputType.number,
                    NativeSheetKeyboard.decimal =>
                      const TextInputType.numberWithOptions(
                        signed: true,
                        decimal: true,
                      ),
                    null => null,
                  },
            textInputAction: multiline
                ? TextInputAction.newline
                : TextInputAction.done,
            suffixIcon: secure
                ? GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => setState(() => _obscured = !_obscured),
                    child: Icon(
                      _obscured
                          ? Icons.visibility_outlined
                          : Icons.visibility_off,
                      color: theme.iconSecondary,
                      size: IconSize.medium,
                    ),
                  )
                : null,
            onChanged: widget.onChanged,
            onSubmitted: multiline ? null : (_) => widget.onSubmitted?.call(),
          ),
          if (item.subtitle != null && item.subtitle!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: Spacing.xs),
              child: Text(
                item.subtitle!,
                style: AppTypography.bodySmallStyle.copyWith(
                  color: theme.textSecondary,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// System, Light and Dark as small screens painted in each option's
/// swatches, with the chosen one marked.
class _SettingsAppearanceTiles extends StatelessWidget {
  const _SettingsAppearanceTiles({
    required this.item,
    required this.selectedId,
    required this.onChanged,
  });

  final NativeSheetItemConfig item;
  final String? selectedId;
  final ValueChanged<String> onChanged;

  void _choose(String id) {
    HapticFeedback.selectionClick();
    onChanged(id);
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return Padding(
      key: ValueKey<String>('settings-row-${item.id}'),
      padding: const EdgeInsets.all(Spacing.md),
      child: Row(
        children: [
          for (final option in item.options)
            Expanded(
              // The tap is the node's own action too: the node stands in for
              // the tile, whose own semantics it leaves out.
              child: Semantics(
                button: true,
                selected: option.id == selectedId,
                label: option.label,
                excludeSemantics: true,
                onTap: () => _choose(option.id),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _choose(option.id),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: Spacing.xs),
                    child: Column(
                      children: [
                        _AppearancePreview(
                          swatches: option.swatches ?? const [],
                          darkSwatches: option.darkSwatches,
                          selected: option.id == selectedId,
                        ),
                        const SizedBox(height: Spacing.sm),
                        Text(
                          option.label,
                          textAlign: TextAlign.center,
                          style: AppTypography.bodySmallStyle.copyWith(
                            color: theme.textPrimary,
                          ),
                        ),
                        const SizedBox(height: Spacing.xs),
                        Icon(
                          option.id == selectedId
                              ? Icons.check_circle
                              : Icons.circle_outlined,
                          size: IconSize.medium,
                          color: option.id == selectedId
                              ? theme.buttonPrimary
                              : theme.iconSecondary,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A miniature screen: background, a line of ink, a card, its border, in
/// the order [nativeSchemePreviewSwatches] gives them. System, which
/// carries both sets, shows light and dark side by side.
class _AppearancePreview extends StatelessWidget {
  const _AppearancePreview({
    required this.swatches,
    required this.darkSwatches,
    required this.selected,
  });

  final List<int> swatches;
  final List<int>? darkSwatches;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final dark = darkSwatches;
    final radius = BorderRadius.circular(AppBorderRadius.md);
    return AspectRatio(
      aspectRatio: 0.72,
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          borderRadius: radius,
          border: Border.all(
            color: selected ? theme.buttonPrimary : theme.dividerColor,
            width: selected ? 2 : 1,
          ),
        ),
        child: ClipRRect(
          borderRadius: radius,
          child: dark == null
              ? _PreviewScreen(swatches: swatches)
              : Row(
                  children: [
                    Expanded(child: _PreviewScreen(swatches: swatches)),
                    Expanded(child: _PreviewScreen(swatches: dark)),
                  ],
                ),
        ),
      ),
    );
  }
}

class _PreviewScreen extends StatelessWidget {
  const _PreviewScreen({required this.swatches});

  final List<int> swatches;

  Color _at(int index, Color fallback) =>
      index < swatches.length ? Color(swatches[index]) : fallback;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final border = _at(3, theme.dividerColor);
    return ColoredBox(
      color: _at(0, theme.groupedSurface),
      child: Padding(
        padding: const EdgeInsets.all(Spacing.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            FractionallySizedBox(
              widthFactor: 0.6,
              child: Container(height: 4, color: _at(1, theme.textPrimary)),
            ),
            const SizedBox(height: Spacing.xs),
            Expanded(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: _at(2, theme.groupedBackground),
                  borderRadius: BorderRadius.circular(AppBorderRadius.sm),
                  border: Border.all(color: border),
                ),
                child: const SizedBox.expand(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
