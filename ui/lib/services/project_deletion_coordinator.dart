import '../data/local/backup_repository.dart';
import '../data/local/project_deletion_recovery_repository.dart';
import '../data/local/project_repository.dart';
import '../data/local/scheduler_task_repository.dart';
import '../data/local/server_credential_repository.dart';
import '../data/local/server_repository.dart';
import '../models/result.dart';
import '../utils/project_slug.dart';
import '../utils/trim_or_null.dart';
import 'project_database_settings.dart';
import 'sensitive_data_sanitizer.dart';
import 'ssh_service.dart';

/// What one attempt at removing a project's server-side resources achieved.
///
/// Deletion is not all-or-nothing: a project can lose its containers and keep
/// its database because the server went away mid-run. The outcome reports that
/// honestly so the caller can leave the local record in place and offer a
/// retry, rather than telling the user a project is gone while its data is
/// still on their machine.
class ProjectDeletionOutcome {
  /// Records the result of one attempt.
  const ProjectDeletionOutcome({
    required this.projectName,
    required this.completed,
    required this.messages,
  });

  /// The project's name, for the message the user is shown.
  final String projectName;

  /// Whether every step finished, so the local record can now be deleted.
  ///
  /// False while any step failed *or* is still pending -- an unattempted step
  /// is not a successful one.
  final bool completed;

  /// One line per step that did not succeed, already sanitized for display.
  /// Empty when [completed] is true.
  final List<String> messages;
}

/// Removes a project's resources from its server, one resumable step at a
/// time.
///
/// Deletion touches the app runtime, every backup plan, every scheduled job
/// and the managed database, on a machine that can become unreachable between
/// any two of them. So each step is written to the recovery record as it
/// completes: a step already marked successful is skipped on the next attempt,
/// and an interrupted deletion resumes rather than restarting -- which matters
/// because several of these steps are not safely repeatable.
///
/// This coordinator only ever touches the *server*. Deleting the local project
/// row is the caller's job, and only once [ProjectDeletionOutcome.completed]
/// is true; doing it here would leave a user with resources on a paid server
/// and nothing in the app pointing at them.
class ProjectDeletionCoordinator {
  /// Creates a coordinator over the repositories and the SSH service it drives.
  const ProjectDeletionCoordinator({
    required ProjectDeletionRecoveryRepository recoveryRepository,
    required ProjectRepository projectRepository,
    required BackupRepository backupRepository,
    required SchedulerTaskRepository schedulerRepository,
    required ServerCredentialRepository credentialRepository,
    required SSHService sshService,
  }) : _recoveryRepository = recoveryRepository,
       _projectRepository = projectRepository,
       _backupRepository = backupRepository,
       _schedulerRepository = schedulerRepository,
       _credentialRepository = credentialRepository,
       _sshService = sshService;

  final ProjectDeletionRecoveryRepository _recoveryRepository;
  final ProjectRepository _projectRepository;
  final BackupRepository _backupRepository;
  final SchedulerTaskRepository _schedulerRepository;
  final ServerCredentialRepository _credentialRepository;
  final SSHService _sshService;

  /// Begins deleting [project]'s resources from [server].
  ///
  /// Writes the recovery record before doing anything, so a crash during the
  /// first step still leaves the deletion resumable. A null [server] is not an
  /// error the caller must pre-empt: it is recorded as a failed connection
  /// step and returned as an incomplete outcome, which is the same shape a
  /// retry can act on.
  Future<ProjectDeletionOutcome> start({
    required Project project,
    required Server? server,
  }) async {
    await _recoveryRepository.startRecovery(
      projectId: project.id,
      serverId: server?.id ?? project.serverId,
      projectName: project.name,
      projectSlug: slugifyProjectName(project.name, fallback: 'project-app'),
    );
    return _run(project: _DeletionProject.fromProject(project), server: server);
  }

  /// Resumes a recorded deletion, skipping steps already marked successful.
  ///
  /// A recovery record whose project row no longer exists is completed and
  /// discarded: the user removed the local record themselves, and there is
  /// nothing left to describe the remote work against.
  Future<ProjectDeletionOutcome> retry({
    required ProjectDeletionRecoveryRecord recovery,
    required Server? server,
  }) async {
    final project = await _projectRepository.readProject(
      recovery.projectId,
      includePendingDeletion: true,
    );
    if (project == null) {
      await _recoveryRepository.removeRecovery(recovery.projectId);
      return ProjectDeletionOutcome(
        projectName: recovery.projectName,
        completed: true,
        messages: const [],
      );
    }
    return _run(project: _DeletionProject.fromProject(project), server: server);
  }

  Future<ProjectDeletionOutcome> _run({
    required _DeletionProject project,
    required Server? server,
  }) async {
    var recovery = await _recoveryRepository.beginAttempt(project.id);
    final steps = <String, ProjectDeletionStepState>{
      for (final step in recovery.steps) step.id: step,
    };

    Future<void> persist({String? lastError}) {
      final failures = steps.values
          .where((step) => step.status == ProjectDeletionStepStatus.failed)
          .toList(growable: false);
      return _recoveryRepository.saveProgress(
        projectId: project.id,
        steps: steps.values.toList(growable: false),
        failed: failures.isNotEmpty,
        lastError:
            lastError ?? (failures.isEmpty ? null : failures.last.message),
      );
    }

    ProjectDeletionStepState ensureStep(String id, String label) {
      return steps.putIfAbsent(
        id,
        () => ProjectDeletionStepState(
          id: id,
          label: label,
          status: ProjectDeletionStepStatus.pending,
        ),
      );
    }

    Future<void> failWithoutRemote(
      String id,
      String label,
      String message,
    ) async {
      final step = ensureStep(id, label);
      steps[id] = step.copyWith(
        status: ProjectDeletionStepStatus.failed,
        message: _safeMessage(message),
      );
      await persist(lastError: message);
    }

    if (server == null) {
      await failWithoutRemote(
        'connection',
        'Connect to the project server',
        'Server cleanup could not run because the project server is not available.',
      );
      return _outcome(project.name, steps.values);
    }

    final connection = await _credentialRepository.connectionPayload(server);
    if (connection == null) {
      await failWithoutRemote(
        'connection',
        'Connect to the project server',
        'This server connection needs to be reconnected before cleanup can continue.',
      );
      return _outcome(project.name, steps.values);
    }

    final connectionStep = ensureStep(
      'connection',
      'Connect to the project server',
    );
    steps['connection'] = connectionStep.copyWith(
      status: ProjectDeletionStepStatus.success,
      message: null,
    );
    await persist();

    Future<void> runStep({
      required String id,
      required String label,
      required String workflowId,
      required String operationId,
      required Map<String, dynamic> settings,
      bool confirmDeleteLists = false,
    }) async {
      // The step as it stood before this attempt. Every write below is a
      // `copyWith` that replaces both status and message, so carrying the
      // original rather than re-reading gives the same result -- only its id
      // and label survive the copy, and those do not change.
      final step = ensureStep(id, label);
      if (step.status == ProjectDeletionStepStatus.success) {
        return;
      }
      steps[id] = step.copyWith(
        status: ProjectDeletionStepStatus.pending,
        message: null,
      );
      await persist();
      try {
        // Confirmed deletes capture the orchestrator's deletion plan first and
        // echo it back on execute, so the server refuses when the registry
        // drifted between the two calls. A plan that errors or arrives in the
        // wrong shape fails the step without executing: deleting blind is the
        // outcome this handshake exists to prevent.
        var effectiveSettings = settings;
        if (confirmDeleteLists) {
          final plan = (await _sshService.runWorkflow(
            workflowId: workflowId,
            operationId: operationId,
            connection: connection,
            params: <String, dynamic>{'dry_run': true, 'settings': settings},
          )).diagnosticPayload;
          final databases = _stringList(plan['databases']);
          final users = _stringList(plan['users']);
          if (plan['status'] != 'success' ||
              databases == null ||
              users == null) {
            final message = plan['status'] == 'success'
                ? 'The delete confirmation list was unavailable, so nothing was deleted.'
                : _responseMessage(plan, 'Cleanup did not finish.');
            steps[id] = step.copyWith(
              status: ProjectDeletionStepStatus.failed,
              message: message,
            );
            await persist();
            return;
          }
          effectiveSettings = <String, dynamic>{
            ...settings,
            'confirmed_databases': databases,
            'confirmed_users': users,
          };
        }
        final response = (await _sshService.runWorkflow(
          workflowId: workflowId,
          operationId: operationId,
          connection: connection,
          params: <String, dynamic>{
            'dry_run': false,
            'settings': effectiveSettings,
          },
        )).diagnosticPayload;
        if (response['status'] == 'success') {
          steps[id] = step.copyWith(
            status: ProjectDeletionStepStatus.success,
            message: null,
          );
        } else {
          final message = _responseMessage(response, 'Cleanup did not finish.');
          steps[id] = step.copyWith(
            status: ProjectDeletionStepStatus.failed,
            message: message,
          );
        }
      } catch (error) {
        steps[id] = step.copyWith(
          status: ProjectDeletionStepStatus.failed,
          message: _safeMessage(error.toString()),
        );
      }
      await persist();
    }

    await runStep(
      id: 'app_runtime',
      label: 'Remove the web app and worker runtime',
      workflowId: 'app',
      operationId: 'disconnect',
      settings: _buildAppRuntimeSettings(project),
    );

    List<BackupDestinationRecord> destinations = const [];
    List<BackupPolicyRecord> policies = const [];
    try {
      destinations = await _backupRepository.listDestinationsForScope(
        projectId: project.id,
        serverId: server.id,
      );
      policies = await _backupRepository.listPoliciesForScope(
        projectId: project.id,
        serverId: server.id,
      );
      final step = ensureStep('load_backup_plans', 'Load saved backup plans');
      steps['load_backup_plans'] = step.copyWith(
        status: ProjectDeletionStepStatus.success,
        message: null,
      );
      await persist();
    } catch (error) {
      await failWithoutRemote(
        'load_backup_plans',
        'Load saved backup plans',
        error.toString(),
      );
    }
    final destinationsById = <String, BackupDestinationRecord>{
      for (final destination in destinations) destination.id: destination,
    };
    for (final policy in policies) {
      final destination = destinationsById[policy.destinationId];
      await runStep(
        id: 'backup_policy:${policy.id}',
        label: 'Delete backup plan ${policy.name}',
        workflowId: 'postgres',
        operationId: 'backup_policy_delete',
        settings: buildManagedPostgresProjectSettings(
          projectName: project.name,
          config: server.postgresConfig,
          overrides: <String, dynamic>{
            'backup_policy_id': policy.id,
            'backup_task_id': policy.managedTaskId,
            if (destination?.type == BackupDestinationType.s3) ...{
              'backup_destination_type': 's3',
              'backup_s3_prefix': destination?.config['prefix'],
              'backup_aws_access_key_id': destination?.config['access_key_id'],
              'backup_aws_secret_access_key':
                  destination?.config['secret_access_key'],
              'backup_aws_region': destination?.config['region'],
              'backup_aws_endpoint': destination?.config['endpoint'],
              'backup_aws_force_path_style':
                  destination?.config['force_path_style'] == true,
            },
          },
        ),
      );
    }

    List<SchedulerTaskRecord> schedulerTasks = const [];
    try {
      schedulerTasks = (await _schedulerRepository.listTasksForProject(
        project.id,
      )).where((task) => !task.managedByService).toList(growable: false);
      final step = ensureStep(
        'load_scheduler_tasks',
        'Load saved scheduled jobs',
      );
      steps['load_scheduler_tasks'] = step.copyWith(
        status: ProjectDeletionStepStatus.success,
        message: null,
      );
      await persist();
    } catch (error) {
      await failWithoutRemote(
        'load_scheduler_tasks',
        'Load saved scheduled jobs',
        error.toString(),
      );
    }
    for (final task in schedulerTasks) {
      await runStep(
        id: 'scheduler_task:${task.id}',
        label: 'Delete scheduled job ${task.name}',
        workflowId: 'scheduler',
        operationId: 'task_delete',
        settings: <String, dynamic>{
          'project_slug': project.projectSlug,
          'task_id': task.id,
        },
      );
    }

    if (server.serviceDatabaseEnabled) {
      await runStep(
        id: 'postgres_project',
        label: 'Delete project databases and users',
        workflowId: 'postgres',
        operationId: 'project_delete',
        settings: buildManagedPostgresProjectSettings(
          projectName: project.name,
          config: server.postgresConfig,
        ),
        confirmDeleteLists: true,
      );
    }

    recovery = (await _recoveryRepository.getRecovery(project.id)) ?? recovery;
    return _outcome(project.name, recovery.steps);
  }

  static ProjectDeletionOutcome _outcome(
    String projectName,
    Iterable<ProjectDeletionStepState> steps,
  ) {
    final failed = steps
        .where((step) => step.status == ProjectDeletionStepStatus.failed)
        .toList(growable: false);
    final pending = steps
        .where((step) => step.status == ProjectDeletionStepStatus.pending)
        .toList(growable: false);
    return ProjectDeletionOutcome(
      projectName: projectName,
      completed: failed.isEmpty && pending.isEmpty,
      messages: <String>[
        for (final step in failed)
          '${step.label}: ${step.message ?? 'cleanup did not finish'}',
        for (final step in pending) '${step.label}: cleanup is still pending',
      ],
    );
  }

  static Map<String, dynamic> _buildAppRuntimeSettings(
    _DeletionProject project,
  ) {
    final repository = trimOrNull(project.repositoryFullName);
    final branch = trimOrNull(project.deployBranch) ?? 'main';
    final normalizedDomain = _isValidDomain(project.primaryDomain)
        ? project.primaryDomain.trim().toLowerCase()
        : 'app.example.com';
    final appPort = project.appPort < 1 || project.appPort > 65535
        ? 3000
        : project.appPort;
    final appSubdirectory = trimOrNull(project.appSubdirectory);
    final buildCommand = trimOrNull(project.railpackBuildCommand);
    final runCommand = trimOrNull(project.railpackRunCommand);
    final useDnsTls =
        project.tlsChallengeMode == 'dns' &&
        trimOrNull(project.tlsDnsProvider) != null &&
        project.tlsDnsCredentials.isNotEmpty;
    return <String, dynamic>{
      'project_slug': project.projectSlug,
      'repository_full_name': repository ?? 'deploydash/local-app',
      'branch': branch,
      'primary_domain': normalizedDomain,
      'app_port': appPort,
      'railpack_build_cmd': buildCommand ?? 'npm run build',
      'railpack_start_cmd': runCommand ?? 'npm run start',
      'railpack_node_mode': project.railpackNodeMode,
      'tls_challenge_mode': useDnsTls ? 'dns' : 'http',
      if (useDnsTls) 'tls_dns_provider': project.tlsDnsProvider,
      if (useDnsTls) 'tls_dns_credentials': project.tlsDnsCredentials,
      'app_subdirectory': ?appSubdirectory,
    };
  }

  static String _responseMessage(
    Map<String, dynamic> response,
    String fallback,
  ) {
    return _safeMessage(trimOrNull(response['msg']?.toString()) ?? fallback);
  }

  /// Reads one dry-run plan list, or null when the plan is unusable.
  ///
  /// A missing key, a non-list value, or a non-string entry all mean the
  /// orchestrator did not return the shape project deletes execute against,
  /// and the step must fail without executing rather than confirm blindly.
  static List<String>? _stringList(Object? value) {
    if (value is! List) {
      return null;
    }
    final parsed = <String>[];
    for (final entry in value) {
      if (entry is! String) {
        return null;
      }
      parsed.add(entry);
    }
    return parsed;
  }

  static String _safeMessage(String message) {
    final sanitized = sanitizeSensitiveText(message);
    return sanitized.isEmpty ? 'Cleanup did not finish.' : sanitized;
  }

  static bool _isValidDomain(String value) {
    return RegExp(
      r'^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])$',
    ).hasMatch(value.trim().toLowerCase());
  }
}

class _DeletionProject {
  const _DeletionProject({
    required this.id,
    required this.name,
    required this.primaryDomain,
    required this.repositoryFullName,
    required this.appSubdirectory,
    required this.deployBranch,
    required this.appPort,
    required this.railpackBuildCommand,
    required this.railpackRunCommand,
    required this.railpackNodeMode,
    required this.tlsChallengeMode,
    required this.tlsDnsProvider,
    required this.tlsDnsCredentials,
  });

  factory _DeletionProject.fromProject(Project project) {
    return _DeletionProject(
      id: project.id,
      name: project.name,
      primaryDomain: project.primaryDomain,
      repositoryFullName: project.repositoryFullName,
      appSubdirectory: project.appSubdirectory,
      deployBranch: project.deployBranch,
      appPort: project.appPort,
      railpackBuildCommand: project.railpackBuildCommand,
      railpackRunCommand: project.railpackRunCommand,
      railpackNodeMode: project.railpackNodeMode,
      tlsChallengeMode: project.tlsChallengeMode,
      tlsDnsProvider: project.tlsDnsProvider,
      tlsDnsCredentials: project.tlsDnsCredentials,
    );
  }

  final String id;
  final String name;
  final String primaryDomain;
  final String? repositoryFullName;
  final String? appSubdirectory;
  final String deployBranch;
  final int appPort;
  final String railpackBuildCommand;
  final String railpackRunCommand;
  final String railpackNodeMode;
  final String tlsChallengeMode;
  final String? tlsDnsProvider;
  final Map<String, String> tlsDnsCredentials;

  String get projectSlug => slugifyProjectName(name, fallback: 'project-app');
}
