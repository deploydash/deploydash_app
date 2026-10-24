import 'data/local/app_environment_variable_repository.dart';

/// Hostname of the managed PostgreSQL service on the Docker network, which is
/// also its container name.
///
/// The owner of this value is
/// `orchestrator/src/orchestrator/server_identifiers.py::postgres_container()`.
/// A language boundary means the value is stated twice; stating it three times
/// in one file, as this module did until T-3.4.2, meant nothing named it at
/// all. If the backend renames the container, this constant changes with it.
const String managedPostgresHost = 'deploydash_postgres';

const Set<String> _managedPostgresRuntimeEnvKeys = <String>{
  'DATABASE_HOST',
  'DATABASE_PORT',
  'DATABASE_NAME',
  'DATABASE_USER',
  'DATABASE_PASSWORD',
  'DATABASE_URL',
};

bool isManagedPostgresRuntimeEnvKey(String key) {
  return _managedPostgresRuntimeEnvKeys.contains(key);
}

Map<String, String> buildRuntimeEnvFromRows({
  required Iterable<MapEntry<String, String>> rows,
  bool injectPostgresEnv = false,
  Set<String> excludedKeys = const <String>{},
}) {
  final runtimeEnv = <String, String>{};
  for (final row in rows) {
    final key = row.key.trim();
    if (key.isEmpty) {
      continue;
    }
    if (excludedKeys.contains(key)) {
      continue;
    }
    runtimeEnv[key] = row.value;
  }
  return runtimeEnv;
}

String buildManagedPostgresDatabaseUrl({
  required String username,
  required String password,
  required int port,
  required String databaseName,
  String host = managedPostgresHost,
}) {
  return 'postgresql://$username:${Uri.encodeComponent(password)}'
      '@$host:$port/$databaseName';
}

Map<String, String> buildManagedPostgresRuntimeEnv({
  required String databaseName,
  required String username,
  required String password,
  required int port,
  String host = managedPostgresHost,
}) {
  final databaseUrl = buildManagedPostgresDatabaseUrl(
    username: username,
    password: password,
    port: port,
    databaseName: databaseName,
    host: host,
  );
  return <String, String>{
    'DATABASE_HOST': host,
    'DATABASE_PORT': '$port',
    'DATABASE_NAME': databaseName,
    'DATABASE_USER': username,
    'DATABASE_PASSWORD': password,
    'DATABASE_URL': databaseUrl,
  };
}

List<AppEnvironmentVariableRecord> buildManagedPostgresRuntimeEnvRecords({
  required String projectId,
  required String databaseName,
  required String username,
  required String password,
  required int port,
  String host = managedPostgresHost,
}) {
  return buildManagedPostgresRuntimeEnv(
        databaseName: databaseName,
        username: username,
        password: password,
        port: port,
        host: host,
      ).entries
      .map((entry) {
        return AppEnvironmentVariableRecord(
          projectId: projectId,
          key: entry.key,
          value: entry.value,
          secret: true,
        );
      })
      .toList(growable: false);
}
