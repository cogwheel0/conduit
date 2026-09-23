import 'dart:async';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';

import '../l10n/strings.g.dart';
import '../rpc/direct_providers.dart';
import '../widgets/form_field.dart';

/// One Ollama connection's models (M4): whether each is in memory, loading
/// and unloading it, how long it stays loaded, and for Ollama Cloud how
/// much it thinks.
///
/// Mobile puts these in each model's menu in the picker; the desktop's
/// picker is a plain list, so they live with the connection instead.
class OllamaModels extends StatefulComponent {
  const OllamaModels({required this.connectionId, super.key});

  final String connectionId;

  @override
  State<OllamaModels> createState() => _OllamaModelsState();
}

/// The keep-alive presets mobile offers, and what each is called.
final List<(String?, String Function())> _keepAlives =
    <(String?, String Function())>[
      (null, () => t.app.ollamaKeepAliveServerDefault),
      ('5m', () => t.app.ollamaKeepAliveFiveMinutes),
      ('30m', () => t.app.ollamaKeepAliveThirtyMinutes),
      ('1h', () => t.app.ollamaKeepAliveOneHour),
      ('-1', () => t.app.ollamaKeepAliveAlways),
      ('0', () => t.app.ollamaKeepAliveImmediate),
    ];

final List<(String?, String Function())> _thinking =
    <(String?, String Function())>[
      (null, () => t.app.ollamaThinkingAutomatic),
      ('disabled', () => t.app.ollamaThinkingDisabled),
      ('low', () => t.app.ollamaThinkingLow),
      ('medium', () => t.app.ollamaThinkingMedium),
      ('high', () => t.app.ollamaThinkingHigh),
    ];

const String _custom = '__custom__';

class _OllamaModelsState extends State<OllamaModels> {
  OllamaModelList? _list;
  String? _error;
  final Set<String> _busy = <String>{};

  /// The model whose custom keep-alive is being typed, and the text.
  String? _customFor;
  String _customValue = '';

  @override
  void initState() {
    super.initState();
    unawaited(_run(ConduitMethods.directOllamaModels, null));
  }

  /// Calls [method] and shows the list it answers with.
  Future<void> _run(String method, OllamaModelAction? action) async {
    final model = action?.model;
    setState(() {
      _error = null;
      if (model != null) _busy.add(model);
    });
    try {
      final list = await context
          .read(directActionsProvider)
          .ollama(method, connectionId: component.connectionId, action: action);
      if (!mounted) return;
      setState(() => _list = list);
    } on RpcError catch (error) {
      if (!mounted) return;
      setState(
        () => _error =
            method == ConduitMethods.directOllamaKeepAlive &&
                error.code == ConduitErrorCodes.invalidParams
            ? t.app.ollamaKeepAliveInvalid
            : method == ConduitMethods.directOllamaModels
            ? t.app.directConnectionReachFailed
            : t.app.ollamaModelActionFailed,
      );
    } finally {
      if (mounted && model != null) setState(() => _busy.remove(model));
    }
  }

  OllamaModelAction _action(String model, [String? value]) =>
      OllamaModelAction(id: component.connectionId, model: model, value: value);

  @override
  Component build(BuildContext context) {
    final list = _list;
    return div(
      classes: 'mt-2 space-y-2 border-t border-border pt-2',
      attributes: <String, String>{
        'role': 'group',
        'aria-label': t.app.ollamaModelActions,
      },
      [
        if (_error case final error?) formError(error),
        if (list == null && _error == null)
          p(classes: 'text-ui-sm text-muted-foreground', [
            Component.text(t.app.directMcpContentLoading),
          ]),
        if (list != null)
          ul(classes: 'space-y-1.5', [
            for (final model in list.models) _row(list, model),
          ]),
      ],
    );
  }

  Component _row(OllamaModelList list, OllamaModelStatus model) {
    final busy = _busy.contains(model.id);
    final presets = _keepAlives.map((entry) => entry.$1).toSet();
    final custom =
        _customFor == model.id ||
        (model.keepAlive != null && !presets.contains(model.keepAlive));
    return li(classes: 'flex flex-wrap items-center gap-2 text-ui-base', [
      span(classes: 'min-w-0 flex-1 truncate font-mono text-xs', [
        Component.text(model.name),
      ]),
      if (model.loaded == true)
        span(
          classes: 'rounded-full border border-primary px-2 text-ui-sm text-foreground',
          [Component.text(t.app.ollamaModelLoaded)],
        ),
      if (list.lifecycle) ...[
        button(
          [
            Component.text(
              model.loaded == true
                  ? t.app.ollamaUnloadModel
                  : t.app.ollamaLoadModel,
            ),
          ],
          classes: 'rounded px-2 py-0.5 text-ui-sm hover:bg-accent disabled:opacity-50',
          type: ButtonType.button,
          disabled: busy,
          onClick: () {
            if (busy) return;
            unawaited(
              _run(
                model.loaded == true
                    ? ConduitMethods.directOllamaUnload
                    : ConduitMethods.directOllamaLoad,
                _action(model.id),
              ),
            );
          },
        ),
        select(
          [
            for (final (value, labelOf) in _keepAlives)
              option(
                value: value ?? '',
                selected: !custom && model.keepAlive == value,
                [Component.text(labelOf())],
              ),
            option(value: _custom, selected: custom, [
              Component.text(
                custom && model.keepAlive != null && _customFor != model.id
                    ? '${t.app.ollamaKeepAliveCustom}: ${model.keepAlive}'
                    : t.app.ollamaKeepAliveCustom,
              ),
            ]),
          ],
          classes: 'rounded border border-border bg-background px-1.5 py-0.5 text-ui-sm',
          attributes: <String, String>{
            'aria-label': '${t.app.ollamaKeepAlive}: ${model.name}',
          },
          disabled: busy,
          onChange: (values) {
            final value = values.firstOrNull;
            if (value == _custom) {
              setState(() {
                _customFor = model.id;
                _customValue = model.keepAlive ?? '';
              });
              return;
            }
            setState(() => _customFor = null);
            unawaited(
              _run(
                ConduitMethods.directOllamaKeepAlive,
                _action(
                  model.id,
                  value == null || value.isEmpty ? null : value,
                ),
              ),
            );
          },
        ),
        if (_customFor == model.id)
          form(
            classes: 'flex basis-full items-center justify-end gap-2',
            events: <String, EventCallback>{
              'submit': (event) => event.preventDefault(),
            },
            [
              textField(
                id: 'keep-alive-${model.id}',
                labelText: t.app.ollamaKeepAlive,
                hideLabel: true,
                placeholder: t.app.ollamaKeepAliveCustomHint,
                value: _customValue,
                onInput: (value) => setState(() => _customValue = value),
              ),
              button(
                [Component.text(t.app.save)],
                classes:
                    'rounded bg-primary px-2 py-1 text-ui-sm '
                    'text-primary-foreground',
                type: ButtonType.button,
                onClick: () {
                  final value = _customValue.trim();
                  setState(() => _customFor = null);
                  unawaited(
                    _run(
                      ConduitMethods.directOllamaKeepAlive,
                      _action(model.id, value.isEmpty ? null : value),
                    ),
                  );
                },
              ),
            ],
          ),
      ],
      if (list.cloud)
        select(
          [
            for (final (value, labelOf) in _thinking)
              option(value: value ?? '', selected: model.thinking == value, [
                Component.text(labelOf()),
              ]),
          ],
          classes: 'rounded border border-border bg-background px-1.5 py-0.5 text-ui-sm',
          attributes: <String, String>{
            'aria-label': '${t.app.ollamaThinking}: ${model.name}',
          },
          disabled: busy,
          onChange: (values) {
            final value = values.firstOrNull;
            unawaited(
              _run(
                ConduitMethods.directOllamaThinking,
                _action(
                  model.id,
                  value == null || value.isEmpty ? null : value,
                ),
              ),
            );
          },
        ),
    ]);
  }
}
