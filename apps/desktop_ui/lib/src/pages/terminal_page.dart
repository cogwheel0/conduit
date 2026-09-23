import 'dart:async';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:jaspr_router/jaspr_router.dart';

import '../l10n/strings.g.dart';
import '../rpc/chat_providers.dart' show selectedChatIdProvider;
import '../rpc/rpc_providers.dart'
    show
        attachmentsProvider,
        fileSaverProvider,
        rpcClientProvider,
        windowCommandsProvider;
import '../rpc/terminal_providers.dart';
import '../terminal_port.dart';
import '../widgets/form_field.dart';
import 'workspace/workspace_common.dart'
    show actionButton, confirmBox, modal, statusLine, workspaceGo;

/// The terminal (M7): a shell on one of the account's terminal servers,
/// its files and its listening ports.
class TerminalPage extends StatelessComponent {
  const TerminalPage({super.key});

  @override
  Component build(BuildContext context) {
    final servers = context.watch(terminalServersProvider);
    final value = servers.value;
    return div(classes: 'flex h-screen min-h-0 bg-background text-foreground', [
      if (value == null)
        div(classes: 'flex flex-1 items-center justify-center', [
          statusLine(
            servers.hasError
                ? t.app.terminalFailedToConnect
                : t.app.loadingShort,
          ),
        ])
      else if (value.servers.isEmpty)
        div(classes: 'flex flex-1 flex-col items-center justify-center gap-3', [
          statusLine(t.app.terminalNoServersConfigured),
          Link(
            to: '/',
            classes: 'text-ui-sm text-muted-foreground hover:underline',
            child: Component.text('← ${t.app.back}'),
          ),
        ])
      else
        TerminalWorkspace(servers: value),
    ]);
  }
}

/// The page once there are servers. Attaches to the selected one and
/// keeps a shell open on it.
class TerminalWorkspace extends StatefulComponent {
  const TerminalWorkspace({required this.servers, super.key});

  final TerminalServers servers;

  @override
  State<TerminalWorkspace> createState() => _TerminalWorkspaceState();
}

class _TerminalWorkspaceState extends State<TerminalWorkspace> {
  static const String _hostId = 'terminal-host';

  late String _serverId;
  TerminalAttached? _attached;
  TerminalViewSession? _session;
  TerminalLinkState _link = TerminalLinkState.disconnected;
  bool _fullscreen = false;

  TerminalListing? _listing;
  List<TerminalPort> _ports = const <TerminalPort>[];
  String? _status;
  bool _statusIsError = false;
  bool _busy = false;

  /// A file being shown, and the folder being named, and the entry being
  /// renamed or deleted.
  TerminalFileContent? _preview;
  String? _previewPath;
  bool _namingFolder = false;
  String? _renaming;
  String? _deleting;
  String _name = '';

  late TerminalActions _actions;
  late TerminalViewPort _view;

  @override
  void initState() {
    super.initState();
    final servers = component.servers;
    _serverId = servers.selectedId ?? servers.servers.first.id;
  }

  @override
  void dispose() {
    _session?.close();
    super.dispose();
  }

  void _say(String text, {bool error = false}) => setState(() {
    _status = text;
    _statusIsError = error;
  });

  Future<void> _attach() async {
    _session?.close();
    _session = null;
    setState(() {
      _attached = null;
      _listing = null;
      _ports = const <TerminalPort>[];
    });
    try {
      final attached = await _actions.attach(_serverId);
      if (!mounted) return;
      setState(() => _attached = attached);
      if (!attached.supported) {
        _say(t.app.terminalFeatureDisabled, error: true);
      } else {
        // After this frame, so the host element exists to draw into.
        Future<void>.delayed(Duration.zero, _connect);
      }
      await Future.wait(<Future<void>>[_open(attached.cwd), _loadPorts()]);
      await _showRequested();
    } on Object {
      _say(t.app.terminalFailedToConnect, error: true);
    }
  }

  void _connect() {
    final attached = _attached;
    if (attached == null || !mounted) return;
    _session?.close();
    _session = _view.open(
      _hostId,
      handle: attached.handle,
      onState: (state) {
        if (mounted) setState(() => _link = state);
      },
    );
  }

  void _disconnect() {
    _session?.close();
    _session = null;
    setState(() => _link = TerminalLinkState.disconnected);
  }

  Future<void> _open(String path) async {
    final attached = _attached;
    if (attached == null) return;
    try {
      final listing = await _actions.list(attached.handle, path);
      if (mounted) setState(() => _listing = listing);
    } on Object {
      _say(t.app.terminalFailedToLoadFiles, error: true);
    }
  }

  Future<void> _loadPorts() async {
    final attached = _attached;
    if (attached == null) return;
    try {
      final ports = await _actions.ports(attached.handle);
      if (mounted) setState(() => _ports = ports.ports);
    } on Object {
      _say(t.app.terminalFailedToLoadPorts, error: true);
    }
  }

  Future<void> _run(
    Future<void> Function(String handle) action, {
    required String failed,
  }) async {
    final attached = _attached;
    if (attached == null) return;
    setState(() => _busy = true);
    try {
      await action(attached.handle);
      await _open(_listing?.path ?? attached.cwd);
    } on Object {
      _say(failed, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _select(String serverId) async {
    setState(() => _serverId = serverId);
    try {
      await _actions.select(serverId);
    } on Object {
      // The choice still applies to this page.
    }
    await _attach();
  }

  Future<void> _upload(BuildContext context) async {
    final attachments = context.read(attachmentsProvider);
    final picked = await attachments.pick();
    final attached = _attached;
    final directory = _listing?.path;
    if (picked.isEmpty || attached == null || directory == null) return;
    await _run((handle) async {
      for (final file in picked) {
        await attachments.upload(
          file.handle,
          terminal: (handle: handle, directory: directory),
        );
      }
    }, failed: t.app.terminalUploadFailed);
  }

  Future<void> _show(TerminalEntry entry) => _showPath(entry.path);

  Future<void> _showPath(String path) async {
    final attached = _attached;
    if (attached == null) return;
    try {
      final content = await _actions.read(attached.handle, path);
      if (mounted) {
        setState(() {
          _preview = content;
          _previewPath = path;
        });
      }
    } on Object {
      _say(t.app.terminalPreviewUnavailable, error: true);
    }
  }

  /// A file a model's tool asked to show (`terminal.displayFile`): its
  /// folder, and the file itself open over it.
  Future<void> _showRequested() async {
    if (_attached == null || !mounted) return;
    final path = context.read(terminalDisplayFileProvider.notifier).take();
    if (path == null) return;
    final slash = path.lastIndexOf('/');
    if (slash > 0) await _open(path.substring(0, slash + 1));
    await _showPath(path);
  }

  Future<void> _download(BuildContext context, String path) async {
    final saver = context.read(fileSaverProvider);
    final attached = _attached;
    if (attached == null) return;
    try {
      final file = await _actions.download(attached.handle, path);
      saver.save(
        filename: file.name,
        mimeType: file.contentType,
        text: file.text,
        base64: file.base64,
      );
    } on Object {
      _say(t.app.terminalDownloadFailed, error: true);
    }
  }

  Future<void> _previewPort(BuildContext context, int port) async {
    final commands = context.read(windowCommandsProvider);
    final attached = _attached;
    if (attached == null) return;
    try {
      commands.openExternal(await _actions.previewPort(attached.handle, port));
    } on Object {
      _say(t.app.terminalFailedToLoadPorts, error: true);
    }
  }

  bool _started = false;

  @override
  Component build(BuildContext context) {
    _actions = context.read(terminalActionsProvider);
    _view = context.read(terminalViewProvider);
    // Asked for while the page is already open.
    if (context.watch(terminalDisplayFileProvider) != null &&
        _attached != null) {
      Future<void>.microtask(_showRequested);
    }
    if (!_started) {
      _started = true;
      Future<void>.delayed(Duration.zero, _attach);
    }
    return div(classes: 'flex min-h-0 flex-1', [
      if (!_fullscreen) _sidePanel(context),
      _console(context),
      if (_preview case final preview?) _previewModal(context, preview),
    ]);
  }

  Component _sidePanel(BuildContext context) {
    final servers = component.servers.servers;
    final listing = _listing;
    return nav(
      classes:
          'flex w-80 shrink-0 flex-col gap-3 overflow-y-auto border-r '
          'border-border bg-card p-3',
      attributes: <String, String>{'aria-label': t.app.terminal},
      [
        div(classes: 'flex items-center gap-2', [
          Link(
            to: '/',
            classes: 'rounded px-2 py-1 text-ui-base hover:bg-accent',
            attributes: <String, String>{'aria-label': t.app.back},
            child: Component.text('←'),
          ),
          h1(classes: 'flex-1 text-ui-base font-semibold', [
            Component.text(t.app.terminal),
          ]),
        ]),
        if (servers.length > 1)
          select(
            [
              for (final server in servers)
                option(value: server.id, selected: server.id == _serverId, [
                  Component.text(server.name),
                ]),
            ],
            id: 'terminal-server',
            classes:
                'w-full rounded border border-border bg-background px-2 py-2 '
                'text-ui-base',
            attributes: <String, String>{
              'aria-label': t.app.terminalSelectServer,
            },
            onChange: (values) {
              if (values.isNotEmpty && values.first != _serverId) {
                unawaited(_select(values.first));
              }
            },
          )
        else
          p(classes: 'text-ui-base', [Component.text(servers.single.name)]),
        if (_status case final status?)
          statusLine(status, error: _statusIsError),
        section(
          classes: 'space-y-2',
          attributes: <String, String>{
            'aria-label': t.app.terminalCurrentPathLabel,
          },
          [
            div(classes: 'flex flex-wrap items-center gap-1', [
              actionButton(
                t.app.terminalHomeAction,
                disabled: _attached == null,
                onClick: () => unawaited(_open(_attached!.cwd)),
              ),
              if (listing != null && listing.path != '/')
                actionButton(
                  '..',
                  ariaLabel: t.app.back,
                  onClick: () => unawaited(_open(_parent(listing.path))),
                ),
              actionButton(
                t.app.terminalUploadAction,
                id: 'terminal-upload',
                disabled: listing == null || _busy,
                onClick: () => unawaited(_upload(context)),
              ),
              actionButton(
                t.app.workspaceKnowledgeNewFolder,
                id: 'terminal-new-folder',
                disabled: listing == null || _busy,
                onClick: () => setState(() {
                  _namingFolder = true;
                  _name = '';
                }),
              ),
            ]),
            if (listing != null)
              code(classes: 'block truncate text-ui-sm text-muted-foreground', [
                Component.text(listing.path),
              ]),
            if (_namingFolder)
              _nameField(
                id: 'terminal-folder-name',
                label: t.app.terminalFolderNameHint,
                onSave: (name) => _run(
                  (handle) => _actions.fileAction(
                    handle,
                    TerminalFileOp.mkdir,
                    '${listing!.path}$name',
                  ),
                  failed: t.app.terminalFolderCreateFailed,
                ),
                onDone: () => setState(() => _namingFolder = false),
              ),
            if (listing != null && listing.entries.isEmpty)
              statusLine(t.app.terminalNoFiles),
            ul(classes: 'space-y-0.5', [
              for (final entry in listing?.entries ?? const <TerminalEntry>[])
                _entryRow(context, entry),
            ]),
          ],
        ),
        section(
          classes: 'space-y-2 border-t border-border pt-3',
          attributes: <String, String>{
            'aria-label': t.app.terminalPortsSectionLabel,
          },
          [
            div(classes: 'flex items-center gap-2', [
              h2(classes: 'flex-1 text-ui-sm font-semibold', [
                Component.text(t.app.terminalPortsSectionLabel),
              ]),
              actionButton(
                '↻',
                ariaLabel: t.app.workspaceKnowledgeRefreshFiles,
                onClick: () => unawaited(_loadPorts()),
              ),
            ]),
            if (_ports.isEmpty) statusLine(t.app.terminalNoPorts),
            ul(classes: 'space-y-1', [
              for (final port in _ports)
                li(classes: 'flex items-center gap-2 text-ui-base', [
                  code([Component.text('${port.port}')]),
                  span(
                    classes: 'min-w-0 flex-1 truncate text-ui-sm text-muted-foreground',
                    [Component.text(port.process ?? '')],
                  ),
                  actionButton(
                    t.app.terminalOpenInBrowserAction,
                    onClick: () => unawaited(_previewPort(context, port.port)),
                  ),
                ]),
            ]),
          ],
        ),
      ],
    );
  }

  Component _entryRow(BuildContext context, TerminalEntry entry) => li(
    classes: 'space-y-1',
    attributes: <String, String>{'data-entry': entry.path},
    [
      div(classes: 'group flex items-center gap-1 text-ui-base', [
        button(
          [Component.text('${entry.directory ? '📁' : '📄'} ${entry.name}')],
          classes:
              'min-w-0 flex-1 truncate rounded px-1 py-0.5 text-left '
              'hover:bg-accent',
          type: ButtonType.button,
          onClick: () =>
              unawaited(entry.directory ? _open(entry.path) : _show(entry)),
        ),
        if (!entry.directory)
          actionButton(
            '↓',
            ariaLabel: '${t.app.download}: ${entry.name}',
            onClick: () => unawaited(_download(context, entry.path)),
          ),
        actionButton(
          '✎',
          ariaLabel: '${t.app.rename}: ${entry.name}',
          onClick: () => setState(() {
            _renaming = entry.path;
            _name = entry.name;
          }),
        ),
        actionButton(
          '✕',
          ariaLabel: '${t.app.delete}: ${entry.name}',
          onClick: () => setState(() => _deleting = entry.path),
        ),
      ]),
      if (_renaming == entry.path)
        _nameField(
          id: 'terminal-rename',
          label: t.app.rename,
          initial: entry.name,
          onSave: (name) => _run(
            (handle) => _actions.fileAction(
              handle,
              TerminalFileOp.move,
              entry.path,
              destination:
                  '${_parent(entry.path)}$name${entry.directory ? '/' : ''}',
            ),
            failed: t.app.terminalRenameFailed,
          ),
          onDone: () => setState(() => _renaming = null),
        ),
      if (_deleting == entry.path)
        confirmBox(
          title: '${t.app.delete} ${entry.name}?',
          confirmText: t.app.delete,
          onConfirm: () {
            setState(() => _deleting = null);
            unawaited(
              _run(
                (handle) => _actions.fileAction(
                  handle,
                  TerminalFileOp.delete,
                  entry.path,
                ),
                failed: t.app.terminalDeleteFailed,
              ),
            );
          },
          onCancel: () => setState(() => _deleting = null),
        ),
    ],
  );

  Component _nameField({
    required String id,
    required String label,
    required Future<void> Function(String name) onSave,
    required void Function() onDone,
    String initial = '',
  }) => div(classes: 'flex items-end gap-1', [
    div(classes: 'flex-1', [
      textField(
        id: id,
        labelText: label,
        value: _name.isEmpty ? initial : _name,
        autofocus: true,
        onInput: (value) => setState(() => _name = value),
      ),
    ]),
    actionButton(
      t.app.save,
      primary: true,
      id: '$id-save',
      disabled: _name.trim().isEmpty,
      onClick: () {
        final name = _name.trim();
        onDone();
        unawaited(onSave(name));
      },
    ),
    actionButton(t.app.cancel, onClick: onDone),
  ]);

  Component _console(BuildContext context) {
    final label = switch (_link) {
      TerminalLinkState.connecting => t.app.terminalConnectingStatus,
      TerminalLinkState.connected => t.app.terminalConnectedStatus,
      TerminalLinkState.failed => t.app.terminalFailedToConnect,
      TerminalLinkState.disconnected => t.app.terminalDisconnectedStatus,
    };
    final live =
        _link == TerminalLinkState.connected ||
        _link == TerminalLinkState.connecting;
    return main_(
      classes: _fullscreen
          ? 'fixed inset-0 z-40 flex flex-col bg-background p-2'
          : 'flex min-w-0 flex-1 flex-col p-3',
      [
        div(classes: 'mb-2 flex flex-wrap items-center gap-2', [
          span(
            classes: 'flex-1 text-ui-sm text-muted-foreground',
            attributes: const <String, String>{'role': 'status'},
            [Component.text(label)],
          ),
          if (_attached?.supported ?? false)
            live
                ? actionButton(
                    t.app.terminalDisconnectAction,
                    onClick: _disconnect,
                  )
                : actionButton(
                    t.app.terminalConnectAction,
                    primary: true,
                    id: 'terminal-connect',
                    onClick: _connect,
                  ),
          actionButton(
            t.app.terminalCopyAction,
            onClick: () async {
              final copied = await _session?.copy() ?? false;
              if (!copied) _say(t.app.terminalNothingToCopy);
            },
          ),
          actionButton(
            t.app.terminalPasteAction,
            disabled: _link != TerminalLinkState.connected,
            onClick: () => unawaited(_session?.paste()),
          ),
          actionButton(
            _fullscreen ? t.app.close : t.app.terminalExpandAction,
            id: 'terminal-fullscreen',
            onClick: () {
              setState(() => _fullscreen = !_fullscreen);
              // Once the new size is on screen.
              Future<void>.delayed(Duration.zero, () {
                _session?.fit();
                _session?.focus();
              });
            },
          ),
        ]),
        // xterm's; the page renders nothing inside it.
        div(
          id: _hostId,
          classes:
              'terminal-host min-h-0 flex-1 overflow-hidden rounded border '
              'border-border bg-card p-1',
          [],
        ),
      ],
    );
  }

  Component _previewModal(BuildContext context, TerminalFileContent file) {
    void close() => setState(() {
      _preview = null;
      _previewPath = null;
    });
    final path = _previewPath;
    return modal(
      label: file.name,
      width: 'max-w-3xl',
      onClose: close,
      children: [
        if (file.text case final text?)
          pre(
            classes:
                'max-h-[60vh] overflow-auto rounded bg-muted p-3 font-mono '
                'text-xs',
            [Component.text(text)],
          )
        else if (file.contentType.startsWith('image/') && file.base64 != null)
          img(
            src: 'data:${file.contentType};base64,${file.base64}',
            alt: file.name,
            classes: 'max-h-[60vh] max-w-full',
          )
        else
          statusLine(t.app.terminalPreviewUnavailable),
        div(classes: 'flex justify-end gap-2', [
          if (path != null)
            actionButton(
              t.app.download,
              onClick: () => unawaited(_download(context, path)),
            ),
          actionButton(t.app.close, onClick: close),
        ]),
      ],
    );
  }

  static String _parent(String path) {
    final trimmed = path.endsWith('/')
        ? path.substring(0, path.length - 1)
        : path;
    final slash = trimmed.lastIndexOf('/');
    return slash <= 0 ? '/' : trimmed.substring(0, slash + 1);
  }
}

/// Whether the terminal is offered: an account with a terminal server.
bool terminalOffered(TerminalServers? servers) =>
    servers != null && servers.servers.isNotEmpty;

/// Hears `terminal.displayFile` for the open conversation, and takes the
/// window to the terminal with the file shown (M7).
class TerminalDisplayRequests extends StatefulComponent {
  const TerminalDisplayRequests({super.key});

  @override
  State<TerminalDisplayRequests> createState() =>
      _TerminalDisplayRequestsState();
}

class _TerminalDisplayRequestsState extends State<TerminalDisplayRequests> {
  StreamSubscription<EventEnvelope>? _events;

  @override
  void initState() {
    super.initState();
    _events = context.read(rpcClientProvider).events.listen((envelope) {
      if (envelope.event != ConduitEvents.terminalDisplayFile || !mounted) {
        return;
      }
      final request = TerminalDisplayFile.fromJson(envelope.payload);
      if (request.chatId != context.read(selectedChatIdProvider)) return;
      context.read(terminalDisplayFileProvider.notifier).show(request.path);
      workspaceGo(context, '/terminal');
    });
  }

  @override
  void dispose() {
    unawaited(_events?.cancel());
    super.dispose();
  }

  @override
  Component build(BuildContext context) => const Component.fragment([]);
}
