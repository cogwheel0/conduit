import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../shared/theme/conduit_input_styles.dart';

/// Comprehensive input validation service
class InputValidationService {
  // Email regex pattern
  static final RegExp _emailRegex = RegExp(
    r'^[a-zA-Z0-9._%+-]+@([a-zA-Z0-9.-]+\.[a-zA-Z]{2,}|localhost)$',
  );

  // Strong password regex (min 8 chars, 1 upper, 1 lower, 1 number, 1 special)
  static final RegExp _strongPasswordRegex = RegExp(
    r'^(?=.*[a-z])(?=.*[A-Z])(?=.*\d)(?=.*[@$!%*?&])[A-Za-z\d@$!%*?&]{8,}$',
  );

  /// Validate email address
  static String? validateEmail(String? value) {
    if (value == null || value.isEmpty) {
      return 'Email is required';
    }

    final trimmed = value.trim();
    if (!_emailRegex.hasMatch(trimmed)) {
      return 'Please enter a valid email address';
    }

    return null;
  }

  /// Validate URL (enhanced version for server addresses)
  static String? validateUrl(String? value, {bool required = true}) {
    if (value == null || value.isEmpty) {
      return required ? 'Server address is required' : null;
    }

    final trimmed = value.trim();

    // Add protocol if missing
    String urlToValidate = trimmed;
    if (!trimmed.startsWith('http://') && !trimmed.startsWith('https://')) {
      urlToValidate = 'http://$trimmed';
    }

    try {
      final uri = Uri.parse(urlToValidate);

      // Validate scheme
      if (!uri.hasScheme || (uri.scheme != 'http' && uri.scheme != 'https')) {
        return 'Use http:// or https:// only';
      }

      // Validate host
      if (!uri.hasAuthority || uri.host.isEmpty) {
        return 'Please enter a server address (e.g., 192.168.1.10:3000)';
      }

      // Validate port if specified
      if (uri.hasPort) {
        if (uri.port < 1 || uri.port > 65535) {
          return 'Port must be between 1 and 65535';
        }
      }

      // Validate IP address format if it looks like an IP
      if (_isIPAddress(uri.host) && !_isValidIPAddress(uri.host)) {
        return 'Invalid IP address format (use 192.168.1.10)';
      }
    } catch (e) {
      return 'Invalid server address format';
    }

    return null;
  }

  /// Check if a string looks like an IP address
  static bool _isIPAddress(String host) {
    return RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(host);
  }

  /// Validate IP address format
  static bool _isValidIPAddress(String ip) {
    final parts = ip.split('.');
    if (parts.length != 4) return false;

    for (final part in parts) {
      final num = int.tryParse(part);
      if (num == null || num < 0 || num > 255) return false;
    }
    return true;
  }

  /// Validate password strength
  static String? validatePassword(String? value, {bool checkStrength = true}) {
    if (value == null || value.isEmpty) {
      return 'Password is required';
    }

    if (value.length < 8) {
      return 'Password must be at least 8 characters';
    }

    if (checkStrength && !_strongPasswordRegex.hasMatch(value)) {
      return 'Password must contain uppercase, lowercase, number, and special character';
    }

    return null;
  }

  /// Validate confirm password
  static String? validateConfirmPassword(String? value, String password) {
    if (value == null || value.isEmpty) {
      return 'Please confirm your password';
    }

    if (value != password) {
      return 'Passwords do not match';
    }

    return null;
  }

  /// Validate required field
  static String? validateRequired(
    String? value, {
    String fieldName = 'This field',
  }) {
    if (value == null || value.trim().isEmpty) {
      return '$fieldName is required';
    }
    return null;
  }

  /// Validate minimum length
  static String? validateMinLength(
    String? value,
    int minLength, {
    String fieldName = 'This field',
  }) {
    if (value == null || value.isEmpty) {
      return '$fieldName is required';
    }

    if (value.length < minLength) {
      return '$fieldName must be at least $minLength characters';
    }

    return null;
  }

  /// Validate maximum length
  static String? validateMaxLength(
    String? value,
    int maxLength, {
    String fieldName = 'This field',
  }) {
    if (value != null && value.length > maxLength) {
      return '$fieldName must be at most $maxLength characters';
    }

    return null;
  }

  /// Validate numeric input
  static String? validateNumber(
    String? value, {
    double? min,
    double? max,
    bool allowDecimal = true,
    bool required = true,
  }) {
    if (value == null || value.isEmpty) {
      return required ? 'Number is required' : null;
    }

    final number = allowDecimal ? double.tryParse(value) : int.tryParse(value);

    if (number == null) {
      return allowDecimal
          ? 'Please enter a valid number'
          : 'Please enter a whole number';
    }

    if (min != null && number < min) {
      return 'Value must be at least $min';
    }

    if (max != null && number > max) {
      return 'Value must be at most $max';
    }

    return null;
  }

  /// Validate phone number
  static String? validatePhoneNumber(String? value, {bool required = true}) {
    if (value == null || value.isEmpty) {
      return required ? 'Phone number is required' : null;
    }

    // Remove all non-digits
    final digitsOnly = value.replaceAll(RegExp(r'\D'), '');

    if (digitsOnly.length < 10) {
      return 'Please enter a valid phone number';
    }

    return null;
  }

  /// Validate alphanumeric input
  static String? validateAlphanumeric(
    String? value, {
    bool allowSpaces = false,
    bool required = true,
    String fieldName = 'This field',
  }) {
    if (value == null || value.isEmpty) {
      return required ? '$fieldName is required' : null;
    }

    final pattern = allowSpaces ? r'^[a-zA-Z0-9\s]+$' : r'^[a-zA-Z0-9]+$';
    if (!RegExp(pattern).hasMatch(value)) {
      return allowSpaces
          ? '$fieldName can only contain letters, numbers, and spaces'
          : '$fieldName can only contain letters and numbers';
    }

    return null;
  }

  /// Validate username
  static String? validateUsername(String? value) {
    if (value == null || value.isEmpty) {
      return 'Username is required';
    }

    if (value.length < 3) {
      return 'Username must be at least 3 characters';
    }

    if (value.length > 20) {
      return 'Username must be at most 20 characters';
    }

    if (!RegExp(r'^[a-zA-Z0-9_]+$').hasMatch(value)) {
      return 'Username can only contain letters, numbers, and underscores';
    }

    return null;
  }

  /// Validate email or username (flexible login)
  static String? validateEmailOrUsername(String? value) {
    if (value == null || value.isEmpty) {
      return 'Email or username is required';
    }

    final trimmed = value.trim();

    // If it contains @ symbol, validate as email
    if (trimmed.contains('@')) {
      return validateEmail(value);
    }

    // Otherwise validate as username
    return validateUsername(value);
  }

  /// Sanitize input to prevent XSS
  static String sanitizeInput(String input) {
    return input
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&#x27;')
        .replaceAll('/', '&#x2F;');
  }

  /// Create input formatter for numeric input
  static List<TextInputFormatter> numericInputFormatters({
    bool allowDecimal = true,
    bool allowNegative = false,
  }) {
    return [
      FilteringTextInputFormatter.allow(
        RegExp(
          allowDecimal
              ? (allowNegative ? r'[0-9.-]' : r'[0-9.]')
              : (allowNegative ? r'[0-9-]' : r'[0-9]'),
        ),
      ),
    ];
  }

  /// Create input formatter for alphanumeric input
  static List<TextInputFormatter> alphanumericInputFormatters({
    bool allowSpaces = false,
  }) {
    return [
      FilteringTextInputFormatter.allow(
        RegExp(allowSpaces ? r'[a-zA-Z0-9\s]' : r'[a-zA-Z0-9]'),
      ),
    ];
  }

  /// Create input formatter for phone number
  static List<TextInputFormatter> phoneNumberFormatters() {
    return [
      FilteringTextInputFormatter.digitsOnly,
      LengthLimitingTextInputFormatter(15),
      _PhoneNumberFormatter(),
    ];
  }

  /// Validate file size
  static String? validateFileSize(int sizeInBytes, {int maxSizeInMB = 10}) {
    final maxSizeInBytes = maxSizeInMB * 1024 * 1024;
    if (sizeInBytes > maxSizeInBytes) {
      return 'File size must be less than ${maxSizeInMB}MB';
    }
    return null;
  }

  /// Validate file extension
  static String? validateFileExtension(
    String fileName,
    List<String> allowedExtensions,
  ) {
    final extension = fileName.split('.').last.toLowerCase();
    if (!allowedExtensions.contains(extension)) {
      return 'File type not allowed. Allowed types: ${allowedExtensions.join(', ')}';
    }
    return null;
  }

  /// Composite validator that runs multiple validators
  static String? Function(String?) combine(
    List<String? Function(String?)> validators,
  ) {
    return (String? value) {
      for (final validator in validators) {
        final result = validator(value);
        if (result != null) {
          return result;
        }
      }
      return null;
    };
  }
}

/// Custom phone number formatter
class _PhoneNumberFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final text = newValue.text;

    if (text.length <= 3) {
      return newValue;
    }

    if (text.length <= 6) {
      final newText = '(${text.substring(0, 3)}) ${text.substring(3)}';
      return TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: newText.length),
      );
    }

    if (text.length <= 10) {
      final newText =
          '(${text.substring(0, 3)}) ${text.substring(3, 6)}-${text.substring(6)}';
      return TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: newText.length),
      );
    }

    final newText =
        '(${text.substring(0, 3)}) ${text.substring(3, 6)}-${text.substring(6, 10)}';
    return TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: newText.length),
    );
  }
}

/// Form field wrapper with validation
class ValidatedFormField extends StatefulWidget {
  final String label;
  final String? hint;
  final TextEditingController controller;
  final String? Function(String?) validator;
  final List<TextInputFormatter>? inputFormatters;
  final TextInputType? keyboardType;
  final bool obscureText;
  final Widget? suffixIcon;
  final bool autofocus;
  final void Function(String)? onChanged;
  final void Function(String)? onFieldSubmitted;
  final FocusNode? focusNode;
  final int? maxLines;
  final bool enabled;

  const ValidatedFormField({
    super.key,
    required this.label,
    this.hint,
    required this.controller,
    required this.validator,
    this.inputFormatters,
    this.keyboardType,
    this.obscureText = false,
    this.suffixIcon,
    this.autofocus = false,
    this.onChanged,
    this.onFieldSubmitted,
    this.focusNode,
    this.maxLines = 1,
    this.enabled = true,
  });

  @override
  State<ValidatedFormField> createState() => _ValidatedFormFieldState();
}

class _ValidatedFormFieldState extends State<ValidatedFormField> {
  String? _errorText;
  bool _hasInteracted = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_validate);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_validate);
    super.dispose();
  }

  void _validate() {
    if (!_hasInteracted) return;

    final error = widget.validator(widget.controller.text);
    if (error != _errorText) {
      setState(() {
        _errorText = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: widget.controller,
      focusNode: widget.focusNode,
      validator: (value) {
        setState(() {
          _hasInteracted = true;
        });
        return widget.validator(value);
      },
      inputFormatters: widget.inputFormatters,
      keyboardType: widget.keyboardType,
      obscureText: widget.obscureText,
      autofocus: widget.autofocus,
      maxLines: widget.maxLines,
      enabled: widget.enabled,
      onChanged: (value) {
        if (!_hasInteracted) {
          setState(() {
            _hasInteracted = true;
          });
        }
        _validate();
        widget.onChanged?.call(value);
      },
      onFieldSubmitted: widget.onFieldSubmitted,
      decoration: context.conduitInputStyles
          .standard(
            hint: widget.hint,
            error: _errorText,
          )
          .copyWith(
            labelText: widget.label,
            suffixIcon: widget.suffixIcon,
          ),
    );
  }
}
