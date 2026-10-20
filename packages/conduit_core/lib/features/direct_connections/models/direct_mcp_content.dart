final class DirectMcpPromptArgument {
  const DirectMcpPromptArgument({
    required this.name,
    required this.label,
    required this.description,
    required this.required,
  });

  final String name;
  final String label;
  final String description;
  final bool required;
}

final class DirectMcpPromptSummary {
  DirectMcpPromptSummary({
    required this.name,
    required this.displayName,
    required this.description,
    required Iterable<DirectMcpPromptArgument> arguments,
    required this.inventoryIdentity,
  }) : arguments = List.unmodifiable(arguments);

  final String name;
  final String displayName;
  final String description;
  final List<DirectMcpPromptArgument> arguments;
  final String inventoryIdentity;
}

final class DirectMcpResourceSummary {
  const DirectMcpResourceSummary({
    required this.uri,
    required this.displayName,
    required this.description,
    required this.mimeType,
    required this.inventoryIdentity,
  });

  final String uri;
  final String displayName;
  final String description;
  final String? mimeType;
  final String inventoryIdentity;
}

final class DirectMcpContentInventory {
  DirectMcpContentInventory({
    required this.serverId,
    required this.serverName,
    required Iterable<DirectMcpPromptSummary> prompts,
    required Iterable<DirectMcpResourceSummary> resources,
  }) : prompts = List.unmodifiable(prompts),
       resources = List.unmodifiable(resources);

  final String serverId;
  final String serverName;
  final List<DirectMcpPromptSummary> prompts;
  final List<DirectMcpResourceSummary> resources;
}

final class DirectMcpPromptMessage {
  const DirectMcpPromptMessage({required this.role, required this.text});

  final String role;
  final String text;
}

final class DirectMcpPromptPreview {
  DirectMcpPromptPreview({required Iterable<DirectMcpPromptMessage> messages})
    : messages = List.unmodifiable(messages);

  final List<DirectMcpPromptMessage> messages;
}

final class DirectMcpResourcePreview {
  const DirectMcpResourcePreview({required this.text});

  final String text;
}

String formatDirectMcpPromptInsertion({
  required String heading,
  required DirectMcpPromptPreview preview,
  required String Function(String role) roleLabel,
}) => [
  heading,
  for (final message in preview.messages)
    '${roleLabel(message.role)}:\n${message.text}',
].join('\n\n');

String formatDirectMcpResourceInsertion({
  required String heading,
  required DirectMcpResourcePreview preview,
}) => '$heading\n\n${preview.text}';
