import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/local/backup_repository.dart';
import '../data/local/project_deletion_recovery_repository.dart';
import '../data/local/project_repository.dart';
import '../data/local/scheduler_task_repository.dart';
import '../data/local/server_credential_repository.dart';
import '../services/project_deletion_coordinator.dart';
import 'server_provider.dart';

/// Provider-layer recovery API used by project-deletion presentation flows.
export '../data/local/project_deletion_recovery_repository.dart';
export '../services/project_deletion_coordinator.dart';

final projectDeletionCoordinatorProvider = Provider<ProjectDeletionCoordinator>(
  (ref) => ProjectDeletionCoordinator(
    recoveryRepository: ref.watch(projectDeletionRecoveryRepositoryProvider),
    projectRepository: ref.watch(projectRepositoryProvider),
    backupRepository: ref.watch(backupRepositoryProvider),
    schedulerRepository: ref.watch(schedulerTaskRepositoryProvider),
    credentialRepository: ref.watch(serverCredentialRepositoryProvider),
    sshService: ref.watch(sshServiceProvider),
  ),
);
