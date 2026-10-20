import 'package:checks/checks.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit/features/workspace/models/workspace_capabilities.dart';
import 'package:conduit/features/workspace/providers/workspace_capabilities_provider.dart';

void main() {
  test('parses section, import/export, sharing, public, and user grants', () {
    final capabilities = WorkspaceCapabilities.fromPermissions({
      'workspace': {
        'models': true,
        'models_import': true,
        'models_export': false,
        'tools': true,
      },
      'sharing': {
        'models': true,
        'public_models': false,
        'tools': false,
        'public_tools': true,
      },
      'access_grants': {'allow_users': true},
    });

    check(capabilities.models.manage).isTrue();
    check(capabilities.models.importItems).isTrue();
    check(capabilities.models.exportItems).isFalse();
    check(capabilities.models.share).isTrue();
    check(capabilities.models.sharePublicly).isFalse();
    check(capabilities.tools.manage).isTrue();
    check(capabilities.tools.share).isFalse();
    check(capabilities.tools.sharePublicly).isTrue();
    check(capabilities.prompts.manage).isFalse();
    check(capabilities.allowUserGrants).isTrue();
  });

  test('user and group grant permissions are read independently', () {
    WorkspaceCapabilities parse(Map<String, dynamic> accessGrants) =>
        WorkspaceCapabilities.fromPermissions({'access_grants': accessGrants});

    final usersOnly = parse({'allow_users': true, 'allow_groups': false});
    check(usersOnly.allowUserGrants).isTrue();
    check(usersOnly.allowGroupGrants).isFalse();

    final groupsOnly = parse({'allow_users': false, 'allow_groups': true});
    check(groupsOnly.allowUserGrants).isFalse();
    check(groupsOnly.allowGroupGrants).isTrue();

    final neither = parse({'allow_users': false, 'allow_groups': false});
    check(neither.allowUserGrants).isFalse();
    check(neither.allowGroupGrants).isFalse();
  });

  test('a missing grant permission is allowed, as in the web editors', () {
    final noSection = WorkspaceCapabilities.fromPermissions(const {});
    check(noSection.allowUserGrants).isTrue();
    check(noSection.allowGroupGrants).isTrue();

    final oneKind = WorkspaceCapabilities.fromPermissions({
      'access_grants': {'allow_groups': false},
    });
    check(oneKind.allowUserGrants).isTrue();
    check(oneKind.allowGroupGrants).isFalse();
  });

  test('chat, folder and note sharing follow each pinned caller', () {
    final capabilities = WorkspaceCapabilities.fromPermissions({
      'sharing': {
        'notes': true,
        'public_notes': false,
        'folders': false,
        'public_chats': true,
        'open_chats': false,
      },
      'chat': {'share': false},
    });

    check(capabilities.notes.section.share).isTrue();
    check(capabilities.notes.section.sharePublicly).isFalse();
    check(capabilities.folders.section.share).isFalse();
    // A folder has no public audience at all.
    check(capabilities.folders.section.sharePublicly).isFalse();
    check(capabilities.chats.section.share).isFalse();
    check(capabilities.chats.section.sharePublicly).isTrue();
    // Open is its own permission, independent of Public.
    check(capabilities.chats.shareOpenly).isFalse();
    check(
      WorkspaceCapabilities.fromPermissions({
        'sharing': {'open_chats': true},
      }).chats.shareOpenly,
    ).isTrue();

    // With no `access_grants` block the note and chat callers allow both kinds
    // while the folder caller allows groups only.
    check(capabilities.notes.allowUserGrants).isTrue();
    check(capabilities.chats.allowUserGrants).isTrue();
    check(capabilities.folders.allowUserGrants).isFalse();
    check(capabilities.folders.allowGroupGrants).isTrue();
  });

  test('an admin may grant every kind on every resource', () {
    check(WorkspaceCapabilities.all.notes.allowUserGrants).isTrue();
    check(WorkspaceCapabilities.all.folders.allowUserGrants).isTrue();
    check(WorkspaceCapabilities.all.chats.section.sharePublicly).isTrue();
    check(WorkspaceCapabilities.all.chats.shareOpenly).isTrue();
    check(WorkspaceCapabilities.all.folders.section.sharePublicly).isFalse();
  });

  test('admin is all-capable without an ApiService', () async {
    final container = ProviderContainer(
      overrides: [
        reviewerModeProvider.overrideWithValue(false),
        currentUserProvider2.overrideWithValue(
          const User(
            id: 'admin-1',
            username: 'admin',
            email: 'admin@example.com',
            role: 'admin',
          ),
        ),
        apiServiceProvider.overrideWithValue(null),
      ],
    );
    addTearDown(container.dispose);

    final capabilities = await container.read(
      workspaceCapabilitiesProvider.future,
    );

    for (final section in [
      capabilities.models,
      capabilities.knowledge,
      capabilities.prompts,
      capabilities.skills,
      capabilities.tools,
    ]) {
      _checkSection(section, expected: true);
    }
    check(capabilities.allowUserGrants).isTrue();
    check(capabilities.allowGroupGrants).isTrue();
  });

  test('non-admin without an ApiService fails closed', () async {
    final container = ProviderContainer(
      overrides: [
        reviewerModeProvider.overrideWithValue(false),
        currentUserProvider2.overrideWithValue(
          const User(
            id: 'user-1',
            username: 'user',
            email: 'user@example.com',
            role: 'user',
          ),
        ),
        apiServiceProvider.overrideWithValue(null),
      ],
    );
    addTearDown(container.dispose);

    final capabilities = await container.read(
      workspaceCapabilitiesProvider.future,
    );

    for (final section in [
      capabilities.models,
      capabilities.knowledge,
      capabilities.prompts,
      capabilities.skills,
      capabilities.tools,
    ]) {
      _checkSection(section, expected: false);
    }
    check(capabilities.allowUserGrants).isFalse();
    check(capabilities.allowGroupGrants).isFalse();
  });
}

void _checkSection(
  WorkspaceSectionCapabilities section, {
  required bool expected,
}) {
  check(section.manage).equals(expected);
  check(section.importItems).equals(expected);
  check(section.exportItems).equals(expected);
  check(section.share).equals(expected);
  check(section.sharePublicly).equals(expected);
}
