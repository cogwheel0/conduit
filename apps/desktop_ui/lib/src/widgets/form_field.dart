import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

/// Form controls shared by onboarding, sign-in and settings.
///
/// Plain functions rather than components: they hold no state and have no
/// lifecycle, so a component would add a rebuild boundary and an element to
/// the tree for nothing.
///
/// Each pairs its `<label>` with the control through `htmlFor`. That is not
/// decoration -- it is what makes a screen reader announce the field, and
/// what makes clicking the label focus the input.
Component textField({
  required String id,
  required String labelText,
  required String value,
  required void Function(String value) onInput,
  String? placeholder,
  InputType type = InputType.text,
  bool disabled = false,
  bool autofocus = false,
  bool hideLabel = false,
  String? error,
}) {
  final errorId = '$id-error';
  return div(classes: 'space-y-1.5', [
    _label(id, labelText, hidden: hideLabel),
    input<Object?>(
      id: id,
      classes: _controlClasses(invalid: error != null),
      type: type,
      value: value,
      disabled: disabled,
      // A number field reports a number in the browser -- NaN when empty --
      // and text on the VM; callers get text either way.
      onInput: (value) => onInput(numberFieldText(value)),
      attributes: <String, String>{
        'placeholder': ?placeholder,
        // `input` has no typed `autofocus`; the attribute is the same thing.
        if (autofocus) 'autofocus': '',
        // Both, deliberately: `aria-invalid` is what a screen reader
        // announces on focus, `aria-describedby` is what it reads out as the
        // reason. A red border alone communicates neither.
        if (error != null) ...<String, String>{
          'aria-invalid': 'true',
          'aria-describedby': errorId,
        },
      },
    ),
    if (error != null) _fieldError(errorId, error),
  ]);
}

Component textAreaField({
  required String id,
  required String labelText,
  required String value,
  required void Function(String value) onInput,
  String? placeholder,
  bool disabled = false,
  bool hideLabel = false,
  int rows = 3,

  /// Character-accurate input -- a PEM block, a header list -- where
  /// alignment carries meaning and an ambiguous `l`/`1` costs the user a
  /// debugging session. Prose is the other case, and the composer is prose.
  bool monospace = false,

  /// Raised on every keydown, before the field acts on it. The composer
  /// uses it to send on Enter; `event.preventDefault()` is what stops the
  /// newline that would otherwise follow.
  EventCallback? onKeyDown,
  String? error,
}) {
  final errorId = '$id-error';
  return div(classes: 'space-y-1.5', [
    _label(id, labelText, hidden: hideLabel),
    textarea(
      [Component.text(value)],
      id: id,
      classes:
          '${_controlClasses(invalid: error != null)}'
          '${monospace ? ' font-mono text-xs' : ''}',
      disabled: disabled,
      rows: rows,
      placeholder: placeholder,
      onInput: onInput,
      events: <String, EventCallback>{'keydown': ?onKeyDown},
      attributes: <String, String>{
        if (error != null) ...<String, String>{
          'aria-invalid': 'true',
          'aria-describedby': errorId,
        },
      },
    ),
    if (error != null) _fieldError(errorId, error),
  ]);
}

Component checkboxField({
  required String id,
  // Not named `label`: that is the element function this file calls.
  required String text,
  required bool checked,
  required void Function({required bool value}) onChanged,
  bool disabled = false,
}) => div(classes: 'flex items-center gap-2', [
  input<bool>(
    id: id,
    classes: 'size-4 rounded border-border',
    type: InputType.checkbox,
    disabled: disabled,
    checked: checked,
    onChange: (value) => onChanged(value: value),
  ),
  label(
    [Component.text(text)],
    htmlFor: id,
    classes: 'text-sm text-foreground',
  ),
]);

/// The submit button, which is disabled while a request is in flight.
///
/// `type: submit` rather than a click handler, so the form also submits on
/// Enter from any field -- which is how a two-field login is actually used.
/// [fullWidth] is the stacked-form shape -- sign-in, onboarding, the add
/// server sheet -- where the button is the last row and owns the width. The
/// composer is the other shape: the button sits *beside* the field, and
/// `w-full` there resolves against the flex line, so the button claims the
/// whole row and squeezes the textarea down to its scrollbar.
Component submitButton({
  required String labelText,
  required String busyLabel,
  required bool busy,
  bool enabled = true,
  bool fullWidth = true,
}) => button(
  [Component.text(busy ? busyLabel : labelText)],
  classes:
      '${fullWidth ? 'w-full' : 'shrink-0'} rounded bg-primary px-4 py-2 '
      'text-primary-foreground disabled:opacity-60',
  type: ButtonType.submit,
  disabled: busy || !enabled,
  attributes: <String, String>{if (busy) 'aria-busy': 'true'},
);

/// A whole-form failure, as opposed to a single bad field.
Component formError(String message) => p(
  classes: 'text-sm text-destructive',
  // `alert` so it is announced when it appears, rather than only being found
  // by someone who happens to navigate back over it.
  attributes: const <String, String>{'role': 'alert'},
  [Component.text(message)],
);

String _controlClasses({bool invalid = false}) =>
    'w-full rounded border bg-background px-3 py-2 text-sm '
    'text-foreground outline-none focus-visible:ring-2 '
    'focus-visible:ring-ring disabled:opacity-60 '
    '${invalid ? 'border-destructive' : 'border-border'}';

/// [hidden] keeps the label in the DOM and takes it off the screen.
///
/// For a field whose placeholder already says the same words, the visible
/// label is noise -- but deleting it strips the control's accessible name,
/// because a placeholder is a hint, not a name, and is dropped the moment
/// the field has a value. `sr-only` is the one that keeps both.
Component _label(String id, String text, {bool hidden = false}) => label(
  [Component.text(text)],
  htmlFor: id,
  classes: hidden ? 'sr-only' : 'block text-sm font-medium text-foreground',
);

Component _fieldError(String id, String message) =>
    p(id: id, classes: 'text-xs text-destructive', [Component.text(message)]);

/// What a text callback gets from an input's value: a number field's value
/// arrives as a `num` in the browser.
String numberFieldText(Object? value) => switch (value) {
  final num number when number.isNaN => '',
  final num number when number == number.truncateToDouble() =>
    '${number.toInt()}',
  final num number => '$number',
  _ => '${value ?? ''}',
};
