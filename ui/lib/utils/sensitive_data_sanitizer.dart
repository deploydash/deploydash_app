import 'dart:convert';

import 'payload_codecs.dart';

final RegExp _ansiEscapePattern = RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]');
final RegExp _sensitiveKeyPattern = RegExp(
  r'(password|passphrase|token|secret|credential|api[_-]?key|access[_-]?key|private[_-]?key|key_path|_sudo_password|ssh_password|pgpassword)',
  caseSensitive: false,
);
final RegExp _sensitiveFieldPattern = RegExp(
  r'''((?:(?<=\W)|^)(?:["']?[A-Za-z0-9_-]*(?:password|passphrase|token|secret|credential|api[_-]?key|access[_-]?key|private[_-]?key|key_path|pgpassword)[A-Za-z0-9_-]*["']?)\s*[:=]\s*)(["']?)([^"'\s,\)\]}]+)\2''',
  caseSensitive: false,
);
final RegExp _uriCredentialPattern = RegExp(
  r'([a-z][a-z0-9+\-.]*://[^/\s:@]+:)([^@/\s]+)(@)',
  caseSensitive: false,
);
final RegExp _environmentAssignmentPattern = RegExp(
  r'''(?<![A-Za-z0-9_])([A-Z][A-Z0-9_]{1,})=("[^"]*"|'[^']*'|[^\s;,\)\]}]+)''',
);
final RegExp _environmentMappingPattern = RegExp(
  r'''((?:(?<=\W)|^)(?:["']?(?:[A-Z][A-Z0-9_]{1,})["']?)\s*[:=]\s*)(["'])([^"']*)\2''',
);
final RegExp _environmentTabValuePattern = RegExp(
  r'^([A-Z][A-Z0-9_]{1,})\t.+$',
  multiLine: true,
);
final RegExp _privateKeyBlockPattern = RegExp(
  r'-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?-----END [A-Z0-9 ]*PRIVATE KEY-----',
  caseSensitive: false,
  dotAll: true,
);
final RegExp _authorizationHeaderPattern = RegExp(
  r'((?:(?<=\W)|^)authorization\s*[:=]\s*)((?:bearer|basic)\s+)?([^\s,;]+)',
  caseSensitive: false,
);
const _environmentContainerKeys = <String>{
  'env',
  'env_vars',
  'environment',
  'runtime_env',
};

/// Preserves environment-container shape while redacting every leaf value.
// D-58 (T-014): left — a redact shape (stringify + recursive '***'), not a
// plain key-stringify; neither codec owner applies.
Object? _redactEnvironmentDescendants(Object? value) {
  if (value is Map) {
    return <String, Object?>{
      for (final entry in value.entries)
        entry.key.toString(): _redactEnvironmentDescendants(entry.value),
    };
  }
  if (value is List) {
    return value
        .map<Object?>(_redactEnvironmentDescendants)
        .toList(growable: false);
  }
  return '***';
}

/// Strips terminal escapes and redacts credential-looking values in free text.
///
/// Text matching is defence in depth; structured payloads must also pass
/// through [sanitizeSensitiveData] at every persisted or exposed boundary.
String sanitizeSensitiveText(String message) {
  var cleaned = message.replaceAll(_ansiEscapePattern, '');
  cleaned = cleaned.replaceAll(_privateKeyBlockPattern, '***');
  cleaned = cleaned.replaceAllMapped(_authorizationHeaderPattern, (match) {
    final prefix = match.group(1) ?? '';
    final scheme = match.group(2) ?? '';
    return '$prefix$scheme***';
  });
  cleaned = cleaned.replaceAllMapped(_sensitiveFieldPattern, (match) {
    final prefix = match.group(1) ?? '';
    final quote = match.group(2) ?? '';
    if (quote.isNotEmpty) {
      return '$prefix$quote***$quote';
    }
    return '$prefix***';
  });
  cleaned = cleaned.replaceAllMapped(
    _environmentTabValuePattern,
    (match) => '${match.group(1)}\t***',
  );
  cleaned = cleaned.replaceAllMapped(_environmentMappingPattern, (match) {
    final prefix = match.group(1) ?? '';
    final quote = match.group(2) ?? '';
    return '$prefix$quote***$quote';
  });
  cleaned = cleaned.replaceAllMapped(
    _environmentAssignmentPattern,
    (match) => '${match.group(1)}=***',
  );
  return cleaned.replaceAllMapped(_uriCredentialPattern, (match) {
    final prefix = match.group(1) ?? '';
    final suffix = match.group(3) ?? '';
    return '$prefix***$suffix';
  }).trim();
}

/// Recursively redacts a decoded JSON value at every exposure boundary.
///
/// Sensitive keys are redacted whole. Environment-container keys preserve
/// their diagnostic shape but replace every descendant value, even when a
/// child key such as `FEATURE_FLAG` is not intrinsically secret-looking.
// D-58 (T-014): left — key normalization feeds the redact dispatch
// (environment/sensitive/plain arms), not a plain stringify.
Object? sanitizeSensitiveData(Object? value) {
  if (value is Map) {
    return value.map<String, Object?>((key, item) {
      final normalizedKey = key.toString();
      if (_environmentContainerKeys.contains(
        normalizedKey.trim().toLowerCase(),
      )) {
        return MapEntry<String, Object?>(
          normalizedKey,
          _redactEnvironmentDescendants(item),
        );
      }
      if (_sensitiveKeyPattern.hasMatch(normalizedKey)) {
        return MapEntry<String, Object?>(normalizedKey, '***');
      }
      return MapEntry<String, Object?>(
        normalizedKey,
        sanitizeSensitiveData(item),
      );
    });
  }
  if (value is List) {
    return value.map<Object?>(sanitizeSensitiveData).toList(growable: false);
  }
  if (value is String) {
    return sanitizeSensitiveText(value);
  }
  return value;
}

/// [sanitizeSensitiveData] for a payload already known to be a JSON object.
///
/// Throws [FormatException] instead of returning an unsanitized fallback.
Map<String, dynamic> sanitizeSensitivePayloadMap(Map<String, dynamic> payload) {
  final sanitized = sanitizeSensitiveData(payload)! as Map;
  return mapFrom(sanitized);
}

/// Sanitizes a JSON object that may still be encoded, or wrongly typed.
///
/// Anything other than a map or an encoded map throws because guessing would
/// permit an unsanitized value to cross the boundary.
Map<String, dynamic> sanitizeJsonObjectFromUnknown(Object? value) {
  if (value is Map<String, dynamic>) {
    return sanitizeSensitivePayloadMap(value);
  }
  if (value is Map) {
    return sanitizeSensitivePayloadMap(mapFrom(value));
  }
  if (value is String && value.trim().isNotEmpty) {
    final decoded = jsonDecode(value);
    if (decoded is Map) {
      return sanitizeSensitivePayloadMap(mapFrom(decoded));
    }
  }
  throw const FormatException('Value is not a JSON object.');
}
