/// A storage-provider failure, split into the sentence a user can act on and
/// the raw provider text that sits behind it.
///
/// Deliberately **not** an [AppFailure]: `result.dart`'s sealed hierarchy
/// models engine, connection, validation, local-storage and cancellation
/// failures, and no variant carries a user sentence and raw detail together.
/// Adding one is a decision that belongs with the `Result` adoption work, not
/// with a defect fix, so this keeps both halves in its own value type instead.
/// Callers pair [message] with [detail] behind `AppTechnicalDetails`. G-38.
class StorageFailureMessage {
  /// Creates a failure carrying both halves: what to say, and what was said.
  const StorageFailureMessage({required this.message, required this.detail});

  /// What to show on the primary path. Never contains provider markup.
  final String message;

  /// The original text, for the technical-details reveal. Never discarded:
  /// a code this mapper has not seen still reaches the user intact.
  final String detail;

  @override
  bool operator ==(Object other) =>
      other is StorageFailureMessage &&
      other.message == message &&
      other.detail == detail;

  @override
  int get hashCode => Object.hash(StorageFailureMessage, message, detail);

  @override
  String toString() => 'StorageFailureMessage($message)';
}

/// Shown when the provider sent no recognisable code, or one with no mapping.
const storageFailureFallbackMessage =
    'Deploy Dash could not reach the storage destination.';

/// S3-compatible error codes this mapper can turn into an actionable
/// sentence. Anything absent falls back rather than guessing: a wrong
/// diagnosis costs the user more than an honest "could not reach".
const _messagesByCode = <String, String>{
  'SignatureDoesNotMatch':
      'The secret access key is not correct for this access key ID.',
  'InvalidAccessKeyId':
      'That access key ID was not recognised by the storage provider.',
  'NoSuchBucket':
      'That bucket does not exist, or is not visible to these credentials.',
  'AccessDenied':
      'These credentials are valid but are not allowed to write to this '
      'bucket.',
  // Both codes mean the same thing to a user: the bucket lives elsewhere.
  'PermanentRedirect':
      'That bucket is in a different region. Check the region setting.',
  'AuthorizationHeaderMalformed':
      'That bucket is in a different region. Check the region setting.',
};

const _codeOpenTag = '<Code>';
const _codeCloseTag = '</Code>';

/// Reads the S3 error code out of a provider's XML body, or null when there
/// is no complete `<Code>...</Code>` pair.
String? _extractS3ErrorCode(String raw) {
  final start = raw.indexOf(_codeOpenTag);
  if (start < 0) {
    return null;
  }
  final valueStart = start + _codeOpenTag.length;
  final end = raw.indexOf(_codeCloseTag, valueStart);
  if (end < 0) {
    return null;
  }
  final code = raw.substring(valueStart, end).trim();
  return code.isEmpty ? null : code;
}

/// Maps an S3-compatible provider's error onto a sentence a user can act on.
///
/// The code is read from the `<Code>...</Code>` element that S3-compatible
/// providers put in their XML error bodies.
StorageFailureMessage mapStorageFailure(Object error) {
  final raw = error.toString();
  final code = _extractS3ErrorCode(raw);
  return StorageFailureMessage(
    message: _messagesByCode[code] ?? storageFailureFallbackMessage,
    detail: raw,
  );
}
