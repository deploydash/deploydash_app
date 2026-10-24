import 'dart:math';

/// Generates the PostgreSQL superuser credential kept in encrypted storage.
///
/// The value is intentionally returned only to the caller that persists the
/// server configuration. Callers must not render or log it.
// coverage-gate: generate_postgres_service_password
String generatePostgresServicePassword({Random? random}) {
  const alphabet =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
      'abcdefghijklmnopqrstuvwxyz'
      '0123456789'
      '-_';
  final source = random ?? Random.secure();
  final buffer = StringBuffer();
  for (var index = 0; index < 48; index += 1) {
    buffer.write(alphabet[source.nextInt(alphabet.length)]);
  }
  return buffer.toString();
}
// end coverage-gate
