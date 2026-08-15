import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'server_connection_page.dart';

/// Entry point for the connection and sign-in flow.
/// We now forward directly to the server connection experience.
class ConnectAndSignInPage extends ConsumerWidget {
  const ConnectAndSignInPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return const ServerConnectionPage();
  }
}
