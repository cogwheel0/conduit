import 'package:material_ui/material_ui.dart';

/// Opens the open-source licenses of the packages the app ships, as the
/// platform's license page lists them.
void showAdaptiveLicensePage({
  required BuildContext context,
  required String applicationName,
}) => showLicensePage(context: context, applicationName: applicationName);
