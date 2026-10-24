import 'dart:io';

import 'package:ui/data/local/app_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;

import '../../_support/sqlite_test_harness.dart';

// NEVER DELETE THIS TEST FILE, and never modify the assertions below
// against an *existing* fixture file. T-1.3.3: the frozen corpus under
// orchestrator/tests/fixtures/artifact-compat/v1/ is the only evidence this
// build can ever open format-version-1 artifacts, because those artifacts
// cannot be reconstructed later -- the build that could produce a "fresh"
// v1 sample will not exist forever. When format 2 ships, add a new
// orchestrator/tests/fixtures/artifact-compat/v2/ directory and new test
// methods; do not touch the v1 fixtures or their assertions.
//
// The corpus lives beside the suites that consume it so every checkout of
// this repository can run these tests with no other checkout present.
//
// This fixture's passphrase is a fixed, checked-in test value, not a
// secret: 'artifact-compat-v1-fixture-passphrase'.

const String _fixturePassphrase = 'artifact-compat-v1-fixture-passphrase';

void main() {
  final encryptedSqliteAvailable = ensureEncryptedSqliteRuntimeAvailable();

  test(
    'SQLite backup snapshot v1 opens and reports the expected metadata',
    () async {
      final fixturePath = p.join(
        Directory.current.path,
        '..',
        'orchestrator',
        'tests',
        'fixtures',
        'artifact-compat',
        'v1',
        'sqlite-backup-snapshot.db',
      );
      final fixtureFile = File(fixturePath);
      expect(
        fixtureFile.existsSync(),
        isTrue,
        reason: 'Missing frozen fixture: $fixturePath',
      );

      final database = sqlite.sqlite3.open(fixtureFile.path);
      addTearDown(database.close);
      configureAppDatabaseEncryption(database, passphrase: _fixturePassphrase);

      final rows = database.select(
        'SELECT backup_format_version, source_schema_version, '
        'app_build_name, app_build_number FROM deploydash_backup_metadata '
        'WHERE id = 1;',
      );

      expect(rows, hasLength(1));
      expect(rows.first['backup_format_version'], 1);
      expect(rows.first['source_schema_version'], 1);
      expect(rows.first['app_build_name'], 'artifact-compat-fixture');
      expect(rows.first['app_build_number'], '1');

      // The corpus exists to prove *this build* can still read format 1,
      // not just that the frozen file happens to look right.
      expect(rows.first['backup_format_version'], sqliteBackupFormatVersion);
      await enforceSqliteBackupFormatVersion(
        sourcePath: fixtureFile.path,
        passphrase: _fixturePassphrase,
      );
    },
    skip: !encryptedSqliteAvailable,
  );
}
