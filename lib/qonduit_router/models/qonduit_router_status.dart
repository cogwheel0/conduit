class QonduitRouterStatus {
  final bool running;
  final bool exists;
  final String containerName;
  final String webuiBase;
  final String llamaBase;

  const QonduitRouterStatus({
    required this.running,
    required this.exists,
    required this.containerName,
    required this.webuiBase,
    required this.llamaBase,
  });

  factory QonduitRouterStatus.fromJson(Map<String, dynamic> json) {
    return QonduitRouterStatus(
      running: json['running'] == true,
      exists: json['exists'] == true,
      containerName: (json['container_name'] ?? 'llama_server') as String,
      webuiBase: (json['webui_base'] ?? 'https://openai.qneural.org') as String,
      llamaBase: (json['llama_base'] ?? 'https://llama.qneural.org') as String,
    );
  }
}