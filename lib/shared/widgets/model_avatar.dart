import 'package:flutter/material.dart';

import '../theme/theme_extensions.dart';
import 'user_avatar.dart';

/// Displays a model's avatar image with automatic caching and fallback UI.
///
/// The avatar can display:
/// - Network images from the OpenWebUI model avatar endpoint
/// - Data URIs (base64-encoded images)
/// - A fallback UI showing the first letter of the model name or a brain icon
///
/// Images are automatically cached using [CachedNetworkImage] with proper
/// authentication headers. The cache respects self-signed certificates if
/// configured.
///
/// Usage:
/// ```dart
/// final avatarUrl = resolveModelIconUrlForModel(apiService, model);
/// ModelAvatar(size: 40, imageUrl: avatarUrl, label: model.name)
/// ```
class ModelAvatar extends StatelessWidget {
  /// The size (width and height) of the avatar in logical pixels.
  final double size;

  /// The URL of the avatar image. Should be obtained via
  /// [resolveModelIconUrlForModel] to use the correct OpenWebUI endpoint.
  final String? imageUrl;

  /// The model name, used for the fallback UI (shows first letter).
  final String? label;

  const ModelAvatar({super.key, required this.size, this.imageUrl, this.label});

  @override
  Widget build(BuildContext context) {
    return AvatarImage(
      size: size,
      imageUrl: imageUrl,
      borderRadius: BorderRadius.circular(AppBorderRadius.small),
      fallbackBuilder: (context, size) {
        final theme = context.qonduitTheme;
        String? uppercase;
        final trimmed = label?.trim();
        if (trimmed != null && trimmed.isNotEmpty) {
          uppercase = trimmed.substring(0, 1).toUpperCase();
        }

        return Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: theme.buttonPrimary.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(AppBorderRadius.small),
            border: Border.all(
              color: theme.buttonPrimary.withValues(alpha: 0.25),
              width: BorderWidth.thin,
            ),
          ),
          alignment: Alignment.center,
          child: uppercase != null
              ? Text(
                  uppercase,
                  style: AppTypography.small.copyWith(
                    color: theme.buttonPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                )
              : Icon(
                  Icons.psychology,
                  color: theme.buttonPrimary,
                  size: size * 0.5,
                ),
        );
      },
    );
  }
}
