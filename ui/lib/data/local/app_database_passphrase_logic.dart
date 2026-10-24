/// A database connection opened while creating it for the first time.
///
/// An interface rather than the concrete database so the creation sequence
/// below can be tested at every failure point without SQLCipher.
abstract interface class DatabasePassphraseCreationHandle {
  /// Forces the connection to actually open and write, so encryption failures
  /// surface now rather than at the first real query.
  Future<void> warmUp();

  /// Closes the connection, releasing the file.
  Future<void> close();
}

/// Opens a new encrypted database with the given passphrase.
typedef DatabasePassphraseHandleFactory =
    Future<DatabasePassphraseCreationHandle> Function(String passphrase);

/// Reopens the database with a passphrase and reports whether it worked.
typedef DatabasePassphraseValidator = Future<bool> Function(String passphrase);

/// Reports whether a database already exists.
typedef DatabasePassphraseStateLoader = Future<bool> Function();

/// Removes the database file and its SQLite sidecars.
typedef DatabasePassphraseCleanup = Future<void> Function();

/// Reports why creation failed, for diagnostics.
typedef DatabasePassphraseFailureReporter = void Function(Object error);

/// Creates the encrypted local database, or leaves nothing behind.
///
/// The sequence is deliberate, and every step guards one way of ending up with
/// a database the user cannot open:
///
/// 1. A blank passphrase is refused, and an existing database is never
///    overwritten -- creation is for first run only.
/// 2. Stale files are cleared first, so a half-created database from a
///    previous attempt cannot be adopted.
/// 3. The new database is opened, warmed up, and then **reopened and
///    validated** with the same passphrase. Creating a file is not evidence it
///    can be read back; only reopening it is.
/// 4. If anything fails, the files are deleted in a `finally`. Leaving a
///    database the passphrase does not open would lock the user out of an app
///    they had not yet used.
///
/// Returns whether the database now exists and is openable.
Future<bool> createDatabasePassphraseWithDependencies({
  required String passphrase,
  required DatabasePassphraseStateLoader databaseAlreadyExists,
  required DatabasePassphraseCleanup deleteDatabaseFiles,
  required DatabasePassphraseHandleFactory openDatabase,
  required DatabasePassphraseValidator validatePassphrase,
  DatabasePassphraseFailureReporter? reportFailure,
}) async {
  final normalizedPassphrase = passphrase.trim();
  if (normalizedPassphrase.isEmpty) {
    return false;
  }
  if (await databaseAlreadyExists()) {
    return false;
  }

  await deleteDatabaseFiles();

  DatabasePassphraseCreationHandle? handle;
  var createdSuccessfully = false;
  try {
    handle = await openDatabase(normalizedPassphrase);
    await handle.warmUp();
    createdSuccessfully = await validatePassphrase(normalizedPassphrase);
    if (!createdSuccessfully) {
      reportFailure?.call(
        StateError(
          'The encrypted database could not be reopened after it was created.',
        ),
      );
    }
    return createdSuccessfully;
  } catch (error) {
    reportFailure?.call(error);
    return false;
  } finally {
    await handle?.close();
    if (!createdSuccessfully) {
      await deleteDatabaseFiles();
    }
  }
}
