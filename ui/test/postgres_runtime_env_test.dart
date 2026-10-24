import 'package:ui/postgres_runtime_env.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'managed postgres key matcher includes DATABASE_URL and excludes others',
    () {
      expect(isManagedPostgresRuntimeEnvKey('DATABASE_HOST'), isTrue);
      expect(isManagedPostgresRuntimeEnvKey('DATABASE_URL'), isTrue);
      expect(isManagedPostgresRuntimeEnvKey('APP_ENV'), isFalse);
    },
  );

  test('database URL builder encodes the password and uses managed host', () {
    expect(
      buildManagedPostgresDatabaseUrl(
        username: 'app_user',
        password: 'secret with/slash',
        port: 5432,
        databaseName: 'app_db',
      ),
      'postgresql://app_user:secret%20with%2Fslash@deploydash_postgres:5432/app_db',
    );
  });

  test('runtime env builder returns all managed postgres keys', () {
    final env = buildManagedPostgresRuntimeEnv(
      databaseName: 'app_db',
      username: 'app_user',
      password: 'secret',
      port: 5432,
    );

    expect(env, <String, String>{
      'DATABASE_HOST': 'deploydash_postgres',
      'DATABASE_PORT': '5432',
      'DATABASE_NAME': 'app_db',
      'DATABASE_USER': 'app_user',
      'DATABASE_PASSWORD': 'secret',
      'DATABASE_URL':
          'postgresql://app_user:secret@deploydash_postgres:5432/app_db',
    });
  });

  test(
    'runtime env record builder marks every managed postgres key secret',
    () {
      final records = buildManagedPostgresRuntimeEnvRecords(
        projectId: 'project-1',
        databaseName: 'app_db',
        username: 'app_user',
        password: 'secret',
        port: 5432,
      );

      expect(records.map((row) => row.key), contains('DATABASE_URL'));
      expect(records.every((row) => row.projectId == 'project-1'), isTrue);
      expect(records.every((row) => row.secret), isTrue);
    },
  );

  test('runtime env row builder preserves user-managed database keys', () {
    final env = buildRuntimeEnvFromRows(
      rows: const [
        MapEntry('APP_ENV', 'production'),
        MapEntry('DATABASE_URL', 'postgresql://manual'),
      ],
      injectPostgresEnv: false,
    );

    expect(env, <String, String>{
      'APP_ENV': 'production',
      'DATABASE_URL': 'postgresql://manual',
    });
  });

  test('runtime env row builder filters excluded keys and trims blanks', () {
    final env = buildRuntimeEnvFromRows(
      rows: const [
        MapEntry(' APP_ENV ', 'production'),
        MapEntry('', 'ignored'),
        MapEntry(' DATABASE_PASSWORD ', ' secret '),
      ],
      injectPostgresEnv: true,
      excludedKeys: {'DATABASE_PASSWORD'},
    );

    expect(env, <String, String>{'APP_ENV': 'production'});
  });
}
