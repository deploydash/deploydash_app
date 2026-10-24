import 'package:ui/data/local/server_repository.dart';
import 'package:ui/domain/project.dart';
import 'package:ui/services/project_database_settings.dart';
import 'package:ui/utils/project_slug.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('managed postgres project helper normalizes slugs and settings', () {
    expect(slugifyProjectName('  Blog API  '), 'blog-api');
    expect(slugifyProjectName('***'), 'project-app');

    expect(managedPostgresProjectPrefix('Blog API'), 'dd_blog_api_');
    expect(managedPostgresProjectPrefix('123 app'), 'dd_n_123_app_');
    expect(
      managedPostgresProjectPrefix(
        'This project name is intentionally far longer than PostgreSQL allows',
      ).length,
      lessThanOrEqualTo(63),
    );

    final settings = buildManagedPostgresProjectSettings(
      projectName: 'Blog API',
      config: const ServerPostgresConfig(
        postgresVersion: '17',
        superuserPassword: 'pg-secret',
        enabledExtensions: <String>['vector'],
      ),
      overrides: const <String, dynamic>{'database_name': 'app'},
    );

    expect(settings['project_slug'], 'blog-api');
    // superuser_name is server-owned (T-1.4.4); the built settings map must
    // not carry it at all.
    expect(settings.containsKey('superuser_name'), isFalse);
    // host_port is backend-resolved (only 5432 is legal); the wire must not
    // carry it at all or params_schema rejects the whole operation.
    expect(settings.containsKey('host_port'), isFalse);
    expect(settings['superuser_password'], 'pg-secret');
    expect(settings['enabled_extensions'], <String>['vector']);
    expect(settings['database_name'], 'app');
  });

  test('logical managed postgres name strips only the own project prefix', () {
    expect(
      logicalManagedPostgresName(
        projectName: 'Blog API',
        remoteName: 'dd_blog_api_app',
      ),
      'app',
    );
    expect(
      logicalManagedPostgresName(projectName: 'Blog API', remoteName: 'app'),
      'app',
    );
    expect(
      logicalManagedPostgresName(
        projectName: 'Blog API',
        remoteName: 'dd_other_app',
      ),
      'dd_other_app',
    );
    // Mechanical strip: the engine's ownership check decides whether the
    // nested remainder belongs to this project.
    expect(
      logicalManagedPostgresName(
        projectName: 'Shop',
        remoteName: 'dd_shop_api_main',
      ),
      'api_main',
    );
    expect(
      logicalManagedPostgresName(
        projectName: 'Regs v3',
        remoteName: 'dd_regs_v3_main_user',
      ),
      'main_user',
    );
  });

  test('known project slugs scope, slugify, dedupe, and sort', () {
    const serverId = 'server-database-enabled';
    const otherServerId = 'server-elsewhere';
    // Builds only the identity fields the slug helper reads.
    Project project(String id, String? projectServerId, String name) {
      return Project(
        id: id,
        serverId: projectServerId,
        name: name,
        type: 'Web app',
        gitUrl: 'https://github.com/example/app',
        primaryDomain: 'app.example.com',
      );
    }

    expect(
      knownProjectSlugsOnServer(
        projects: <Project>[
          project('b', serverId, 'Shop API'),
          project('a', serverId, 'Regs v3'),
          project('c', otherServerId, 'Elsewhere'),
          project('d', null, 'No Server'),
          project('e', serverId, 'Regs v3'),
        ],
        serverId: serverId,
      ),
      <String>['regs-v3', 'shop-api'],
    );
    expect(
      knownProjectSlugsOnServer(
        projects: const <Project>[],
        serverId: serverId,
      ),
      isEmpty,
    );
  });

  test('managed settings map keeps exact keys, order, and overrides-last', () {
    // D-28 pair 1 (T-010): the deletion coordinator routes through this
    // owner, so its byte shape is pinned here — version, password,
    // extensions, slug, then the overrides spread last.
    final settings = buildManagedPostgresProjectSettings(
      projectName: 'Example App',
      config: const ServerPostgresConfig(
        postgresVersion: '17',
        superuserPassword: 'pg-secret',
        enabledExtensions: <String>['vector'],
      ),
      overrides: const <String, dynamic>{'database_name': 'app'},
    );

    expect(settings.keys.toList(), <String>[
      'postgres_version',
      'superuser_password',
      'enabled_extensions',
      'project_slug',
      'database_name',
    ]);
    expect(settings, <String, dynamic>{
      'postgres_version': '17',
      'superuser_password': 'pg-secret',
      'enabled_extensions': <String>['vector'],
      'project_slug': 'example-app',
      'database_name': 'app',
    });
  });

  test('service settings map carries exactly the 3 unslugged keys', () {
    // D-28 pair 1 (T-010): service payloads address the server's own
    // postgres, never a project's managed databases — a slug key here
    // would be a contract violation, and the twins this replaces carried
    // exactly these three keys in this order.
    final settings = buildPostgresServiceSettings(
      const ServerPostgresConfig(
        postgresVersion: '18',
        superuserPassword: 'svc-secret',
        enabledExtensions: <String>['pg_search'],
      ),
    );

    expect(settings.keys.toList(), <String>[
      'postgres_version',
      'superuser_password',
      'enabled_extensions',
    ]);
    expect(settings, <String, dynamic>{
      'postgres_version': '18',
      'superuser_password': 'svc-secret',
      'enabled_extensions': <String>['pg_search'],
    });
    expect(settings.containsKey('project_slug'), isFalse);
  });
}
