@TestOn('vm')
library;

import 'package:conduit_desktop_ui/src/l10n/strings.g.dart';
import 'package:conduit_desktop_ui/src/rpc/chat_providers.dart';
import 'package:conduit_desktop_ui/src/widgets/message_files.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr/dom.dart' show button, img;
import 'package:jaspr/jaspr.dart' show Builder, Component;
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:jaspr_test/jaspr_test.dart';

void main() {
  Component scoped(Component child) => ProviderScope(
    overrides: [
      fileUrlProvider.overrideWithValue(
        (id) => 'http://127.0.0.1:9/files/s1/$id',
      ),
    ],
    child: child,
  );

  testComponents('an image loads through the daemon; a file is named', (
    tester,
  ) async {
    tester.pumpComponent(
      scoped(
        const MessageFiles(<ChatFileDto>[
          ChatFileDto(id: 'f1', name: 'diagram.png', image: true),
          ChatFileDto(id: 'f2', name: 'notes.pdf'),
        ]),
      ),
    );
    await pumpEventQueue();
    final image = find.byComponentPredicate(
      (component) =>
          component is img && component.src == 'http://127.0.0.1:9/files/s1/f1',
    );
    expect(image, findsOneComponent);
    expect(find.text('notes.pdf'), findsOneComponent);
  });

  testComponents('a thumbnail opens the lightbox', (tester) async {
    late ProviderContainer container;
    tester.pumpComponent(
      scoped(
        Builder(
          builder: (context) {
            container = ProviderScope.containerOf(context, listen: false);
            return const MessageFiles(<ChatFileDto>[
              ChatFileDto(
                name: 'old.png',
                image: true,
                dataUrl: 'data:image/png;base64,AAAA',
              ),
            ]);
          },
        ),
      ),
    );
    await pumpEventQueue();
    await tester.click(
      find.byComponentPredicate(
        (component) =>
            component is button &&
            component.attributes?['aria-label'] ==
                t.desktop.desktopOpenImage(name: 'old.png'),
      ),
    );
    expect(container.read(lightboxProvider)?.src, 'data:image/png;base64,AAAA');
  });

  testComponents('audio plays where it is', (tester) async {
    tester.pumpComponent(
      scoped(
        const MessageFiles(<ChatFileDto>[
          ChatFileDto(id: 'a1', name: 'memo.m4a', contentType: 'audio/mp4'),
        ]),
      ),
    );
    await pumpEventQueue();
    expect(find.tag('audio'), findsOneComponent);
  });

  testComponents('a PDF is a link that opens a window', (tester) async {
    tester.pumpComponent(
      scoped(
        const MessageFiles(<ChatFileDto>[
          ChatFileDto(id: 'p1', name: 'report.pdf'),
        ]),
      ),
    );
    await pumpEventQueue();
    expect(find.tag('a'), findsOneComponent);
    expect(find.text('report.pdf'), findsOneComponent);
  });
}
