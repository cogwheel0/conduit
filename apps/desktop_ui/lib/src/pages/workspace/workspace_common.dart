import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:jaspr_router/jaspr_router.dart';

import '../../l10n/strings.g.dart';

/// Pieces every workspace screen draws the same way (M6).

String sectionLabel(WorkspaceKind kind) => switch (kind) {
  WorkspaceKind.models => t.app.workspaceModels,
  WorkspaceKind.knowledge => t.app.workspaceKnowledge,
  WorkspaceKind.prompts => t.app.workspacePrompts,
  WorkspaceKind.tools => t.app.workspaceTools,
  WorkspaceKind.skills => t.app.workspaceSkills,
};

String sectionPath(WorkspaceKind kind, [String? id]) => id == null
    ? '/workspace/${kind.name}'
    : '/workspace/${kind.name}/${Uri.encodeComponent(id)}';

WorkspaceKind? sectionFromPath(String? segment) {
  for (final kind in WorkspaceKind.values) {
    if (kind.name == segment) return kind;
  }
  return null;
}

/// Moves between workspace screens. A provider so a VM test, where the
/// router cannot navigate, sees where the page went instead.
typedef WorkspaceNavigate = void Function(
  BuildContext context,
  String to, {
  bool replace,
});

final workspaceNavigateProvider = Provider<WorkspaceNavigate>(
  (ref) =>
      (context, to, {replace = false}) => replace
      ? Router.of(context).replace(to)
      : Router.of(context).push(to),
);

void workspaceGo(BuildContext context, String to, {bool replace = false}) =>
    context.read(workspaceNavigateProvider)(context, to, replace: replace);

/// Whether an editor holds changes that are not saved. The workspace's own
/// navigation asks before leaving while it does.
final workspaceEditorDirtyProvider =
    NotifierProvider<WorkspaceEditorDirty, bool>(WorkspaceEditorDirty.new);

class WorkspaceEditorDirty extends Notifier<bool> {
  @override
  bool build() => false;

  // ignore: use_setters_to_change_properties
  void set(bool dirty) => state = dirty;
}

Component actionButton(
  String text, {
  required void Function() onClick,
  bool primary = false,
  bool destructive = false,
  bool disabled = false,
  String? id,
  String? ariaLabel,
}) => button(
  [Component.text(text)],
  id: id,
  classes: primary
      ? 'rounded bg-primary px-3 py-1.5 text-xs text-primary-foreground '
            'disabled:opacity-60'
      : destructive
      ? 'rounded px-3 py-1.5 text-xs text-destructive hover:bg-destructive/10 '
            'disabled:opacity-60'
      : 'rounded border border-border px-3 py-1.5 text-xs hover:bg-accent '
            'disabled:opacity-60',
  type: ButtonType.button,
  disabled: disabled,
  attributes: <String, String>{'aria-label': ?ariaLabel},
  onClick: disabled ? null : onClick,
);

/// A modal over the page. A click outside closes it, as Escape would.
Component modal({
  required String label,
  required void Function() onClose,
  required List<Component> children,
  String width = 'max-w-lg',
}) => div(
  classes:
      'fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-6',
  events: <String, EventCallback>{'click': (_) => onClose()},
  [
    div(
      classes:
          'max-h-[85vh] w-full $width space-y-4 overflow-y-auto rounded '
          'border border-border bg-popover p-5 text-sm '
          'text-popover-foreground shadow-lg',
      attributes: <String, String>{
        'role': 'dialog',
        'aria-modal': 'true',
        'aria-label': label,
      },
      events: <String, EventCallback>{
        'click': (event) => event.stopPropagation(),
      },
      [
        h2(classes: 'text-base font-semibold', [Component.text(label)]),
        ...children,
      ],
    ),
  ],
);

/// A yes-or-no question in the page's flow, for deleting and discarding.
Component confirmBox({
  required String title,
  String? message,
  required String confirmText,
  required void Function() onConfirm,
  required void Function() onCancel,
  String? cancelText,
}) => div(
  classes:
      'space-y-2 rounded border border-destructive/40 bg-destructive/10 p-3 '
      'text-sm',
  attributes: const <String, String>{'role': 'alertdialog'},
  [
    p(classes: 'font-medium', [Component.text(title)]),
    if (message != null)
      p(classes: 'text-muted-foreground', [Component.text(message)]),
    div(classes: 'flex gap-2', [
      button(
        [Component.text(confirmText)],
        classes:
            'rounded bg-destructive px-2.5 py-1 text-xs '
            'text-destructive-foreground',
        type: ButtonType.button,
        onClick: onConfirm,
      ),
      button(
        [Component.text(cancelText ?? t.app.cancel)],
        classes: 'rounded px-2.5 py-1 text-xs hover:bg-accent',
        type: ButtonType.button,
        onClick: onCancel,
      ),
    ]),
  ],
);

Component badge(String text, {bool muted = true}) => span(
  classes:
      'shrink-0 rounded-full border px-1.5 text-[10px] '
      '${muted ? 'border-border text-muted-foreground' : 'border-primary/50 text-primary'}',
  [Component.text(text)],
);

Component statusLine(String text, {bool error = false}) => p(
  classes: error ? 'text-xs text-destructive' : 'text-xs text-muted-foreground',
  attributes: <String, String>{'role': error ? 'alert' : 'status'},
  [Component.text(text)],
);

/// The day, year first, as the folder page shows it.
String dayOf(int ms) {
  final date = DateTime.fromMillisecondsSinceEpoch(ms);
  String two(int n) => n.toString().padLeft(2, '0');
  return '${date.year}-${two(date.month)}-${two(date.day)}';
}

/// A list typed as text: split on [separator], trimmed, blanks dropped.
List<String> splitList(String text, {String separator = ','}) => [
  for (final part in text.split(separator))
    if (part.trim().isNotEmpty) part.trim(),
];

/// Whether [error] is the daemon saying the thing is gone.
bool isNotFound(Object? error) =>
    error is RpcError && error.code == ConduitErrorCodes.notFound;

/// The server's own words for a refusal, when it gave any.
String? serverDetail(Object? error) =>
    error is RpcError ? error.args['detail'] : null;
