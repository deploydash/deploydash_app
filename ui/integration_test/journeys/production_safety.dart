part of '../e2e_checklist_test.dart';

Future<void> _runProductionSafetyScenarios(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding,
  List<E2eScenarioDefinition> scenarios,
) async {
  for (final scenario in scenarios) {
    stdout.writeln('DEPLOYDASH_E2E_PRODUCTION_SAFETY_START=${scenario.id}');
    switch (scenario.id) {
      case 'local_database_safety':
        await _runLocalDatabaseSafetyScenario(tester);
        break;
      case 'postgres_backup':
        await _runPostgresBackupScenario(tester, binding);
        break;
      case 'app_rollback':
        await _runAppRollbackScenario(tester, binding);
        break;
      case 'managed_software_rollback':
        await _runManagedSoftwareRollbackScenario(tester, binding);
        break;
      case 'firewall_recovery':
        await _runFirewallRecoveryScenario(tester, binding);
        break;
      case 'project_deletion_recovery':
        await _runProjectDeletionRecoveryScenario(tester, binding);
        break;
      case 'host_key_recovery':
        await _runHostKeyRecoveryScenario(tester, binding);
        break;
      default:
        fail('No E2E implementation exists for ${scenario.id}.');
    }
    stdout.writeln('DEPLOYDASH_E2E_PRODUCTION_SAFETY_COMPLETE=${scenario.id}');
  }
}
