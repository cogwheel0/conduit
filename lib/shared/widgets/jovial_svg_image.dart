import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:jovial_svg/jovial_svg.dart';

typedef JovialSvgImageErrorBuilder =
    Widget Function(BuildContext context, Object error, StackTrace? stackTrace);

/// Loads and renders SVG content with `jovial_svg`.
///
/// The string and byte constructors parse synchronously so small inline SVGs can
/// render without a placeholder flash, while the network constructor resolves
/// asynchronously and falls back to the provided loading widget.
class JovialSvgImage extends StatefulWidget {
  const JovialSvgImage._({
    super.key,
    required this.sourceKey,
    required this.loader,
    this.fit = BoxFit.contain,
    this.alignment = Alignment.center,
    this.width,
    this.height,
    this.isComplex = false,
    this.placeholderBuilder,
    this.errorBuilder,
  });

  factory JovialSvgImage.string(
    String svg, {
    Key? key,
    BoxFit fit = BoxFit.contain,
    Alignment alignment = Alignment.center,
    double? width,
    double? height,
    bool isComplex = false,
    WidgetBuilder? placeholderBuilder,
    JovialSvgImageErrorBuilder? errorBuilder,
  }) {
    return JovialSvgImage._(
      key: key,
      sourceKey: svg,
      loader: () => ScalableImage.fromSvgString(svg, warnF: _warnF()),
      fit: fit,
      alignment: alignment,
      width: width,
      height: height,
      isComplex: isComplex,
      placeholderBuilder: placeholderBuilder,
      errorBuilder: errorBuilder,
    );
  }

  factory JovialSvgImage.bytes(
    Uint8List bytes, {
    Key? key,
    Encoding encoding = utf8,
    BoxFit fit = BoxFit.contain,
    Alignment alignment = Alignment.center,
    double? width,
    double? height,
    bool isComplex = false,
    WidgetBuilder? placeholderBuilder,
    JovialSvgImageErrorBuilder? errorBuilder,
  }) {
    return JovialSvgImage._(
      key: key,
      sourceKey: (bytes, encoding.name),
      loader: () => ScalableImage.fromSvgString(
        _decodeSvgBytes(bytes, encoding),
        warnF: _warnF(),
      ),
      fit: fit,
      alignment: alignment,
      width: width,
      height: height,
      isComplex: isComplex,
      placeholderBuilder: placeholderBuilder,
      errorBuilder: errorBuilder,
    );
  }

  factory JovialSvgImage.network(
    String url, {
    Key? key,
    Map<String, String>? headers,
    Object? cacheIdentity,
    BoxFit fit = BoxFit.contain,
    Alignment alignment = Alignment.center,
    double? width,
    double? height,
    bool isComplex = false,
    WidgetBuilder? placeholderBuilder,
    JovialSvgImageErrorBuilder? errorBuilder,
  }) {
    final normalizedHeaders = _normalizeHeaders(headers);
    return JovialSvgImage._(
      key: key,
      sourceKey: _NetworkSvgSourceKey(url, normalizedHeaders, cacheIdentity),
      loader: () => ScalableImage.fromSvgHttpUrl(
        Uri.parse(url),
        httpHeaders: normalizedHeaders,
        warnF: _warnF(),
      ),
      fit: fit,
      alignment: alignment,
      width: width,
      height: height,
      isComplex: isComplex,
      placeholderBuilder: placeholderBuilder,
      errorBuilder: errorBuilder,
    );
  }

  final Object sourceKey;
  final FutureOr<ScalableImage> Function() loader;
  final BoxFit fit;
  final Alignment alignment;
  final double? width;
  final double? height;
  final bool isComplex;
  final WidgetBuilder? placeholderBuilder;
  final JovialSvgImageErrorBuilder? errorBuilder;

  @override
  State<JovialSvgImage> createState() => _JovialSvgImageState();
}

class _JovialSvgImageState extends State<JovialSvgImage> {
  ScalableImage? _image;
  Object? _error;
  StackTrace? _stackTrace;
  bool _isLoading = false;
  Object _loadToken = Object();

  @override
  void initState() {
    super.initState();
    _loadImage();
  }

  @override
  void didUpdateWidget(covariant JovialSvgImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sourceKey != widget.sourceKey) {
      _loadImage(notify: true);
    }
  }

  void _loadImage({bool notify = false}) {
    final loadToken = Object();
    _loadToken = loadToken;
    _image = null;
    _error = null;
    _stackTrace = null;

    try {
      final loadResult = widget.loader();
      if (loadResult is ScalableImage) {
        _isLoading = false;
        _image = loadResult;
        if (notify && mounted) {
          setState(() {});
        }
        return;
      }

      _isLoading = true;
      if (notify && mounted) {
        setState(() {});
      }

      loadResult.then(
        (image) {
          if (!mounted || !identical(_loadToken, loadToken)) {
            return;
          }
          setState(() {
            _image = image;
            _isLoading = false;
          });
        },
        onError: (Object error, StackTrace stackTrace) {
          if (!mounted || !identical(_loadToken, loadToken)) {
            return;
          }
          setState(() {
            _error = error;
            _stackTrace = stackTrace;
            _isLoading = false;
          });
        },
      );
    } catch (error, stackTrace) {
      _isLoading = false;
      _error = error;
      _stackTrace = stackTrace;
      if (notify && mounted) {
        setState(() {});
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return widget.errorBuilder?.call(context, _error!, _stackTrace) ??
          const SizedBox.shrink();
    }
    if (_image == null) {
      if (_isLoading) {
        return widget.placeholderBuilder?.call(context) ??
            const SizedBox.shrink();
      }
      return const SizedBox.shrink();
    }

    final svg = ScalableImageWidget(
      si: _image!,
      fit: widget.fit,
      alignment: widget.alignment,
      isComplex: widget.isComplex,
    );
    return _wrapWithDimensions(svg, _image!);
  }

  Widget _wrapWithDimensions(Widget child, ScalableImage image) {
    final width = widget.width;
    final height = widget.height;
    if (width == null && height == null) {
      return child;
    }
    if (width != null && height != null) {
      return SizedBox(width: width, height: height, child: child);
    }

    final intrinsicWidth = image.width ?? image.viewport.width;
    final intrinsicHeight = image.height ?? image.viewport.height;
    if (intrinsicWidth > 0 && intrinsicHeight > 0) {
      final aspectRatio = intrinsicWidth / intrinsicHeight;
      if (width != null) {
        return SizedBox(
          width: width,
          height: width / aspectRatio,
          child: child,
        );
      }
      if (height != null) {
        return SizedBox(
          width: height * aspectRatio,
          height: height,
          child: child,
        );
      }
    }

    return SizedBox(width: width, height: height, child: child);
  }
}

String _decodeSvgBytes(Uint8List bytes, Encoding encoding) {
  if (encoding == utf8) {
    return utf8.decode(bytes, allowMalformed: true);
  }
  return encoding.decode(bytes);
}

void Function(String)? _warnF() {
  if (!kDebugMode) {
    return (_) {};
  }
  return (message) => debugPrint(message);
}

Map<String, String>? _normalizeHeaders(Map<String, String>? headers) {
  if (headers == null || headers.isEmpty) {
    return null;
  }
  final sortedEntries = headers.entries.toList()
    ..sort((left, right) {
      final keyCompare = left.key.compareTo(right.key);
      if (keyCompare != 0) {
        return keyCompare;
      }
      return left.value.compareTo(right.value);
    });
  return Map<String, String>.unmodifiable({
    for (final entry in sortedEntries) entry.key: entry.value,
  });
}

@immutable
class _NetworkSvgSourceKey {
  const _NetworkSvgSourceKey(this.url, this.headers, this.cacheIdentity);

  final String url;
  final Map<String, String>? headers;
  final Object? cacheIdentity;

  @override
  bool operator ==(Object other) {
    return other is _NetworkSvgSourceKey &&
        other.url == url &&
        mapEquals(other.headers, headers) &&
        other.cacheIdentity == cacheIdentity;
  }

  @override
  int get hashCode {
    final headerEntries =
        headers?.entries ?? const <MapEntry<String, String>>[];
    return Object.hash(
      url,
      cacheIdentity,
      Object.hashAll(
        headerEntries.map((entry) => Object.hash(entry.key, entry.value)),
      ),
    );
  }
}
