import 'package:ui/domain/server.dart';
import 'package:ui/services/backup_logic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('backup base postgres settings carry intent only, never host_port', () {
    final settings = buildBackupBasePostgresSettings(
      projectName: 'Blog API',
      server: const Server(
        id: 'server-1',
        name: 'Server',
        host: '192.0.2.10',
        port: 22,
        sshUser: 'ubuntu',
        authMethod: ServerAuthMethod.sshKey,
        postgresConfig: ServerPostgresConfig(
          postgresVersion: '17',
          superuserPassword: 'pg-secret',
          enabledExtensions: <String>['vector'],
        ),
      ),
    );

    expect(settings['postgres_version'], '17');
    expect(settings['superuser_password'], 'pg-secret');
    expect(settings['enabled_extensions'], <String>['vector']);
    expect(settings['project_slug'], 'blog-api');
    // host_port is backend-resolved (only 5432 is legal); the wire must not
    // carry it at all or params_schema rejects the whole operation.
    expect(settings.containsKey('host_port'), isFalse);
  });
}
