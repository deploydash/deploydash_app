import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/local/app_preferences_repository.dart';
import '../models/app_user_attribute.dart';
import '../models/result.dart';
import '../services/postgres_service_password.dart';
import '../services/project_database_settings.dart';
import '../services/sensitive_data_sanitizer.dart';
import 'telemetry_settings_provider.dart';
import 'server_list_provider.dart';
import 'server_provider.dart';

final serverOnboardingActionsProvider = Provider<ServerOnboardingActions>(
  ServerOnboardingActions.new,
);

typedef ServerStateResetter = void Function();

final serverStateResetterProvider = Provider<ServerStateResetter>(
  (ref) => ref.read(serverProvider.notifier).reset,
);

typedef PostgresServicePasswordGenerator = String Function();

final postgresServicePasswordGeneratorProvider =
    Provider<PostgresServicePasswordGenerator>(
      (ref) => generatePostgresServicePassword,
    );

typedef PostgresServiceWorkflow =
    Future<Result<Map<String, dynamic>>> Function({
      required Map<String, dynamic> connection,
      required Map<String, dynamic> settings,
      required void Function(Map<String, dynamic> event) onEvent,
    });

final postgresServiceWorkflowProvider = Provider<PostgresServiceWorkflow>((
  ref,
) {
  final sshService = ref.read(sshServiceProvider);
  return ({required connection, required settings, required onEvent}) {
    return sshService.runWorkflow(
      workflowId: 'postgres',
      operationId: 'service_enable',
      connection: connection,
      params: <String, dynamic>{'dry_run': false, 'settings': settings},
      onEvent: onEvent,
    );
  };
});

/// A terminal-safe event emitted while enabling PostgreSQL during onboarding.
class ServerOnboardingTerminalEvent {
  const ServerOnboardingTerminalEvent({
    required this.message,
    required this.source,
    required this.detail,
  });

  final String message;
  final String source;
  final bool detail;
}

typedef ServerOnboardingEventWriter =
    void Function(ServerOnboardingTerminalEvent event);

/// Owns server persistence and service-enablement workflows outside ShellPage.
class ServerOnboardingActions {
  ServerOnboardingActions(this._ref);

  final Ref _ref;

  /// Persists a checked server before provisioning starts.
  ///
  /// The record carries the bootstrap identity under `setup_in_progress`
  /// so a crash or quit mid-setup resumes against a real server instead
  /// of nothing; [completeManagedHandoff] pivots it once setup verifies.
  Future<Server> savePendingServer({
    required ServerDraft draft,
    required Map<String, dynamic> checkResult,
  }) {
    return _ref
        .read(serverCatalogProvider.notifier)
        .saveConnectedServer(
          draft: draft,
          checkResult: checkResult,
          onboardingStep: 'setup_in_progress',
          setupComplete: false,
        );
  }

  /// Rewrites the bootstrap identity of an early-saved server in place.
  ///
  /// The wizard saves once per opening and updates on every later Finish,
  /// so reprovisioning the same record never creates a duplicate.
  Future<Server> updatePendingServer({
    required String serverId,
    required ServerDraft draft,
    required Map<String, dynamic> checkResult,
  }) {
    return _ref
        .read(serverCatalogProvider.notifier)
        .updatePendingServer(
          serverId: serverId,
          draft: draft,
          checkResult: checkResult,
        );
  }

  /// Pivots an early-saved server to its verified managed identity,
  /// scrubbing the bootstrap credential it was saved with.
  Future<Server> completeManagedHandoff({
    required String serverId,
    required String sshUser,
    required ServerAuthMethod authMethod,
    String? privateKey,
    String? publicKey,
    String? managedUserPassword,
  }) {
    return _ref
        .read(serverCatalogProvider.notifier)
        .adoptManagedServerIdentity(
          serverId: serverId,
          sshUser: sshUser,
          authMethod: authMethod,
          privateKey: privateKey,
          publicKey: publicKey,
          managedUserPassword: managedUserPassword,
        );
  }

  Future<String?> removeSelectedServer() async {
    final removedName = await _ref
        .read(serverCatalogProvider.notifier)
        .removeSelectedServer();
    _ref.read(serverProvider.notifier).reset();
    return removedName;
  }

  Future<void> prepareAddServer() async {
    _ref.read(serverStateResetterProvider)();
    await _ref
        .read(serverCatalogProvider.notifier)
        .setOnboardingStep('credentials');
  }

  Future<void> selectServerIfDifferent(String serverId) async {
    if (serverId == _ref.read(serverCatalogProvider).selectedServerId) {
      return;
    }
    await _ref.read(serverCatalogProvider.notifier).selectServer(serverId);
  }

  Future<ServerPostgresConfig> completeServiceSelection({
    required bool enableEmailAccounts,
    required bool enableDomains,
    required bool enableDatabases,
    required String postgresVersion,
    required List<String> postgresExtensions,
    required ServerOnboardingEventWriter onEvent,
  }) async {
    final catalog = _ref.read(serverCatalogProvider.notifier);
    final server = _ref.read(serverCatalogProvider).selectedServer;
    if (server == null) {
      throw Exception('No server selected for service setup.');
    }

    await catalog.updateSelectedServerServices(
      enableDatabases: false,
      enableEmailAccounts: enableEmailAccounts,
      enableDomains: enableDomains,
    );

    final postgresConfig = await _persistOnboardingPostgresConfig(
      server: server,
      postgresVersion: postgresVersion,
      postgresExtensions: postgresExtensions,
      ensurePassword: enableDatabases,
    );

    if (enableDatabases) {
      await _enableDatabaseServiceFromOnboarding(
        server: server,
        config: postgresConfig,
        onEvent: onEvent,
      );
    }

    await catalog.updateSelectedServerServices(
      enableDatabases: enableDatabases,
      enableEmailAccounts: enableEmailAccounts,
      enableDomains: enableDomains,
    );
    await catalog.setOnboardingStep('connected');
    await _recordOnboardingMilestone();
    return postgresConfig;
  }

  /// Persists the onboarding milestone and stamps the setup-progress
  /// telemetry notice as shown: reaching setup completion means the notice
  /// ran its course. Best-effort: a timestamp write must never fail a setup
  /// that already succeeded.
  Future<void> _recordOnboardingMilestone() async {
    try {
      final preferences = _ref.read(appPreferencesRepositoryProvider);
      await preferences.recordAnalyticsMilestone(
        AppUserAttribute.hasCompletedOnboarding,
      );
      await preferences.markTelemetryNoticeShown();
      await _ref.read(telemetrySettingsProvider.notifier).refresh();
    } on Exception catch (error) {
      if (kDebugMode) {
        debugPrint('Onboarding milestone skipped; the setup stands: $error');
      }
    } on StateError catch (error) {
      if (kDebugMode) {
        debugPrint('Onboarding milestone skipped; the setup stands: $error');
      }
    }
  }

  Future<ServerPostgresConfig> _persistOnboardingPostgresConfig({
    required Server server,
    required String postgresVersion,
    required List<String> postgresExtensions,
    required bool ensurePassword,
  }) async {
    final version =
        ServerPostgresConfig.supportedVersions.contains(postgresVersion)
        ? postgresVersion
        : ServerPostgresConfig.defaults.postgresVersion;
    final existingPassword = server.postgresConfig.superuserPassword?.trim();
    var superuserPassword = existingPassword;
    if (ensurePassword &&
        (superuserPassword == null || superuserPassword.isEmpty)) {
      superuserPassword = _ref.read(postgresServicePasswordGeneratorProvider)();
    }
    final enabledExtensions =
        postgresExtensions
            .where(ServerPostgresConfig.supportedExtensions.contains)
            .toSet()
            .toList()
          ..sort((left, right) => left.compareTo(right));
    final normalizedConfig = ServerPostgresConfig(
      postgresVersion: version,
      superuserPassword:
          superuserPassword != null && superuserPassword.isNotEmpty
          ? superuserPassword
          : null,
      enabledExtensions: enabledExtensions,
    );
    await _ref
        .read(serverCatalogProvider.notifier)
        .updateSelectedServerPostgresConfig(normalizedConfig);
    return normalizedConfig;
  }

  Future<void> _enableDatabaseServiceFromOnboarding({
    required Server server,
    required ServerPostgresConfig config,
    required ServerOnboardingEventWriter onEvent,
  }) async {
    final connection = await _ref.read(serverConnectionPayloadResolverProvider)(
      server,
    );
    if (connection == null) {
      throw Exception(
        'Server credentials are incomplete. Update SSH authentication and '
        'retry.',
      );
    }

    onEvent(
      ServerOnboardingTerminalEvent(
        message: 'Enabling Postgres service (v${config.postgresVersion})',
        source: 'engine',
        detail: false,
      ),
    );
    final result = await _ref.read(postgresServiceWorkflowProvider)(
      connection: connection,
      settings: buildPostgresServiceSettings(config),
      onEvent: (event) => _appendOnboardingDatabaseEvent(event, onEvent),
    );

    switch (result) {
      case Err<Map<String, dynamic>>(:final failure):
        final failureMessage = switch (failure) {
          EngineFailure(:final msg) when msg.trim().isNotEmpty => msg.trim(),
          _ => 'Database service enable failed.',
        };
        final failureDetails = switch (failure) {
          EngineFailure(:final details) => details?.trim(),
          _ => null,
        };
        if (failureDetails != null && failureDetails.isNotEmpty) {
          onEvent(
            ServerOnboardingTerminalEvent(
              message: sanitizeSensitiveText(failureDetails),
              source: 'engine',
              detail: true,
            ),
          );
        }
        throw Exception(failureMessage);
      case Ok<Map<String, dynamic>>(:final value):
        final successMessage =
            value['msg']?.toString().trim().isNotEmpty == true
            ? value['msg'].toString().trim()
            : 'Database service enabled.';
        onEvent(
          ServerOnboardingTerminalEvent(
            message: sanitizeSensitiveText(successMessage),
            source: 'engine',
            detail: false,
          ),
        );
    }
  }

  void _appendOnboardingDatabaseEvent(
    Map<String, dynamic> event,
    ServerOnboardingEventWriter onEvent,
  ) {
    final message = event['message']?.toString() ?? '';
    final trimmed = sanitizeSensitiveText(message);
    if (trimmed.isEmpty) {
      return;
    }

    final type = (event['type']?.toString() ?? '').toLowerCase();
    const detailTypes = <String>{
      'pyinfra_log',
      'pyinfra_operation_stdout',
      'pyinfra_operation_stderr',
      'task_started',
      'task_finished',
    };
    onEvent(
      ServerOnboardingTerminalEvent(
        message: trimmed,
        source: type.startsWith('pyinfra') ? 'pyinfra' : 'engine',
        detail: detailTypes.contains(type),
      ),
    );
  }
}
