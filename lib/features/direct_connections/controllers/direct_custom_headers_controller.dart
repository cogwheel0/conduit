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

final class DirectHeaderValidationError {
  const DirectHeaderValidationError(this.issue, {this.headerName});

  final DirectHeaderValidationIssue issue;
  final String? headerName;
}

/// Owns custom-header input, validation, and collection mutations.
final class DirectCustomHeadersController extends ChangeNotifier {
  DirectCustomHeadersController({this.onHeadersChanged});

  final VoidCallback? onHeadersChanged;
  final name = TextEditingController();
  final value = TextEditingController();
  final valueFocusNode = FocusNode();
  final Map<String, String> _headers = {};

  DirectHeaderValidationError? _error;
  bool _dirty = false;

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

  void markInputChanged() {
    if (_error == null) return;
    _error = null;
    notifyListeners();
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
      notifyListeners();
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
      notifyListeners();
      return false;
    }
    _headers[normalizedName] = value.text;
    name.clear();
    value.clear();
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
    onHeadersChanged?.call();
    notifyListeners();
  }

  @override
  void dispose() {
    name.dispose();
    value.dispose();
    valueFocusNode.dispose();
    super.dispose();
  }
}
