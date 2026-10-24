import 'package:flutter_test/flutter_test.dart';
import 'package:ui/data/local/sqlite_validation.dart';

void main() {
  Matcher throwsMessage(String message) {
    return throwsA(
      isA<ArgumentError>().having((error) => error.message, 'message', message),
    );
  }

  group('requiredSqliteField', () {
    test('trims the value', () {
      expect(requiredSqliteField('  name  ', 'name'), 'name');
    });

    test('rejects blank values', () {
      expect(
        () => requiredSqliteField('   ', 'name'),
        throwsMessage('must not be empty'),
      );
    });
  });

  group('requiredSqliteName', () {
    test('accepts a valid name', () {
      expect(
        requiredSqliteName(
          'Catalog DB 1.0',
          'name',
          patternMessage: 'must be a SQLite name',
        ),
        'Catalog DB 1.0',
      );
    });

    test('rejects names outside the pattern with the caller message', () {
      expect(
        () => requiredSqliteName(
          'Bad!Name',
          'name',
          patternMessage: 'must be a SQLite name',
        ),
        throwsMessage('must be a SQLite name'),
      );
      expect(
        () => requiredSqliteName(
          'Bad!Name',
          'name',
          patternMessage: 'must start with alphanumeric',
          lengthCap: (max: 64, message: 'must be 64 characters or fewer'),
        ),
        throwsMessage('must start with alphanumeric'),
      );
    });

    test('caps length only when the caller passes a cap', () {
      final longName = 'n'.padRight(65, 'a');
      // Snapshot callers pass no cap: accepted.
      expect(
        requiredSqliteName(
          longName,
          'name',
          patternMessage: 'must be a SQLite name',
        ),
        longName,
      );
      // Database callers pass the 64-char cap: rejected.
      expect(
        () => requiredSqliteName(
          longName,
          'name',
          patternMessage: 'must start with alphanumeric',
          lengthCap: (max: 64, message: 'must be 64 characters or fewer'),
        ),
        throwsMessage('must be 64 characters or fewer'),
      );
      // ... while valid names still pass with the cap set.
      expect(
        requiredSqliteName(
          'Catalog',
          'name',
          patternMessage: 'must start with alphanumeric',
          lengthCap: (max: 64, message: 'must be 64 characters or fewer'),
        ),
        'Catalog',
      );
    });
  });

  group('requiredDockerName', () {
    test('accepts a valid Docker name', () {
      expect(
        requiredDockerName(
          'deploydash_sqlite_p1_db1',
          'volumeName',
          patternMessage: 'must be a Docker name',
        ),
        'deploydash_sqlite_p1_db1',
      );
    });

    test('rejects invalid names with the caller message', () {
      expect(
        () => requiredDockerName(
          '!!!',
          'volumeName',
          patternMessage: 'must be a Docker name',
        ),
        throwsMessage('must be a Docker name'),
      );
      expect(
        () => requiredDockerName(
          'has space',
          'volumeName',
          patternMessage: 'must be a valid Docker volume name',
        ),
        throwsMessage('must be a valid Docker volume name'),
      );
    });
  });

  group('requiredFileName', () {
    test('accepts a plain filename', () {
      expect(
        requiredFileName(
          'catalog.db',
          'fileName',
          patternMessage: 'must be a filename',
        ),
        'catalog.db',
      );
      expect(
        requiredFileName(
          'catalog.db',
          'fileName',
          patternMessage: 'must contain only letters, numbers, _, -, .',
          slashMessage: 'must be a plain filename without /, . or ..',
        ),
        'catalog.db',
      );
    });

    test('routes separators to the caller message split', () {
      // Snapshot callers pass no slash message: the pattern message fires.
      expect(
        () => requiredFileName(
          'sub/dir.db',
          'fileName',
          patternMessage: 'must be a filename',
        ),
        throwsMessage('must be a filename'),
      );
      // Database callers pass a slash message: it fires first.
      expect(
        () => requiredFileName(
          'sub/dir.db',
          'fileName',
          patternMessage: 'must contain only letters, numbers, _, -, .',
          slashMessage: 'must be a plain filename without /, . or ..',
        ),
        throwsMessage('must be a plain filename without /, . or ..'),
      );
      expect(
        () => requiredFileName(
          '.',
          'fileName',
          patternMessage: 'must contain only letters, numbers, _, -, .',
          slashMessage: 'must be a plain filename without /, . or ..',
        ),
        throwsMessage('must be a plain filename without /, . or ..'),
      );
      expect(
        () => requiredFileName(
          '..',
          'fileName',
          patternMessage: 'must contain only letters, numbers, _, -, .',
          slashMessage: 'must be a plain filename without /, . or ..',
        ),
        throwsMessage('must be a plain filename without /, . or ..'),
      );
      // ... while the pattern message still fires for non-separator input.
      expect(
        () => requiredFileName(
          'bad!name',
          'fileName',
          patternMessage: 'must contain only letters, numbers, _, -, .',
          slashMessage: 'must be a plain filename without /, . or ..',
        ),
        throwsMessage('must contain only letters, numbers, _, -, .'),
      );
    });
  });

  group('requiredMountPath', () {
    test('pass-through callers keep the input verbatim', () {
      const caller = (
        absoluteMessage: 'must be absolute',
        dotSegmentMessage: 'must not contain . or ..',
      );
      expect(
        requiredMountPath(
          '/data//doubled/',
          'mountPath',
          normalize: false,
          absoluteMessage: caller.absoluteMessage,
          dotSegmentMessage: caller.dotSegmentMessage,
        ),
        '/data//doubled/',
      );
      expect(
        requiredMountPath(
          '/',
          'mountPath',
          normalize: false,
          absoluteMessage: caller.absoluteMessage,
          dotSegmentMessage: caller.dotSegmentMessage,
        ),
        '/',
      );
    });

    test('pass-through callers reject relative and dotted paths', () {
      expect(
        () => requiredMountPath(
          'relative/path',
          'mountPath',
          normalize: false,
          absoluteMessage: 'must be absolute',
          dotSegmentMessage: 'must not contain . or ..',
        ),
        throwsMessage('must be absolute'),
      );
      expect(
        () => requiredMountPath(
          '/data/./escape',
          'mountPath',
          normalize: false,
          absoluteMessage: 'must be absolute',
          dotSegmentMessage: 'must not contain . or ..',
        ),
        throwsMessage('must not contain . or ..'),
      );
      expect(
        () => requiredMountPath(
          '/data/../escape',
          'mountPath',
          normalize: false,
          absoluteMessage: 'must be absolute',
          dotSegmentMessage: 'must not contain . or ..',
        ),
        throwsMessage('must not contain . or ..'),
      );
    });

    test('normalizing callers get a rebuilt path', () {
      expect(
        requiredMountPath(
          '/data//db1/',
          'mountPath',
          normalize: true,
          absoluteMessage: 'must be an absolute path',
          dotSegmentMessage: 'must not include . or .. segments',
          emptySegmentsMessage: 'must include path segments',
        ),
        '/data/db1',
      );
      expect(
        requiredMountPath(
          '/data/ /db1',
          'mountPath',
          normalize: true,
          absoluteMessage: 'must be an absolute path',
          dotSegmentMessage: 'must not include . or .. segments',
          emptySegmentsMessage: 'must include path segments',
        ),
        '/data/db1',
      );
    });

    test('normalizing callers reject bare root and dotted segments', () {
      expect(
        () => requiredMountPath(
          '/',
          'mountPath',
          normalize: true,
          absoluteMessage: 'must be an absolute path',
          dotSegmentMessage: 'must not include . or .. segments',
          emptySegmentsMessage: 'must include path segments',
        ),
        throwsMessage('must include path segments'),
      );
      expect(
        () => requiredMountPath(
          'relative/path',
          'mountPath',
          normalize: true,
          absoluteMessage: 'must be an absolute path',
          dotSegmentMessage: 'must not include . or .. segments',
          emptySegmentsMessage: 'must include path segments',
        ),
        throwsMessage('must be an absolute path'),
      );
      expect(
        () => requiredMountPath(
          '/data/./escape',
          'mountPath',
          normalize: true,
          absoluteMessage: 'must be an absolute path',
          dotSegmentMessage: 'must not include . or .. segments',
          emptySegmentsMessage: 'must include path segments',
        ),
        throwsMessage('must not include . or .. segments'),
      );
      expect(
        () => requiredMountPath(
          '/data/../escape',
          'mountPath',
          normalize: true,
          absoluteMessage: 'must be an absolute path',
          dotSegmentMessage: 'must not include . or .. segments',
          emptySegmentsMessage: 'must include path segments',
        ),
        throwsMessage('must not include . or .. segments'),
      );
    });
  });
}
