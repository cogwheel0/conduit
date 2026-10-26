// ignore_for_file: public_member_api_docs

import 'dart:io';

class OrtThreadingConfig {
  final int intraOpNumThreads;
  final int interOpNumThreads;
  final bool useGlobalThreadPool;

  const OrtThreadingConfig({
    required this.intraOpNumThreads,
    required this.interOpNumThreads,
    this.useGlobalThreadPool = false,
  });

  factory OrtThreadingConfig.platformOptimal() {
    if (Platform.isIOS || Platform.isAndroid) {
      // Mobile platforms: Use 2-4 threads for intra-op based on cores
      // Keep inter-op at 1 since VAD models are sequential
      final cores = Platform.numberOfProcessors;
      return OrtThreadingConfig(
        intraOpNumThreads: (cores / 2).clamp(2, 4).toInt(),
        interOpNumThreads: 1,
        useGlobalThreadPool: false,
      );
    } else if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
      // Desktop platforms: More aggressive threading
      final cores = Platform.numberOfProcessors;
      return OrtThreadingConfig(
        intraOpNumThreads: (cores / 2).clamp(4, 8).toInt(),
        interOpNumThreads: 2,
        useGlobalThreadPool: true,
      );
    } else {
      // Fallback: Conservative settings
      return const OrtThreadingConfig(
        intraOpNumThreads: 2,
        interOpNumThreads: 1,
        useGlobalThreadPool: false,
      );
    }
  }

  /// Conservative configuration for low latency
  factory OrtThreadingConfig.lowLatency() {
    return const OrtThreadingConfig(
      intraOpNumThreads: 1,
      interOpNumThreads: 1,
      useGlobalThreadPool: false,
    );
  }

  /// High performance configuration
  factory OrtThreadingConfig.highPerformance() {
    final cores = Platform.numberOfProcessors;
    return OrtThreadingConfig(
      intraOpNumThreads: cores,
      interOpNumThreads: (cores / 4).clamp(1, 4).toInt(),
      useGlobalThreadPool: true,
    );
  }
}
