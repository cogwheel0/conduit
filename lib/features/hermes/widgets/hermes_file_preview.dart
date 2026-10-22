import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_backend_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:dio/dio.dart';
import 'package:share_plus/share_plus.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/platform_ui/platform_ui.dart';
import '../../chat/widgets/enhanced_image_attachment.dart';
import '../providers/hermes_mobile_files.dart';
import 'hermes_session_tile.dart';
import 'hermes_mobile_shell.dart' show HermesLoadError;
import 'package:conduit_core/features/hermes/models/hermes_media.dart';
import 'hermes_media_attachment.dart';

Future<void> showHermesFilePreview(
  BuildContext context,
  WidgetRef ref,
  HermesLibraryFile file,
) {
  final media = HermesMediaReference.fromPath(file.outputPath, name: file.name);
  if (media != null) return showHermesMedia(context, media, sessionId: file.session.id);
  return showCompactConversationSheet(
  context,
  _FilePreview(
    file: file,
    onOpen: () => openHermesSession(context, ref, file.session),
  ),
  );
}

class _FilePreview extends ConsumerStatefulWidget {
  const _FilePreview({required this.file, required this.onOpen});
  final Future<void> Function() onOpen;
  final HermesLibraryFile file;
  @override
  ConsumerState<_FilePreview> createState() => _FilePreviewState();
}

class _FilePreviewState extends ConsumerState<_FilePreview> {
  late final HermesBackendService? _service;
  final _cancel = CancelToken();
  Future<String>? _data;
  bool _sharing = false;
  bool _shareError = false;
  @override
  void initState() {
    super.initState();
    _service = ref.read(hermesApiServiceProvider);
    _load();
  }

  void _load() {
    final service = _service;
    if (service is HermesDesktopApiService && widget.file.outputPath != null) {
      _data = service.readSessionFileDataUrl(
        widget.file.outputPath!,
        widget.file.session.id,
        cancelToken: _cancel,
      );
    }
  }

  @override
  void dispose() {
    _cancel.cancel();
    super.dispose();
  }

  Future<void> _share(String source) async {
    setState(() {
      _sharing = true;
      _shareError = false;
    });
    try {
      final data = UriData.parse(source);
      final bytes = Uint8List.fromList(data.contentAsBytes());
      if (bytes.length > 8 * 1024 * 1024) throw const FormatException();
      final name = widget.file.name.replaceAll(
        RegExp(r'[^a-zA-Z0-9._ -]'),
        '_',
      );
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile.fromData(bytes, mimeType: data.mimeType, name: name)],
          fileNameOverrides: [name],
        ),
      );
    } catch (_) {
      if (mounted) {
        setState(() => _shareError = true);
      }
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  Widget _preview(String source) {
    final l10n = AppLocalizations.of(context)!;
    try {
      final data = UriData.parse(source);
      final bytes = Uint8List.fromList(data.contentAsBytes());
      if (bytes.length > 8 * 1024 * 1024) throw const FormatException();
      return Column(
        children: [
          if (data.mimeType.startsWith('image/'))
            Image.memory(
              bytes,
              height: 260,
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => Text(l10n.mobilePreviewUnavailable),
            )
          else if (data.mimeType.startsWith('text/') ||
              data.mimeType == 'application/json')
            SelectableText(
              utf8.decode(bytes.take(100000).toList(), allowMalformed: true),
            )
          else
            Text(l10n.mobilePreviewUnavailable),
          AdaptiveButton.child(
            style: AdaptiveButtonStyle.plain,
            onPressed: _sharing ? null : () => _share(source),
            child: Text(l10n.mobileSaveShare),
          ),
        ],
      );
    } catch (_) {
      return Text(l10n.mobilePreviewUnavailable);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // Close over the authenticated transport that admitted this file. A
    // connection switch must hide the previous account's preview immediately.
    if (!identical(ref.watch(hermesApiServiceProvider), _service)) {
      _cancel.cancel();
      return Center(child: Text(l10n.mobileLoadFailed));
    }
    final file = widget.file;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(file.name, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 16),
        if (file.extractedText != null) ...[
          Text(l10n.mobileExtractedPreview),
          const SizedBox(height: 8),
          SelectableText(file.extractedText!),
        ] else if (file.imageId != null)
          EnhancedImageAttachment(
            attachmentId: file.imageId!,
            constraints: const BoxConstraints(maxWidth: 340, maxHeight: 280),
          )
        else if (_data != null)
          FutureBuilder<String>(
            future: _data,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return HermesLoadError(onRetry: () => setState(_load));
              }
              if (!snapshot.hasData) {
                return const Center(child: AdaptiveProgressIndicator());
              }
              return _preview(snapshot.data!);
            },
          )
        else
          Text(l10n.mobilePreviewUnavailable),
        if (_shareError) Text(l10n.mobileLoadFailed),
        AdaptiveButton.child(
          style: AdaptiveButtonStyle.plain,
          onPressed: () async {
            Navigator.of(context).pop();
            await widget.onOpen();
          },
          child: Text(l10n.mobileOpenConversation),
        ),
      ],
    );
  }
}
