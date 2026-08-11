import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/network/conduit_user_agent.dart';
import '../../../../core/network/image_header_utils.dart';
import '../../../../core/providers/app_providers.dart';
import '../../../../core/services/raster_media_policy.dart';
import '../../../../shared/theme/theme_extensions.dart';

/// Renders an inline model avatar or lazily loads the persisted server image.
final class WorkspaceModelAvatar extends ConsumerStatefulWidget {
  const WorkspaceModelAvatar({
    super.key,
    required this.draftImage,
    required this.modelId,
    this.removed = false,
  });

  final String? draftImage;
  final String modelId;

  /// Prevents re-fetching a persisted image after an unsaved removal.
  final bool removed;

  @override
  ConsumerState<WorkspaceModelAvatar> createState() =>
      _WorkspaceModelAvatarState();
}

final class _WorkspaceModelAvatarState
    extends ConsumerState<WorkspaceModelAvatar> {
  Future<List<int>?>? _imageFuture;
  String? _fetchedModelId;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final decodeTarget = RasterMediaPolicy.forBox(
      context,
      profile: RasterDecodeProfile.avatar,
      logicalWidth: 56,
      logicalHeight: 56,
    );
    final draftImage = widget.draftImage;
    final modelId = widget.modelId;
    final placeholder = Container(
      key: const Key('workspace-model-avatar-placeholder'),
      width: 56,
      height: 56,
      decoration: BoxDecoration(
        color: theme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppBorderRadius.medium),
      ),
      child: Icon(Icons.smart_toy_outlined, color: theme.iconSecondary),
    );

    Widget wrap(Widget child) => ClipRRect(
      borderRadius: BorderRadius.circular(AppBorderRadius.medium),
      child: SizedBox(width: 56, height: 56, child: child),
    );

    if (draftImage != null && draftImage.startsWith('data:image')) {
      try {
        final bytes = base64Decode(draftImage.split(',').last);
        return wrap(
          Image(
            image: RasterMediaPolicy.resizeProvider(
              MemoryImage(bytes),
              decodeTarget,
            ),
            fit: BoxFit.cover,
          ),
        );
      } catch (_) {
        return placeholder;
      }
    }
    if (draftImage != null && draftImage.startsWith('http')) {
      final api = ref.watch(apiServiceProvider);
      final headers = imageUrlIsServerOrigin(api?.serverConfig.url, draftImage)
          ? ConduitUserAgent.mergeHeaders()
          : null;
      return wrap(
        Image(
          image: RasterMediaPolicy.resizeProvider(
            NetworkImage(draftImage, headers: headers),
            decodeTarget,
          ),
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => placeholder,
        ),
      );
    }
    if (modelId.isEmpty || widget.removed) return placeholder;

    if (_fetchedModelId != modelId) {
      _fetchedModelId = modelId;
      _imageFuture = ref
          .read(apiServiceProvider)
          ?.getWorkspaceModelProfileImage(modelId);
    }

    return FutureBuilder<List<int>?>(
      future: _imageFuture,
      builder: (context, snapshot) {
        final data = snapshot.data;
        if (data == null || data.isEmpty) return placeholder;
        return wrap(
          Image(
            image: RasterMediaPolicy.resizeProvider(
              MemoryImage(Uint8List.fromList(data)),
              decodeTarget,
            ),
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => placeholder,
          ),
        );
      },
    );
  }
}
