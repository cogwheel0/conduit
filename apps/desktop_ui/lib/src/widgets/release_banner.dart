import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';

import '../l10n/strings.g.dart';
import '../rpc/rpc_providers.dart';
import 'desktop_integration.dart';
import 'ui.dart';

/// Where Conduit's source, releases and support live.
const String conduitRepositoryUrl = 'https://github.com/cogwheel0/conduit';
const String conduitSponsorsUrl = 'https://github.com/sponsors/cogwheel0';
const String conduitCoffeeUrl = 'https://www.buymeacoffee.com/cogwheel0';

/// The release page for desktop version [version].
String desktopReleaseUrl(String version) =>
    '$conduitRepositoryUrl/releases/tag/desktop-v$version';

/// Whether [a] is a later version than [b]: `x.y.z`, then a prerelease
/// after a hyphen sorting below the release. Unreadable means "yes" when
/// they differ -- a banner too many beats none after an update.
bool isNewerVersion(String a, String b) {
  (List<int>, String) parse(String v) {
    final dash = v.indexOf('-');
    final core = dash < 0 ? v : v.substring(0, dash);
    final pre = dash < 0 ? '' : v.substring(dash + 1);
    return (
      core.split('.').map((part) => int.tryParse(part) ?? -1).toList(),
      pre,
    );
  }

  final (left, leftPre) = parse(a);
  final (right, rightPre) = parse(b);
  if (left.contains(-1) || right.contains(-1)) return a != b;
  for (var i = 0; i < 3; i++) {
    final x = i < left.length ? left[i] : 0;
    final y = i < right.length ? right[i] : 0;
    if (x != y) return x > y;
  }
  if (leftPre == rightPre) return false;
  if (leftPre.isEmpty) return true;
  if (rightPre.isEmpty) return false;
  return leftPre.compareTo(rightPre) > 0;
}

/// "What's new in 0.2" after an update, with the release's notes
/// a click away and the support links beside them. Gone once dismissed; a
/// first run records the version and shows nothing.
class ReleaseBanner extends StatefulComponent {
  const ReleaseBanner({super.key});

  @override
  State<ReleaseBanner> createState() => _ReleaseBannerState();
}

class _ReleaseBannerState extends State<ReleaseBanner> {
  /// The version saved as seen from here. A refresh shows the old settings
  /// while it loads, and they must not make it save again -- or bring a
  /// dismissed banner back for a moment.
  String? _remembered;

  @override
  Component build(BuildContext context) {
    final shell = context.read(desktopShellProvider);
    if (!shell.available) return const Component.empty();
    final settings = context.watch(shellSettingsProvider).value;
    if (settings == null) return const Component.empty();
    final current = context.read(shellBridgeProvider).appVersion;

    void remember() {
      if (_remembered == current) return;
      setState(() => _remembered = current);
      unawaited(
        shell.settings(<String, Object?>{'lastSeenVersion': current}).then((_) {
          if (mounted) context.invalidate(shellSettingsProvider);
        }),
      );
    }

    if (_remembered == current) return const Component.empty();
    if (settings.lastSeenVersion.isEmpty) {
      // A first run: nothing is new to someone who has not seen the old.
      Future<void>.microtask(remember);
      return const Component.empty();
    }
    if (!isNewerVersion(current, settings.lastSeenVersion)) {
      return const Component.empty();
    }
    final shown = current.split('.').take(2).join('.');
    Component link(String text, String href) => a(
      href: href,
      target: Target.blank,
      classes: 'underline underline-offset-2 hover:text-foreground',
      attributes: const <String, String>{'rel': 'noopener'},
      [Component.text(text)],
    );
    return section(
      classes:
          'flex flex-wrap items-center gap-x-4 gap-y-1 border-b border-border '
          'bg-card px-4 py-2 text-ui-base',
      attributes: <String, String>{
        'role': 'region',
        'aria-label': t.app.releaseNotesTitle,
      },
      [
        span(classes: 'font-medium', [
          Component.text(t.app.releaseNotesAnnouncementTitle(version: shown)),
        ]),
        link(t.desktop.desktopReleaseSeeChanges, desktopReleaseUrl(current)),
        span(classes: 'text-foreground-subtle', [
          Component.text(t.app.releaseNotesSupportPromptHeading),
        ]),
        link(t.app.buyMeACoffeeTitle, conduitCoffeeUrl),
        link(t.app.githubSponsorsTitle, conduitSponsorsUrl),
        button(
          [
            span(
              attributes: const <String, String>{'aria-hidden': 'true'},
              [icon(LucideIcon.x, classes: 'size-4')],
            ),
          ],
          classes: 'ml-auto rounded-lg px-2 hover:bg-hover',
          type: ButtonType.button,
          attributes: <String, String>{
            'aria-label': t.desktop.desktopReleaseDismiss,
            'title': t.desktop.desktopReleaseDismiss,
          },
          onClick: remember,
        ),
      ],
    );
  }
}
