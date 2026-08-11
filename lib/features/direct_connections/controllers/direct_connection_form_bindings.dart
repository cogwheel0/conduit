import 'package:flutter/widgets.dart';

/// Owns the Flutter input primitives used by the Direct connection form.
///
/// Keeping widget lifecycle objects separate from draft policy makes their
/// ownership explicit and lets the editor controller focus on transitions and
/// validation.
final class DirectConnectionFormBindings {
  final name = TextEditingController();
  final baseUrl = TextEditingController();
  final apiKey = TextEditingController();
  final apiVersion = TextEditingController();
  final modelIdPrefix = TextEditingController();
  final tags = TextEditingController();
  final models = TextEditingController();

  void dispose() {
    name.dispose();
    baseUrl.dispose();
    apiKey.dispose();
    apiVersion.dispose();
    modelIdPrefix.dispose();
    tags.dispose();
    models.dispose();
  }
}
