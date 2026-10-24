import 'package:flutter/material.dart';
import 'package:ui/services/concurrency_engine.dart';
import 'package:ui/ui/system/operation_state_presentation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yaru/yaru.dart';

// D-57 (T-015) characterization: the queue-state label table (all 9 arms,
// byte-identical strings) + the orange-parameterized color resolver (all 9
// arms x both orange variants + theme-derived arms against a fixed theme).
void main() {
  test('operationStateLabel renders all nine states', () {
    const labels = <OperationQueueState, String>{
      OperationQueueState.queued: 'Queued',
      OperationQueueState.dispatching: 'Dispatching',
      OperationQueueState.running: 'Running',
      OperationQueueState.cancelling: 'Cancelling',
      OperationQueueState.succeeded: 'Succeeded',
      OperationQueueState.failed: 'Failed',
      OperationQueueState.cancelled: 'Cancelled',
      OperationQueueState.rejected: 'Rejected',
      OperationQueueState.deduped: 'Deduped',
    };
    for (final entry in labels.entries) {
      expect(operationStateLabel(entry.key), entry.value);
    }
  });

  test('operationStateColor keeps the Yaru/Material orange split', () {
    final theme = ThemeData.light();
    for (final orange in [YaruColors.orange, Colors.orange]) {
      for (final state in [
        OperationQueueState.queued,
        OperationQueueState.cancelling,
        OperationQueueState.cancelled,
      ]) {
        expect(
          operationStateColor(state, orange: orange, theme: theme),
          orange,
        );
      }
    }
  });

  test('operationStateColor resolves green + theme arms', () {
    final theme = ThemeData(
      colorScheme: ColorScheme.light(
        primary: Color(0xff112233),
        error: Color(0xff445566),
      ),
    );
    for (final state in [
      OperationQueueState.running,
      OperationQueueState.succeeded,
    ]) {
      expect(
        operationStateColor(state, orange: Colors.orange, theme: theme),
        Colors.green,
      );
    }
    for (final state in [
      OperationQueueState.dispatching,
      OperationQueueState.deduped,
    ]) {
      expect(
        operationStateColor(state, orange: Colors.orange, theme: theme),
        const Color(0xff112233),
      );
    }
    for (final state in [
      OperationQueueState.failed,
      OperationQueueState.rejected,
    ]) {
      expect(
        operationStateColor(state, orange: Colors.orange, theme: theme),
        const Color(0xff445566),
      );
    }
  });
}
