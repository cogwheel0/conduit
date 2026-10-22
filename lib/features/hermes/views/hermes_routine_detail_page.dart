import 'package:material_ui/material_ui.dart';
import 'package:conduit_core/features/hermes/models/hermes_job.dart';
import 'package:conduit_core/features/hermes/utils/hermes_schedule_format.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/platform_ui/platform_ui.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../widgets/hermes_message_icon.dart';

class HermesRoutineDetailPage extends StatelessWidget {
  const HermesRoutineDetailPage({super.key, required this.job});
  final HermesJob job;
  @override
  Widget build(BuildContext context) => AdaptiveScaffold(
    body: SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 16, 8),
            child: Row(
              children: [
                CompactIconAction(
                  tooltip: AppLocalizations.of(context)!.back,
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(HermesMessageIcons.back),
                ),
                Expanded(
                  child: Text(
                    job.displayName,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text(
                  describeHermesCronSchedule(job.schedule),
                  style: TextStyle(color: context.conduitTheme.textSecondary),
                ),
                const SizedBox(height: 16),
                SelectableText(job.prompt),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
