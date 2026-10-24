part of '../server_management_view.dart';

typedef ServerTerminalLineWriter =
    void Function(String line, {bool detail, String source, String? taskType});

class _PostgresExtensionOption {
  const _PostgresExtensionOption({
    required this.key,
    required this.title,
    required this.supported,
    this.supportHint,
  });

  final String key;
  final String title;
  final bool supported;
  final String? supportHint;
}

const List<_PostgresExtensionOption>
_postgresExtensionOptions = <_PostgresExtensionOption>[
  _PostgresExtensionOption(
    key: 'pg_stat_statements',
    title: 'pg_stat_statements',
    supported: true,
  ),
  _PostgresExtensionOption(key: 'plpgsql', title: 'plpgsql', supported: true),
  _PostgresExtensionOption(key: 'pgcrypto', title: 'pgcrypto', supported: true),
  _PostgresExtensionOption(key: 'pg_trgm', title: 'pg_trgm', supported: true),
  _PostgresExtensionOption(key: 'vector', title: 'pgvector', supported: true),
  _PostgresExtensionOption(
    key: 'pg_search',
    title: 'pg_search',
    supported: true,
  ),
  _PostgresExtensionOption(
    key: 'uuid-ossp',
    title: 'uuid-ossp',
    supported: true,
  ),
  _PostgresExtensionOption(
    key: 'pg_session_jwt',
    title: 'pg_session_jwt',
    supported: false,
    supportHint: 'Not packaged in our current Postgres image.',
  ),
  _PostgresExtensionOption(key: 'hstore', title: 'hstore', supported: true),
  _PostgresExtensionOption(key: 'postgis', title: 'postgis', supported: true),
  _PostgresExtensionOption(
    key: 'btree_gin',
    title: 'btree_gin',
    supported: true,
  ),
];
