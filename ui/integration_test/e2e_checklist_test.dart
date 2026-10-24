import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:ui/data/local/app_data_directory.dart';
import 'package:ui/data/local/app_database.dart';
import 'package:ui/main.dart' as app;
import 'package:ui/models/app_user_attribute.dart';
import 'package:ui/native_bridge.dart';
import 'package:ui/providers/github_integration_provider.dart';
import 'package:ui/providers/project_provider.dart';
import 'package:ui/providers/server_list_provider.dart';
import 'package:ui/services/app_analytics_service.dart';
import 'package:ui/services/deploydash_data_dir.dart';
import 'package:ui/ui/project/project_workspace.dart';
import 'package:ui/ui/settings/app_settings_view.dart';
import 'package:ui/ui/startup/database_unlock_gate.dart';
import 'package:ui/ui/system/app_dialogs.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:window_manager/window_manager.dart';

import 'support/e2e_checklist.dart';
import 'support/relay_client.dart';

part 'journeys/production_safety.dart';
part 'journeys/local_database_safety.dart';
part 'journeys/postgres_backup.dart';
part 'journeys/app_rollback.dart';
part 'journeys/firewall_recovery.dart';
part 'journeys/project_deletion_recovery.dart';
part 'journeys/host_key_recovery.dart';
part 'journeys/managed_software_rollback.dart';
part 'journeys/checklist_entrypoint.dart';
part 'journeys/ux_audit.dart';
part 'journeys/onboarding.dart';
part 'journeys/navigation_and_server.dart';
part 'journeys/project_entry.dart';
part 'journeys/github_auth.dart';
part 'journeys/deployment.dart';
part 'journeys/runtime_and_workers.dart';
part 'journeys/scheduler.dart';
part 'journeys/releases_and_logs.dart';
part 'journeys/project_data.dart';
part 'journeys/settings.dart';
part 'support/widget_driver.dart';
part 'support/vm_driver.dart';
part 'support/noop_analytics.dart';

void main() {
  _registerE2eChecklistTests();
}

final bool _liveE2e =
    const bool.fromEnvironment('DEPLOYDASH_E2E_LIVE') ||
    _environmentFlag('DEPLOYDASH_E2E_LIVE');
final bool _reuseE2eProfile =
    const bool.fromEnvironment('DEPLOYDASH_E2E_REUSE_PROFILE') ||
    _environmentFlag('DEPLOYDASH_E2E_REUSE_PROFILE');
final bool _requireProcessHardening =
    const bool.fromEnvironment('DEPLOYDASH_E2E_REQUIRE_HARDENING') ||
    _environmentFlag('DEPLOYDASH_E2E_REQUIRE_HARDENING');
final bool _captureE2eScreenshots =
    const bool.fromEnvironment('DEPLOYDASH_E2E_CAPTURE_SCREENSHOTS') ||
    _environmentFlag('DEPLOYDASH_E2E_CAPTURE_SCREENSHOTS');
final bool _pauseAtManualGitHub =
    const bool.fromEnvironment('DEPLOYDASH_E2E_PAUSE_AT_GITHUB') ||
    _environmentFlag('DEPLOYDASH_E2E_PAUSE_AT_GITHUB');
final bool _resumeSelectedProjectLiveAudit =
    const bool.fromEnvironment('DEPLOYDASH_E2E_RESUME_LIVE_AUDIT') ||
    _environmentFlag('DEPLOYDASH_E2E_RESUME_LIVE_AUDIT');
final bool _captureSelectedProjectLiveAuditOnly =
    const bool.fromEnvironment('DEPLOYDASH_E2E_CAPTURE_LIVE_AUDIT_ONLY') ||
    _environmentFlag('DEPLOYDASH_E2E_CAPTURE_LIVE_AUDIT_ONLY');
final bool _captureNewProjectAuditOnly =
    const bool.fromEnvironment(
      'DEPLOYDASH_E2E_CAPTURE_NEW_PROJECT_AUDIT_ONLY',
    ) ||
    _environmentFlag('DEPLOYDASH_E2E_CAPTURE_NEW_PROJECT_AUDIT_ONLY');
final bool _captureWorkspaceUxAuditOnly =
    const bool.fromEnvironment(
      'DEPLOYDASH_E2E_CAPTURE_WORKSPACE_UX_AUDIT_ONLY',
    ) ||
    _environmentFlag('DEPLOYDASH_E2E_CAPTURE_WORKSPACE_UX_AUDIT_ONLY');
final bool _captureOnboardingUxAuditOnly =
    const bool.fromEnvironment(
      'DEPLOYDASH_E2E_CAPTURE_ONBOARDING_UX_AUDIT_ONLY',
    ) ||
    _environmentFlag('DEPLOYDASH_E2E_CAPTURE_ONBOARDING_UX_AUDIT_ONLY');
final bool _verifyWorkerSchedulerRuntimeOnly =
    const bool.fromEnvironment('DEPLOYDASH_E2E_VERIFY_WORKER_SCHEDULER_ONLY') ||
    _environmentFlag('DEPLOYDASH_E2E_VERIFY_WORKER_SCHEDULER_ONLY');
final bool _verifyPublicHealthOnly =
    const bool.fromEnvironment('DEPLOYDASH_E2E_VERIFY_PUBLIC_HEALTH_ONLY') ||
    _environmentFlag('DEPLOYDASH_E2E_VERIFY_PUBLIC_HEALTH_ONLY');
final bool _verifyCaddyRouteCleanupOnly =
    const bool.fromEnvironment(
      'DEPLOYDASH_E2E_VERIFY_CADDY_ROUTE_CLEANUP_ONLY',
    ) ||
    _environmentFlag('DEPLOYDASH_E2E_VERIFY_CADDY_ROUTE_CLEANUP_ONLY');
final bool _slimMacOs =
    const bool.fromEnvironment('DEPLOYDASH_E2E_SLIM_MACOS') ||
    _environmentFlag('DEPLOYDASH_E2E_SLIM_MACOS');
final bool _bootstrapProductionSafetyProfileOnly =
    const bool.fromEnvironment(
      'DEPLOYDASH_E2E_BOOTSTRAP_PRODUCTION_SAFETY_ONLY',
    ) ||
    _environmentFlag('DEPLOYDASH_E2E_BOOTSTRAP_PRODUCTION_SAFETY_ONLY');
// Crash-injection modes for the fresh-onboarding journey. Each restarts the
// app once at its injection point, then proves the honest resumable state:
// before Finish no database exists and the server is untouched; mid-setup
// the enrolled install unlocks and the incomplete server retries. Full flow
// only: the slim leg pins its checklist set and provisions exactly once.
final bool _crashBeforeFinishE2e =
    const bool.fromEnvironment('DEPLOYDASH_E2E_CRASH_BEFORE_FINISH') ||
    _environmentFlag('DEPLOYDASH_E2E_CRASH_BEFORE_FINISH');
final bool _crashMidSetupE2e =
    const bool.fromEnvironment('DEPLOYDASH_E2E_CRASH_MID_SETUP') ||
    _environmentFlag('DEPLOYDASH_E2E_CRASH_MID_SETUP');
const String _productionSafetyScenarioRequest = String.fromEnvironment(
  'DEPLOYDASH_E2E_SCENARIO',
);
const String _workerSchedulerRuntimeProject = String.fromEnvironment(
  'DEPLOYDASH_E2E_WORKER_SCHEDULER_PROJECT',
);
const String _e2eScreenshotDirectory = String.fromEnvironment(
  'DEPLOYDASH_E2E_SCREENSHOT_DIR',
);
const String _vmHost = String.fromEnvironment('DEPLOYDASH_E2E_VM_HOST');
const String _vmName = String.fromEnvironment('DEPLOYDASH_E2E_VM_NAME');
const String _multipassBin = String.fromEnvironment(
  'DEPLOYDASH_E2E_MULTIPASS_BIN',
  defaultValue: 'multipass',
);
const String _vmUser = String.fromEnvironment(
  'DEPLOYDASH_E2E_VM_USER',
  defaultValue: 'ubuntu',
);
const int _vmPort = int.fromEnvironment(
  'DEPLOYDASH_E2E_VM_PORT',
  defaultValue: 22,
);
// Transport for in-test target access: `multipass` (default, `multipass exec`)
// or `ssh` (direct SSH for droplet-equivalent targets such as port-forwarded
// Multipass VMs and DigitalOcean droplets).
const String _e2eSshTransport = String.fromEnvironment(
  'DEPLOYDASH_E2E_SSH_TRANSPORT',
  defaultValue: 'multipass',
);
// SSH user for harness shell verification in ssh transport mode. Defaults to
// the app-flow user, but post-takeover only a non-managed account (whose keys
// onboarding never touches) can still connect, so DO runs use an auditor.
const String _e2eSshVerifyUser = String.fromEnvironment(
  'DEPLOYDASH_E2E_SSH_VERIFY_USER',
  defaultValue: '',
);
// Base64-encoded SSH private key material for ssh-transport verification.
// Delivered as a define (compiled in) because the sandboxed test host cannot
// open key files from shared locations; the driver writes it into the
// app-data directory it owns before invoking ssh.
const String _e2eSshKeyMaterialB64 = String.fromEnvironment(
  'DEPLOYDASH_E2E_SSH_KEY_MATERIAL_B64',
  defaultValue: '',
);
const String _vmPassword = String.fromEnvironment(
  'DEPLOYDASH_E2E_VM_PASSWORD',
  defaultValue: 'test1234',
);
const String _databasePassphrase = String.fromEnvironment(
  'DEPLOYDASH_E2E_DB_PASSPHRASE',
  defaultValue: 'aaaaaaaaaaaa',
);
const String _rotatedDatabasePassphrase = String.fromEnvironment(
  'DEPLOYDASH_E2E_ROTATED_DB_PASSPHRASE',
  defaultValue: 'bbbbbbbbbbbb',
);
const String _githubRepositoryFullName = String.fromEnvironment(
  'DEPLOYDASH_E2E_GITHUB_REPOSITORY',
  defaultValue: 'deploydash-test/laravel-example-app',
);
const String _localDatabaseBackupPath = String.fromEnvironment(
  'DEPLOYDASH_E2E_LOCAL_DATABASE_BACKUP_PATH',
);

final List<E2eRunResult> _runResults = <E2eRunResult>[];

/// Fresh isolated profile directory for slim macOS runs (see setUpAll).
Directory? _slimE2eProfileDir;

bool _environmentFlag(String name) {
  final value = Platform.environment[name]?.trim().toLowerCase();
  return value == '1' || value == 'true';
}
