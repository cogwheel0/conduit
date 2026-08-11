import 'dart:collection';

import 'package:flutter/widgets.dart';

import '../models/direct_connection_profile.dart';

enum DirectHeaderValidationIssue {
  nameRequired,
  invalidName,
  reservedName,
  duplicateName,
  invalidValue,
}

enum DirectCustomHeadersChange { input, collection }

final class DirectHeaderValidationError {
  const DirectHeaderValidationError(this.issue, {this.headerName});

  final DirectHeaderValidationIssue issue;
  final String? headerName;
}

/// Owns custom-header input, validation, and collection mutations.
final class DirectCustomHeadersController {
  DirectCustomHeadersController({required this.onChanged}) {
    name.addListener(_handleInputChanged);
    value.addListener(_handleInputChanged);
  }

  final ValueChanged<DirectCustomHeadersChange> onChanged;
  final name = TextEditingController();
  final value = TextEditingController();
  final valueFocusNode = FocusNode();
  final Map<String, String> _headers = {};

  DirectHeaderValidationError? _error;
  bool _dirty = false;
  bool _updatingInput = false;

  UnmodifiableMapView<String, String> get headers =>
      UnmodifiableMapView(_headers);
  DirectHeaderValidationError? get error => _error;
  bool get isDirty => _dirty;
  bool get canAdd => name.text.trim().isNotEmpty;

  void hydrate(Map<String, String> headers) {
    _headers
      ..clear()
      ..addAll(headers);
    _dirty = false;
    _error = null;
  }

  void _handleInputChanged() {
    if (_updatingInput) return;
    _error = null;
    onChanged(DirectCustomHeadersChange.input);
  }

  void clearError() {
    _error = null;
  }

  bool commitPending() {
    final hasName = name.text.trim().isNotEmpty;
    final hasValue = value.text.isNotEmpty;
    if (!hasName && !hasValue) return true;
    if (!hasName) {
      _error = const DirectHeaderValidationError(
        DirectHeaderValidationIssue.nameRequired,
      );
      onChanged(DirectCustomHeadersChange.input);
      return false;
    }
    return add();
  }

  bool add() {
    if (!canAdd) return false;
    final normalizedName = name.text.trim();
    final validationError =
        _validateName(normalizedName) ?? _validateValue(value.text);
    if (validationError != null) {
      _error = validationError;
      onChanged(DirectCustomHeadersChange.input);
      return false;
    }
    _headers[normalizedName] = value.text;
    _updatingInput = true;
    try {
      name.clear();
      value.clear();
    } finally {
      _updatingInput = false;
    }
    _markChanged();
    return true;
  }

  void remove(String name) {
    if (_headers.remove(name) == null) return;
    _markChanged();
  }

  DirectHeaderValidationError? _validateName(String name) {
    if (!DirectConnectionProfile.isValidCustomHeaderName(name)) {
      return const DirectHeaderValidationError(
        DirectHeaderValidationIssue.invalidName,
      );
    }
    if (DirectConnectionProfile.reservedHeaderNames.contains(
      name.toLowerCase(),
    )) {
      return DirectHeaderValidationError(
        DirectHeaderValidationIssue.reservedName,
        headerName: name,
      );
    }
    final duplicate = _headers.keys.any(
      (existing) => existing.toLowerCase() == name.toLowerCase(),
    );
    if (duplicate) {
      return DirectHeaderValidationError(
        DirectHeaderValidationIssue.duplicateName,
        headerName: name,
      );
    }
    return null;
  }

  DirectHeaderValidationError? _validateValue(String value) {
    if (!DirectConnectionProfile.isValidCustomHeaderValue(value)) {
      return const DirectHeaderValidationError(
        DirectHeaderValidationIssue.invalidValue,
      );
    }
    return null;
  }

  void _markChanged() {
    _dirty = true;
    _error = null;
    onChanged(DirectCustomHeadersChange.collection);
  }

  void dispose() {
    name.removeListener(_handleInputChanged);
    value.removeListener(_handleInputChanged);
    name.dispose();
    value.dispose();
    valueFocusNode.dispose();
  }
}
