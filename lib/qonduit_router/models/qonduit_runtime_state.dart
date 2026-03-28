class QonduitRuntimeState {
  final String? selectedModel;
  final int contextSize;

  const QonduitRuntimeState({
    required this.selectedModel,
    required this.contextSize,
  });

  QonduitRuntimeState copyWith({
    String? selectedModel,
    int? contextSize,
  }) {
    return QonduitRuntimeState(
      selectedModel: selectedModel ?? this.selectedModel,
      contextSize: contextSize ?? this.contextSize,
    );
  }
}