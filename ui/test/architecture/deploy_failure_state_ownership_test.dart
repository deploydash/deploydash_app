import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards the four existing owners that must absorb DFH-4 without a parallel path.
void main() {
  test('deploy failure state and recovery stay with their current owners', () {
    final stateSource = File(
      'lib/providers/github_integration_state.dart',
    ).readAsStringSync();
    final providerSource = File(
      'lib/providers/github_integration_provider.dart',
    ).readAsStringSync();
    final journalSource = File(
      'lib/data/local/app_release_repository.dart',
    ).readAsStringSync();
    final terminalSource = File(
      'lib/data/local/terminal_log_repository.dart',
    ).readAsStringSync();

    expect(
      stateSource,
      contains('final DeployFailureEvidence? failureEvidence;'),
    );
    expect(
      stateSource,
      contains('final String? suggestedNextStep;'),
      reason: 'heuristic advice must stay separate from status and evidence',
    );
    expect(
      File('lib/services/app_analytics_service.dart').readAsStringSync(),
      contains('void trackDeployFailureEvidence({'),
      reason: 'failure availability has one closed, text-free analytics seam',
    );
    expect(providerSource, contains('restoreLatestDeployFailure'));
    expect(journalSource, contains('readLatestFailedJournalForOperation'));
    expect(terminalSource, contains('appendLogBatchOnce'));
    expect(
      Directory('lib/data/local')
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart'))
          .where(
            (file) =>
                file.readAsStringSync().contains('class DeployFailureEvidence'),
          ),
      isEmpty,
    );
  });
}
