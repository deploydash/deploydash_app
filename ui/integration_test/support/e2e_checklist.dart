import 'dart:convert';
import 'dart:io';

enum E2eAutomationStatus { automated, planned, external }

class E2eChecklistSurface {
  const E2eChecklistSurface({
    required this.section,
    required this.surface,
    required this.done,
    required this.manualStatus,
    required this.notes,
  });

  final String section;
  final String surface;
  final bool done;
  final String manualStatus;
  final String notes;

  String get key => '$section::$surface';

  String get id => '${_slug(section)}__${_slug(surface)}';

  E2eAutomationStatus get automationStatus {
    if (automatedChecklistKeys.contains(key)) {
      return E2eAutomationStatus.automated;
    }
    if (_externalOnlyChecklistKeys.contains(key) ||
        _externalOnlySections.contains(section) ||
        _externalOnlySurfaceFragments.any(surface.contains)) {
      return E2eAutomationStatus.external;
    }
    return E2eAutomationStatus.planned;
  }

  String get automationStatusLabel {
    return switch (automationStatus) {
      E2eAutomationStatus.automated => 'Automated',
      E2eAutomationStatus.planned => 'Planned',
      E2eAutomationStatus.external => 'External runner',
    };
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'key': key,
      'section': section,
      'surface': surface,
      'done': done,
      'manual_status': manualStatus,
      'notes': notes,
      'automation_status': automationStatusLabel,
    };
  }
}

class E2eRunResult {
  const E2eRunResult({
    required this.surfaceKey,
    required this.status,
    required this.message,
    this.scenarioId,
    this.evidence = const <String, Object?>{},
  });

  final String surfaceKey;
  final String status;
  final String message;
  final String? scenarioId;
  final Map<String, Object?> evidence;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'surface_key': surfaceKey,
      'status': status,
      'message': _redactReportValue(message),
      if (scenarioId != null) 'scenario_id': scenarioId,
      'evidence': _redactReportValue(evidence),
    };
  }
}

class E2eRunMetadata {
  const E2eRunMetadata({
    this.runId = '',
    this.scenario = 'all',
    this.gitCommitSha = '',
    this.appVersion = '',
  });

  final String runId;
  final String scenario;
  final String gitCommitSha;
  final String appVersion;

  Map<String, Object?> toJson() => <String, Object?>{
    'run_id': runId,
    'scenario': scenario,
    'git_commit_sha': gitCommitSha,
    'app_version': appVersion,
  };
}

String redactE2eDiagnosticText(String value) {
  return _redactReportValue(value)?.toString() ?? '';
}

const Set<String> _baselineAutomatedChecklistKeys = <String>{
  'Core App Shell::First launch with isolated profile',
  'Core App Shell::Local database creation and unlock',
  'Core App Shell::App restart and unlock existing isolated DB',
  'Core App Shell::Home dashboard after setup',
  'Core App Shell::Bottom terminal collapsed/expanded states',
  'Core App Shell::Advanced activity current vs old tasks',
  'Core App Shell::Project selection from Home',
  'Core App Shell::Project switching from rail recents with multiple projects',
  'Core App Shell::Delete last project and empty Home state',
  'Server Onboarding::Password-based SSH connection check',
  'Server Onboarding::Compatibility review screen',
  'Server Onboarding::Long-running setup progress',
  'Server Onboarding::Successful baseline setup',
  'Server Onboarding::Service selection during onboarding',
  'Server Onboarding::Onboarding with optional services disabled',
  'Server Onboarding::Onboarding on Ubuntu 24.04',
  'Server Management::Overview tab load',
  'Server Management::Services tab load',
  'Server Management::Services container status copy',
  'Server Management::Updates tab load',
  'Server Management::Updates version vs health separation',
  'Server Management::Firewall status',
  'Server Management::Firewall scan open ports',
  'Server Management::System settings load/apply',
  'Server Management::Automatic updates settings',
  'Server Management::Docker image/cache usage scan',
  'Server Management::Docker image/cache prune',
  'Server Management::Server hostname/IP edit in Settings',
  'GitHub And Repository Flow::GitHub OAuth connect with human login',
  'GitHub And Repository Flow::Repository list and selection',
  'GitHub And Repository Flow::Branch selector/change',
  'GitHub And Repository Flow::Inline deploy-key GitHub SSH trust prompt',
  'Project Web App::New project Web app empty state',
  'Project Web App::Deployment settings modal',
  'Project Web App::Runtime auto-detect/recommendation',
  'Project Web App::PHP/Laravel deploy',
  'Project Web App::Deploy progress copy',
  'Project Web App::Readiness failure surfacing',
  'Project Web App::Successful deploy state',
  'Project Web App::Redeploy after success',
  'Project Web App::Deploy failure then retry',
  'Project Web App::Release history refresh',
  'Project Web App::Rollback to previous release',
  'Project Web App::One-off command success',
  'Project Web App::One-off command failure',
  'Project Web App::One-off command cancel',
  'Project Web App::Resource usage refresh',
  'Project Web App::Environment variable editor',
  'Project Web App::Save environment and redeploy',
  'Project Web App::Domain routing: single host',
  'Project Web App::Domain routing: redirect www to apex',
  'Project Web App::Domain routing: redirect apex to www',
  'Project Web App::Deployment preflight/check settings',
  'Project Web App::Disconnect/remove web app runtime',
  'Project Workers::Workers tab before live release',
  'Project Workers::Workers tab after live release',
  'Project Workers::Add worker modal',
  'Project Workers::Create worker',
  'Project Workers::Edit worker',
  'Project Workers::Delete worker',
  'Project Workers::Apply worker runtime',
  'Project Workers::Worker status refresh',
  'Project Workers::Worker start/stop/restart',
  'Project Workers::Worker logs',
  'Project Workers::Worker database-password field relevance',
  'Project Database::Database tab with PostgreSQL disabled',
  'Project Database::Open server services action',
  'Project Database::SQLite create database storage',
  'Project Database::SQLite set primary',
  'Project Database::SQLite refresh storage usage',
  'Project Database::SQLite delete database storage',
  'Project Backup::Backup tab with PostgreSQL unavailable',
  'Project Scheduler::Scheduler before live release',
  'Project Scheduler::Add scheduled job after live release',
  'Project Scheduler::Command persistence with arguments',
  'Project Scheduler::Run now for web-app job',
  'Project Scheduler::Edit scheduled job',
  'Project Scheduler::Delete scheduled job',
  'Project Scheduler::Enable/disable scheduled job',
  'Project Scheduler::Scheduler status refresh',
  'Project Scheduler::Scheduler after redeploy',
  'Project Scheduler::Scheduler worker target',
  'Project Scheduler::Legacy scheduler wrappers after app fixes',
  'Project Scheduler::Scheduler failure details after latest fixes',
  'Project Logs::Runtime logs empty-app-output state',
  'Project Logs::Runtime live stream toggle',
  'Project Logs::Deployment log filtering',
  'Project Logs::Deployment log after failed deploy',
  'Project Logs::Runtime logs after successful deploy',
  'Project Logs::Failed candidate runtime logs',
  'Project Email, Domain, And Settings::Email tab',
  'Project Email, Domain, And Settings::Domain tab',
  'Project Email, Domain, And Settings::Project Settings tab viewed',
  'Project Email, Domain, And Settings::Project delete workflow',
  'Project Email, Domain, And Settings::Runtime disconnect from Settings/Web app',
  'App Settings And Local Database Safety::Rotate local DB password',
  'App Settings And Local Database Safety::Agent Access enable/disable',
  'App Settings And Local Database Safety::Agent Access redeploy session',
  'App Settings And Local Database Safety::Agent audit visibility',
  'App Settings And Local Database Safety::App version/update badge',
  'Packaging And Platform Smoke Tests::Linux debug run from repo',
  'Remote Server Stack Verification::Ubuntu package reachability preflight',
  'Remote Server Stack Verification::Docker install via setup',
  'Remote Server Stack Verification::Railpack install via setup',
  'Remote Server Stack Verification::Caddy runtime through app deploy',
  'Remote Server Stack Verification::Fail2ban status and behavior',
  'Remote Server Stack Verification::Auditd/sysstat/unattended-upgrades status',
};

class E2eScenarioDefinition {
  const E2eScenarioDefinition({
    required this.id,
    required this.label,
    required this.description,
    required this.requiredChecklistKeys,
    this.requiresLiveVm = true,
    this.requiresB2 = false,
  });

  final String id;
  final String label;
  final String description;
  final Set<String> requiredChecklistKeys;
  final bool requiresLiveVm;
  final bool requiresB2;
}

const List<E2eScenarioDefinition>
productionSafetyScenarios = <E2eScenarioDefinition>[
  E2eScenarioDefinition(
    id: 'postgres_backup',
    label: 'PostgreSQL and backup recovery',
    description:
        'Creates and removes managed databases and users, exercises SQL imports, and proves real B2 backup and restore behavior.',
    requiresB2: true,
    requiredChecklistKeys: <String>{
      'Project Database::Project Database after PostgreSQL start',
      'Project Database::PostgreSQL create database',
      'Project Database::PostgreSQL delete database',
      'Project Database::PostgreSQL create user',
      'Project Database::PostgreSQL reset password',
      'Project Database::PostgreSQL delete user',
      'Project Database::PostgreSQL copy connection URI',
      'Project Database::PostgreSQL local .sql import',
      'Project Database::PostgreSQL failed import path',
      'Project Backup::Backup destination create',
      'Project Backup::Backup destination connectivity test',
      'Project Backup::Backup destination edit/delete',
      'Project Backup::PostgreSQL backup policy create/edit/delete',
      'Project Backup::Run backup now',
      'Project Backup::Backup artifact list refresh',
      'Project Backup::Restore backup artifact',
      'Project Backup::Backup failure surfacing',
    },
  ),
  E2eScenarioDefinition(
    id: 'app_rollback',
    label: 'Application release rollback',
    description:
        'Deploys two healthy releases, rolls back through the UI, and proves a failed rollback leaves the live release unchanged.',
    requiredChecklistKeys: <String>{
      'Project Web App::Rollback to previous release',
      'Project Web App::Rollback failure path',
    },
  ),
  E2eScenarioDefinition(
    id: 'managed_software_rollback',
    label: 'Managed software rollback',
    description:
        'Exercises update and one-version rollback adapters for every managed non-Ubuntu-apt component on disposable snapshots.',
    requiredChecklistKeys: <String>{
      'Server Management::Railpack update/reconcile',
      'Server Management::Caddy update/rollback',
      'Server Management::BIND update/rollback',
      'Server Management::WAL-G update/rollback',
      'Server Management::Docker package update/rollback guard',
      'Server Management::PostgreSQL managed update/rollback',
    },
  ),
  E2eScenarioDefinition(
    id: 'firewall_recovery',
    label: 'Firewall commit and rollback',
    description:
        'Applies staged IPv4 and IPv6 rules, verifies commit, explicit rollback, and automatic timeout recovery without losing SSH.',
    requiredChecklistKeys: <String>{
      'Server Management::PostgreSQL temporary remote access',
      'Server Management::Firewall staged apply/commit',
      'Server Management::Firewall rollback',
      'Server Management::Firewall custom TCP/UDP/IPv6 rules',
      'Server Management::Firewall ICMPv6 preamble and IPv6 traffic',
    },
  ),
  E2eScenarioDefinition(
    id: 'local_database_safety',
    label: 'Local encrypted database safety',
    description:
        'Exports, rotates, restarts, and restores only an isolated E2E database while proving old snapshots keep their original password.',
    requiresLiveVm: false,
    requiredChecklistKeys: <String>{
      'App Settings And Local Database Safety::Export encrypted local DB snapshot',
      'App Settings And Local Database Safety::Restore encrypted DB before unlock',
      'App Settings And Local Database Safety::Rotate local DB password',
      'App Settings And Local Database Safety::Existing exported DB still uses old password warning',
    },
  ),
  E2eScenarioDefinition(
    id: 'project_deletion_recovery',
    label: 'Project deletion and recovery',
    description:
        'Deletes a disposable project, interrupts remote cleanup, and proves the durable tombstone retries without losing local recovery state.',
    requiredChecklistKeys: <String>{
      'Core App Shell::Delete last project and empty Home state',
      'Project Email, Domain, And Settings::Project delete workflow',
      'Project Email, Domain, And Settings::Project delete failure/warning path',
    },
  ),
  E2eScenarioDefinition(
    id: 'host_key_recovery',
    label: 'SSH host-key recovery',
    description:
        'Exercises cancel and explicit replacement for both managed-server and repository SSH identity changes.',
    requiredChecklistKeys: <String>{
      'Server Onboarding::Server host-key mismatch confirmation',
      'GitHub And Repository Flow::Inline deploy-key GitHub SSH trust prompt',
      'GitHub And Repository Flow::GitHub SSH trust cancel path',
      'GitHub And Repository Flow::GitHub SSH changed-host-key path',
    },
  ),
];

final Map<String, E2eScenarioDefinition> productionSafetyScenarioById =
    <String, E2eScenarioDefinition>{
      for (final scenario in productionSafetyScenarios) scenario.id: scenario,
    };

final Set<String> productionSafetyChecklistKeys = <String>{
  for (final scenario in productionSafetyScenarios)
    ...scenario.requiredChecklistKeys,
};

final Set<String> automatedChecklistKeys = <String>{
  ..._baselineAutomatedChecklistKeys,
  ...productionSafetyChecklistKeys,
};

/// Pinned checklist surface set for the slim macOS QA leg
/// (`DEPLOYDASH_E2E_SLIM_MACOS`): encrypted DB create/unlock, server
/// onboarding, independent baseline asserts, GitHub integration, and first
/// web-app deploy success. Conditional entries (service selection, OAuth
/// connect, deploy-key trust prompt) are included because the subset check
/// below permits absence, not presence outside this set.
///
/// A slim run whose recorded surfaces fall outside this set fails loudly in
/// `_validateSlimMacOsResults` instead of silently running a wider flow, and
/// `slim_macos_guard_test.dart` pins the count. Extend deliberately: add the
/// key here AND update that test's count in the same commit.
const Set<String> slimMacOsChecklistKeys = <String>{
  'Core App Shell::First launch with isolated profile',
  'Core App Shell::Local database creation and unlock',
  'Core App Shell::Home dashboard after setup',
  'Server Onboarding::Password-based SSH connection check',
  'Server Onboarding::Compatibility review screen',
  'Remote Server Stack Verification::Ubuntu package reachability preflight',
  'Server Onboarding::Long-running setup progress',
  'Server Onboarding::Successful baseline setup',
  'Remote Server Stack Verification::Docker install via setup',
  'Remote Server Stack Verification::Railpack install via setup',
  'Server Onboarding::Service selection during onboarding',
  'Server Onboarding::Onboarding with optional services disabled',
  'Server Onboarding::Onboarding on Ubuntu 24.04',
  'Remote Server Stack Verification::Fail2ban status and behavior',
  'Remote Server Stack Verification::Auditd/sysstat/unattended-upgrades status',
  'Project Web App::New project Web app empty state',
  'Project Web App::Environment variable editor',
  'GitHub And Repository Flow::GitHub OAuth connect with human login',
  'GitHub And Repository Flow::Repository list and selection',
  'GitHub And Repository Flow::Inline deploy-key GitHub SSH trust prompt',
  'Project Web App::Domain routing: redirect www to apex',
  'Project Web App::Domain routing: redirect apex to www',
  'Project Web App::Domain routing: single host',
  'GitHub And Repository Flow::Branch selector/change',
  'Project Web App::Deployment settings modal',
  'Project Web App::Runtime auto-detect/recommendation',
  'Project Web App::Deployment preflight/check settings',
  'Project Web App::Deploy progress copy',
  'Project Web App::PHP/Laravel deploy',
  'Project Web App::Successful deploy state',
  'Remote Server Stack Verification::Caddy runtime through app deploy',
};

/// Surface keys in [surfaceKeys] that fall outside [slimMacOsChecklistKeys].
List<String> slimMacOsUnexpectedKeys(Iterable<String> surfaceKeys) {
  return <String>[
    for (final key in surfaceKeys)
      if (!slimMacOsChecklistKeys.contains(key)) key,
  ];
}

List<E2eScenarioDefinition> selectProductionSafetyScenarios(String requested) {
  final normalized = requested.trim().toLowerCase();
  if (normalized.isEmpty || normalized == 'all') {
    return productionSafetyScenarios;
  }
  final ids = normalized
      .split(',')
      .map((value) => value.trim())
      .where((value) => value.isNotEmpty)
      .toList(growable: false);
  final unknown = ids
      .where((id) => !productionSafetyScenarioById.containsKey(id))
      .toList(growable: false);
  if (unknown.isNotEmpty) {
    throw ArgumentError(
      'Unknown production-safety scenario(s): ${unknown.join(', ')}.',
    );
  }
  return ids
      .map((id) => productionSafetyScenarioById[id]!)
      .toList(growable: false);
}

void validateProductionSafetyScenarioRegistry(
  Iterable<E2eChecklistSurface> surfaces, {
  Iterable<E2eScenarioDefinition> scenarios = productionSafetyScenarios,
}) {
  final checklistKeys = surfaces.map((surface) => surface.key).toSet();
  final scenarioIds = <String>{};
  final ownersByKey = <String, String>{};
  for (final scenario in scenarios) {
    if (!scenarioIds.add(scenario.id)) {
      throw StateError(
        'Duplicate production-safety scenario id: ${scenario.id}.',
      );
    }
    if (scenario.requiredChecklistKeys.isEmpty) {
      throw StateError(
        'Production-safety scenario ${scenario.id} has no checklist rows.',
      );
    }
    for (final key in scenario.requiredChecklistKeys) {
      final previousOwner = ownersByKey[key];
      if (previousOwner != null) {
        throw StateError(
          'Checklist row $key belongs to both $previousOwner and ${scenario.id}.',
        );
      }
      ownersByKey[key] = scenario.id;
      if (!checklistKeys.contains(key)) {
        throw StateError(
          'Production-safety scenario ${scenario.id} references missing checklist row: $key.',
        );
      }
    }
  }
}

void validateProductionSafetyResults({
  required Iterable<E2eScenarioDefinition> scenarios,
  required Iterable<E2eRunResult> results,
}) {
  final resultGroups = <String, List<E2eRunResult>>{};
  for (final result in results) {
    resultGroups
        .putIfAbsent(result.surfaceKey, () => <E2eRunResult>[])
        .add(result);
  }
  final failures = <String>[];
  for (final scenario in scenarios) {
    for (final key in scenario.requiredChecklistKeys) {
      final matching = resultGroups[key] ?? const <E2eRunResult>[];
      if (matching.isEmpty) {
        failures.add('${scenario.id}: missing result for $key');
      } else if (matching.length > 1) {
        failures.add('${scenario.id}: duplicate results for $key');
      } else if (matching.single.status.toLowerCase() != 'passed') {
        failures.add('${scenario.id}: $key ended as ${matching.single.status}');
      }
    }
  }
  if (failures.isNotEmpty) {
    throw StateError(
      'Production-safety E2E gate failed:\n${failures.join('\n')}',
    );
  }
}

const Set<String> _externalOnlySections = <String>{
  'Website',
  'Packaging And Platform Smoke Tests',
};

const Set<String> _externalOnlyChecklistKeys = <String>{
  'Core App Shell::Server switching from Home with multiple servers',
  'Server Onboarding::SSH-key based connection check',
  'Server Onboarding::Server host-key mismatch confirmation',
  'Server Onboarding::Setup failure handling',
  'Server Onboarding::Onboarding on Ubuntu 22.04',
  'Server Management::HTTP gateway install/start/stop/restart',
  'Server Management::PostgreSQL install/start/recovery',
  'Server Management::PostgreSQL temporary remote access',
  'Server Management::Railpack update/reconcile',
  'Server Management::Caddy update/rollback',
  'Server Management::BIND update/rollback',
  'Server Management::WAL-G update/rollback',
  'Server Management::Docker package update/rollback guard',
  'Server Management::PostgreSQL managed update/rollback',
  'Server Management::Firewall staged apply/commit',
  'Server Management::Firewall rollback',
  'Server Management::Firewall custom TCP/UDP/IPv6 rules',
  'Server Management::Firewall ICMPv6 preamble and IPv6 traffic',
  'GitHub And Repository Flow::GitHub SSH trust cancel path',
  'GitHub And Repository Flow::GitHub SSH changed-host-key path',
  'Project Web App::Rollback failure path',
  'Project Workers::Worker database binding',
  'Project Database::Project Database after PostgreSQL start',
  'Project Database::PostgreSQL create database',
  'Project Database::PostgreSQL create database service-not-ready failure',
  'Project Database::PostgreSQL delete database',
  'Project Database::PostgreSQL create user',
  'Project Database::PostgreSQL reset password',
  'Project Database::PostgreSQL delete user',
  'Project Database::PostgreSQL copy connection URI',
  'Project Database::PostgreSQL local .sql import',
  'Project Database::PostgreSQL failed import path',
  'Project Database::Project database sharing/linking',
  'Project Database::Consumer project shared DB user flow',
  'Project Backup::Backup destination create',
  'Project Backup::Backup destination connectivity test',
  'Project Backup::Backup destination edit/delete',
  'Project Backup::PostgreSQL backup policy create/edit/delete',
  'Project Backup::Run backup now',
  'Project Backup::Backup artifact list refresh',
  'Project Backup::Restore backup artifact',
  'Project Backup::Backup failure surfacing',
  'Project Logs::Clear logs actions',
  'Project Logs::Copy logs/details actions',
  'Project Email, Domain, And Settings::Project delete failure/warning path',
  'App Settings And Local Database Safety::Export encrypted local DB snapshot',
  'App Settings And Local Database Safety::Restore encrypted DB before unlock',
  'App Settings And Local Database Safety::Existing exported DB still uses old password warning',
  'App Settings And Local Database Safety::Analytics/cookie consent website-adjacent flows',
  'Remote Server Stack Verification::BIND/DNS service',
  'Remote Server Stack Verification::PostgreSQL service container',
  'Remote Server Stack Verification::WAL-G inside Postgres image/tooling',
};

const List<String> _externalOnlySurfaceFragments = <String>[
  'GitHub OAuth connect with human login',
  'Cold-launch OAuth callback recovery',
  'Private repository deploy',
  'Domain routing:',
];

List<E2eChecklistSurface> parseManualE2eChecklist(String markdown) {
  final surfaces = <E2eChecklistSurface>[];
  var currentSection = '';
  for (final rawLine in const LineSplitter().convert(markdown)) {
    final line = rawLine.trim();
    if (line.startsWith('## ')) {
      currentSection = line.substring(3).trim();
      continue;
    }
    if (currentSection.isEmpty || currentSection == 'Status rules') {
      continue;
    }
    if (!line.startsWith('|')) {
      continue;
    }
    final rawCells = line.split('|').toList();
    if (rawCells.isNotEmpty && rawCells.first.trim().isEmpty) {
      rawCells.removeAt(0);
    }
    if (rawCells.isNotEmpty && rawCells.last.trim().isEmpty) {
      rawCells.removeLast();
    }
    final cells = rawCells.map((cell) => cell.trim()).toList(growable: false);
    if (cells.length < 4) {
      continue;
    }
    final doneCell = cells[0];
    if (doneCell != '[x]' && doneCell != '[ ]') {
      continue;
    }
    surfaces.add(
      E2eChecklistSurface(
        section: currentSection,
        surface: _stripMarkdownCode(cells[1]),
        done: doneCell == '[x]',
        manualStatus: _stripMarkdownCode(cells[2]),
        notes: _stripMarkdownCode(cells[3]),
      ),
    );
  }
  return surfaces;
}

bool _looksLikeRepositoryRoot(Directory dir) =>
    File('${dir.path}/ui/pubspec.yaml').existsSync() &&
    File('${dir.path}/orchestrator/pyproject.toml').existsSync();

Directory findRepositoryRoot({Directory? start, String? repoRootOverride}) {
  final override =
      (repoRootOverride ??
              const String.fromEnvironment('DEPLOYDASH_E2E_REPO_ROOT'))
          .trim();
  if (override.isNotEmpty) {
    final dir = Directory(override);
    if (_looksLikeRepositoryRoot(dir)) {
      return dir;
    }
    throw StateError(
      'DEPLOYDASH_E2E_REPO_ROOT is not an application checkout: $override.',
    );
  }
  var current = start ?? Directory.current;
  while (true) {
    // Anchor on markers owned by the application repository itself: the
    // desktop pubspec and the backend package manifest travel together in
    // every checkout that can build or test this code. The QA checklist
    // must never be the anchor -- it lives in the private QA repository,
    // which application checkouts do not contain.
    if (_looksLikeRepositoryRoot(current)) {
      return current;
    }
    final parent = current.parent;
    if (parent.path == current.path) {
      throw StateError(
        'Could not find ui/pubspec.yaml and '
        'orchestrator/pyproject.toml from '
        '${Directory.current.path}.',
      );
    }
    current = parent;
  }
}

List<E2eChecklistSurface> readManualE2eChecklist({
  Directory? repositoryRoot,
  String? checklistPathOverride,
}) {
  final override =
      (checklistPathOverride ??
              const String.fromEnvironment('DEPLOYDASH_E2E_CHECKLIST_PATH'))
          .trim();
  if (override.isNotEmpty) {
    return parseManualE2eChecklist(File(override).readAsStringSync());
  }
  final root = repositoryRoot ?? findRepositoryRoot();
  final checklist = File('${root.path}/qa/e2e/checklist.md');
  return parseManualE2eChecklist(checklist.readAsStringSync());
}

String renderE2eAutomationReport({
  required List<E2eChecklistSurface> surfaces,
  required List<E2eRunResult> results,
  E2eRunMetadata metadata = const E2eRunMetadata(),
}) {
  final byStatus = <E2eAutomationStatus, int>{
    for (final status in E2eAutomationStatus.values) status: 0,
  };
  for (final surface in surfaces) {
    byStatus[surface.automationStatus] =
        (byStatus[surface.automationStatus] ?? 0) + 1;
  }

  final resultByKey = <String, E2eRunResult>{
    for (final result in results) result.surfaceKey: result,
  };

  final buffer = StringBuffer()
    ..writeln('# Automated E2E checklist report')
    ..writeln()
    ..writeln('Generated: ${DateTime.now().toUtc().toIso8601String()}')
    ..writeln()
    ..writeln('- Run ID: ${_reportLabel(metadata.runId)}')
    ..writeln('- Scenario: ${_reportLabel(metadata.scenario)}')
    ..writeln('- Git commit: ${_reportLabel(metadata.gitCommitSha)}')
    ..writeln('- App version: ${_reportLabel(metadata.appVersion)}')
    ..writeln()
    ..writeln('- Automated rows: ${byStatus[E2eAutomationStatus.automated]}')
    ..writeln('- Planned rows: ${byStatus[E2eAutomationStatus.planned]}')
    ..writeln(
      '- External-runner rows: ${byStatus[E2eAutomationStatus.external]}',
    )
    ..writeln()
    ..writeln('| Section | Surface | Scenario | Automation | Latest run |')
    ..writeln('| --- | --- | --- | --- | --- |');

  for (final surface in surfaces) {
    final result = resultByKey[surface.key];
    final scenario = _scenarioIdForChecklistKey(surface.key);
    buffer.writeln(
      '| ${_escapeMarkdownTable(surface.section)} '
      '| ${_escapeMarkdownTable(surface.surface)} '
      '| ${_escapeMarkdownTable(scenario ?? '-')} '
      '| ${surface.automationStatusLabel} '
      '| ${_escapeMarkdownTable(result?.status ?? '-')} |',
    );
  }
  return buffer.toString();
}

void writeE2eAutomationArtifacts({
  required List<E2eChecklistSurface> surfaces,
  required List<E2eRunResult> results,
}) {
  const reportPath = String.fromEnvironment('DEPLOYDASH_E2E_REPORT_PATH');
  const jsonPath = String.fromEnvironment('DEPLOYDASH_E2E_REPORT_JSON_PATH');
  const metadata = E2eRunMetadata(
    runId: String.fromEnvironment('DEPLOYDASH_E2E_RUN_ID'),
    scenario: String.fromEnvironment(
      'DEPLOYDASH_E2E_SCENARIO',
      defaultValue: 'all',
    ),
    gitCommitSha: String.fromEnvironment('DEPLOYDASH_E2E_GIT_SHA'),
    appVersion: String.fromEnvironment('DEPLOYDASH_E2E_APP_VERSION'),
  );
  if (reportPath.trim().isNotEmpty) {
    final reportFile = File(reportPath);
    reportFile.parent.createSync(recursive: true);
    reportFile.writeAsStringSync(
      renderE2eAutomationReport(
        surfaces: surfaces,
        results: results,
        metadata: metadata,
      ),
    );
  }
  if (jsonPath.trim().isNotEmpty) {
    final jsonFile = File(jsonPath);
    jsonFile.parent.createSync(recursive: true);
    jsonFile.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        'generated_at': DateTime.now().toUtc().toIso8601String(),
        'metadata': metadata.toJson(),
        'surfaces': surfaces.map((surface) => surface.toJson()).toList(),
        'results': results.map((result) => result.toJson()).toList(),
      }),
    );
  }
}

String? _scenarioIdForChecklistKey(String key) {
  for (final scenario in productionSafetyScenarios) {
    if (scenario.requiredChecklistKeys.contains(key)) {
      return scenario.id;
    }
  }
  return null;
}

String _reportLabel(String value) {
  final normalized = value.trim();
  return normalized.isEmpty ? '-' : _escapeMarkdownTable(normalized);
}

Object? _redactReportValue(Object? value) {
  if (value is Map) {
    return <String, Object?>{
      for (final entry in value.entries)
        entry.key.toString(): _isSensitiveReportKey(entry.key.toString())
            ? '***'
            : _redactReportValue(entry.value),
    };
  }
  if (value is Iterable) {
    return value.map(_redactReportValue).toList(growable: false);
  }
  if (value is String) {
    return value
        .replaceAllMapped(
          RegExp(
            r'(password|passphrase|secret|token|private[_ -]?key|access[_ -]?key)(\s*(?:[:=]|\|)\s*)[^\s,;|]+',
            caseSensitive: false,
          ),
          (match) => '${match.group(1)}${match.group(2)}***',
        )
        .replaceAll(
          RegExp(
            r'-----BEGIN [^-]+ PRIVATE KEY-----[\s\S]*?-----END [^-]+ PRIVATE KEY-----',
          ),
          '***REDACTED PRIVATE KEY***',
        );
  }
  return value;
}

bool _isSensitiveReportKey(String key) {
  final normalized = key.toLowerCase().replaceAll('-', '_');
  return normalized.contains('password') ||
      normalized.contains('passphrase') ||
      normalized.contains('secret') ||
      normalized.contains('token') ||
      normalized.contains('private_key') ||
      normalized.contains('access_key');
}

String _stripMarkdownCode(String value) {
  return value.replaceAll('`', '').trim();
}

String _escapeMarkdownTable(String value) {
  return value.replaceAll('|', r'\|').replaceAll('\n', ' ').trim();
}

String _slug(String value) {
  final lower = value.toLowerCase();
  final buffer = StringBuffer();
  var previousDash = false;
  for (final codeUnit in lower.codeUnits) {
    final isAlphaNumeric =
        (codeUnit >= 97 && codeUnit <= 122) ||
        (codeUnit >= 48 && codeUnit <= 57);
    if (isAlphaNumeric) {
      buffer.writeCharCode(codeUnit);
      previousDash = false;
      continue;
    }
    if (!previousDash) {
      buffer.write('-');
      previousDash = true;
    }
  }
  return buffer.toString().replaceAll(RegExp(r'^-+|-+$'), '');
}
