sealed class DirectMcpAppInboundMessage {
  const DirectMcpAppInboundMessage();
}

final class DirectMcpAppInitializeRequest extends DirectMcpAppInboundMessage {
  const DirectMcpAppInitializeRequest({
    required this.id,
    required this.appCapabilities,
  });

  final Object id;
  final Map<String, dynamic> appCapabilities;
}

final class DirectMcpAppInitializedNotification
    extends DirectMcpAppInboundMessage {
  const DirectMcpAppInitializedNotification();
}

final class DirectMcpAppPingRequest extends DirectMcpAppInboundMessage {
  const DirectMcpAppPingRequest(this.id);

  final Object id;
}

final class DirectMcpAppToolCallRequest extends DirectMcpAppInboundMessage {
  DirectMcpAppToolCallRequest({
    required this.id,
    required this.toolName,
    required Map<String, dynamic> arguments,
  }) : arguments = Map.unmodifiable(arguments);

  final Object id;
  final String toolName;
  final Map<String, dynamic> arguments;
}

final class DirectMcpAppToolPolicy {
  const DirectMcpAppToolPolicy({
    required this.serverId,
    required this.toolName,
    required this.visibleToModel,
    required this.visibleToApp,
    this.resourceUri,
  });

  final String serverId;
  final String toolName;
  final bool visibleToModel;
  final bool visibleToApp;
  final String? resourceUri;
}

final class DirectMcpAppResourcePolicy {
  DirectMcpAppResourcePolicy({
    required Iterable<String> connectDomains,
    required Iterable<String> resourceDomains,
    required Iterable<String> frameDomains,
    required Iterable<String> baseUriDomains,
    required this.requestsCamera,
    required this.requestsMicrophone,
    required this.requestsGeolocation,
    required this.requestsClipboardWrite,
    required this.prefersBorder,
  }) : connectDomains = List.unmodifiable(connectDomains),
       resourceDomains = List.unmodifiable(resourceDomains),
       frameDomains = List.unmodifiable(frameDomains),
       baseUriDomains = List.unmodifiable(baseUriDomains);

  final List<String> connectDomains;
  final List<String> resourceDomains;
  final List<String> frameDomains;
  final List<String> baseUriDomains;
  final bool requestsCamera;
  final bool requestsMicrophone;
  final bool requestsGeolocation;
  final bool requestsClipboardWrite;
  final bool? prefersBorder;
}
