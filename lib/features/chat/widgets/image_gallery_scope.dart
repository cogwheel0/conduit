import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// One image that the full-screen viewer can page to.
@immutable
class ImageViewerItem {
  const ImageViewerItem({required this.attachmentId, this.httpHeaders});

  /// Same value passed to `EnhancedImageAttachment.attachmentId`.
  final String attachmentId;
  final Map<String, String>? httpHeaders;

  @override
  bool operator ==(Object other) =>
      other is ImageViewerItem &&
      other.attachmentId == attachmentId &&
      mapEquals(other.httpHeaders, httpHeaders);

  @override
  int get hashCode => Object.hash(
    attachmentId,
    httpHeaders == null
        ? null
        : Object.hashAllUnordered(
            httpHeaders!.entries.map((e) => Object.hash(e.key, e.value)),
          ),
  );
}

/// Groups sibling image attachments so the viewer can page between them.
///
/// Image attachments below this scope open the viewer on their own item and
/// let the user swipe through [items]. Attachments without a scope, or whose
/// item is not listed, open alone.
class ImageGalleryScope extends InheritedWidget {
  const ImageGalleryScope({
    super.key,
    required this.items,
    required super.child,
  });

  final List<ImageViewerItem> items;

  static ImageGalleryScope? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<ImageGalleryScope>();

  /// Returns the gallery that contains [item] and the item's index in it.
  static (List<ImageViewerItem>, int) galleryFor(
    BuildContext context,
    ImageViewerItem item,
  ) {
    final items = maybeOf(context)?.items;
    final index = items?.indexOf(item) ?? -1;
    if (items == null || index == -1) return ([item], 0);
    return (items, index);
  }

  @override
  bool updateShouldNotify(ImageGalleryScope oldWidget) =>
      !listEquals(oldWidget.items, items);
}
