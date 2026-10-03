import 'package:checks/checks.dart';
import 'package:conduit/features/chat/widgets/image_gallery_scope.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const a = ImageViewerItem(attachmentId: 'a', httpHeaders: {'x': '1'});
  const b = ImageViewerItem(attachmentId: 'b');

  Future<(List<ImageViewerItem>, int)> galleryFor(
    WidgetTester tester,
    ImageViewerItem item, {
    List<ImageViewerItem>? items,
  }) async {
    late (List<ImageViewerItem>, int) result;
    final probe = Builder(
      builder: (context) {
        result = ImageGalleryScope.galleryFor(context, item);
        return const SizedBox();
      },
    );
    await tester.pumpWidget(
      items == null ? probe : ImageGalleryScope(items: items, child: probe),
    );
    return result;
  }

  testWidgets('finds the tapped item among its siblings', (tester) async {
    final (items, index) = await galleryFor(
      tester,
      const ImageViewerItem(attachmentId: 'b'),
      items: const [a, b],
    );
    check(items).deepEquals(const [a, b]);
    check(index).equals(1);
  });

  testWidgets('matches headers as part of the item identity', (tester) async {
    final (items, index) = await galleryFor(
      tester,
      const ImageViewerItem(attachmentId: 'a', httpHeaders: {'x': '1'}),
      items: const [a, b],
    );
    check(items.length).equals(2);
    check(index).equals(0);

    final (alone, aloneIndex) = await galleryFor(
      tester,
      const ImageViewerItem(attachmentId: 'a'),
      items: const [a, b],
    );
    check(alone).deepEquals(const [ImageViewerItem(attachmentId: 'a')]);
    check(aloneIndex).equals(0);
  });

  testWidgets('opens alone without a scope', (tester) async {
    final (items, index) = await galleryFor(tester, b);
    check(items).deepEquals(const [b]);
    check(index).equals(0);
  });

  testWidgets('lists a repeated image once', (tester) async {
    final (items, index) = await galleryFor(tester, b, items: const [b, a, b]);
    check(items).deepEquals(const [b, a]);
    check(index).equals(0);
  });
}
