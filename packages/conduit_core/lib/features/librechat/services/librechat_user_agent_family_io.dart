import 'dart:io';

import 'package:conduit_core/features/librechat/services/librechat_user_agent.dart';

LibreChatUserAgentFamily get platformUserAgentFamily {
  if (Platform.isIOS) return LibreChatUserAgentFamily.iosSafari;
  if (Platform.isAndroid) return LibreChatUserAgentFamily.androidChrome;
  if (Platform.isMacOS) return LibreChatUserAgentFamily.macSafari;
  return LibreChatUserAgentFamily.desktopChrome;
}
