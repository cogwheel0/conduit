import 'dart:async';

import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/features/chat/server_speech/server_speech_providers.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/widgets.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/services/ios_native_dropdown_bridge.dart';
import '../../../shared/widgets/themed_dialogs.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/platform_ui/platform_ui.dart';
import '../../../shared/widgets/platform_ui/vocabulary.dart';
import '../providers/composer_draft_provider.dart';
import '../services/native_stt_service.dart';

final composerRecordingsProvider = StreamProvider.autoDispose
    .family<List<ComposerRecording>, ComposerDraftContext>((ref, owner) {
      if (owner.temporary || owner.store == null) return Stream.value(const []);
      return owner.store!.recordings.watch(owner.scope, owner.chatId);
    });

final recordingShareProvider =
    Provider<Future<ShareResult> Function(ShareParams)>(
      (_) => SharePlus.instance.share,
    );

enum _RecordingError { export, transcription, discard, capture }

/// Recoverable audio is part of the unsent draft, never chat history. Keying
/// this widget by its owner also retires pending transcription UI when
/// the user changes chats or accounts.
class ComposerRecordings extends ConsumerStatefulWidget {
  const ComposerRecordings({
    super.key,
    required this.owner,
    required this.onInsert,
    this.activeId,
    this.transcribing = false,
    this.transcriptionErrorId,
    this.captureErrorId,
    this.onTranscribingChanged,
  });

  final ComposerDraftContext owner;
  final String? activeId;
  final bool transcribing;
  final String? transcriptionErrorId;
  final String? captureErrorId;
  final void Function(ComposerDraftContext, bool)? onTranscribingChanged;
  final void Function(String) onInsert;

  @override
  ConsumerState<ComposerRecordings> createState() => _ComposerRecordingsState();
}

class _ComposerRecordingsState extends ConsumerState<ComposerRecordings> {
  final _nativeStt = NativeSttService();
  int _transcriptionGeneration = 0;
  String? _busy;
  _RecordingError? _error;
  String? _errorId;
  bool _confirmingDiscard = false;

  bool get _ownsInput =>
      mounted && ref.read(composerDraftContextProvider) == widget.owner;

  @override
  void initState() {
    super.initState();
    _takeTranscriptionError();
  }

  @override
  void didUpdateWidget(covariant ComposerRecordings oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.transcriptionErrorId != oldWidget.transcriptionErrorId ||
        widget.captureErrorId != oldWidget.captureErrorId) {
      _takeTranscriptionError();
    }
  }

  void _takeTranscriptionError() {
    if (widget.captureErrorId != null) {
      _errorId = widget.captureErrorId;
      _error = _RecordingError.capture;
    } else if (widget.transcriptionErrorId != null) {
      _errorId = widget.transcriptionErrorId;
      _error = _RecordingError.transcription;
    }
  }

  @override
  void dispose() {
    ++_transcriptionGeneration;
    if (_busy != null) {
      final owner = widget.owner;
      final notify = widget.onTranscribingChanged;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => notify?.call(owner, false),
      );
    }
    unawaited(_nativeStt.cancelRecordingTranscription());
    super.dispose();
  }

  Future<void> _export(String id) async {
    if (_busy != null || !_ownsInput) return;
    final origin = context.findRenderObject() as RenderBox?;
    final shareOrigin = origin == null
        ? null
        : origin.localToGlobal(Offset.zero) & origin.size;
    try {
      final wav = await widget.owner.store!.recordings.readWav(id);
      if (!_ownsInput) return;
      await ref.read(recordingShareProvider)(
        ShareParams(
          files: [XFile.fromData(wav, mimeType: 'audio/wav')],
          fileNameOverrides: ['recording.wav'],
          sharePositionOrigin: shareOrigin,
        ),
      );
    } catch (_) {
      if (_ownsInput) {
        setState(() {
          _errorId = id;
          _error = _RecordingError.export;
        });
      }
    }
  }

  Future<bool> _confirmDiscard() async {
    final l10n = AppLocalizations.of(context)!;
    if (PlatformUiCapabilities.usesNativeIOS26) {
      try {
        return await IosNativeDropdownBridge.instance.showFromContext(
              context: context,
              title: l10n.recordingDiscard,
              message: l10n.recordingDiscardConfirmation,
              cancelLabel: l10n.cancel,
              options: [
                IosNativeDropdownOption(
                  id: 'discard',
                  label: l10n.recordingDiscard,
                  destructive: true,
                ),
              ],
              rethrowErrors: true,
            ) ==
            'discard';
      } catch (_) {
        if (!mounted) return false;
      }
    }
    return ThemedDialogs.confirm(
      context,
      title: l10n.recordingDiscard,
      message: l10n.recordingDiscardConfirmation,
      confirmText: l10n.recordingDiscard,
      isDestructive: true,
      // Use a compact alert rather than the helper's native detail page.
      barrierDismissible: false,
    );
  }

  Future<void> _transcribe(String id, {required bool onDevice}) async {
    if (_busy != null || !_ownsInput) return;
    final generation = ++_transcriptionGeneration;
    final speech = ref.read(serverSpeechProviderProvider);
    final language = SettingsService.normalizeSttLanguageCode(
      ref.read(appSettingsProvider).sttLanguageCode,
    );
    setState(() {
      _busy = id;
      _error = null;
    });
    widget.onTranscribingChanged?.call(widget.owner, true);
    try {
      final store = widget.owner.store!.recordings;
      final String text;
      if (onDevice) {
        final pcm = await store.readPcm(id);
        if (!_ownsInput || generation != _transcriptionGeneration) return;
        text = await _nativeStt.transcribeRecording(pcm, localeId: language);
      } else {
        if (speech?.canTranscribe != true) {
          throw StateError('STT unavailable');
        }
        final wav = await store.readWav(id);
        if (!_ownsInput || generation != _transcriptionGeneration) return;
        text = await speech!.transcribe(
          wav,
          fileName: 'recording.wav',
          mimeType: 'audio/wav',
          language: language,
        );
      }
      if (text.trim().isEmpty) throw StateError('Empty transcription');
      if (_ownsInput && generation == _transcriptionGeneration) {
        widget.onInsert(text.trim());
      }
    } catch (_) {
      if (_ownsInput && generation == _transcriptionGeneration) {
        setState(() {
          _errorId = id;
          _error = _RecordingError.transcription;
        });
      }
    } finally {
      if (mounted && generation == _transcriptionGeneration) {
        setState(() => _busy = null);
        widget.onTranscribingChanged?.call(widget.owner, false);
      }
    }
  }

  Future<void> _discard(String id) async {
    if (_busy != null || _confirmingDiscard || !_ownsInput) return;
    _confirmingDiscard = true;
    try {
      final confirmed = await _confirmDiscard();
      if (!confirmed || !_ownsInput || _busy != null) return;
      await widget.owner.store!.recordings.discard(id);
      if (mounted) {
        setState(() {
          _error = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _errorId = id;
          _error = _RecordingError.discard;
        });
      }
    } finally {
      _confirmingDiscard = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(composerRecordingsProvider(widget.owner), (_, next) {
      final items = next.asData?.value;
      if (items == null) return;
      final ids = items.map((item) => item.id).toSet();
      // Sending or discarding a draft also retires its pending audio work.
      if (_busy != null && !ids.contains(_busy)) {
        ++_transcriptionGeneration;
        _busy = null;
        widget.onTranscribingChanged?.call(widget.owner, false);
        unawaited(_nativeStt.cancelRecordingTranscription());
      }
      if (_errorId != null && !ids.contains(_errorId)) _error = null;
    });
    final recordings = ref.watch(composerRecordingsProvider(widget.owner));
    final l10n = AppLocalizations.of(context)!;
    return recordings.when(
      loading: () => const SizedBox.shrink(),
      error: (_, _) => Padding(
        padding: const EdgeInsets.all(12),
        child: AdaptiveButton(
          label: l10n.recordingLoadFailed,
          style: AdaptiveButtonStyle.plain,
          onPressed: () =>
              ref.invalidate(composerRecordingsProvider(widget.owner)),
        ),
      ),
      data: (items) {
        if (items.isEmpty) return const SizedBox.shrink();
        return ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 200),
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final item in items)
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${item.id == widget.activeId
                                ? widget.transcribing
                                      ? l10n.transcribingAudio
                                      : l10n.recordingAudio
                                : l10n.savedRecording} · ${_duration(item.byteCount)}',
                          ),
                        ),
                        if (item.id != widget.activeId &&
                            item.byteCount > 0) ...[
                          if (_busy == item.id)
                            const Padding(
                              padding: EdgeInsets.all(12),
                              child: AdaptiveProgressIndicator(),
                            )
                          else
                            AdaptivePopupMenuButton.icon<String>(
                              icon: Icons.more_horiz,
                              enabled: _busy == null && widget.activeId == null,
                              items: [
                                AdaptivePopupMenuItem(
                                  value: 'server',
                                  label: l10n.transcribeOnServer,
                                ),
                                AdaptivePopupMenuItem(
                                  value: 'device',
                                  label: l10n.transcribeOnDevice,
                                ),
                                AdaptivePopupMenuItem(
                                  value: 'export',
                                  label: l10n.exportRecording,
                                ),
                                AdaptivePopupMenuItem(
                                  value: 'discard',
                                  label: l10n.recordingDiscard,
                                  isDestructive: true,
                                ),
                              ],
                              onSelected: (_, entry) => switch (entry.value) {
                                'server' => unawaited(
                                  _transcribe(item.id, onDevice: false),
                                ),
                                'device' => unawaited(
                                  _transcribe(item.id, onDevice: true),
                                ),
                                'export' => unawaited(_export(item.id)),
                                _ => unawaited(_discard(item.id)),
                              },
                            ),
                        ] else if (item.id != widget.activeId)
                          AdaptiveButton.icon(
                            icon: Icons.delete_outline,
                            semanticLabel: l10n.recordingDiscard,
                            style: AdaptiveButtonStyle.plain,
                            onPressed: () => unawaited(_discard(item.id)),
                          ),
                      ],
                    ),
                  if (_error != null)
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: AdaptivePopupMenuButton.text<String>(
                        key: const ValueKey('recording-error'),
                        label: l10n.error,
                        tint: context.conduitTheme.error,
                        buttonStyle: PopupButtonStyle.glass,
                        shrinkWrap: true,
                        items: [
                          AdaptivePopupMenuItem<String>(
                            label: switch (_error!) {
                              _RecordingError.export =>
                                l10n.recordingExportFailed,
                              _RecordingError.transcription =>
                                l10n.recordingTranscriptionFailed,
                              _RecordingError.discard =>
                                l10n.recordingDiscardFailed,
                              _RecordingError.capture =>
                                l10n.recordingCaptureInterrupted,
                            },
                            enabled: false,
                          ),
                          if (_error == _RecordingError.export)
                            AdaptivePopupMenuItem<String>(
                              value: 'export',
                              label: l10n.exportRecording,
                            )
                          else if (_error == _RecordingError.discard)
                            AdaptivePopupMenuItem<String>(
                              value: 'discard',
                              label: l10n.recordingDiscard,
                              isDestructive: true,
                            )
                          else ...[
                            AdaptivePopupMenuItem<String>(
                              value: 'server',
                              label: l10n.transcribeOnServer,
                            ),
                            AdaptivePopupMenuItem<String>(
                              value: 'device',
                              label: l10n.transcribeOnDevice,
                            ),
                          ],
                        ],
                        onSelected: (_, entry) =>
                            unawaited(switch (entry.value) {
                              'export' => _export(_errorId!),
                              'discard' => _discard(_errorId!),
                              _ => _transcribe(
                                _errorId!,
                                onDevice: entry.value == 'device',
                              ),
                            }),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  String _duration(int bytes) {
    final seconds = bytes ~/ 32000;
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }
}
