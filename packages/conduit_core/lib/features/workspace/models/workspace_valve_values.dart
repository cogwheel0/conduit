import 'workspace_resources.dart';

/// Value rules for the schema-driven tool valve form, mirroring Open WebUI's
/// `Valves.svelte` and `ValvesModal.svelte`.
///
/// A valve is either at its server default (value `null`) or overridden with
/// a custom value whose runtime type follows the property's schema `type`.
/// `array` properties are edited as comma-separated strings: [hydrate] joins
/// them on load and [serialize] splits them on submit, as upstream does.
abstract final class WorkspaceValveValues {
  /// The schema of one valve property, or an empty map when it is missing or
  /// malformed.
  static Map<String, dynamic> propertySpec(
    WorkspaceValveSpec spec,
    String property,
  ) {
    final value = spec.properties[property];
    return value is Map ? Map<String, dynamic>.from(value) : {};
  }

  /// Whether the schema marks a property as a secret to be masked: Open WebUI's
  /// `input.type: password` hint, or JSON Schema `format: password` (what
  /// Pydantic emits for `SecretStr`, also inside an `Optional` `anyOf`). Only
  /// the schema decides; field names are never guessed.
  static bool isPasswordProperty(Map<String, dynamic> propertySpec) {
    final input = propertySpec['input'];
    if (propertySpec['type'] == 'string' &&
        input is Map &&
        input['type']?.toString() == 'password') {
      return true;
    }
    if (propertySpec['format'] == 'password') return true;
    for (final key in const ['anyOf', 'oneOf']) {
      final branches = propertySpec[key];
      if (branches is List &&
          branches.any((b) => b is Map && b['format'] == 'password')) {
        return true;
      }
    }
    return false;
  }

  /// The value a property takes when it is toggled from its server default
  /// to a custom value.
  static dynamic customValueFor(Map<String, dynamic> propertySpec) {
    final enumValues = propertySpec['enum'];
    if (propertySpec['type'] == 'array') {
      final defaultArray = propertySpec['default'];
      return defaultArray is List ? defaultArray.join(', ') : '';
    }
    if (enumValues is List && enumValues.isNotEmpty) {
      // Enum valves must start on an allowed option of the correct runtime
      // type. Prefer the declared default; otherwise seed the first option so
      // an untouched custom control never submits a value outside the schema
      // (and never the empty string for a numeric/boolean enum).
      return propertySpec['default'] ?? enumValues.first;
    }
    // Fall back to a type-appropriate empty value when the schema omits a
    // default, so a boolean valve becomes `false` (not `''`) and a numeric
    // valve becomes `0`; otherwise a custom-but-untouched control would
    // submit a string where the server expects a bool/number.
    return propertySpec['default'] ??
        typedFallback(propertySpec['type']?.toString());
  }

  /// The next value when a property toggles between its server default
  /// (null) and a custom value.
  static dynamic toggleDefault(
    Map<String, dynamic> propertySpec,
    dynamic current,
  ) => current == null ? customValueFor(propertySpec) : null;

  /// Maps a dropdown's stringified selection back to the original enum entry
  /// so numeric/boolean enums keep their runtime type (`1`, not `"1"`). The
  /// string form is only ever a display label.
  static dynamic enumValueFor(List<dynamic> enumValues, String? selection) {
    if (selection == null) return null;
    for (final option in enumValues) {
      if (option.toString() == selection) return option;
    }
    return selection;
  }

  /// The type-appropriate empty value used when a property toggles to custom
  /// and the schema declares no `default`.
  static dynamic typedFallback(String? type) {
    switch (type) {
      case 'boolean':
        return false;
      case 'integer':
      case 'number':
        return 0;
      default:
        return '';
    }
  }

  /// Coerces raw text into the schema type where it is unambiguous. Numbers
  /// are parsed when valid; `array` stays a string (split on submit);
  /// anything else is stored verbatim.
  ///
  /// For numeric types a cleared or malformed field never replaces the value:
  /// the last valid value ([previous]) is kept, so the submit path only ever
  /// sends a number.
  static dynamic coerceText(String? type, String value, dynamic previous) {
    if (type == 'integer') {
      return int.tryParse(value.trim()) ?? previous;
    }
    if (type == 'number') {
      return num.tryParse(value.trim()) ?? previous;
    }
    return value;
  }

  /// Joins `array`-typed values into comma strings for editing, matching the
  /// upstream load path.
  static Map<String, dynamic> hydrate(
    WorkspaceValveSpec? spec,
    Map<String, dynamic> values,
  ) {
    final result = Map<String, dynamic>.from(values);
    if (spec == null) return result;
    spec.properties.forEach((property, raw) {
      final propSpec = raw is Map ? raw : const {};
      if (propSpec['type'] == 'array') {
        final current = result[property];
        result[property] = current is List ? current.join(', ') : current;
      }
    });
    return result;
  }

  /// Splits comma strings back into lists for `array`-typed values before
  /// submit, matching the upstream save path.
  static Map<String, dynamic> serialize(
    WorkspaceValveSpec? spec,
    Map<String, dynamic> values,
  ) {
    final result = Map<String, dynamic>.from(values);
    if (spec == null) return result;
    spec.properties.forEach((property, raw) {
      final propSpec = raw is Map ? raw : const {};
      if (propSpec['type'] == 'array') {
        final current = result[property];
        if (current is String) {
          result[property] = current
              .split(',')
              .map((v) => v.trim())
              .where((v) => v.isNotEmpty)
              .toList(growable: false);
        }
      }
    });
    return result;
  }
}
