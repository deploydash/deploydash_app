import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yaru/yaru.dart';
import '../../postgres_runtime_env.dart';
import '../../models/railpack_runtime.dart';
import '../../models/app_public_health.dart';
import '../../models/postgres_storage_status.dart';
import '../../models/run_guard.dart';
import '../../models/result.dart';
import '../../models/workspace_scope.dart';
import '../../utils/format_clock_time.dart';
import '../../utils/host_format.dart';
import '../../utils/message_or.dart';
import '../../utils/open_external_url.dart';
import '../../utils/payload_codecs.dart';
import '../../utils/project_slug.dart';
import '../../utils/stringify_keys.dart';
import '../../utils/terminal_output_filter.dart';
import '../../utils/trim_or_null.dart';
import '../../providers/app_environment_variable_revision_provider.dart';
import '../../providers/app_release_provider.dart';
import '../../providers/backup_provider.dart';
import '../../providers/github_deploy_diagnostics.dart';
import '../../providers/github_integration_provider.dart';
import '../../providers/project_web_app_read_model_provider.dart';
import '../../providers/project_workspace_data_provider.dart';
import '../../providers/project_deletion_provider.dart';
import '../../providers/project_lifecycle_provider.dart';
import '../../providers/project_provider.dart';
import '../../providers/project_managed_database_provider.dart';
import '../../providers/project_sqlite_database_provider.dart';
import '../../providers/recent_projects_provider.dart';
import '../../providers/scheduler_task_provider.dart';
import '../../providers/server_list_provider.dart';
import '../../providers/server_provider.dart';
import '../../providers/worker_instance_provider.dart';
import '../../services/app_analytics_service.dart';
import '../../services/project_database_settings.dart';
import '../../services/runtime_log_settings.dart';
import '../system/app_dialogs.dart';
import '../system/app_forms.dart';
import '../system/app_copy.dart';
import '../system/app_context_navigation.dart';
import '../system/app_state_views.dart';
import '../system/app_sections.dart';
import '../system/app_theme.dart';
import '../system/app_workspace.dart';
import '../system/container_runtime_status.dart';
import '../system/app_rows.dart';
import '../system/app_cards.dart';
import 'workspace/app/app_deployment_failure_card.dart';
import 'workspace/app/app_deployment_tab_logic.dart';
import '../../services/backup_logic.dart';
import 'workspace/logs/log_tab_logic.dart';
import 'workspace/settings/settings_tab_logic.dart';
import 'workspace/workers/workers_tab_logic.dart';
import 'workspace/scheduler/scheduler_tab_logic.dart';
import 'workspace/shell/project_destinations.dart';
import 'workspace/workers/worker_runtime_contract.dart';

part 'workspace/app/dns_provider_specs.dart';
part 'workspace/shell/workspace_shell.dart';
part 'workspace/workspace_scope_mixin.dart';
part 'workspace/app/app_deployment_tab.dart';
part 'workspace/app/app_deployment_state_sync_methods.dart';
part 'workspace/app/app_deployment_environment_methods.dart';
part 'workspace/app/app_deployment_runtime_methods.dart';
part 'workspace/app/app_deployment_one_off_methods.dart';
part 'workspace/app/app_deployment_dialog_methods.dart';
part 'workspace/app/app_deployment_github_connection_feedback.dart';
part 'workspace/app/app_deployment_models.dart';
part 'workspace/app/app_deployment_settings_dialog.dart';
part 'workspace/app/app_deployment_env_editor_dialog.dart';
part 'workspace/app/app_deployment_payload_helpers.dart';
part 'workspace/workers/workers_tab.dart';
part 'workspace/database/database_tab.dart';
part 'workspace/database/database_tab_logic.dart';
part 'workspace/database/database_tab_sqlite_operations.dart';
part 'workspace/database/database_create_sqlite_dialog.dart';
part 'workspace/database/database_tab_postgres_operations.dart';
part 'workspace/database/database_credentials_dialog.dart';
part 'workspace/database/database_restore_sql_dialog.dart';
part 'workspace/database/database_create_postgres_dialog.dart';
part 'workspace/database/database_create_user_dialog.dart';
part 'workspace/database/database_managed_service_state_card.dart';
part 'workspace/database/database_sqlite_card.dart';
part 'workspace/database/database_project_sharing_card.dart';
part 'workspace/comms/email_domain_tabs.dart';
part 'workspace/backup/backup_tab.dart';
part 'workspace/backup/backup_state_methods.dart';
part 'workspace/backup/backup_dialog_methods.dart';
part 'workspace/backup/backup_operation_methods.dart';
part 'workspace/scheduler/scheduler_tab.dart';
part 'workspace/logs/log_tab.dart';
part 'workspace/settings/settings_tab.dart';

Future<String?> _pickPostgresRestoreSqlFile() async {
  final file = await openFile(
    acceptedTypeGroups: const [
      XTypeGroup(label: 'SQL files', extensions: ['sql']),
      XTypeGroup(label: 'PostgreSQL custom dumps', extensions: ['dump']),
    ],
    confirmButtonText: 'Select dump file',
  );
  return file?.path;
}

Future<String?> Function()? _debugPostgresRestoreSqlFilePicker;

void debugOverridePostgresRestoreSqlFilePicker(
  Future<String?> Function()? picker,
) {
  _debugPostgresRestoreSqlFilePicker = picker;
}

const String _domainRoutingModeSingleHost = 'single_host';
const String _domainRoutingModeRedirectWwwToApex = 'redirect_www_to_apex';
const String _domainRoutingModeRedirectApexToWww = 'redirect_apex_to_www';

bool _projectHasAppRuntime({
  required Project project,
  required AppReleaseScopeState releaseScope,
}) {
  return releaseScope.liveRelease != null || project.lastDeployedAt != null;
}

class _JournaledProjectWorkflowResult {
  const _JournaledProjectWorkflowResult({
    required this.response,
    required this.journal,
  });

  final Map<String, dynamic> response;
  final ProjectManagedOperationJournalRecord journal;

  Future<void> markCommitted(WidgetRef ref, {Map<String, dynamic>? result}) {
    return ref
        .read(appReleaseRepositoryProvider)
        .updateJournalStatus(
          id: journal.id,
          status: 'committed_local',
          result: result ?? response,
        );
  }
}

Future<_JournaledProjectWorkflowResult> _runJournaledProjectWorkflow({
  required WidgetRef ref,
  required Project project,
  required Server server,
  required String surface,
  required String operationType,
  required String workflowId,
  required String operationId,
  Map<String, dynamic>? connection,
  Map<String, dynamic>? params,
  Map<String, dynamic>? journalRequest,
  void Function(Map<String, dynamic> event)? onEvent,
  void Function(int taskId)? onTaskStarted,
  bool serializePerHost = true,
}) async {
  final repository = ref.read(appReleaseRepositoryProvider);
  final defaultRequest = <String, dynamic>{
    'workflow_id': workflowId,
    'operation_id': operationId,
  };
  if (params != null) {
    defaultRequest['params'] = params;
  }
  final journal = await repository.createJournalEntry(
    projectId: project.id,
    serverId: server.id,
    surface: surface,
    operationType: operationType,
    request: journalRequest ?? defaultRequest,
  );
  var remoteSucceeded = false;
  try {
    final response =
        (await ref
                .read(sshServiceProvider)
                .runWorkflow(
                  workflowId: workflowId,
                  operationId: operationId,
                  connection: connection,
                  params: params,
                  onEvent: onEvent,
                  onTaskStarted: onTaskStarted,
                  serializePerHost: serializePerHost,
                ))
            .diagnosticPayload;
    final status = response['status']?.toString();
    if (status == 'success') {
      await repository.updateJournalStatus(
        id: journal.id,
        status: 'remote_success',
        result: response,
      );
      remoteSucceeded = true;
    } else {
      await repository.updateJournalStatus(
        id: journal.id,
        status: 'failed',
        result: response,
        errorMessage: response['msg']?.toString(),
      );
    }
    return _JournaledProjectWorkflowResult(
      response: response,
      journal: journal,
    );
  } catch (error) {
    if (!remoteSucceeded) {
      await repository.updateJournalStatus(
        id: journal.id,
        status: 'failed',
        errorMessage: error.toString(),
      );
    }
    rethrow;
  }
}

String _normalizedDomainRoutingModeForWorkspace(String value) {
  final normalized = value.trim().toLowerCase();
  return switch (normalized) {
    _domainRoutingModeRedirectWwwToApex => _domainRoutingModeRedirectWwwToApex,
    _domainRoutingModeRedirectApexToWww => _domainRoutingModeRedirectApexToWww,
    _ => _domainRoutingModeSingleHost,
  };
}

String _stripLeadingWwwForWorkspace(String value) {
  final trimmed = value.trim().toLowerCase();
  if (trimmed.startsWith('www.') && trimmed.length > 4) {
    return trimmed.substring(4);
  }
  return trimmed;
}

({String primaryDomain, String domainRoutingMode})
_normalizedDomainRoutingConfigForWorkspace({
  required String primaryDomain,
  required String domainRoutingMode,
}) {
  final normalizedPrimaryDomain = primaryDomain.trim().toLowerCase();
  final normalizedMode = _normalizedDomainRoutingModeForWorkspace(
    domainRoutingMode,
  );
  if (normalizedMode == _domainRoutingModeSingleHost) {
    return (
      primaryDomain: normalizedPrimaryDomain,
      domainRoutingMode: normalizedMode,
    );
  }
  return (
    primaryDomain: _stripLeadingWwwForWorkspace(normalizedPrimaryDomain),
    domainRoutingMode: normalizedMode,
  );
}

String _canonicalDomainForWorkspace({
  required String primaryDomain,
  required String domainRoutingMode,
}) {
  final normalizedDomain = primaryDomain.trim().toLowerCase();
  final normalizedMode = _normalizedDomainRoutingModeForWorkspace(
    domainRoutingMode,
  );
  return switch (normalizedMode) {
    _domainRoutingModeRedirectApexToWww =>
      'www.${_stripLeadingWwwForWorkspace(normalizedDomain)}',
    _domainRoutingModeRedirectWwwToApex => _stripLeadingWwwForWorkspace(
      normalizedDomain,
    ),
    _ => normalizedDomain,
  };
}
