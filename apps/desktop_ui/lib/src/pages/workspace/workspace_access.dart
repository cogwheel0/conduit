import 'dart:async';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';

import '../../l10n/strings.g.dart';
import '../../rpc/workspace_providers.dart';
import '../../widgets/form_field.dart';
import 'workspace_common.dart';

/// Who may read and write one item: public or not, and people and groups
/// each with read or write. Saved together, on Save.
class AccessDialog extends StatefulComponent {
  const AccessDialog({
    required this.kind,
    required this.id,
    required this.grants,
    required this.section,
    required this.allowUserGrants,
    required this.onClose,
    required this.onSaved,
    super.key,
  });

  final WorkspaceKind kind;
  final String id;
  final List<WorkspaceGrant> grants;
  final WorkspaceSectionAccess section;
  final bool allowUserGrants;
  final void Function() onClose;
  final void Function(WorkspaceDetail detail) onSaved;

  @override
  State<AccessDialog> createState() => _AccessDialogState();
}

class _AccessDialogState extends State<AccessDialog> {
  late List<WorkspaceGrant> _grants;

  /// Names for the grants' principals, by `type:id`.
  final Map<String, String> _names = <String, String>{};
  String _query = '';
  List<WorkspacePrincipal> _found = const <WorkspacePrincipal>[];
  Timer? _searchTimer;
  bool _busy = false;
  String? _error;

  static String _key(String type, String id) => '$type:$id';

  bool get _public =>
      _grants.any((g) => g.principalType == 'user' && g.principalId == '*');

  @override
  void initState() {
    super.initState();
    _grants = [...component.grants];
  }

  @override
  void dispose() {
    _searchTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadNames(BuildContext context) async {
    final ids = [
      for (final g in _grants)
        if (g.principalId != '*') g.principalId,
    ];
    if (ids.isEmpty) return;
    try {
      final found = await context
          .read(workspaceActionsProvider)
          .principals(ids: ids);
      if (!mounted) return;
      setState(() {
        for (final p in found) {
          _names[_key(p.type, p.id)] = p.name;
        }
      });
    } on Object {
      // Ids stand in for names.
    }
  }

  bool _loadedNames = false;

  void _search(BuildContext context, String query) {
    setState(() => _query = query);
    _searchTimer?.cancel();
    _searchTimer = Timer(const Duration(milliseconds: 250), () async {
      try {
        final found = await context
            .read(workspaceActionsProvider)
            .principals(query: query);
        if (!mounted) return;
        setState(() {
          _found = [
            for (final p in found)
              if (p.type == 'group' || component.allowUserGrants) p,
          ];
        });
      } on Object {
        if (mounted) {
          setState(() => _error = t.app.workspacePrincipalLoadFailed);
        }
      }
    });
  }

  void _add(WorkspacePrincipal principal) => setState(() {
    _names[_key(principal.type, principal.id)] = principal.name;
    if (!_grants.any(
      (g) => g.principalType == principal.type && g.principalId == principal.id,
    )) {
      _grants = [
        ..._grants,
        WorkspaceGrant(
          principalType: principal.type,
          principalId: principal.id,
        ),
      ];
    }
  });

  Future<void> _save(BuildContext context) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final detail = await context
          .read(workspaceActionsProvider)
          .setAccess(component.kind, component.id, _grants);
      component.onSaved(detail);
    } on Object {
      if (mounted) setState(() => _error = t.app.workspaceLoadFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Component build(BuildContext context) {
    if (!_loadedNames) {
      _loadedNames = true;
      unawaited(Future<void>.microtask(() => _loadNames(context)));
    }
    final people = [
      for (final g in _grants)
        if (g.principalId != '*') g,
    ];
    return modal(
      label: t.app.workspaceAccessTitle,
      onClose: component.onClose,
      children: [
        if (!component.section.share)
          statusLine(t.app.workspaceAccessSharingDisabled)
        else ...[
          div(classes: 'space-y-1', [
            checkboxField(
              id: 'access-public',
              text: t.app.workspaceAccessVisibilityLabel,
              checked: _public,
              disabled: !component.section.sharePublicly,
              onChanged: ({required value}) => setState(() {
                _grants = value
                    ? [..._grants, const WorkspaceGrant(principalId: '*')]
                    : [
                        for (final g in _grants)
                          if (!(g.principalType == 'user' &&
                              g.principalId == '*'))
                            g,
                      ];
              }),
            ),
            p(classes: 'pl-6 text-xs text-muted-foreground', [
              Component.text(
                component.section.sharePublicly
                    ? t.app.workspaceAccessVisibilityDescription
                    : t.app.workspaceAccessPublicDisabled,
              ),
            ]),
          ]),
          h3(classes: 'text-sm font-semibold', [
            Component.text(t.app.workspaceAccessPeopleHeading),
          ]),
          if (!component.allowUserGrants)
            statusLine(t.app.workspaceAccessUsersDisabled),
          if (people.isEmpty)
            statusLine(t.app.workspaceAccessEmpty)
          else
            ul(classes: 'divide-y divide-border rounded border border-border', [
              for (final g in people)
                li(classes: 'flex items-center gap-2 px-2 py-1.5', [
                  span(classes: 'min-w-0 flex-1 truncate', [
                    Component.text(
                      _names[_key(g.principalType, g.principalId)] ??
                          g.principalId,
                    ),
                  ]),
                  badge(
                    g.principalType == 'group'
                        ? t.app.workspaceAccessGroupBadge
                        : t.app.workspaceAccessUserBadge,
                  ),
                  checkboxField(
                    id: 'access-write-${g.principalType}-${g.principalId}',
                    text: t.app.workspaceAccessCanEdit,
                    checked: g.write,
                    onChanged: ({required value}) => setState(() {
                      _grants = [
                        for (final other in _grants)
                          identical(other, g)
                              ? other.copyWith(write: value)
                              : other,
                      ];
                    }),
                  ),
                  actionButton(
                    '✕',
                    ariaLabel: t.app.workspaceAccessRemoveGrant,
                    onClick: () => setState(() {
                      _grants = [
                        for (final other in _grants)
                          if (!identical(other, g)) other,
                      ];
                    }),
                  ),
                ]),
            ]),
          textField(
            id: 'access-search',
            labelText: component.allowUserGrants
                ? t.app.workspaceAccessAddPeople
                : t.app.workspaceAccessAddGroups,
            placeholder: t.app.workspacePrincipalSearchHint,
            value: _query,
            onInput: (value) => _search(context, value),
          ),
          if (_query.isNotEmpty && _found.isEmpty)
            statusLine(t.app.workspacePrincipalNoResults),
          ul(classes: 'space-y-1', [
            for (final principal in _found)
              li(classes: 'flex items-center gap-2', [
                span(classes: 'min-w-0 flex-1 truncate', [
                  Component.text(
                    principal.name.isEmpty ? principal.id : principal.name,
                  ),
                  if (principal.email case final email?)
                    span(classes: 'ml-1 text-xs text-muted-foreground', [
                      Component.text(email),
                    ]),
                ]),
                badge(
                  principal.type == 'group'
                      ? t.app.workspaceAccessGroupBadge
                      : t.app.workspaceAccessUserBadge,
                ),
                actionButton(
                  t.desktop.desktopWorkspaceAccessAdd,
                  onClick: () => _add(principal),
                ),
              ]),
          ]),
        ],
        if (_error case final error?) statusLine(error, error: true),
        div(classes: 'flex justify-end gap-2', [
          actionButton(t.app.cancel, onClick: component.onClose),
          if (component.section.share)
            actionButton(
              t.app.save,
              primary: true,
              id: 'access-save',
              disabled: _busy,
              onClick: () => unawaited(_save(context)),
            ),
        ]),
      ],
    );
  }
}
