import 'package:ui/data/local/server_repository.dart';
import 'package:ui/ui/project/project_workspace.dart';
import 'package:ui/utils/project_slug.dart';
import 'package:flutter_test/flutter_test.dart';

Server _server({required ServerAuthMethod authMethod}) {
  return Server(
    id: 'server-1',
    name: 'Primary server',
    host: 'example.com',
    port: 22,
    sshUser: 'ubuntu',
    authMethod: authMethod,
  );
}

void main() {
  group('app deployment payload helpers', () {
    test('app deployment slugs normalize names and fall back', () {
      // D-26 (T-011): appDeploymentSlugifyProjectName folded into the owner;
      // same values asserted through slugifyProjectName with the explicit
      // site fallback.
      expect(
        slugifyProjectName(' Deploy Dash Website ', fallback: 'project-app'),
        'deploy-dash-website',
      );
      expect(slugifyProjectName('!!!', fallback: 'project-app'), 'project-app');
    });

    test(
      'buildAppDeploymentConnectionPayload delegates password auth',
      () async {
        final payload = await buildAppDeploymentConnectionPayload(
          (server) async => <String, dynamic>{
            'host': server.host,
            'port': server.port,
            'username': server.sshUser,
            'password': 'secret',
          },
          _server(authMethod: ServerAuthMethod.password),
        );

        expect(payload, {
          'host': 'example.com',
          'port': 22,
          'username': 'ubuntu',
          'password': 'secret',
        });
      },
    );

    test(
      'buildAppDeploymentConnectionPayload propagates missing credentials',
      () async {
        final payload = await buildAppDeploymentConnectionPayload(
          (_) async => null,
          _server(authMethod: ServerAuthMethod.sshKey),
        );
        expect(payload, isNull);
      },
    );

    test(
      'buildAppDeploymentConnectionPayload forwards resolved private keys',
      () async {
        final payload = await buildAppDeploymentConnectionPayload(
          (_) async => <String, dynamic>{
            'host': 'example.com',
            'port': 22,
            'username': 'ubuntu',
            'private_key': '-----BEGIN OPENSSH PRIVATE KEY-----\ninline-key',
          },
          _server(authMethod: ServerAuthMethod.sshKey),
        );

        expect(payload, isNotNull);
        expect(payload!['host'], 'example.com');
        expect(payload['port'], 22);
        expect(payload['username'], 'ubuntu');
        expect(
          payload['private_key'],
          '-----BEGIN OPENSSH PRIVATE KEY-----\ninline-key',
        );
        expect(payload.containsKey('key_path'), isFalse);
      },
    );
  });
}
