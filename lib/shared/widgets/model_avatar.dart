import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import '../../core/services/native_symbol_image_service.dart';
import '../theme/theme_extensions.dart';
import 'user_avatar.dart';

/// Displays a model's avatar image with automatic caching and fallback UI.
///
/// The avatar can display:
/// - Network images from the OpenWebUI model avatar endpoint
/// - Data URIs (base64-encoded images)
/// - A system symbol, for models the platform itself provides
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
    final symbolName = nativeSymbolNameFromUrl(imageUrl);
    if (symbolName != null) {
      return _SymbolAvatar(size: size, symbolName: symbolName);
    }

    return AvatarImage(
      size: size,
      imageUrl: imageUrl,
      tintColor:
          imageUrl?.trim().startsWith('asset:') == true &&
              Theme.of(context).brightness == Brightness.dark
          ? Colors.white
          : null,
      borderRadius: BorderRadius.circular(AppBorderRadius.small),
      fallbackBuilder: (context, size) =>
          _ModelAvatarPlaceholder(size: size, label: label),
    );
  }
}

/// A model avatar backed by a system symbol, drawn on the same tinted plate the
/// lettered fallback uses so every avatar keeps one shape.
///
/// The platform rasterizes the glyph once per size; until it lands, and on
/// platforms that have no such symbol, the plate keeps Conduit's own mark.
class _SymbolAvatar extends StatefulWidget {
  const _SymbolAvatar({required this.size, required this.symbolName});

  final double size;
  final String symbolName;

  @override
  State<_SymbolAvatar> createState() => _SymbolAvatarState();
}

class _SymbolAvatarState extends State<_SymbolAvatar> {
  static const double _glyphFraction = 0.62;

  Uint8List? _glyph;
  double? _requestedScale;

  double get _pointSize => widget.size * _glyphFraction;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolveGlyph();
  }

  @override
  void didUpdateWidget(_SymbolAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.symbolName != widget.symbolName ||
        oldWidget.size != widget.size) {
      _glyph = null;
      _requestedScale = null;
      _resolveGlyph();
    }
  }

  void _resolveGlyph() {
    final scale = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
    if (_requestedScale == scale) return;
    _requestedScale = scale;

    // A request that is already in flight keeps running when the avatar moves
    // to another symbol or size, so its completion has to prove it still
    // describes what the widget wants.
    final name = widget.symbolName;
    final pointSize = _pointSize;

    final service = NativeSymbolImageService.instance;
    final cached = service.cached(name, pointSize: pointSize, scale: scale);
    if (cached != null) {
      _glyph = cached;
      return;
    }
    if (service.isResolved(name, pointSize: pointSize, scale: scale)) {
      return;
    }

    service.load(name, pointSize: pointSize, scale: scale).then((bytes) {
      if (!mounted ||
          bytes == null ||
          _requestedScale != scale ||
          widget.symbolName != name ||
          _pointSize != pointSize) {
        return;
      }
      setState(() => _glyph = bytes);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final glyph = _glyph;
    return _ModelAvatarPlaceholder(
      size: widget.size,
      label: null,
      child: glyph == null
          // Conduit's own mark stands in until the platform glyph lands, and
          // wherever the system has no such symbol.
          ? Icon(
              Icons.auto_awesome,
              color: theme.buttonPrimary,
              size: _pointSize,
            )
          : Image.memory(
              glyph,
              width: _pointSize,
              height: _pointSize,
              fit: BoxFit.contain,
              color: theme.buttonPrimary,
              colorBlendMode: BlendMode.srcIn,
              gaplessPlayback: true,
              errorBuilder: (context, error, stackTrace) => Icon(
                Icons.auto_awesome,
                color: theme.buttonPrimary,
                size: _pointSize,
              ),
            ),
    );
  }
}

/// The tinted plate shared by every model avatar that has no image of its own.
class _ModelAvatarPlaceholder extends StatelessWidget {
  const _ModelAvatarPlaceholder({
    required this.size,
    required this.label,
    this.child,
  });

  final double size;
  final String? label;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
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
      child:
          child ??
          (uppercase != null
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
                )),
    );
  }
}
