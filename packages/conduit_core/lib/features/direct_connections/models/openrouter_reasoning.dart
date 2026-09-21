import 'dart:collection';

/// Reasoning effort levels accepted by OpenRouter's normalized API.
///
/// The order matches OpenRouter's catalog contract, from highest to lowest.
const List<String> kOpenRouterReasoningEfforts = <String>[
  'max',
  'xhigh',
  'high',
  'medium',
  'low',
  'minimal',
  'none',
];

/// Sanitized model-level reasoning metadata from OpenRouter's model catalog.
///
/// A null [supportedEfforts] means the gateway accepts every normalized
/// OpenRouter effort. An empty list means the catalog exposed an effort list
/// but none of its entries were recognized.
final class OpenRouterReasoningSupport {
  OpenRouterReasoningSupport({
    required List<String>? supportedEfforts,
    this.defaultEffort,
    this.defaultEnabled,
    this.supportsMaxTokens,
    this.mandatory = false,
  }) : supportedEfforts = supportedEfforts == null
           ? null
           : List<String>.unmodifiable(supportedEfforts);

  factory OpenRouterReasoningSupport.fromCatalog(Object? value) {
    if (value is! Map || !value.containsKey('supported_efforts')) {
      throw const FormatException(
        'OpenRouter reasoning metadata is missing supported efforts.',
      );
    }
    final rawEfforts = value['supported_efforts'];
    List<String>? supportedEfforts;
    if (rawEfforts == null) {
      supportedEfforts = null;
    } else if (rawEfforts is Iterable) {
      final seen = <String>{};
      supportedEfforts = <String>[
        for (final value in rawEfforts)
          if (value is String &&
              kOpenRouterReasoningEfforts.contains(
                value.trim().toLowerCase(),
              ) &&
              seen.add(value.trim().toLowerCase()))
            value.trim().toLowerCase(),
      ];
    } else {
      throw const FormatException(
        'OpenRouter supported reasoning efforts are invalid.',
      );
    }

    final defaultEffort = value['default_effort'];
    final normalizedDefault = defaultEffort is String
        ? defaultEffort.trim().toLowerCase()
        : null;
    return OpenRouterReasoningSupport(
      supportedEfforts: supportedEfforts,
      defaultEffort:
          normalizedDefault != null &&
              kOpenRouterReasoningEfforts.contains(normalizedDefault)
          ? normalizedDefault
          : null,
      defaultEnabled: value['default_enabled'] is bool
          ? value['default_enabled'] as bool
          : null,
      supportsMaxTokens: value['supports_max_tokens'] is bool
          ? value['supports_max_tokens'] as bool
          : null,
      mandatory: value['mandatory'] == true,
    );
  }

  static OpenRouterReasoningSupport? tryParseCatalog(Object? value) {
    try {
      return OpenRouterReasoningSupport.fromCatalog(value);
    } on FormatException {
      return null;
    }
  }

  final List<String>? supportedEfforts;
  final String? defaultEffort;
  final bool? defaultEnabled;
  final bool? supportsMaxTokens;
  final bool mandatory;

  List<String> get selectableEfforts => List<String>.unmodifiable(
    (supportedEfforts ?? kOpenRouterReasoningEfforts).where(
      (effort) => !mandatory || effort != 'none',
    ),
  );

  Map<String, dynamic> toCapabilitiesJson() =>
      UnmodifiableMapView(<String, dynamic>{
        'supported_efforts': supportedEfforts,
        if (defaultEffort != null) 'default_effort': defaultEffort,
        if (defaultEnabled != null) 'default_enabled': defaultEnabled,
        if (supportsMaxTokens != null) 'supports_max_tokens': supportsMaxTokens,
        'mandatory': mandatory,
      });
}
