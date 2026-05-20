import 'package:flutter/material.dart';

import '../skeleton_loader.dart';

class MarkdownLoadingSkeleton extends StatelessWidget {
  const MarkdownLoadingSkeleton({
    super.key,
    required this.contentLength,
    this.lineCount,
    this.widthFactors,
  });

  final int contentLength;
  final int? lineCount;
  final List<double>? widthFactors;

  int get _resolvedLineCount {
    final override = lineCount;
    if (override != null && override > 0) {
      return override;
    }
    if (contentLength >= 8000) {
      return 7;
    }
    if (contentLength >= 4000) {
      return 6;
    }
    if (contentLength >= 1600) {
      return 5;
    }
    return 4;
  }

  @override
  Widget build(BuildContext context) {
    final resolvedWidthFactors =
        widthFactors ??
        const <double>[0.94, 0.88, 0.97, 0.76, 0.91, 0.84, 0.68];

    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth =
            constraints.maxWidth.isFinite && constraints.maxWidth > 0
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var index = 0; index < _resolvedLineCount; index++) ...[
              SkeletonLoader(
                width:
                    availableWidth *
                    resolvedWidthFactors[index % resolvedWidthFactors.length],
                height: index == 0 ? 18 : 14,
                borderRadius: BorderRadius.circular(index == 0 ? 8 : 6),
              ),
              if (index < _resolvedLineCount - 1)
                SizedBox(height: index == 0 ? 16 : 10),
            ],
          ],
        );
      },
    );
  }
}
