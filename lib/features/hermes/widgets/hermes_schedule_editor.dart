import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:conduit_core/features/hermes/models/hermes_job.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/features/hermes/utils/hermes_schedule_validation.dart';
import 'package:conduit_core/utils/unicode_prefix.dart';

import '../../../l10n/app_localizations.dart';
import '../../../l10n/app_localizations_en.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/platform_ui/platform_ui.dart';
import '../../../shared/widgets/sheet_handle.dart';
import '../../../shared/widgets/themed_sheets.dart';

AppLocalizations _labels(BuildContext context) =>
    AppLocalizations.of(context) ?? AppLocalizationsEn();

/// Schedule ownership follows the invoking workspace through nested sheets.
final hermesScheduleProfileProvider = Provider<String?>((ref) => null);

enum HermesScheduleRepeat { daily, weekdays, weekly, once, custom }

/// Unrecognized or zone-bearing expressions retain their exact editable value.
class HermesScheduleTiming {
  HermesScheduleTiming([String? expression]) {
    custom = expression ?? '';
    if (expression == null) return;
    repeat = HermesScheduleRepeat.custom;
    final parts = expression.trim().split(RegExp(r'\s+'));
    if (parts.length != 5 || parts[2] != '*' || parts[3] != '*') return;
    final hour = int.tryParse(parts[1]), minute = int.tryParse(parts[0]);
    if (hour == null ||
        minute == null ||
        hour < 0 ||
        hour > 23 ||
        minute < 0 ||
        minute > 59) {
      return;
    }
    if (parts[4] == '*') {
      repeat = HermesScheduleRepeat.daily;
    } else if (parts[4] == '1-5' || parts[4].toUpperCase() == 'MON-FRI') {
      repeat = HermesScheduleRepeat.weekdays;
    } else {
      final value = int.tryParse(parts[4]);
      if (value == null || value < 0 || value > 7) return;
      repeat = HermesScheduleRepeat.weekly;
      day = value % 7;
    }
    time = TimeOfDay(hour: hour, minute: minute);
  }
  HermesScheduleRepeat repeat = HermesScheduleRepeat.daily;
  TimeOfDay time = const TimeOfDay(hour: 8, minute: 0);
  int day = 1;
  DateTime date = DateTime.now().add(const Duration(days: 1));
  String custom = '';
  String get expression => switch (repeat) {
    HermesScheduleRepeat.daily => '${time.minute} ${time.hour} * * *',
    HermesScheduleRepeat.weekdays => '${time.minute} ${time.hour} * * 1-5',
    HermesScheduleRepeat.weekly => '${time.minute} ${time.hour} * * $day',
    HermesScheduleRepeat.once =>
      '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}T${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}:00',
    HermesScheduleRepeat.custom => custom,
  };
}

/// All schedule sheets share the recently updated app presenter and its swipe,
/// coverage, root-navigation, and reduced-motion behavior.
Future<T?> showHermesScheduleSheet<T>(
  BuildContext context,
  Widget child, {
  bool editor = false,
  double? heightFraction,
}) async {
  final guard = ValueNotifier(true);
  final container = ProviderScope.containerOf(context, listen: false);
  try {
    return await ThemedSheets.showAdaptive<T>(
      context: context,
      canDismiss: guard,
      builder: (context) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SafeArea(
          top: false,
          child: SizedBox(
            height:
                (MediaQuery.sizeOf(context).height *
                            (heightFraction ?? (editor ? .9 : .72)) -
                        MediaQuery.viewInsetsOf(context).bottom)
                    .clamp(160.0, MediaQuery.sizeOf(context).height * .9),
            child: UncontrolledProviderScope(
              container: container,
              child: HermesScheduleDismissScope(guard: guard, child: child),
            ),
          ),
        ),
      ),
    );
  } finally {
    guard.dispose();
  }
}

class HermesScheduleDismissScope extends InheritedWidget {
  const HermesScheduleDismissScope({
    super.key,
    required this.guard,
    required super.child,
  });
  final ValueNotifier<bool> guard;
  static void allow(BuildContext context, bool value) {
    context
            .getInheritedWidgetOfExactType<HermesScheduleDismissScope>()
            ?.guard
            .value =
        value;
  }

  @override
  bool updateShouldNotify(HermesScheduleDismissScope oldWidget) =>
      guard != oldWidget.guard;
}

class HermesScheduleSheetFrame extends StatelessWidget {
  const HermesScheduleSheetFrame({
    super.key,
    required this.title,
    required this.body,
    this.actions = const [],
    this.footer,
  });
  final String title;
  final Widget body;
  final List<Widget> actions;
  final Widget? footer;
  @override
  Widget build(BuildContext context) => Column(
    children: [
      const SheetHandle(),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            CompactIconAction(
              tooltip: _labels(context).close,
              icon: const Icon(Icons.close_rounded),
              onPressed: () => Navigator.of(context).maybePop(),
            ),
            Expanded(
              child: Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            ...actions,
          ],
        ),
      ),
      Expanded(child: body),
      if (footer != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
          child: footer!,
        ),
    ],
  );
}

Future<bool?> showHermesScheduleEditor(
  BuildContext context, {
  HermesJob? job,
}) => showHermesScheduleSheet<bool>(
  context,
  HermesScheduleEditor(job: job),
  editor: true,
);

class HermesScheduleEditor extends ConsumerStatefulWidget {
  const HermesScheduleEditor({super.key, this.job});
  final HermesJob? job;
  @override
  ConsumerState<HermesScheduleEditor> createState() =>
      _HermesScheduleEditorState();
}

class _HermesScheduleEditorState extends ConsumerState<HermesScheduleEditor> {
  late final _name = TextEditingController(text: widget.job?.name ?? '');
  late final _instructions = TextEditingController(
    text: widget.job?.prompt ?? '',
  );
  late final _custom = TextEditingController(text: widget.job?.schedule ?? '');
  late final _timing = HermesScheduleTiming(widget.job?.schedule);
  late final _skills = <String>[...?widget.job?.skills];
  late final _service = ref.read(hermesApiServiceProvider);
  bool _busy = false, _failed = false;
  bool get _current => identical(ref.read(hermesApiServiceProvider), _service);
  bool get _hasScript => widget.job?.script?.isNotEmpty == true;
  bool get _scriptOnly => _hasScript && widget.job?.noAgent == true;
  bool get _valid =>
      _current &&
      _name.text.runes.length <= kMaxHermesJobNameCharacters &&
      _instructions.text.runes.length <= kMaxHermesJobPromptCharacters &&
      (_hasScript ||
          _skills.isNotEmpty ||
          _instructions.text.trim().isNotEmpty) &&
      _timing.expression.length <= kMaxHermesJobScheduleCharacters &&
      isValidHermesSchedule(_timing.expression);
  @override
  void dispose() {
    _name.dispose();
    _instructions.dispose();
    _custom.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy || !_valid || _service == null) return;
    HermesScheduleDismissScope.allow(context, false);
    setState(() {
      _busy = true;
      _failed = false;
    });
    final fallback = _hasScript
        ? widget.job!.script!
        : _skills.isNotEmpty
        ? _skills.first
        : _instructions.text.trim().replaceAll(RegExp(r'\s+'), ' ');
    final name = _name.text.trim().isEmpty
        ? takeUnicodeScalarPrefix(fallback, kMaxHermesJobNameCharacters)
        : _name.text.trim();
    try {
      final controller = ref.read(hermesJobsProvider.notifier);
      final skills = _service is HermesDesktopApiService
          ? List<String>.of(_skills)
          : null;
      if (widget.job == null) {
        await controller.create(
          name: name,
          prompt: _instructions.text.trim(),
          schedule: _timing.expression.trim(),
          skills: skills,
        );
      } else {
        await controller.edit(
          widget.job!.id,
          name: name,
          prompt: _instructions.text.trim(),
          schedule: _timing.expression.trim(),
          skills: skills,
        );
      }
      if (mounted && _current) {
        HermesScheduleDismissScope.allow(context, true);
        Navigator.of(context).pop(true);
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) {
        HermesScheduleDismissScope.allow(context, true);
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _chooseSkills() async {
    final selected = await showHermesScheduleSheet<List<String>>(
      context,
      HermesScheduleSkillPicker(selected: _skills),
    );
    if (!mounted || selected == null || !_current) return;
    setState(() {
      _skills
        ..clear()
        ..addAll(selected);
    });
  }

  Future<void> _chooseTime() async {
    final value = await showTimePicker(
      context: context,
      initialTime: _timing.time,
    );
    if (mounted && value != null) setState(() => _timing.time = value);
  }

  Future<void> _chooseDate() async {
    final value = await showDatePicker(
      context: context,
      initialDate: _timing.date,
      firstDate: DateTime.now().subtract(const Duration(days: 1)),
      lastDate: DateTime(2100),
    );
    if (mounted && value != null) setState(() => _timing.date = value);
  }

  Widget _label(String value) => Padding(
    padding: const EdgeInsets.only(top: 20, bottom: 8),
    child: Text(value, style: Theme.of(context).textTheme.titleSmall),
  );
  @override
  Widget build(BuildContext context) {
    final l10n = _labels(context);
    final material = MaterialLocalizations.of(context);
    final writable =
        _current &&
        (ref.watch(hermesCapabilitiesProvider).asData?.value.jobsAdmin ?? true);
    return PopScope(
      canPop: !_busy,
      child: HermesScheduleSheetFrame(
        title: widget.job == null ? l10n.scheduleNew : l10n.scheduleEdit,
        body: AbsorbPointer(
          absorbing: _busy || !writable,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
            children: [
              ConduitInput(
                key: const ValueKey('schedule-name'),
                label: '${l10n.name} (${l10n.scheduleOptional})',
                hint: l10n.scheduleNameHint,
                controller: _name,
                onChanged: (_) => setState(() {}),
                errorText: _name.text.runes.length > kMaxHermesJobNameCharacters
                    ? l10n.hermesJobTooLong(kMaxHermesJobNameCharacters)
                    : null,
              ),
              _label(l10n.scheduleWhen),
              DropdownButtonFormField<HermesScheduleRepeat>(
                key: const ValueKey('schedule-repeat'),
                initialValue: _timing.repeat,
                isExpanded: true,
                decoration: const InputDecoration(),
                items: [
                  for (final value in HermesScheduleRepeat.values)
                    DropdownMenuItem(
                      value: value,
                      child: Text(switch (value) {
                        HermesScheduleRepeat.daily => l10n.scheduleDaily,
                        HermesScheduleRepeat.weekdays => l10n.scheduleWeekdays,
                        HermesScheduleRepeat.weekly => l10n.scheduleWeekly,
                        HermesScheduleRepeat.once => l10n.scheduleOnce,
                        HermesScheduleRepeat.custom => l10n.scheduleCustom,
                      }),
                    ),
                ],
                onChanged: (value) {
                  if (value != null) setState(() => _timing.repeat = value);
                },
              ),
              AnimatedSize(
                duration: context.motionDuration(
                  AnimationDuration.microInteraction,
                ),
                curve: Curves.easeOutCubic,
                alignment: Alignment.topCenter,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_timing.repeat == HermesScheduleRepeat.custom) ...[
                      const SizedBox(height: 12),
                      ConduitInput(
                        key: const ValueKey('schedule-expression'),
                        label: l10n.scheduleExpression,
                        hint: l10n.hermesJobScheduleHint,
                        controller: _custom,
                        onChanged: (value) =>
                            setState(() => _timing.custom = value),
                        errorText: isValidHermesSchedule(_custom.text)
                            ? null
                            : l10n.hermesJobScheduleInvalid,
                      ),
                    ] else ...[
                      if (_timing.repeat == HermesScheduleRepeat.weekly) ...[
                        const SizedBox(height: 12),
                        DropdownButtonFormField<int>(
                          key: const ValueKey('schedule-day'),
                          initialValue: _timing.day,
                          isExpanded: true,
                          decoration: InputDecoration(
                            labelText: l10n.scheduleDay,
                          ),
                          items: [
                            for (var i = 0; i < 7; i++)
                              DropdownMenuItem(
                                value: i,
                                child: Text(
                                  material
                                      .formatFullDate(DateTime(2026, 1, 4 + i))
                                      .split(',')
                                      .first,
                                ),
                              ),
                          ],
                          onChanged: (value) {
                            if (value != null) {
                              setState(() => _timing.day = value);
                            }
                          },
                        ),
                      ],
                      if (_timing.repeat == HermesScheduleRepeat.once)
                        CompactContentRow(
                          surface: true,
                          title: Text(l10n.scheduleDate),
                          subtitle: Text(
                            material.formatMediumDate(_timing.date),
                          ),
                          trailing: const Icon(Icons.calendar_today_outlined),
                          onTap: _chooseDate,
                        ),
                      CompactContentRow(
                        key: const ValueKey('schedule-time'),
                        surface: true,
                        title: Text(l10n.scheduleTime),
                        subtitle: Text(material.formatTimeOfDay(_timing.time)),
                        trailing: const Icon(Icons.schedule_rounded),
                        onTap: _chooseTime,
                      ),
                    ],
                  ],
                ),
              ),
              Text(
                l10n.scheduleTimezone,
                style: TextStyle(
                  color: context.conduitTheme.textSecondary,
                  fontSize: 12,
                ),
              ),
              _label(l10n.scheduleWhat),
              if (_hasScript) ...[
                CompactContentRow(
                  surface: true,
                  title: Text(l10n.scheduleScript),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => showHermesScheduleSkillDetail(
                    context,
                    l10n.scheduleScript,
                    widget.job!.script,
                  ),
                ),
                const SizedBox(height: 16),
              ],
              if (!_scriptOnly && _service is HermesDesktopApiService) ...[
                Text(
                  l10n.scheduleWhatHint,
                  style: TextStyle(
                    color: context.conduitTheme.textSecondary,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 8),
                CompactContentRow(
                  key: const ValueKey('schedule-skills'),
                  surface: true,
                  title: Text(
                    _skills.isEmpty
                        ? l10n.scheduleChooseSkills
                        : _skills.join(', '),
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: _chooseSkills,
                ),
                const SizedBox(height: 16),
              ],
              ConduitInput(
                key: const ValueKey('schedule-instructions'),
                enabled: !_scriptOnly,
                label: l10n.scheduleInstructions,
                hint: l10n.hermesJobPromptHint,
                controller: _instructions,
                minLines: 3,
                maxLines: 6,
                onChanged: (_) => setState(() {}),
                errorText:
                    _instructions.text.runes.length >
                        kMaxHermesJobPromptCharacters
                    ? l10n.hermesJobTooLong(kMaxHermesJobPromptCharacters)
                    : null,
              ),
              if (_failed)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    widget.job == null
                        ? l10n.hermesJobCreateFailed
                        : l10n.hermesJobUpdateFailed,
                    style: TextStyle(color: context.conduitTheme.error),
                  ),
                ),
              if (!writable)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(l10n.hermesJobAdminDisabled),
                ),
            ],
          ),
        ),
        footer: Row(
          children: [
            Expanded(
              child: ConduitTextButton(
                text: l10n.cancel,
                onPressed: _busy ? null : () => Navigator.of(context).pop(),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: ConduitButton(
                key: const ValueKey('schedule-save'),
                text: l10n.save,
                isLoading: _busy,
                onPressed: writable && !_busy && _valid ? _save : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class HermesScheduleSkillPicker extends ConsumerStatefulWidget {
  const HermesScheduleSkillPicker({super.key, required this.selected});
  final List<String> selected;
  @override
  ConsumerState<HermesScheduleSkillPicker> createState() =>
      _HermesScheduleSkillPickerState();
}

class _HermesScheduleSkillPickerState
    extends ConsumerState<HermesScheduleSkillPicker> {
  late final _selected = <String>{...widget.selected};
  @override
  Widget build(BuildContext context) {
    final l10n = _labels(context);
    final skills = ref.watch(hermesInstalledSkillsProvider);
    return HermesScheduleSheetFrame(
      title: l10n.scheduleChooseSkills,
      body: skills.when(
        loading: () => const Center(child: AdaptiveProgressIndicator()),
        error: (_, _) => Center(
          child: ConduitButton(
            text: l10n.retry,
            onPressed: () => ref.invalidate(hermesInstalledSkillsProvider),
          ),
        ),
        data: (items) {
          final indexed = {
            for (final item in items)
              if (item['name'] is String) item['name'] as String: item,
          };
          return ListView(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            children: [
              if (indexed.isEmpty && _selected.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(l10n.scheduleNoSkills),
                ),
              for (final name in {...indexed.keys, ..._selected})
                Row(
                  children: [
                    Expanded(
                      child: CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        title: Text(name),
                        value: _selected.contains(name),
                        onChanged: (value) => setState(() {
                          value == true
                              ? _selected.add(name)
                              : _selected.remove(name);
                        }),
                      ),
                    ),
                    CompactIconAction(
                      tooltip: '${l10n.scheduleAboutSkill}: $name',
                      icon: const Icon(Icons.info_outline_rounded),
                      onPressed: () => showHermesScheduleSkillDetail(
                        context,
                        name,
                        indexed[name]?['description']?.toString(),
                      ),
                    ),
                  ],
                ),
            ],
          );
        },
      ),
      footer: ConduitButton(
        text: l10n.scheduleDone,
        onPressed: () => Navigator.of(context).pop(_selected.toList()),
      ),
    );
  }
}

Future<void> showHermesScheduleSkillDetail(
  BuildContext context,
  String name,
  String? description,
) => showHermesScheduleSheet<void>(
  context,
  HermesScheduleSheetFrame(
    title: name,
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: SelectableText(
        description?.trim().isNotEmpty == true
            ? description!
            : _labels(context).scheduleNoSkillDescription,
      ),
    ),
  ),
);
