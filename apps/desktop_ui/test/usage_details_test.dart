@TestOn('vm')
library;

import 'package:conduit_desktop_ui/src/l10n/strings.g.dart';
import 'package:conduit_desktop_ui/src/widgets/usage_details.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr_test/jaspr_test.dart';

void main() {
  testComponents('leads with the speed, and lists the rest', (tester) async {
    tester.pumpComponent(
      const UsageDetails(
        ChatUsageDto(
          generationPerSecond: 42.46,
          generationTokens: 85,
          totalSeconds: 2.5,
        ),
      ),
    );
    // Once closed, once in its row with the count beside it.
    expect(
      find.text(t.app.usageTokensPerSecond(speed: '42.5')),
      findsOneComponent,
    );
    expect(find.text(t.app.usageTokenGeneration), findsOneComponent);
    expect(find.text(t.app.usageTotalDuration), findsOneComponent);
    expect(
      find.text(t.app.usageSecondsFormat(seconds: '2.50')),
      findsOneComponent,
    );
  });

  testComponents('a count alone when nothing was timed', (tester) async {
    tester.pumpComponent(
      const UsageDetails(ChatUsageDto(generationTokens: 12)),
    );
    expect(find.text(t.app.usageTokenCount(count: 12)), findsNComponents(2));
  });

  testComponents('nothing to say renders nothing', (tester) async {
    tester.pumpComponent(const UsageDetails(ChatUsageDto()));
    expect(find.tag('details'), findsNothing);
  });
}
