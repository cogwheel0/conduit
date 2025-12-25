import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/services/api_service.dart';
import 'enhanced_image_attachment.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'dart:convert';
import '../../../core/services/worker_manager.dart';

class EnhancedAttachment extends ConsumerStatefulWidget {
  final String attachmentId;
  final bool isMarkdownFormat;
  final BoxConstraints? constraints;
  final bool isUserMessage;
  final bool disableAnimation;

  const EnhancedAttachment({
    super.key,
    required this.attachmentId,
    this.isMarkdownFormat = false,
    this.constraints,
    this.isUserMessage = false,
    this.disableAnimation = false,
  });

  @override
  ConsumerState<EnhancedAttachment> createState() => _EnhancedAttachmentState();
}

class _EnhancedAttachmentState extends ConsumerState<EnhancedAttachment> {
  Map<String, dynamic>? _fileInfo;
  bool _isLoading = true;
  String? _error;
  String? _localFilePath;

  @override
  void initState() {
    super.initState();
    _resolveType();
  }

  Future<void> _resolveType() async {
    try {
      // Data URL for images – short-circuit to image widget
      if (widget.attachmentId.startsWith('data:image/')) {
        if (!mounted) return;
        setState(() {
          _isLoading = false;
          _fileInfo = {'mime': 'image/inline'};
        });
        return;
      }

      final api = ref.read(apiServiceProvider);
      if (api is! ApiService) {
        if (!mounted) return;
        setState(() {
          _isLoading = false;
          _error = 'Service unavailable';
        });
        return;
      }

      final info = await api.getFileInfo(widget.attachmentId);
      if (!mounted) return;
      setState(() {
        _fileInfo = info;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Failed to load attachment';
        _isLoading = false;
      });
    }
  }

  bool _isImageFile(Map<String, dynamic>? info) {
    if (info == null) return false;
    final mime = (info['content_type'] ?? info['mime'] ?? '')
        .toString()
        .toLowerCase();
    if (mime.startsWith('image/')) return true;
    final name = (info['filename'] ?? info['name'] ?? '')
        .toString()
        .toLowerCase();
    final ext = name.split('.').length > 1 ? name.split('.').last : '';
    return ['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp'].contains(ext);
  }

  Future<String?> _ensureLocalFile() async {
    if (_localFilePath != null && await File(_localFilePath!).exists()) {
      return _localFilePath;
    }
    try {
      final api = ref.read(apiServiceProvider);
      if (api is! ApiService) return null;

      final content = await api.getFileContent(widget.attachmentId);
      final filename = (_fileInfo?['filename'] ?? _fileInfo?['name'] ?? 'file')
          .toString();
      final dir = await getTemporaryDirectory();
      final filePath = '${dir.path}/$filename';

      final worker = ref.read(workerManagerProvider);
      try {
        if (_looksLikeBase64(content)) {
          final bytes = await worker.schedule<String, Uint8List>(
            _decodeAttachmentBase64,
            content,
            debugLabel: 'attachment_decode_bytes',
          );
          await File(filePath).writeAsBytes(bytes, flush: true);
        } else {
          await File(filePath).writeAsString(content, flush: true);
        }
      } catch (_) {
        await File(filePath).writeAsString(content, flush: true);
      }

      _localFilePath = filePath;
      return _localFilePath;
    } catch (e) {
      setState(() {
        _error = 'Failed to prepare file';
      });
      return null;
    }
  }

  Future<void> _shareFile() async {
    final path = await _ensureLocalFile();
    if (path == null) return;
    final filename = (_fileInfo?['filename'] ?? _fileInfo?['name'] ?? 'file')
        .toString();
    await SharePlus.instance.share(
      ShareParams(files: [XFile(path, name: filename)]),
    );
  }

  String _fileIconFor(String filename) {
    final lower = filename.toLowerCase();
    String ext = '';
    final parts = lower.split('.');
    if (parts.length > 1) ext = parts.last;
    if (['pdf', 'doc', 'docx'].contains(ext)) return '📄';
    if (['xls', 'xlsx'].contains(ext)) return '📊';
    if (['ppt', 'pptx'].contains(ext)) return '📊';
    if (['jpg', 'jpeg', 'png', 'gif', 'webp'].contains(ext)) return '🖼️';
    if (['js', 'ts', 'py', 'dart', 'java', 'cpp'].contains(ext)) return '💻';
    if (['html', 'css', 'json', 'xml'].contains(ext)) return '🌐';
    if (['zip', 'rar', '7z', 'tar', 'gz'].contains(ext)) return '📦';
    if (['mp3', 'wav', 'flac', 'm4a'].contains(ext)) return '🎵';
    if (['mp4', 'avi', 'mov', 'mkv'].contains(ext)) return '🎬';
    return '📎';
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Container(
        width: widget.constraints?.maxWidth ?? 160,
        height: 84,
        decoration: BoxDecoration(
          color: context.conduitTheme.cardBackground,
          borderRadius: BorderRadius.circular(AppBorderRadius.md),
          border: Border.all(
            color: context.conduitTheme.textPrimary.withValues(alpha: 0.1),
            width: BorderWidth.regular,
          ),
        ),
      );
    }

    if (_error != null) {
      return Container(
        padding: const EdgeInsets.all(Spacing.sm),
        decoration: BoxDecoration(
          color: context.conduitTheme.surfaceContainer,
          borderRadius: BorderRadius.circular(AppBorderRadius.md),
          border: Border.all(
            color: context.conduitTheme.error.withValues(alpha: 0.3),
            width: BorderWidth.regular,
          ),
        ),
        child: Text(
          _error!,
          style: TextStyle(
            color: context.conduitTheme.error,
            fontSize: AppTypography.labelMedium,
          ),
        ),
      );
    }

    // Image: delegate to existing image widget for consistency
    if (_isImageFile(_fileInfo)) {
      return EnhancedImageAttachment(
        attachmentId: widget.attachmentId,
        isMarkdownFormat: widget.isMarkdownFormat,
        constraints: widget.constraints,
        isUserMessage: widget.isUserMessage,
        disableAnimation: widget.disableAnimation,
      );
    }

    final filename = (_fileInfo?['filename'] ?? _fileInfo?['name'] ?? 'File')
        .toString();
    final size = _fileInfo?['size'];
    final sizeLabel = size is num ? _formatSize(size.toInt()) : null;
    final lowerName = filename.toLowerCase();
    final fileExtension = lowerName.contains('.')
        ? lowerName.split('.').last
        : '';
    final List<String> metaParts = [];
    if (fileExtension.isNotEmpty) {
      metaParts.add('.${fileExtension.toUpperCase()}');
    }
    if (sizeLabel != null) {
      metaParts.add(sizeLabel);
    }
    final metaLabel = metaParts.join(' • ');

    final card = Container(
      constraints: widget.constraints,
      padding: const EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: context.conduitTheme.cardBackground,
        borderRadius: BorderRadius.circular(AppBorderRadius.md),
        border: Border.all(
          color: context.conduitTheme.textPrimary.withValues(alpha: 0.12),
          width: BorderWidth.regular,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _fileIconFor(filename),
            style: const TextStyle(fontSize: AppTypography.headlineLarge),
          ),
          const SizedBox(width: Spacing.sm),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  filename,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: context.conduitTheme.textPrimary,
                    fontSize: AppTypography.labelLarge,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (metaLabel.isNotEmpty)
                  Text(
                    metaLabel,
                    style: TextStyle(
                      color: context.conduitTheme.textSecondary.withValues(
                        alpha: 0.7,
                      ),
                      fontSize: AppTypography.labelMedium,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );

    return InkWell(
      borderRadius: BorderRadius.circular(AppBorderRadius.md),
      onTap: () async {
        await HapticFeedback.mediumImpact();
        await _shareFile();
      },
      child: card,
    );
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}

bool _looksLikeBase64(String content) {
  if (content.length <= 128) return false;
  final sanitized = content.replaceAll('\n', '');
  return RegExp(r'^[A-Za-z0-9+/=]+$').hasMatch(sanitized);
}

Uint8List _decodeAttachmentBase64(String raw) {
  final sanitized = raw.replaceAll('\n', '');
  return base64Decode(sanitized);
}
