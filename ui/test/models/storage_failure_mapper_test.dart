import 'package:ui/models/storage_failure_mapper.dart';
import 'package:flutter_test/flutter_test.dart';

Object _s3Error(String code) {
  return StateError(
    'S3 destination check failed with HTTP 403: '
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<Error><Code>$code</Code>'
    '<Message>Signature validation failed</Message></Error>',
  );
}

void main() {
  group('mapStorageFailure', () {
    const expectedMessages = <String, String>{
      'SignatureDoesNotMatch':
          'The secret access key is not correct for this access key ID.',
      'InvalidAccessKeyId':
          'That access key ID was not recognised by the storage provider.',
      'NoSuchBucket':
          'That bucket does not exist, or is not visible to these credentials.',
      'AccessDenied':
          'These credentials are valid but are not allowed to write to this '
          'bucket.',
      'PermanentRedirect':
          'That bucket is in a different region. Check the region setting.',
      'AuthorizationHeaderMalformed':
          'That bucket is in a different region. Check the region setting.',
    };

    expectedMessages.forEach((code, message) {
      test('$code maps to its own sentence and keeps the raw body', () {
        final error = _s3Error(code);
        final failure = mapStorageFailure(error);

        expect(failure.message, message);
        expect(
          failure.detail,
          error.toString(),
          reason: 'the provider text must survive for the details reveal',
        );
        expect(
          failure.message,
          isNot(contains('<Code>')),
          reason: 'the primary path never shows provider markup',
        );
      });
    });

    test('an unrecognised code falls back but keeps the raw body', () {
      final error = _s3Error('SomeCodeNobodyHasSeen');
      final failure = mapStorageFailure(error);

      expect(failure.message, storageFailureFallbackMessage);
      expect(
        failure.detail,
        contains('SomeCodeNobodyHasSeen'),
        reason: 'an unmapped code still reaches the user intact',
      );
    });

    test('a body with no Code element falls back', () {
      final error = StateError('S3 destination check failed with HTTP 500');
      final failure = mapStorageFailure(error);

      expect(failure.message, storageFailureFallbackMessage);
      expect(failure.detail, error.toString());
    });

    test('an unterminated Code element is treated as absent', () {
      final error = StateError('<Error><Code>SignatureDoesNotMatch');
      final failure = mapStorageFailure(error);

      expect(
        failure.message,
        storageFailureFallbackMessage,
        reason: 'a truncated body must not be parsed as a code',
      );
    });

    test('an empty Code element is treated as absent', () {
      final failure = mapStorageFailure(
        StateError('<Error><Code>   </Code></Error>'),
      );

      expect(failure.message, storageFailureFallbackMessage);
    });

    test('failure messages have value semantics and useful debug output', () {
      const failure = StorageFailureMessage(
        message: 'Check the credentials.',
        detail: 'provider detail',
      );
      const same = StorageFailureMessage(
        message: 'Check the credentials.',
        detail: 'provider detail',
      );

      expect(failure, same);
      expect(failure.hashCode, same.hashCode);
      expect(
        failure.toString(),
        'StorageFailureMessage(Check the credentials.)',
      );
      expect(failure == Object(), isFalse);
      expect(
        failure ==
            const StorageFailureMessage(
              message: 'Different message.',
              detail: 'provider detail',
            ),
        isFalse,
      );
      expect(
        failure ==
            const StorageFailureMessage(
              message: 'Check the credentials.',
              detail: 'different detail',
            ),
        isFalse,
      );
    });
  });
}
