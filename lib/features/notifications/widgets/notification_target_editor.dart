import 'package:collection/collection.dart';
import 'package:material_ui/material_ui.dart';

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit_core/features/notifications/models/notification_target.dart';
import 'package:conduit_core/features/notifications/providers/notification_target_providers.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/adaptive_selection_sheet.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/themed_dialogs.dart';

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
  await showAdaptiveSelectionSheet<void>(
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

class _NotificationTargetEditorState extends State<_NotificationTargetEditor> {
  final _url = TextEditingController();
  final _name = TextEditingController();
  late bool _enabled;
  late String _delivery;
  late final Set<String> _events;
  bool _saving = false;
  bool _testing = false;
  String? _error;

  NotificationTarget? get _target => widget.target;

  @override
  void initState() {
    super.initState();
    _enabled = _target?.enabled ?? true;
    _delivery = _target?.delivery ?? NotificationTarget.deliveryAway;
    _events = {...?_target?.events};
  }

  @override
  void dispose() {
    _url.dispose();
    _name.dispose();
    super.dispose();
  }

  bool get _busy => _saving || _testing;

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
  Future<void> _run(Future<void> Function() action, {String? fallback}) async {
    final l10n = AppLocalizations.of(context)!;
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
      setState(() => _error = l10n.notificationTargetUrlRequired);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    await _run(() async {
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
      UiUtils.showMessage(context, l10n.saved);
      Navigator.of(context).pop();
    });
    if (mounted) setState(() => _saving = false);
  }

  Future<void> _makeDefault() async {
    final target = _target;
    if (target == null || _busy) return;
    final l10n = AppLocalizations.of(context)!;
    setState(() {
      _saving = true;
      _error = null;
    });
    await _run(() async {
      await widget.notifier.makeDefault(target.id, owner: widget.owner);
      if (!mounted) return;
      UiUtils.showMessage(context, l10n.saved);
      Navigator.of(context).pop();
    });
    if (mounted) setState(() => _saving = false);
  }

  /// Sends one real test notification. This is the only place that does, and
  /// only for a press: opening the editor or the list never calls it.
  Future<void> _sendTest() async {
    final target = _target;
    if (target == null || _busy) return;
    final l10n = AppLocalizations.of(context)!;
    setState(() {
      _testing = true;
      _error = null;
    });
    await _run(() async {
      await widget.notifier.sendTest(target.id, owner: widget.owner);
      if (!mounted) return;
      UiUtils.showMessage(context, l10n.notificationTargetTestSent);
    }, fallback: l10n.notificationTargetTestFailed);
    if (mounted) setState(() => _testing = false);
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
    setState(() {
      _saving = true;
      _error = null;
    });
    await _run(() async {
      await widget.notifier.remove(target.id, owner: widget.owner);
      if (!mounted) return;
      Navigator.of(context).pop();
    });
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final viewInsets = MediaQuery.of(context).viewInsets;
    final target = _target;
    final rows = _eventRows;

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.9,
      ),
      decoration: BoxDecoration(
        color: theme.sidebarBackground,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppBorderRadius.modal),
        ),
        boxShadow: ConduitShadows.modal(context),
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            Spacing.lg,
            Spacing.lg,
            Spacing.lg,
            Spacing.lg + viewInsets.bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                target == null
                    ? l10n.notificationTargetNewTitle
                    : l10n.notificationTargetEditTitle,
                style: theme.headingSmall?.copyWith(
                  color: theme.sidebarForeground,
                ),
              ),
              const SizedBox(height: Spacing.md),
              if (target == null) ...[
                ConduitInput(
                  key: const Key('notification-target-name'),
                  controller: _name,
                  label: l10n.notificationTargetNameLabel,
                  hint: l10n.notificationTargetNameHint,
                  enabled: !_busy,
                ),
                const SizedBox(height: Spacing.md),
              ] else if (target.maskedUrl case final masked?) ...[
                // Display only: the server never returns the saved URL.
                Text(
                  l10n.notificationTargetUrlLabel,
                  style: theme.label?.copyWith(color: theme.textSecondary),
                ),
                const SizedBox(height: Spacing.xs),
                Text(
                  masked,
                  key: const Key('notification-target-masked-url'),
                  style: theme.bodySmall?.copyWith(
                    color: theme.sidebarForeground,
                  ),
                ),
                const SizedBox(height: Spacing.sm),
              ],
              ConduitInput(
                key: const Key('notification-target-url'),
                controller: _url,
                label: target == null ? l10n.notificationTargetUrlLabel : null,
                semanticLabel: l10n.notificationTargetUrlLabel,
                hint: target == null
                    ? l10n.notificationTargetUrlHint
                    : l10n.notificationTargetUrlKeepHint,
                keyboardType: TextInputType.url,
                enabled: !_busy,
                autofocus: target == null,
              ),
              const SizedBox(height: Spacing.md),
              _SwitchRow(
                key: const Key('notification-target-enabled'),
                title: l10n.notificationTargetEnabledTitle,
                value: _enabled,
                onChanged: _busy ? null : (v) => setState(() => _enabled = v),
              ),
              const SizedBox(height: Spacing.md),
              Text(
                l10n.notificationTargetDeliveryLabel,
                style: theme.label?.copyWith(color: theme.textSecondary),
              ),
              const SizedBox(height: Spacing.xs),
              Row(
                children: [
                  Expanded(
                    child: ConduitChip(
                      key: const Key('notification-target-delivery-away'),
                      label: l10n.notificationTargetDeliveryAway,
                      isSelected: _delivery == NotificationTarget.deliveryAway,
                      onTap: _busy
                          ? null
                          : () => setState(
                              () => _delivery = NotificationTarget.deliveryAway,
                            ),
                    ),
                  ),
                  const SizedBox(width: Spacing.sm),
                  Expanded(
                    child: ConduitChip(
                      key: const Key('notification-target-delivery-always'),
                      label: l10n.notificationTargetDeliveryAlways,
                      isSelected:
                          _delivery == NotificationTarget.deliveryAlways,
                      onTap: _busy
                          ? null
                          : () => setState(
                              () =>
                                  _delivery = NotificationTarget.deliveryAlways,
                            ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Spacing.md),
              Text(
                l10n.notificationTargetEventsLabel,
                style: theme.label?.copyWith(color: theme.textSecondary),
              ),
              const SizedBox(height: Spacing.xs),
              if (rows.isEmpty)
                Text(
                  l10n.notificationTargetEventsUnavailable,
                  style: theme.bodySmall?.copyWith(
                    color: theme.sidebarForeground.withValues(alpha: 0.75),
                  ),
                )
              else
                for (final row in rows)
                  _SwitchRow(
                    key: Key('notification-target-event-${row.id}'),
                    title: row.label,
                    subtitle: row.description,
                    value: _events.contains(row.id),
                    onChanged: _busy
                        ? null
                        : (selected) => setState(() {
                            selected
                                ? _events.add(row.id)
                                : _events.remove(row.id);
                          }),
                  ),
              if (_error case final message?) ...[
                const SizedBox(height: Spacing.md),
                Text(
                  message,
                  key: const Key('notification-target-error'),
                  style: theme.bodySmall?.copyWith(color: theme.error),
                ),
              ],
              const SizedBox(height: Spacing.md),
              if (target != null) ...[
                if (target.isDefault != true) ...[
                  ConduitButton(
                    key: const Key('notification-target-make-default'),
                    text: l10n.notificationTargetMakeDefault,
                    isSecondary: true,
                    isFullWidth: true,
                    onPressed: _busy ? null : _makeDefault,
                  ),
                  const SizedBox(height: Spacing.sm),
                ],
                ConduitButton(
                  key: const Key('notification-target-test'),
                  text: l10n.notificationTargetTest,
                  isSecondary: true,
                  isFullWidth: true,
                  isLoading: _testing,
                  onPressed: _busy ? null : _sendTest,
                ),
                const SizedBox(height: Spacing.sm),
                ConduitButton(
                  key: const Key('notification-target-delete'),
                  text: l10n.notificationTargetDelete,
                  isDestructive: true,
                  isFullWidth: true,
                  onPressed: _busy ? null : _delete,
                ),
                const SizedBox(height: Spacing.md),
              ],
              Row(
                children: [
                  Expanded(
                    child: ConduitButton(
                      text: l10n.cancel,
                      isSecondary: true,
                      onPressed: _busy
                          ? null
                          : () => Navigator.of(context).pop(),
                    ),
                  ),
                  const SizedBox(width: Spacing.sm),
                  Expanded(
                    child: ConduitButton(
                      key: const Key('notification-target-save'),
                      text: l10n.save,
                      isLoading: _saving,
                      onPressed: _busy ? null : _save,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.bodyMedium?.copyWith(
                    color: theme.sidebarForeground,
                  ),
                ),
                if (subtitle case final text?)
                  Text(
                    text,
                    style: theme.bodySmall?.copyWith(
                      color: theme.sidebarForeground.withValues(alpha: 0.75),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: Spacing.sm),
          AdaptiveSwitch(
            value: value,
            onChanged: onChanged,
            semanticLabel: title,
          ),
        ],
      ),
    );
  }
}
