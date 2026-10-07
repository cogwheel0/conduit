import 'package:collection/collection.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit_core/features/notifications/models/notification_target.dart';
import 'package:conduit_core/features/notifications/providers/notification_target_providers.dart';

import '../../../core/services/haptic_service.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/discard_changes.dart';
import '../../../shared/widgets/sheet_handle.dart';
import '../../../shared/widgets/themed_dialogs.dart';
import '../../../shared/widgets/themed_sheets.dart';
import '../../../shared/widgets/utility_components.dart';
import '../../profile/widgets/adaptive_segmented_selector.dart';
import '../../profile/widgets/settings_page_scaffold.dart';

/// Adds a webhook destination, or edits [target].
///
/// [owner] is the account the entry point was opened for, captured when the
/// user tapped it and before anything was awaited. The editor refuses to open
/// for another account, and every action it takes (Save, Test, Make default,
/// Delete) is sent for that account only. After an account change they are
/// refused with the typed input still in the form.
///
/// The server never returns the saved URL, so an edit shows only its masked
/// form and sends a URL only when the user types a replacement.
Future<void> showNotificationTargetEditor(
  BuildContext context, {
  required NotificationTargets notifier,
  required NotificationTargetsOwner? owner,
  required List<NotificationEvent> events,
  NotificationTarget? target,
}) async {
  if (owner == null || !notifier.isCurrentOwner(owner)) {
    UiUtils.showMessage(
      context,
      AppLocalizations.of(context)!.errorMessage,
      isError: true,
    );
    return;
  }
  // A form, so a dimmed backdrop: the sheet keeps the user's attention until
  // it is saved or put away.
  await ThemedSheets.showCustom<void>(
    context: context,
    builder: (_) => _NotificationTargetEditor(
      notifier: notifier,
      owner: owner,
      events: events,
      target: target,
    ),
  );
}

class _NotificationTargetEditor extends StatefulWidget {
  const _NotificationTargetEditor({
    required this.notifier,
    required this.owner,
    required this.events,
    required this.target,
  });

  final NotificationTargets notifier;
  final NotificationTargetsOwner owner;
  final List<NotificationEvent> events;
  final NotificationTarget? target;

  @override
  State<_NotificationTargetEditor> createState() =>
      _NotificationTargetEditorState();
}

/// The one action the editor is running, so its control can show progress
/// while every other control waits.
enum _Action { save, makeDefault, test, delete }

class _NotificationTargetEditorState extends State<_NotificationTargetEditor> {
  final _url = TextEditingController();
  final _name = TextEditingController();
  late final bool _initialEnabled;
  late final String _initialDelivery;
  late final Set<String> _initialEvents;
  late bool _enabled;
  late String _delivery;
  late final Set<String> _events;
  _Action? _running;
  bool _urlTouched = false;
  String? _error;

  NotificationTarget? get _target => widget.target;

  @override
  void initState() {
    super.initState();
    _initialEnabled = _enabled = _target?.enabled ?? true;
    _initialDelivery = _delivery =
        _target?.delivery ?? NotificationTarget.deliveryAway;
    _initialEvents = {...?_target?.events};
    _events = {..._initialEvents};
    _url.addListener(_onTyped);
    _name.addListener(_onTyped);
  }

  @override
  void dispose() {
    _url.dispose();
    _name.dispose();
    super.dispose();
  }

  void _onTyped() {
    if (!mounted) return;
    setState(() {
      if (_url.text.trim().isNotEmpty) _urlTouched = true;
    });
  }

  bool get _busy => _running != null;

  /// Whether the form holds anything the server does not have yet.
  bool get _dirty =>
      _url.text.trim().isNotEmpty ||
      _name.text.trim().isNotEmpty ||
      _enabled != _initialEnabled ||
      _delivery != _initialDelivery ||
      !const SetEquality<String>().equals(_events, _initialEvents);

  /// A new destination needs a URL. Said next to the field once the user has
  /// typed one and cleared it, or tried to save without one, and gone as soon
  /// as a URL is there.
  String? _urlError(AppLocalizations l10n) =>
      _target == null && _urlTouched && _url.text.trim().isEmpty
      ? l10n.notificationTargetUrlRequired
      : null;

  /// The catalog, then any event the destination holds that the catalog does
  /// not list, so a subscription this client cannot name is shown and kept.
  List<({String id, String label, String? description, bool unknown})>
  get _eventRows {
    final l10n = AppLocalizations.of(context)!;
    final listed = {for (final event in widget.events) event.event};
    return [
      for (final event in widget.events)
        (
          id: event.event,
          label: event.label,
          description: event.description,
          unknown: false,
        ),
      for (final id in _target?.events ?? const <String>[])
        if (!listed.contains(id))
          (
            id: id,
            label: id,
            description: l10n.notificationTargetUnknownEvent,
            unknown: true,
          ),
    ];
  }

  /// Runs [action], keeping the form and showing why when it is refused: the
  /// server's own explanation when it gave one, otherwise [fallback].
  Future<void> _run(
    _Action kind,
    Future<void> Function() action, {
    String? fallback,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    setState(() {
      _running = kind;
      _error = null;
    });
    try {
      await action();
    } on NotificationTargetsOwnerChangedException {
      _fail(l10n.notificationTargetsAccountChanged);
    } on NotificationTargetsUnavailableException {
      _fail(l10n.notificationTargetsUnavailable);
    } catch (error) {
      _fail(
        notificationTargetErrorDetail(error) ?? fallback ?? l10n.errorMessage,
      );
    } finally {
      if (mounted) setState(() => _running = null);
    }
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() => _error = message);
  }

  Future<void> _save() async {
    if (_busy) return;
    final l10n = AppLocalizations.of(context)!;
    final target = _target;
    final url = _url.text.trim();
    if (target == null && url.isEmpty) {
      setState(() => _urlTouched = true);
      return;
    }
    await _run(_Action.save, () async {
      final events = [
        for (final row in _eventRows)
          if (_events.contains(row.id)) row.id,
      ];
      if (target == null) {
        await widget.notifier.create(
          url: url,
          id: _name.text,
          enabled: _enabled,
          events: events,
          delivery: _delivery,
          owner: widget.owner,
        );
      } else {
        // Only what changed goes out, so an edit that leaves the destination
        // alone cannot touch the URL the server holds or trip server checks
        // on an event it no longer recognizes.
        await widget.notifier.updateTarget(
          target.id,
          enabled: _enabled != target.enabled ? _enabled : null,
          events:
              const SetEquality<String>().equals(_events, {...target.events})
              ? null
              : events,
          delivery: _delivery != target.delivery ? _delivery : null,
          replacementUrl: url.isEmpty ? null : url,
          owner: widget.owner,
        );
      }
      if (!mounted) return;
      ConduitHaptics.success();
      UiUtils.showMessage(context, l10n.saved);
      Navigator.of(context).pop();
    });
  }

  /// Makes the destination the default as the server holds it, so it waits
  /// until the edits on screen are saved rather than closing over them.
  Future<void> _makeDefault() async {
    final target = _target;
    if (target == null || _busy || _dirty) return;
    final l10n = AppLocalizations.of(context)!;
    await _run(_Action.makeDefault, () async {
      await widget.notifier.makeDefault(target.id, owner: widget.owner);
      if (!mounted) return;
      UiUtils.showMessage(context, l10n.saved);
      Navigator.of(context).pop();
    });
  }

  /// Sends one real test notification. This is the only place that does, and
  /// only for a press: opening the editor or the list never calls it.
  Future<void> _sendTest() async {
    final target = _target;
    if (target == null || _busy) return;
    final l10n = AppLocalizations.of(context)!;
    await _run(_Action.test, () async {
      await widget.notifier.sendTest(target.id, owner: widget.owner);
      if (!mounted) return;
      UiUtils.showMessage(context, l10n.notificationTargetTestSent);
    }, fallback: l10n.notificationTargetTestFailed);
  }

  Future<void> _delete() async {
    final target = _target;
    if (target == null || _busy) return;
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await ThemedDialogs.confirm(
      context,
      title: l10n.notificationTargetDelete,
      message: l10n.notificationTargetDeleteConfirm(target.id),
      confirmText: l10n.notificationTargetDelete,
      isDestructive: true,
    );
    if (!confirmed || !mounted) return;
    await _run(_Action.delete, () async {
      await widget.notifier.remove(target.id, owner: widget.owner);
      if (!mounted) return;
      Navigator.of(context).pop();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final target = _target;
    final rows = _eventRows;
    final dirty = _dirty;
    void close() => Navigator.of(context).maybePop();

    final deliveryNote = switch (_delivery) {
      NotificationTarget.deliveryAway =>
        l10n.notificationTargetDeliveryAwayDescription,
      NotificationTarget.deliveryAlways =>
        l10n.notificationTargetDeliveryAlwaysDescription,
      _ => null,
    };

    final fields = <Widget>[
      if (target == null) ...[
        // The URL is what a destination is; the name is optional and set once.
        ConduitInput(
          key: const Key('notification-target-url'),
          controller: _url,
          label: l10n.notificationTargetUrlLabel,
          hint: l10n.notificationTargetUrlHint,
          errorText: _urlError(l10n),
          keyboardType: TextInputType.url,
          enabled: !_busy,
          autofocus: true,
        ),
        const SizedBox(height: Spacing.md),
        ConduitInput(
          key: const Key('notification-target-name'),
          controller: _name,
          label: l10n.notificationTargetNameLabel,
          hint: l10n.notificationTargetNameHint,
          enabled: !_busy,
        ),
        const SizedBox(height: Spacing.xs),
        _helper(l10n.notificationTargetNameHelper),
      ] else ...[
        InsetGroupedList(
          children: [
            UtilityValueRow(
              key: const Key('notification-target-id'),
              label: l10n.notificationTargetIdLabel,
              value: target.id,
            ),
            // Display only: the server never returns the saved URL.
            if (target.maskedUrl case final masked?)
              UtilityValueRow(
                key: const Key('notification-target-masked-url'),
                label: l10n.notificationTargetUrlLabel,
                value: masked,
              ),
          ],
        ),
        const SizedBox(height: Spacing.md),
        ConduitInput(
          key: const Key('notification-target-url'),
          controller: _url,
          semanticLabel: l10n.notificationTargetUrlLabel,
          hint: l10n.notificationTargetUrlKeepHint,
          keyboardType: TextInputType.url,
          enabled: !_busy,
        ),
      ],
      const SizedBox(height: Spacing.lg),
      InsetGroupedList(
        children: [
          _switchRow(
            key: const Key('notification-target-enabled'),
            title: l10n.notificationTargetEnabledTitle,
            value: _enabled,
            onChanged: (value) => setState(() => _enabled = value),
          ),
        ],
      ),
      const SizedBox(height: Spacing.lg),
      _sectionLabel(l10n.notificationTargetDeliveryLabel),
      const SizedBox(height: Spacing.sm),
      // One choice of two, so a segmented control. A delivery this client
      // does not know leaves both unselected and is kept unless changed.
      IgnorePointer(
        ignoring: _busy,
        child: AdaptiveSegmentedSelector<String>(
          key: const Key('notification-target-delivery'),
          value: _delivery,
          showIcons: false,
          onChanged: (value) => setState(() => _delivery = value),
          options: [
            (
              value: NotificationTarget.deliveryAway,
              label: l10n.notificationTargetDeliveryAway,
              cupertinoIcon: CupertinoIcons.moon,
              materialIcon: Icons.do_not_disturb_on_outlined,
              enabled: true,
            ),
            (
              value: NotificationTarget.deliveryAlways,
              label: l10n.notificationTargetDeliveryAlways,
              cupertinoIcon: CupertinoIcons.bell,
              materialIcon: Icons.notifications_active_outlined,
              enabled: true,
            ),
          ],
        ),
      ),
      if (deliveryNote != null) ...[
        const SizedBox(height: Spacing.xs),
        _helper(
          deliveryNote,
          key: const Key('notification-target-delivery-note'),
        ),
      ],
      const SizedBox(height: Spacing.lg),
      InsetGroupedList(
        title: l10n.notificationTargetEventsLabel,
        children: [
          if (rows.isEmpty)
            UtilityRow(
              title: l10n.notificationTargetEventsUnavailable,
              foregroundColor: theme.textSecondary,
            )
          else
            for (final row in rows)
              _switchRow(
                key: Key('notification-target-event-${row.id}'),
                title: row.label,
                subtitle: row.description,
                value: _events.contains(row.id),
                onChanged: (selected) => setState(() {
                  selected ? _events.add(row.id) : _events.remove(row.id);
                }),
              ),
        ],
      ),
      if (target != null) ...[
        const SizedBox(height: Spacing.lg),
        InsetGroupedList(
          children: [
            // Both act on the destination as the server holds it, so they
            // wait until the edits on screen are saved.
            if (target.isDefault != true)
              _actionRow(
                key: const Key('notification-target-make-default'),
                action: _Action.makeDefault,
                icon: UiUtils.platformIcon(
                  ios: CupertinoIcons.star,
                  android: Icons.star_outline,
                ),
                title: l10n.notificationTargetMakeDefault,
                subtitle: dirty
                    ? l10n.notificationTargetMakeDefaultNeedsSave
                    : null,
                available: !dirty,
                onTap: _makeDefault,
              ),
            _actionRow(
              key: const Key('notification-target-test'),
              action: _Action.test,
              icon: UiUtils.platformIcon(
                ios: CupertinoIcons.paperplane,
                android: Icons.send_outlined,
              ),
              title: l10n.notificationTargetTest,
              subtitle: dirty ? l10n.notificationTargetTestNeedsSave : null,
              available: !dirty,
              onTap: _sendTest,
            ),
          ],
        ),
        const SizedBox(height: Spacing.lg),
        InsetGroupedList(
          children: [
            _actionRow(
              key: const Key('notification-target-delete'),
              action: _Action.delete,
              icon: UiUtils.platformIcon(
                ios: CupertinoIcons.delete,
                android: Icons.delete_outline,
              ),
              title: l10n.notificationTargetDelete,
              destructive: true,
              onTap: _delete,
            ),
          ],
        ),
      ],
    ];

    // Back, Cancel, the close button and a swipe all ask before throwing
    // edits away, and do nothing while an action is on its way. The fields
    // scroll above the keyboard while Cancel and Save stay in view.
    return DiscardChangesScope(
      dirty: dirty,
      busy: _busy,
      child: AnimatedPadding(
        duration: context.motionDuration(AnimationDuration.microInteraction),
        curve: Curves.easeOutCubic,
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SheetDismissGuard(
          guarded: dirty || _busy,
          onDismissRequest: close,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.9,
            ),
            child: ConduitModalSheetSurface(
              showHandle: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SheetHandle(),
                  Row(
                    children: [
                      Expanded(
                        child: Semantics(
                          header: true,
                          child: Text(
                            target == null
                                ? l10n.notificationTargetNewTitle
                                : l10n.notificationTargetEditTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.headingSmall,
                          ),
                        ),
                      ),
                      SheetCloseButton(
                        tooltip: l10n.close,
                        onPressed: _busy ? null : close,
                      ),
                    ],
                  ),
                  Flexible(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.only(top: Spacing.sm),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: fields,
                      ),
                    ),
                  ),
                  if (_error case final message?) ...[
                    const SizedBox(height: Spacing.sm),
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        message,
                        key: const Key('notification-target-error'),
                        style: theme.bodySmall?.copyWith(color: theme.error),
                      ),
                    ),
                  ],
                  const SizedBox(height: Spacing.md),
                  Row(
                    children: [
                      Expanded(
                        child: ConduitButton(
                          text: l10n.cancel,
                          isSecondary: true,
                          onPressed: _busy ? null : close,
                        ),
                      ),
                      const SizedBox(width: Spacing.sm),
                      Expanded(
                        child: ConduitButton(
                          key: const Key('notification-target-save'),
                          text: l10n.save,
                          isLoading: _running == _Action.save,
                          onPressed: _busy ? null : _save,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _sectionLabel(String text) {
    final theme = context.conduitTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.xs),
      child: Semantics(
        header: true,
        child: Text(
          text,
          style: theme.label?.copyWith(color: theme.textSecondary),
        ),
      ),
    );
  }

  Widget _helper(String text, {Key? key}) {
    final theme = context.conduitTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.xs),
      child: Text(
        text,
        key: key,
        style: theme.bodySmall?.copyWith(color: theme.textSecondary),
      ),
    );
  }

  /// A setting row: the whole row flips the switch, and it reads as one
  /// on/off control.
  Widget _switchRow({
    required Key key,
    required String title,
    required bool value,
    required ValueChanged<bool> onChanged,
    String? subtitle,
  }) {
    return UtilityRow(
      key: key,
      title: title,
      subtitle: subtitle,
      toggled: value,
      enabled: !_busy,
      trailing: AdaptiveSwitch(
        value: value,
        onChanged: _busy ? null : onChanged,
        semanticLabel: title,
      ),
      onTap: () => onChanged(!value),
    );
  }

  /// An action on the saved destination. It shows its own progress while it
  /// runs; [available] false keeps it dimmed for a reason its subtitle gives.
  Widget _actionRow({
    required Key key,
    required _Action action,
    required IconData icon,
    required String title,
    required VoidCallback onTap,
    String? subtitle,
    bool available = true,
    bool destructive = false,
  }) {
    final theme = context.conduitTheme;
    final running = _running == action;
    return UtilityRow(
      key: key,
      leading: SettingsIconBadge(
        icon: icon,
        color: destructive ? theme.error : theme.buttonPrimary,
      ),
      title: title,
      subtitle: subtitle,
      destructive: destructive,
      enabled: available && (!_busy || running),
      trailing: running
          ? const SizedBox.square(
              dimension: IconSize.medium,
              child: Center(
                child: ConduitLoadingIndicator(size: 18, isCompact: true),
              ),
            )
          : null,
      onTap: _busy ? null : onTap,
    );
  }
}
