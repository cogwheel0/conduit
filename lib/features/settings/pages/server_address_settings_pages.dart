import 'dart:async';

import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit_core/features/push/models/push_target.dart';
import 'package:conduit_core/models/openwebui_registry.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/openwebui_accounts_controller.dart'
    show addressChangeReplyGuardProvider, addressChangeStopRepliesProvider;
import 'package:conduit_core/providers/openwebui_route_resolver.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../core/services/native_sheet_bridge.dart';
import '../../../core/services/native_sheet_hydration_service.dart'
    show readNativePushAttention;
import '../../../core/utils/account_display.dart'
    show accountSubtitle, serverDisplayName;
import '../../../core/utils/native_sheet_utils.dart';
import '../../../shared/services/navigation_service.dart';
import '../../auth/services/server_address_service.dart';
import '../settings_page_module.dart';
import '../settings_pages.dart';

/// Prefix of the page of one saved Open WebUI server: its accounts and the
/// addresses it is reached at. The server's URI-encoded id follows.
const serverAddressesPagePrefix = nativeServerAddressesPagePrefix;

/// Prefix of an address's editor; `<server>:<address>` follows, each
/// URI-encoded, the address `new` for one being added.
const serverAddressPagePrefix = 'server-address:';

/// Prefix of an address editor's Advanced page; the editor's key follows.
const serverAddressAdvancedPagePrefix = 'server-address-advanced:';

/// Prefix of the page adding a header to an address; the editor's key
/// follows.
const serverAddressHeaderPagePrefix = 'server-address-header:';

/// The address key of an editor adding an address.
const serverAddressNewKey = 'new';

/// Sent by the server page's Add Account row, with the server's id.
const serverAddressesAddAccountActionId = 'server-add-account';

String serverAddressesPageId(String serverId) =>
    '$serverAddressesPagePrefix${Uri.encodeComponent(serverId)}';

/// The key of the editor of [endpointId] on [serverId], or of a new
/// address when [endpointId] is null.
String serverAddressEditorKey(String serverId, String? endpointId) =>
    '${Uri.encodeComponent(serverId)}:'
    '${Uri.encodeComponent(endpointId ?? serverAddressNewKey)}';

String serverAddressPageId(String serverId, String? endpointId) =>
    '$serverAddressPagePrefix${serverAddressEditorKey(serverId, endpointId)}';

/// A row of an address's pages: `server-address.<field>:<editor key>`, with
/// [extra] after another colon.
String serverAddressRowId(String field, String editorKey, [String? extra]) =>
    'server-address.$field:$editorKey'
    '${extra == null ? '' : ':${Uri.encodeComponent(extra)}'}';

/// A row of a server's page: `server-addresses.<field>:<server>[:<extra>]`.
String serverAddressesRowId(String field, String serverId, [String? extra]) =>
    'server-addresses.$field:${Uri.encodeComponent(serverId)}'
    '${extra == null ? '' : ':${Uri.encodeComponent(extra)}'}';

/// The server and address an editor key names.
({String serverId, String? endpointId})? _parseEditorKey(String key) {
  final parts = key.split(':');
  if (parts.length != 2) return null;
  final endpoint = Uri.decodeComponent(parts[1]);
  return (
    serverId: Uri.decodeComponent(parts[0]),
    endpointId: endpoint == serverAddressNewKey ? null : endpoint,
  );
}

/// A server's page: its accounts, switched to on a tap and signed out of
/// from their menus; then its addresses, in the order they are tried, each
/// opening its editor; then a row to add one.
@visibleForTesting
NativeSheetDetailConfig buildServerAddressesPage(
  AppLocalizations l10n, {
  required String serverId,
  required OpenWebUiServer? server,
  required List<OpenWebUiAccountEntry> accounts,
  required String? addressInUse,
  String? notice,
  Set<String> pushAttention = const {},
}) {
  final pageId = serverAddressesPageId(serverId);
  NativeSheetItemConfig problem(String title) => NativeSheetItemConfig(
    id: '$pageId-notice',
    title: title,
    sfSymbol: 'exclamationmark.triangle',
    kind: NativeSheetItemKind.info,
  );
  if (server == null) {
    return NativeSheetDetailConfig(
      id: pageId,
      title: l10n.accountsServerAddresses,
      items: [problem(notice ?? l10n.errorMessage)],
    );
  }
  final removable = server.endpoints.length > 1;
  return NativeSheetDetailConfig(
    id: pageId,
    title: serverDisplayName(server),
    sections: [
      if (notice != null) NativeSheetSectionConfig(items: [problem(notice)]),
      NativeSheetSectionConfig(
        title: l10n.accountsTitle,
        items: [
          for (final entry in accounts)
            buildNativeAccountItem(
              entry,
              l10n,
              subtitle: nativePushAttentionSubtitle(
                l10n,
                pushAttention,
                PushTarget.openWebUiScope(entry.id),
                accountSubtitle(entry, l10n),
              ),
              rowActions: [
                NativeSheetRowAction(
                  id: '$nativeAccountSignOutOfActionId:${entry.id}',
                  label: l10n.signOut,
                  sfSymbol: 'rectangle.portrait.and.arrow.right',
                  destructive: true,
                ),
              ],
            ),
          NativeSheetItemConfig(
            id: '$serverAddressesAddAccountActionId:$serverId',
            title: l10n.accountsAddOnThisServer,
            sfSymbol: 'plus.circle',
            accent: true,
            dismissOnSelect: true,
            showsDisclosure: false,
            actionId: serverAddressesAddAccountActionId,
            actionValue: serverId,
          ),
        ],
      ),
      NativeSheetSectionConfig(
        title: l10n.accountsServerAddresses,
        footer: l10n.accountsServerAddressesHelp,
        reorderActionId: serverAddressesRowId('order', serverId),
        items: [
          for (final endpoint in server.endpoints)
            NativeSheetItemConfig(
              id: serverAddressPageId(serverId, endpoint.id),
              title: _addressTitle(endpoint),
              subtitle: endpoint.id == addressInUse
                  ? '${endpoint.url}\n${l10n.accountsAddressInUse}'
                  : endpoint.url,
              sfSymbol: endpoint.id == addressInUse
                  ? 'checkmark.circle'
                  : 'network',
              rowActions: [
                if (removable)
                  NativeSheetRowAction(
                    id: serverAddressRowId(
                      'remove',
                      serverAddressEditorKey(serverId, endpoint.id),
                    ),
                    label: l10n.accountsRemoveAddress,
                    sfSymbol: 'trash',
                    destructive: true,
                    confirmMessage: l10n.accountsRemoveAddressMessage,
                  ),
              ],
            ),
        ],
      ),
      NativeSheetSectionConfig(
        items: [
          NativeSheetItemConfig(
            id: serverAddressPageId(serverId, null),
            title: l10n.accountsAddAddress,
            sfSymbol: 'plus.circle',
            accent: true,
          ),
        ],
      ),
    ],
  );
}

String _addressTitle(OpenWebUiEndpoint endpoint) {
  final label = endpoint.label?.trim();
  if (label != null && label.isNotEmpty) return label;
  final host = Uri.tryParse(endpoint.url)?.host;
  return host == null || host.isEmpty ? endpoint.url : host;
}

/// An address's editor: its name and URL, a row to its Advanced page, and
/// Remove for a saved one the server can do without. Done checks and saves.
@visibleForTesting
NativeSheetDetailConfig buildServerAddressPage(
  AppLocalizations l10n, {
  required String serverId,
  required String? endpointId,
  required ServerAddressDraft draft,
  required bool removable,
  required bool edited,
  bool busy = false,
  String? notice,
}) {
  final key = serverAddressEditorKey(serverId, endpointId);
  final pageId = serverAddressPageId(serverId, endpointId);
  final advanced = [
    if (draft.allowSelfSigned) l10n.allowSelfSignedCertificates,
    if (draft.hasCertificate || draft.hasPrivateKey) l10n.mutualTlsSectionTitle,
    if (draft.headers.isNotEmpty)
      '${l10n.customHeaders} (${draft.headers.length})',
  ];
  return NativeSheetDetailConfig(
    id: pageId,
    title: endpointId == null
        ? l10n.accountsAddAddress
        : l10n.accountsEditAddress,
    confirmActionId: serverAddressRowId('save', key),
    confirmActionLabel: l10n.accountsSaveAddress,
    discardPrompt: nativeDiscardPrompt(l10n),
    busy: busy,
    edited: edited,
    announcement: notice,
    sections: [
      if (busy)
        NativeSheetSectionConfig(
          items: [
            NativeSheetItemConfig(
              id: '$pageId-checking',
              title: l10n.connecting,
              sfSymbol: 'network',
              kind: NativeSheetItemKind.info,
              pending: true,
            ),
          ],
        )
      else if (notice != null)
        NativeSheetSectionConfig(
          items: [
            NativeSheetItemConfig(
              id: '$pageId-notice',
              title: notice,
              sfSymbol: 'exclamationmark.triangle',
              kind: NativeSheetItemKind.info,
            ),
          ],
        ),
      NativeSheetSectionConfig(
        footer: l10n.serverAddressFooter,
        items: [
          NativeSheetItemConfig(
            id: serverAddressRowId('label', key),
            title: l10n.accountsAddressName,
            sfSymbol: 'tag',
            kind: NativeSheetItemKind.textField,
            value: draft.label,
            placeholder: l10n.accountsAddressNameHint,
          ),
          NativeSheetItemConfig(
            id: serverAddressRowId('url', key),
            title: l10n.authFieldServer,
            sfSymbol: 'link',
            kind: NativeSheetItemKind.textField,
            value: draft.url,
            placeholder: l10n.serverUrlHint,
            keyboard: NativeSheetKeyboard.url,
          ),
        ],
      ),
      NativeSheetSectionConfig(
        items: [
          NativeSheetItemConfig(
            id: '$serverAddressAdvancedPagePrefix$key',
            title: l10n.advancedSettings,
            subtitle: advanced.isEmpty ? null : advanced.join(', '),
            sfSymbol: 'gearshape',
          ),
        ],
      ),
      if (endpointId != null && removable)
        NativeSheetSectionConfig(
          items: [
            NativeSheetItemConfig(
              id: serverAddressRowId('remove', key),
              title: l10n.accountsRemoveAddress,
              sfSymbol: 'trash',
              destructive: true,
              showsDisclosure: false,
              confirmMessage: l10n.accountsRemoveAddressMessage,
            ),
          ],
        ),
    ],
  );
}

/// An address's Advanced page: an unverified certificate trusted or not,
/// a client certificate with its key and the key's password, and the
/// headers sent with every request, each removed from its menu.
@visibleForTesting
NativeSheetDetailConfig buildServerAddressAdvancedPage(
  AppLocalizations l10n, {
  required String editorKey,
  required ServerAddressDraft draft,
  String? notice,
}) {
  final pageId = '$serverAddressAdvancedPagePrefix$editorKey';
  final tls =
      draft.hasCertificate ||
      draft.hasPrivateKey ||
      draft.normalizedPrivateKeyPassword != null;
  return NativeSheetDetailConfig(
    id: pageId,
    title: l10n.advancedSettings,
    announcement: notice,
    sections: [
      if (notice != null)
        NativeSheetSectionConfig(
          items: [
            NativeSheetItemConfig(
              id: '$pageId-notice',
              title: notice,
              sfSymbol: 'exclamationmark.triangle',
              kind: NativeSheetItemKind.info,
            ),
          ],
        ),
      NativeSheetSectionConfig(
        items: [
          NativeSheetItemConfig(
            id: serverAddressRowId('self-signed', editorKey),
            title: l10n.allowSelfSignedCertificates,
            subtitle: l10n.allowSelfSignedCertificatesDescription,
            sfSymbol: 'lock.open',
            kind: NativeSheetItemKind.toggle,
            value: draft.allowSelfSigned,
          ),
        ],
      ),
      NativeSheetSectionConfig(
        title: l10n.mutualTlsSectionTitle,
        footer: l10n.mutualTlsSectionDescription,
        items: [
          NativeSheetItemConfig(
            id: serverAddressRowId('pick-certificate', editorKey),
            title: l10n.mutualTlsSelectCertificate,
            subtitle: draft.certificateLabel ?? l10n.mutualTlsChooseFile,
            sfSymbol: 'doc.badge.gearshape',
            showsDisclosure: false,
          ),
          NativeSheetItemConfig(
            id: serverAddressRowId('pick-key', editorKey),
            title: l10n.mutualTlsSelectPrivateKey,
            subtitle: draft.privateKeyLabel ?? l10n.mutualTlsChooseFile,
            sfSymbol: 'key',
            showsDisclosure: false,
          ),
          NativeSheetItemConfig(
            id: serverAddressRowId('key-password', editorKey),
            title: l10n.password,
            sfSymbol: 'lock',
            kind: NativeSheetItemKind.secureTextField,
            value: draft.privateKeyPassword,
            placeholder: l10n.mutualTlsPrivateKeyPasswordHint,
          ),
          if (tls)
            NativeSheetItemConfig(
              id: serverAddressRowId('clear-tls', editorKey),
              title: l10n.mutualTlsClearCredentials,
              sfSymbol: 'trash',
              destructive: true,
              showsDisclosure: false,
            ),
        ],
      ),
      NativeSheetSectionConfig(
        title: l10n.customHeaders,
        footer: draft.headers.length >= maxServerAddressHeaders
            ? '${l10n.customHeadersDescription}\n\n'
                  '${l10n.maxHeadersReachedDetail}'
            : l10n.customHeadersDescription,
        items: [
          for (final header in draft.headers.entries)
            NativeSheetItemConfig(
              id: serverAddressRowId('header', editorKey, header.key),
              title: header.key,
              subtitle: header.value,
              sfSymbol: 'list.bullet.rectangle',
              kind: NativeSheetItemKind.info,
              rowActions: [
                NativeSheetRowAction(
                  id: serverAddressRowId(
                    'header-remove',
                    editorKey,
                    header.key,
                  ),
                  label: l10n.removeHeader,
                  sfSymbol: 'trash',
                  destructive: true,
                ),
              ],
            ),
          if (draft.headers.length < maxServerAddressHeaders)
            NativeSheetItemConfig(
              id: '$serverAddressHeaderPagePrefix$editorKey',
              title: l10n.addHeader,
              sfSymbol: 'plus.circle',
              accent: true,
            ),
        ],
      ),
    ],
  );
}

/// The page adding a header: its name and value; Done adds it.
@visibleForTesting
NativeSheetDetailConfig buildServerAddressHeaderPage(
  AppLocalizations l10n, {
  required String editorKey,
  String name = '',
  String value = '',
  String? notice,
}) {
  final pageId = '$serverAddressHeaderPagePrefix$editorKey';
  return NativeSheetDetailConfig(
    id: pageId,
    title: l10n.addHeader,
    confirmActionId: serverAddressRowId('header-add', editorKey),
    confirmActionLabel: l10n.addHeader,
    discardPrompt: nativeDiscardPrompt(l10n),
    announcement: notice,
    sections: [
      if (notice != null)
        NativeSheetSectionConfig(
          items: [
            NativeSheetItemConfig(
              id: '$pageId-notice',
              title: notice,
              sfSymbol: 'exclamationmark.triangle',
              kind: NativeSheetItemKind.info,
            ),
          ],
        ),
      NativeSheetSectionConfig(
        footer: l10n.customHeadersDescription,
        items: [
          NativeSheetItemConfig(
            id: serverAddressRowId('header-name', editorKey),
            title: l10n.headerName,
            sfSymbol: 'textformat',
            kind: NativeSheetItemKind.textField,
            value: name,
            placeholder: 'X-Custom-Header',
          ),
          NativeSheetItemConfig(
            id: serverAddressRowId('header-value', editorKey),
            title: l10n.headerValue,
            sfSymbol: 'text.alignleft',
            kind: NativeSheetItemKind.textField,
            value: value,
          ),
        ],
      ),
    ],
  );
}

/// One address editor while it is open: what it holds, what it held when
/// it opened, and what it last said.
final class _Editor {
  _Editor(this.draft) : original = draft.contents;

  final ServerAddressDraft draft;
  final Object original;

  /// The id a new address is saved under: one per editor, so saving again
  /// after a save that stored the address and then failed edits it rather
  /// than adding it twice.
  final String addedEndpointId = const Uuid().v4();
  String? notice;
  String? advancedNotice;
  bool busy = false;

  /// The header being added.
  String headerName = '';
  String headerValue = '';
  String? headerNotice;

  bool get edited => draft.contents != original;
}

/// The pages of a saved Open WebUI server's accounts and addresses: listing,
/// reordering and removing addresses, and an editor that checks an address
/// reaches the same server before saving it.
///
/// A proxy that wants its own sign-in hands the edit to the connection page,
/// which signs in through it in a page of its own.
class ServerAddressSettingsPages extends SettingsPageModule {
  ServerAddressSettingsPages(this._ref);

  final Ref _ref;
  final Map<String, _Editor> _editors = {};
  final Map<String, String> _notices = {};

  SettingsSurface get _surface => _ref.read(settingsSurfaceProvider);

  @override
  bool ownsPage(String detailId) =>
      detailId.startsWith(serverAddressesPagePrefix) ||
      detailId.startsWith(serverAddressPagePrefix) ||
      detailId.startsWith(serverAddressAdvancedPagePrefix) ||
      detailId.startsWith(serverAddressHeaderPagePrefix);

  @override
  Future<void> hydrate(String detailId, AppLocalizations l10n) async {
    if (detailId.startsWith(serverAddressesPagePrefix)) {
      final serverId = Uri.decodeComponent(
        detailId.substring(serverAddressesPagePrefix.length),
      );
      await _hydrateServer(l10n, serverId);
    } else if (detailId.startsWith(serverAddressPagePrefix)) {
      final key = detailId.substring(serverAddressPagePrefix.length);
      final editor = await _editor(key);
      if (editor == null) return;
      await _applyEditor(l10n, key, editor);
    } else if (detailId.startsWith(serverAddressAdvancedPagePrefix)) {
      final key = detailId.substring(serverAddressAdvancedPagePrefix.length);
      final editor = await _editor(key);
      if (editor == null) return;
      await _applyAdvanced(l10n, key, editor);
    } else if (detailId.startsWith(serverAddressHeaderPagePrefix)) {
      final key = detailId.substring(serverAddressHeaderPagePrefix.length);
      final editor = await _editor(key);
      if (editor == null) return;
      editor
        ..headerName = ''
        ..headerValue = ''
        ..headerNotice = null;
      await _applyHeader(l10n, key, editor);
    }
  }

  /// The server's page as stored now. Any editor opened from an earlier
  /// look at it starts over.
  Future<void> _hydrateServer(AppLocalizations l10n, String serverId) async {
    _editors.removeWhere(
      (key, _) => _parseEditorKey(key)?.serverId == serverId,
    );
    OpenWebUiServer? server;
    List<OpenWebUiAccountEntry> accounts = const [];
    var read = false;
    try {
      final registry = await _ref
          .read(optimizedStorageServiceProvider)
          .getOpenWebUiRegistryStrict();
      server = registry.server(serverId);
      final listening = _ref.listen(openWebUiAccountsProvider, (_, _) {});
      try {
        accounts = [
          for (final entry
              in await _ref
                  .read(openWebUiAccountsProvider.future)
                  .timeout(const Duration(seconds: 5)))
            if (entry.server.id == serverId) entry,
        ];
      } finally {
        listening.close();
      }
      read = true;
    } catch (error, stackTrace) {
      DebugLogger.error(
        'server-addresses-load-failed',
        scope: 'settings/addresses',
        error: error,
        stackTrace: stackTrace,
      );
      _notices[serverId] = l10n.errorMessage;
    }
    // Gone with its last account: its page goes too.
    if (read && server == null) {
      await _surface.closeDetail(serverAddressesPageId(serverId));
    }
    final route = _ref.read(openWebUiRouteResolverProvider);
    await _surface.applyDetail(
      buildServerAddressesPage(
        l10n,
        serverId: serverId,
        server: server,
        accounts: accounts,
        addressInUse: route.serverId == serverId ? route.endpointId : null,
        notice: _notices.remove(serverId),
        pushAttention: readNativePushAttention(_ref.read),
      ),
      detailSheets: [
        if (server != null) ...[
          for (final endpoint in server.endpoints)
            buildNativeLoadingDetail(
              l10n: l10n,
              id: serverAddressPageId(serverId, endpoint.id),
              title: l10n.accountsEditAddress,
            ),
          buildNativeLoadingDetail(
            l10n: l10n,
            id: serverAddressPageId(serverId, null),
            title: l10n.accountsAddAddress,
          ),
        ],
      ],
    );
  }

  /// The editor [key] names, opened from the address as stored when it is
  /// not open yet; null when that address is gone.
  Future<_Editor?> _editor(String key) async {
    final open = _editors[key];
    if (open != null) return open;
    final parsed = _parseEditorKey(key);
    if (parsed == null) return null;
    final endpointId = parsed.endpointId;
    if (endpointId == null) {
      return _editors[key] = _Editor(ServerAddressDraft());
    }
    try {
      final registry = await _ref
          .read(optimizedStorageServiceProvider)
          .getOpenWebUiRegistryStrict();
      final endpoint = registry.server(parsed.serverId)?.endpoint(endpointId);
      if (endpoint == null) return null;
      return _editors[key] ??= _Editor(ServerAddressDraft.of(endpoint));
    } catch (error, stackTrace) {
      DebugLogger.error(
        'server-address-load-failed',
        scope: 'settings/addresses',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  Future<bool> _removable(String serverId) async {
    try {
      final registry = await _ref
          .read(optimizedStorageServiceProvider)
          .getOpenWebUiRegistryStrict();
      return (registry.server(serverId)?.endpoints.length ?? 0) > 1;
    } catch (_) {
      return false;
    }
  }

  Future<void> _applyEditor(
    AppLocalizations l10n,
    String key,
    _Editor editor,
  ) async {
    final parsed = _parseEditorKey(key)!;
    await _surface.applyDetail(
      buildServerAddressPage(
        l10n,
        serverId: parsed.serverId,
        endpointId: parsed.endpointId,
        draft: editor.draft,
        removable: await _removable(parsed.serverId),
        edited: editor.edited,
        busy: editor.busy,
        notice: editor.notice,
      ),
      detailSheets: [
        buildServerAddressAdvancedPage(
          l10n,
          editorKey: key,
          draft: editor.draft,
        ),
        buildServerAddressHeaderPage(l10n, editorKey: key),
      ],
    );
  }

  Future<void> _applyAdvanced(
    AppLocalizations l10n,
    String key,
    _Editor editor,
  ) => _surface.applyDetail(
    buildServerAddressAdvancedPage(
      l10n,
      editorKey: key,
      draft: editor.draft,
      notice: editor.advancedNotice,
    ),
    detailSheets: [buildServerAddressHeaderPage(l10n, editorKey: key)],
  );

  Future<void> _applyHeader(
    AppLocalizations l10n,
    String key,
    _Editor editor,
  ) => _surface.applyDetail(
    buildServerAddressHeaderPage(
      l10n,
      editorKey: key,
      name: editor.headerName,
      value: editor.headerValue,
      notice: editor.headerNotice,
    ),
  );

  @override
  Future<bool> handleChange(
    String id,
    Object? value,
    AppLocalizations l10n,
  ) async {
    if (id.startsWith('server-addresses.order:') && value is List) {
      final serverId = Uri.decodeComponent(
        id.substring('server-addresses.order:'.length),
      );
      await _reorder(l10n, serverId, value.whereType<String>().toList());
      return true;
    }
    if (!id.startsWith('server-address.')) return false;
    final separator = id.indexOf(':');
    if (separator < 0) return true;
    final field = id.substring('server-address.'.length, separator);
    final rest = id.substring(separator + 1).split(':');
    if (rest.length < 2) return true;
    final key = '${rest[0]}:${rest[1]}';
    final extra = rest.length > 2 ? Uri.decodeComponent(rest[2]) : null;
    final parsed = _parseEditorKey(key);
    if (parsed == null) return true;

    if (field == 'remove') {
      await _remove(l10n, parsed.serverId, parsed.endpointId, key);
      return true;
    }
    // A row of an editor already closed (a second Done on its way) does
    // nothing.
    final editor = _editors[key];
    if (editor == null || editor.busy) return true;
    final draft = editor.draft;
    switch (field) {
      case 'label' when value is String:
        draft.label = value;
      case 'url' when value is String:
        draft.url = value;
      case 'self-signed' when value is bool:
        draft.allowSelfSigned = value;
      case 'key-password' when value is String:
        draft.privateKeyPassword = value;
      case 'pick-certificate':
        await _pickPem(l10n, key, editor, isPrivateKey: false);
      case 'pick-key':
        await _pickPem(l10n, key, editor, isPrivateKey: true);
      case 'clear-tls':
        draft.clearMutualTls();
        editor.advancedNotice = null;
        await _applyAdvanced(l10n, key, editor);
      case 'header-remove' when extra != null:
        draft.headers.remove(extra);
        await _applyAdvanced(l10n, key, editor);
      case 'header-name' when value is String:
        editor.headerName = value;
      case 'header-value' when value is String:
        editor.headerValue = value;
      case 'header-add':
        await _addHeader(l10n, key, editor);
      case 'save':
        await _save(l10n, key, parsed.serverId, parsed.endpointId, editor);
    }
    return true;
  }

  Future<void> _pickPem(
    AppLocalizations l10n,
    String key,
    _Editor editor, {
    required bool isPrivateKey,
  }) async {
    try {
      // Over the Settings sheet, as a picker opened from one of its rows.
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: isPrivateKey
            ? const ['pem', 'key']
            : const ['pem', 'crt', 'cer'],
      );
      if (file == null) return;
      final pem = await readPickedPemFile(file, l10n);
      final problem = validatePickedPem(
        pem,
        isPrivateKey: isPrivateKey,
        l10n: l10n,
      );
      if (problem != null) {
        editor.advancedNotice = problem;
      } else {
        final label = pickedFileLabel(
          file,
          fallback: isPrivateKey ? 'client-key.pem' : 'client-cert.pem',
        );
        if (isPrivateKey) {
          editor.draft
            ..privateKeyPem = pem
            ..privateKeyLabel = label;
        } else {
          editor.draft
            ..certificatePem = pem
            ..certificateLabel = label;
        }
        editor.advancedNotice = null;
      }
    } on ServerAddressInputException catch (error) {
      editor.advancedNotice = error.message;
    } catch (error, stackTrace) {
      DebugLogger.error(
        'server-address-pick-failed',
        scope: 'settings/addresses',
        error: error,
        stackTrace: stackTrace,
      );
      editor.advancedNotice = l10n.mutualTlsFileReadFailed;
    }
    await _applyAdvanced(l10n, key, editor);
  }

  Future<void> _addHeader(
    AppLocalizations l10n,
    String key,
    _Editor editor,
  ) async {
    final name = editor.headerName.trim();
    final value = editor.headerValue.trim();
    final problem = validateServerAddressHeader(
      editor.draft.headers,
      name: name,
      value: value,
      l10n: l10n,
    );
    if (problem != null) {
      editor.headerNotice = problem;
      await _applyHeader(l10n, key, editor);
      return;
    }
    editor.draft.headers[name] = value;
    editor
      ..headerName = ''
      ..headerValue = ''
      ..headerNotice = null;
    await _surface.closeDetail('$serverAddressHeaderPagePrefix$key');
    await _applyAdvanced(l10n, key, editor);
  }

  /// Checks the address, then saves it, then goes back to the server's
  /// page; a refusal stays on the editor with why. A proxy that wants its
  /// own sign-in, once the user agrees, hands the edit to the connection
  /// page.
  Future<void> _save(
    AppLocalizations l10n,
    String key,
    String serverId,
    String? endpointId,
    _Editor editor,
  ) async {
    editor
      ..busy = true
      ..notice = null;
    await _applyEditor(l10n, key, editor);
    String? notice;
    var saved = false;
    try {
      final container = _ref.container;
      final check = await checkServerAddressDraft(
        container,
        serverId: serverId,
        endpointId: endpointId,
        draft: editor.draft,
        l10n: l10n,
      );
      switch (check) {
        case ServerAddressUnusable(:final message):
          notice = message;
        case ServerAddressBehindProxy():
          editor.busy = false;
          await _handOffToProxySignIn(l10n, key, serverId, endpointId, editor);
          return;
        case ServerAddressAnswered(:final config, :final sessionRevision):
          final outcome = await saveVerifiedServerAddress(
            container,
            serverId: serverId,
            endpointId: endpointId,
            addedEndpointId: editor.addedEndpointId,
            label: editor.draft.label,
            verified: config,
            sessionRevision: sessionRevision,
            l10n: l10n,
            confirmSendingSession: (address) async =>
                await _surface.ask(
                  title: l10n.accountsAddressConfirmTitle,
                  message: l10n.accountsAddressConfirmMessage(
                    address.authority,
                  ),
                  actions: [
                    NativeSheetAlertAction(
                      'cancel',
                      l10n.cancel,
                      style: NativeSheetAlertStyle.cancel,
                    ),
                    NativeSheetAlertAction(
                      'check',
                      l10n.accountsAddressConfirmAction,
                    ),
                  ],
                ) ==
                'check',
            confirmChangingInUse: () => _mayChangeAddressInUse(l10n),
            // Left while the address was checked: the edit is abandoned,
            // and the address stays as it was.
            stillWanted: () => identical(_editors[key], editor),
          );
          switch (outcome) {
            case ServerAddressSaved():
              saved = true;
            case ServerAddressNotSaved(:final message):
              notice = message;
          }
      }
    } catch (error, stackTrace) {
      DebugLogger.error(
        'server-address-save-failed',
        scope: 'settings/addresses',
        error: error,
        stackTrace: stackTrace,
      );
      notice = l10n.errorMessage;
    }
    editor.busy = false;
    // Left meanwhile, the editor is someone else's, or nobody's, now.
    if (!identical(_editors[key], editor)) return;
    if (saved) {
      _editors.remove(key);
      await _surface.closeDetail(serverAddressPageId(serverId, endpointId));
      return;
    }
    editor.notice = notice;
    await _applyEditor(l10n, key, editor);
  }

  /// Asks to sign in through the proxy in front of the address; agreed, the
  /// connection page takes the edit on from here, Settings closing over it.
  Future<void> _handOffToProxySignIn(
    AppLocalizations l10n,
    String key,
    String serverId,
    String? endpointId,
    _Editor editor,
  ) async {
    final answer = await _surface.ask(
      title: l10n.proxyAuthRequired,
      message: l10n.proxyAuthRequiredDescription,
      actions: [
        NativeSheetAlertAction(
          'cancel',
          l10n.cancel,
          style: NativeSheetAlertStyle.cancel,
        ),
        NativeSheetAlertAction('sign-in', l10n.authenticateThroughProxy),
      ],
    );
    if (answer != 'sign-in' || !identical(_editors[key], editor)) {
      await _applyEditor(l10n, key, editor);
      return;
    }
    _editors.remove(key);
    await _surface.closeDetail(serverAddressPageId(serverId, endpointId));
    final bridge = NativeSheetBridge.instance;
    if (bridge.settingsSheetOpen) await bridge.dismiss();
    unawaited(
      NavigationService.router.pushNamed<void>(
        RouteNames.serverAddressEditor,
        extra: ServerAddressEditorRequest(
          serverId: serverId,
          endpointId: endpointId,
          draft: editor.draft,
        ),
      ),
    );
  }

  /// Whether the address in use may change: yes, unless a reply arrives
  /// through it, which the user is asked to stop first.
  Future<bool> _mayChangeAddressInUse(AppLocalizations l10n) async {
    if (!_ref.read(addressChangeReplyGuardProvider)()) return true;
    final answer = await _surface.ask(
      title: l10n.accountsReplyInProgressTitle,
      message: l10n.accountsAddressChangeStopsReply,
      actions: [
        NativeSheetAlertAction(
          'cancel',
          l10n.cancel,
          style: NativeSheetAlertStyle.cancel,
        ),
        NativeSheetAlertAction(
          'change',
          l10n.accountsAddressChangeAnyway,
          style: NativeSheetAlertStyle.destructive,
        ),
      ],
    );
    if (answer != 'change') return false;
    try {
      _ref.read(addressChangeStopRepliesProvider)();
    } catch (error, stackTrace) {
      DebugLogger.error(
        'address-change-stop-replies-failed',
        scope: 'settings/addresses',
        error: error,
        stackTrace: stackTrace,
      );
    }
    return true;
  }

  /// Removes the address of [endpointId], asked first by its row; the
  /// address in use asks again while a reply arrives through it.
  Future<void> _remove(
    AppLocalizations l10n,
    String serverId,
    String? endpointId,
    String key,
  ) async {
    if (endpointId == null) return;
    final route = _ref.read(openWebUiRouteResolverProvider);
    if (route.serverId == serverId &&
        route.endpointId == endpointId &&
        !await _mayChangeAddressInUse(l10n)) {
      return;
    }
    await _editRoutes(
      l10n,
      serverId,
      (endpoints) => [
        for (final endpoint in endpoints)
          if (endpoint.id != endpointId) endpoint,
      ],
    );
    _editors.remove(key);
    await _surface.closeDetail(serverAddressPageId(serverId, endpointId));
    await _hydrateServer(l10n, serverId);
  }

  /// Puts the addresses in the order of [rowIds], as dragged.
  Future<void> _reorder(
    AppLocalizations l10n,
    String serverId,
    List<String> rowIds,
  ) async {
    final order = [
      for (final rowId in rowIds)
        if (rowId.startsWith(serverAddressPagePrefix))
          ?_parseEditorKey(rowId.substring(serverAddressPagePrefix.length))
              ?.endpointId,
    ];
    await _editRoutes(
      l10n,
      serverId,
      (endpoints) => [
        for (final id in order)
          ?endpoints.where((endpoint) => endpoint.id == id).firstOrNull,
        for (final endpoint in endpoints)
          if (!order.contains(endpoint.id)) endpoint,
      ],
    );
    await _hydrateServer(l10n, serverId);
  }

  /// Applies [edit] to the addresses as stored, not as the page last showed
  /// them: another edit may have landed since.
  Future<void> _editRoutes(
    AppLocalizations l10n,
    String serverId,
    List<OpenWebUiEndpoint> Function(List<OpenWebUiEndpoint>) edit,
  ) async {
    try {
      await _ref
          .read(optimizedStorageServiceProvider)
          .editServerEndpoints(serverId, edit);
      await reloadAfterRoutesEdited(_ref.container, serverId);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'server-addresses-save-failed',
        scope: 'settings/addresses',
        error: error,
        stackTrace: stackTrace,
      );
      _notices[serverId] = l10n.errorMessage;
    }
  }
}
