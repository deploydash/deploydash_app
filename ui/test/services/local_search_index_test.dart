import 'package:ui/data/local/server_repository.dart';
import 'package:ui/providers/project_provider.dart';
import 'package:ui/services/local_search_index.dart';
import 'package:flutter_test/flutter_test.dart';

const _prod = Server(
  id: 'server-1',
  name: 'prod-01',
  host: '203.0.113.10',
  port: 22,
  sshUser: 'ubuntu',
  authMethod: ServerAuthMethod.password,
  osName: 'Ubuntu 24.04',
);

const _staging = Server(
  id: 'server-2',
  name: 'staging-eu',
  host: '198.51.100.4',
  port: 22,
  sshUser: 'ubuntu',
  authMethod: ServerAuthMethod.password,
);

const _billing = Project(
  id: 'project-1',
  serverId: 'server-1',
  name: 'Billing',
  type: 'app',
  gitUrl: 'git@github.com:acme/billing.git',
  primaryDomain: 'billing.example.com',
  repositoryFullName: 'acme/billing-service',
);

const _marketing = Project(
  id: 'project-2',
  serverId: 'server-2',
  name: 'Marketing',
  type: 'app',
  gitUrl: 'git@github.com:acme/marketing.git',
  primaryDomain: 'Not configured',
);

const _orphan = Project(
  id: 'project-3',
  name: 'Sandbox',
  type: 'app',
  gitUrl: 'git@github.com:acme/sandbox.git',
  primaryDomain: '',
);

List<LocalSearchResult> _search(String query, {int limitPerKind = 8}) {
  return searchLocalIndex(
    query: query,
    servers: const <Server>[_prod, _staging],
    projects: const <Project>[_billing, _marketing, _orphan],
    limitPerKind: limitPerKind,
  );
}

void main() {
  test('returns nothing for a blank query or a zero limit', () {
    expect(_search('   '), isEmpty);
    expect(_search('billing', limitPerKind: 0), isEmpty);
  });

  test('matches servers on name and host', () {
    final byName = _search('prod');
    expect(byName.first.kind, LocalSearchResultKind.server);
    expect(byName.first.title, 'prod-01');
    expect(byName.first.subtitle, '203.0.113.10 - Ubuntu 24.04');
    expect(byName.first.serverId, 'server-1');

    final byHost = _search('198.51');
    expect(byHost.single.title, 'staging-eu');
    expect(byHost.single.subtitle, '198.51.100.4');
  });

  test('matches projects on name, domain, and repository', () {
    final byName = _search('billing');
    final project = byName.firstWhere(
      (result) => result.kind == LocalSearchResultKind.project,
    );
    expect(project.title, 'Billing');
    expect(project.subtitle, 'app - billing.example.com');
    expect(project.context, 'prod-01');
    expect(project.projectId, 'project-1');
    expect(project.destinationId, 'web-app');

    expect(_search('billing-service').single.projectId, 'project-1');
    expect(_search('example.com').single.projectId, 'project-1');
  });

  test('falls back to the project type when no domain is configured', () {
    expect(_search('marketing').single.subtitle, 'app');
    expect(_search('sandbox').single.subtitle, 'app');
    expect(_search('sandbox').single.context, isNull);
  });

  test('produces screen results only when a screen label matches', () {
    final screens = _search(
      'database',
    ).where((result) => result.kind == LocalSearchResultKind.screen).toList();
    expect(screens, hasLength(3));
    expect(screens.first.title, 'Database');
    expect(screens.first.subtitle, 'Billing');
    expect(screens.first.destinationId, 'database');

    expect(
      _search(
        'billing',
      ).every((result) => result.kind != LocalSearchResultKind.screen),
      isTrue,
    );
  });

  test('ranks prefix matches above interior matches', () {
    const alpha = Project(
      id: 'project-alpha',
      name: 'Payments',
      type: 'app',
      gitUrl: 'git@github.com:acme/payments.git',
      primaryDomain: 'payments.example.com',
    );
    const beta = Project(
      id: 'project-beta',
      name: 'Repayments',
      type: 'app',
      gitUrl: 'git@github.com:acme/repayments.git',
      primaryDomain: 'repayments.example.com',
    );

    final results = searchLocalIndex(
      query: 'pay',
      servers: const <Server>[],
      projects: const <Project>[beta, alpha],
    );

    expect(results.map((result) => result.projectId), <String>[
      'project-alpha',
      'project-beta',
    ]);
  });

  test('caps each section at the per-kind limit', () {
    final results = searchLocalIndex(
      query: 'e',
      servers: const <Server>[_prod, _staging],
      projects: const <Project>[_billing, _marketing, _orphan],
      limitPerKind: 1,
    );

    for (final kind in LocalSearchResultKind.values) {
      expect(results.where((result) => result.kind == kind), hasLength(1));
    }
  });
}
