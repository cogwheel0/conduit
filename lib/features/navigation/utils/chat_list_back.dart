import 'dart:io' show Platform;

import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:flutter/services.dart' show SystemChannels, SystemNavigator;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/sidebar_layout_contract.dart';
import '../../../shared/widgets/themed_dialogs.dart';

/// Overrides the Android check in tests.
@visibleForTesting
bool? debugChatBackIsAndroidOverride;

/// Whether the system back button and gesture exist.
bool get chatBackIsAndroid =>
    debugChatBackIsAndroidOverride ?? Platform.isAndroid;

/// Runs Android back on a page under the chat list.
///
/// Back first clears input focus, then pops a pushed route. Otherwise
/// [openChatList] may show the list the page came from (#852). When it does
/// not, back asks to close the app.
Future<void> handleChatBackNavigation({
  required bool hasInputFocus,
  required VoidCallback dismissInputFocus,
  required bool Function() canNavigateBack,
  required VoidCallback navigateBack,
  required bool Function() openChatList,
  required Future<bool> Function() confirmExit,
  required bool Function() isMounted,
  required bool isAndroid,
  required VoidCallback exitApplication,
}) async {
  if (hasInputFocus) {
    dismissInputFocus();
    return;
  }

  if (!isMounted()) return;
  if (canNavigateBack()) {
    navigateBack();
    return;
  }

  if (isAndroid && openChatList()) return;

  final shouldExit = await confirmExit();
  if (!shouldExit || !isMounted()) return;
  if (isAndroid) {
    exitApplication();
  }
}

/// Whether back should only clear input focus: the composer's, which also
/// holds while its attachment panel is open and covers native inputs outside
/// Flutter's focus tree, or any other focused input.
///
/// The scope left holding focus once an input clears is not an input:
/// counting it swallowed back once per enclosing scope, then for good.
bool backClearsInputFocus({required bool composerHasFocus}) {
  final focus = FocusManager.instance.primaryFocus;
  return composerHasFocus ||
      (focus != null && focus is! FocusScopeNode && focus.hasFocus);
}

/// Opens the chat list for back, and returns whether it did.
///
/// Back with the list already showing returns false, so it asks to close the
/// app rather than closing the list onto the page that opens it again. A
/// docked tablet list counts as showing.
bool openChatListForBack(BuildContext context) {
  final drawer = SidebarDrawerControllerScope.maybeOf(context);
  if (drawer == null || drawer.isOpen) return false;
  drawer.open();
  return true;
}

/// Asks before back closes the app from its top screen.
Future<bool> confirmAppExit(BuildContext context) {
  final l10n = AppLocalizations.of(context)!;
  return ThemedDialogs.confirm(
    context,
    title: l10n.appTitle,
    message: l10n.endYourSession,
    confirmText: l10n.confirm,
    cancelText: l10n.cancel,
    isDestructive: chatBackIsAndroid,
  );
}

/// Android back on a page the chat list leads to, such as a channel or a
/// folder: back opens the list, and back with the list showing asks to close
/// the app (#852). Other platforms have no back button, so the page is left
/// as it is.
class ChatListBackScope extends ConsumerWidget {
  const ChatListBackScope({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!chatBackIsAndroid) return child;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        await handleChatBackNavigation(
          // The composer's attachment panel closes on this same back.
          hasInputFocus: backClearsInputFocus(
            composerHasFocus: ref.read(composerHasFocusProvider),
          ),
          dismissInputFocus: () {
            FocusManager.instance.primaryFocus?.unfocus();
            SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
          },
          canNavigateBack: () => Navigator.of(context).canPop(),
          navigateBack: () => Navigator.of(context).pop(),
          openChatList: () => openChatListForBack(context),
          confirmExit: () => confirmAppExit(context),
          isMounted: () => context.mounted,
          isAndroid: true,
          exitApplication: SystemNavigator.pop,
        );
      },
      child: child,
    );
  }
}

/// Lets Android hand back to the page in [child], the shell's nested
/// navigator, whenever that page handles it.
///
/// Android gives back to the app only when the root navigator says the app
/// handles it, and the root navigator asks only its own top route: the
/// shell, which never handles back itself. So back on a chat skipped its
/// close prompt and the chat list, and closed the app (#852). This holds the
/// shell route while the nested navigator handles back. The router still
/// sends back to that navigator first, so the shell route itself never pops.
class NestedNavigatorBackScope extends StatefulWidget {
  const NestedNavigatorBackScope({super.key, required this.child});

  final Widget child;

  @override
  State<NestedNavigatorBackScope> createState() =>
      _NestedNavigatorBackScopeState();
}

class _NestedNavigatorBackScopeState extends State<NestedNavigatorBackScope> {
  bool _nestedHandlesBack = false;

  bool _onNestedNavigation(NavigationNotification notification) {
    if (notification.canHandlePop != _nestedHandlesBack) {
      setState(() => _nestedHandlesBack = notification.canHandlePop);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    if (!chatBackIsAndroid) return widget.child;
    return PopScope(
      canPop: !_nestedHandlesBack,
      child: NotificationListener<NavigationNotification>(
        onNotification: _onNestedNavigation,
        child: widget.child,
      ),
    );
  }
}
