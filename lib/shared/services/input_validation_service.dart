/// Comprehensive input validation service
class InputValidationService {
  // Email regex pattern
  static final RegExp _emailRegex = RegExp(
    r'^[a-zA-Z0-9._%+-]+@([a-zA-Z0-9.-]+\.[a-zA-Z]{2,}|localhost)$',
    caseSensitive: false,
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
