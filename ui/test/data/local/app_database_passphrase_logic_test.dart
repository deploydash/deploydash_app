import 'package:ui/data/local/app_database_passphrase_logic.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeCreationHandle implements DatabasePassphraseCreationHandle {
  _FakeCreationHandle({this.onWarmUp, this.onClose});

  final Future<void> Function()? onWarmUp;
  final Future<void> Function()? onClose;

  @override
  Future<void> close() async {
    await onClose?.call();
  }

  @override
  Future<void> warmUp() async {
    await onWarmUp?.call();
  }
}

void main() {
  test('returns false when the passphrase is blank', () async {
    var checkedExists = false;

    final result = await createDatabasePassphraseWithDependencies(
      passphrase: '   ',
      databaseAlreadyExists: () async {
        checkedExists = true;
        return false;
      },
      deleteDatabaseFiles: () async {},
      openDatabase: (_) async => _FakeCreationHandle(),
      validatePassphrase: (_) async => true,
    );

    expect(result, isFalse);
    expect(checkedExists, isFalse);
  });

  test('returns false when an encrypted database already exists', () async {
    var deletedFiles = false;

    final result = await createDatabasePassphraseWithDependencies(
      passphrase: 'topsecret',
      databaseAlreadyExists: () async => true,
      deleteDatabaseFiles: () async {
        deletedFiles = true;
      },
      openDatabase: (_) async => _FakeCreationHandle(),
      validatePassphrase: (_) async => true,
    );

    expect(result, isFalse);
    expect(deletedFiles, isFalse);
  });

  test('creates, validates, and closes the database on success', () async {
    final calls = <String>[];

    final result = await createDatabasePassphraseWithDependencies(
      passphrase: '  topsecret  ',
      databaseAlreadyExists: () async {
        calls.add('exists');
        return false;
      },
      deleteDatabaseFiles: () async {
        calls.add('delete');
      },
      openDatabase: (passphrase) async {
        calls.add('open:$passphrase');
        return _FakeCreationHandle(
          onWarmUp: () async => calls.add('warmUp'),
          onClose: () async => calls.add('close'),
        );
      },
      validatePassphrase: (passphrase) async {
        calls.add('validate:$passphrase');
        return true;
      },
    );

    expect(result, isTrue);
    expect(calls, <String>[
      'exists',
      'delete',
      'open:topsecret',
      'warmUp',
      'validate:topsecret',
      'close',
    ]);
  });

  test('deletes the new database when validation fails', () async {
    var deletedFiles = 0;
    Object? reportedFailure;

    final result = await createDatabasePassphraseWithDependencies(
      passphrase: 'topsecret',
      databaseAlreadyExists: () async => false,
      deleteDatabaseFiles: () async {
        deletedFiles += 1;
      },
      openDatabase: (_) async => _FakeCreationHandle(),
      validatePassphrase: (_) async => false,
      reportFailure: (error) => reportedFailure = error,
    );

    expect(result, isFalse);
    expect(deletedFiles, 2);
    expect(
      reportedFailure,
      isA<StateError>().having(
        (error) => error.message,
        'message',
        'The encrypted database could not be reopened after it was created.',
      ),
    );
  });

  test('deletes the new database when warm-up throws', () async {
    var deletedFiles = 0;
    var closeCalls = 0;
    Object? reportedFailure;

    final result = await createDatabasePassphraseWithDependencies(
      passphrase: 'topsecret',
      databaseAlreadyExists: () async => false,
      deleteDatabaseFiles: () async {
        deletedFiles += 1;
      },
      openDatabase: (_) async => _FakeCreationHandle(
        onWarmUp: () => Future<void>.error(StateError('boom')),
        onClose: () async {
          closeCalls += 1;
        },
      ),
      validatePassphrase: (_) async => true,
      reportFailure: (error) => reportedFailure = error,
    );

    expect(result, isFalse);
    expect(deletedFiles, 2);
    expect(closeCalls, 1);
    expect(reportedFailure, isA<StateError>());
  });

  test('deletes the new database when open fails', () async {
    var deletedFiles = 0;

    final result = await createDatabasePassphraseWithDependencies(
      passphrase: 'topsecret',
      databaseAlreadyExists: () async => false,
      deleteDatabaseFiles: () async {
        deletedFiles += 1;
      },
      openDatabase: (_) => Future<DatabasePassphraseCreationHandle>.error(
        StateError('open failed'),
      ),
      validatePassphrase: (_) async => true,
    );

    expect(result, isFalse);
    expect(deletedFiles, 2);
  });
}
