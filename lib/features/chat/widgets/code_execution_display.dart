import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher_string.dart';

import '../../../core/models/chat_message.dart';
import '../../../core/utils/debug_logger.dart';
import '../../../shared/theme/theme_extensions.dart';
import 'assistant_detail_header.dart';

/// Displays a list of code execution results as interactive chips.
///
/// Each chip shows the execution status (success, error, or running)
/// and opens a detail bottom sheet when tapped.
class CodeExecutionListView extends StatelessWidget {
  const CodeExecutionListView({super.key, required this.executions});

  final List<ChatCodeExecution> executions;

  @override
  Widget build(BuildContext context) {
    if (executions.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: executions.map((execution) {
            final hasError = execution.result?.error != null;
            final hasOutput = execution.result?.output != null;
            final label = execution.name?.isNotEmpty == true
                ? execution.name!
                : 'Execution';
            final title = hasError
                ? '$label failed'
                : hasOutput
                ? label
                : '$label…';

            return Padding(
              padding: const EdgeInsets.only(bottom: Spacing.xs),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _showCodeExecutionDetails(context, execution),
                child: AssistantDetailHeader(
                  title: title,
                  showShimmer: !hasError && !hasOutput,
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }

  Future<void> _showCodeExecutionDetails(
    BuildContext context,
    ChatCodeExecution execution,
  ) async {
    final theme = context.conduitTheme;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: theme.surfaceBackground,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppBorderRadius.dialog),
        ),
      ),
      builder: (ctx) {
        final result = execution.result;
        return DraggableScrollableSheet(
          initialChildSize: 0.6,
          maxChildSize: 0.95,
          expand: false,
          builder: (_, controller) {
            return Padding(
              padding: const EdgeInsets.all(Spacing.lg),
              child: ListView(
                controller: controller,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          execution.name ?? 'Code execution',
                          style: AppTypography.bodyLargeStyle.copyWith(
                            fontWeight: FontWeight.w600,
                            color: theme.textPrimary,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.of(ctx).pop(),
                      ),
                    ],
                  ),
                  const SizedBox(height: Spacing.sm),
                  if (execution.language != null)
                    Text(
                      'Language: ${execution.language}',
                      style: AppTypography.bodyMediumStyle.copyWith(
                        color: theme.textSecondary,
                      ),
                    ),
                  const SizedBox(height: Spacing.sm),
                  if (execution.code != null && execution.code!.isNotEmpty) ...[
                    Text(
                      'Code',
                      style: AppTypography.labelStyle.copyWith(
                        fontWeight: FontWeight.w600,
                        color: theme.textPrimary,
                      ),
                    ),
                    const SizedBox(height: Spacing.xs),
                    Container(
                      padding: const EdgeInsets.all(Spacing.sm),
                      decoration: BoxDecoration(
                        color: theme.surfaceContainer,
                        borderRadius: BorderRadius.circular(AppBorderRadius.md),
                      ),
                      child: SelectableText(
                        execution.code!,
                        style: AppTypography.codeStyle.copyWith(height: 1.4),
                      ),
                    ),
                    const SizedBox(height: Spacing.md),
                  ],
                  if (result?.error != null) ...[
                    Text(
                      'Error',
                      style: AppTypography.labelStyle.copyWith(
                        fontWeight: FontWeight.w600,
                        color: theme.error,
                      ),
                    ),
                    const SizedBox(height: Spacing.xs),
                    SelectableText(result!.error!),
                    const SizedBox(height: Spacing.md),
                  ],
                  if (result?.output != null) ...[
                    Text(
                      'Output',
                      style: AppTypography.labelStyle.copyWith(
                        fontWeight: FontWeight.w600,
                        color: theme.textPrimary,
                      ),
                    ),
                    const SizedBox(height: Spacing.xs),
                    SelectableText(result!.output!),
                    const SizedBox(height: Spacing.md),
                  ],
                  if (result?.files.isNotEmpty == true) ...[
                    Text(
                      'Files',
                      style: AppTypography.labelStyle.copyWith(
                        fontWeight: FontWeight.w600,
                        color: theme.textPrimary,
                      ),
                    ),
                    const SizedBox(height: Spacing.xs),
                    ...result!.files.map((file) {
                      final name = file.name ?? file.url ?? 'Download';
                      return AdaptiveListTile(
                        padding: EdgeInsets.zero,
                        leading: const Icon(Icons.insert_drive_file_outlined),
                        title: Text(name),
                        onTap: file.url != null
                            ? () => _launchUri(file.url!)
                            : null,
                        trailing: file.url != null
                            ? const Icon(Icons.open_in_new)
                            : null,
                      );
                    }),
                  ],
                ],
              ),
            );
          },
        );
      },
    );
  }
}

Future<void> _launchUri(String url) async {
  if (url.isEmpty) return;
  try {
    await launchUrlString(url, mode: LaunchMode.externalApplication);
  } catch (err) {
    DebugLogger.log('Unable to open url $url: $err', scope: 'chat/assistant');
  }
}
