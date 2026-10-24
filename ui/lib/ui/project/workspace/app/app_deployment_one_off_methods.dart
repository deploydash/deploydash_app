// ignore_for_file: invalid_use_of_protected_member

part of '../../project_workspace.dart';

extension _AppDeploymentOneOffMethods on _AppDeploymentSummaryState {
  Future<void> _runOneOffCommand({
    required Project project,
    required String branch,
    required int appPort,
    required String? selectedRepository,
    required String domain,
  }) async {
    final selectedServer = ref.read(selectedServerProvider);
    if (selectedServer == null) {
      _showCopiedSnack('No active server selected.');
      return;
    }
    final connection = await buildAppDeploymentConnectionPayload(
      ref.read(serverConnectionPayloadResolverProvider),
      selectedServer,
    );
    if (connection == null) {
      _showCopiedSnack('Selected server credentials are incomplete.');
      return;
    }

    final projectId = project.id;
    final command = _oneOffCommandController.text.trim();
    if (command.isEmpty) {
      setState(() {
        _oneOffCommandStatusByProject[projectId] =
            'Enter a command to run inside the app container.';
      });
      return;
    }
    final timeoutText = _oneOffCommandTimeoutController.text.trim();
    final timeoutSeconds = int.tryParse(timeoutText);
    if (timeoutSeconds == null || timeoutSeconds < 1 || timeoutSeconds > 3600) {
      setState(() {
        _oneOffCommandStatusByProject[projectId] =
            'Timeout must be between 1 and 3600 seconds.';
      });
      return;
    }

    final startedAt = DateTime.now();
    setState(() {
      _runtimeActionInFlightByProject[projectId] = true;
      _oneOffCommandInFlightByProject[projectId] = true;
      _oneOffCommandCancelRequestedByProject[projectId] = false;
      _oneOffCommandTaskIdByProject[projectId] = null;
      _oneOffCommandExitCodeByProject[projectId] = null;
      _oneOffCommandOutputByProject[projectId] = <String>[];
      _oneOffCommandStatusByProject[projectId] =
          'Running command inside app container...';
      _oneOffCommandDraftByProject[projectId] = command;
      _oneOffCommandTimeoutByProject[projectId] = timeoutSeconds.toString();
    });
    await _appendOneOffCommandLine(
      projectId: projectId,
      message: r'$ ' + command,
    );

    try {
      final params = {
        'dry_run': false,
        'command': command,
        'timeout_seconds': timeoutSeconds,
        'settings': await _buildWorkflowSettings(
          project: project,
          branch: branch,
          appPort: appPort,
          selectedRepository: selectedRepository,
          domain: domain,
        ),
      };
      final journaled = await _runJournaledProjectWorkflow(
        ref: ref,
        project: project,
        server: selectedServer,
        surface: 'app',
        operationType: 'exec',
        workflowId: 'app',
        operationId: 'exec',
        connection: connection,
        params: params,
        journalRequest: <String, dynamic>{
          'workflow_id': 'app',
          'operation_id': 'exec',
          'timeout_seconds': timeoutSeconds,
          'command_length': command.length,
        },
        onTaskStarted: (taskId) {
          if (!mounted) {
            return;
          }
          setState(() {
            _oneOffCommandTaskIdByProject[projectId] = taskId;
          });
        },
      );
      final response = journaled.response;
      if (!mounted) {
        return;
      }

      final completedAt = DateTime.now();
      final message = response['msg']?.toString().trim();
      final exitCode = response['exit_code'] is int
          ? response['exit_code'] as int
          : int.tryParse(response['exit_code']?.toString() ?? '');
      await _appendOneOffCommandResponseOutput(
        projectId: projectId,
        response: response,
      );
      if (response['status'] == 'success') {
        final successMessage = (message != null && message.isNotEmpty)
            ? message
            : 'Command finished successfully.';
        await _appendOneOffCommandLine(
          projectId: projectId,
          message: 'Command finished with exit code ${exitCode ?? 0}.',
        );
        setState(() {
          _oneOffCommandExitCodeByProject[projectId] = exitCode ?? 0;
          _oneOffCommandStatusByProject[projectId] = successMessage;
        });
        _recordOneOffCommandHistory(
          projectId: projectId,
          command: command,
          startedAt: startedAt,
          completedAt: completedAt,
          exitCode: exitCode ?? 0,
          status: successMessage,
        );
        await journaled.markCommitted(ref);
        _reportTerminalCommand(DataOperationOutcome.success);
      } else {
        final code = response['code']?.toString();
        final failureMessage = (message != null && message.isNotEmpty)
            ? message
            : 'Command failed.';
        final resolvedStatus =
            code == 'ENGINE_TASK_CANCELLED' ||
                code == 'ENGINE_TASK_CANCELLED_FORCED'
            ? 'Command cancelled.'
            : failureMessage;
        await _appendOneOffCommandLine(
          projectId: projectId,
          message: resolvedStatus,
        );
        setState(() {
          _oneOffCommandExitCodeByProject[projectId] = exitCode;
          _oneOffCommandStatusByProject[projectId] = resolvedStatus;
        });
        _recordOneOffCommandHistory(
          projectId: projectId,
          command: command,
          startedAt: startedAt,
          completedAt: completedAt,
          exitCode: exitCode,
          status: resolvedStatus,
        );
        _reportTerminalCommand(DataOperationOutcome.failure);
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      final failureMessage = 'Command failed: $error';
      await _appendOneOffCommandLine(
        projectId: projectId,
        message: failureMessage,
      );
      setState(() {
        _oneOffCommandStatusByProject[projectId] = failureMessage;
      });
      _recordOneOffCommandHistory(
        projectId: projectId,
        command: command,
        startedAt: startedAt,
        completedAt: DateTime.now(),
        status: failureMessage,
      );
      _reportTerminalCommand(DataOperationOutcome.failure);
    } finally {
      if (mounted) {
        setState(() {
          _runtimeActionInFlightByProject[projectId] = false;
          _oneOffCommandInFlightByProject[projectId] = false;
          _oneOffCommandCancelRequestedByProject[projectId] = false;
        });
        await _refreshResourceUsage(
          project: project,
          branch: branch,
          appPort: appPort,
          selectedRepository: selectedRepository,
          domain: domain,
          markRequested: false,
        );
      }
    }
  }

  // coverage-gate: terminal_command_analytics
  /// Reports one terminal one-off command resolving. One owner for the report
  /// shape: the success, engine-failure, and thrown-error paths above differ
  /// only in outcome. The command text never leaves the device.
  void _reportTerminalCommand(DataOperationOutcome outcome) {
    ref
        .read(appAnalyticsServiceProvider)
        .trackTerminalCommand(outcome: outcome);
  }
  // end coverage-gate

  Future<void> _cancelOneOffCommand(Project project) async {
    final projectId = project.id;
    final taskId = _oneOffCommandTaskIdByProject[projectId];
    if (taskId == null) {
      return;
    }
    setState(() {
      _oneOffCommandCancelRequestedByProject[projectId] = true;
      _oneOffCommandStatusByProject[projectId] = 'Cancellation requested...';
    });
    final cancellation = await ref.read(sshServiceProvider).cancelTask(taskId);
    final cancelled = switch (cancellation) {
      Ok<bool>(:final value) => value,
      Err<bool>() => false,
    };
    if (!mounted) {
      return;
    }
    if (!cancelled) {
      setState(() {
        _oneOffCommandCancelRequestedByProject[projectId] = false;
        _oneOffCommandStatusByProject[projectId] =
            'Could not cancel the running command.';
      });
    }
  }
}
