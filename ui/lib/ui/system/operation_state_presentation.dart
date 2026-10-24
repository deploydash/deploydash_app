import 'package:flutter/material.dart';

import '../../services/concurrency_engine.dart';

// Queue-state presentation (D-57): one label table + one
// orange-parameterized color resolver for the operation-queue surfaces.
//
// Home note: the ticket prescribed utils/, but the layering check forbids
// utils from importing the services-layer `OperationQueueState`, and the
// services layer has no material precedent for a Color-returning owner — so
// the owners live in the shared UI layer both consumers already import.

/// The user-visible label for [state], byte-identical across surfaces.
String operationStateLabel(OperationQueueState state) {
  return switch (state) {
    OperationQueueState.queued => 'Queued',
    OperationQueueState.dispatching => 'Dispatching',
    OperationQueueState.running => 'Running',
    OperationQueueState.cancelling => 'Cancelling',
    OperationQueueState.succeeded => 'Succeeded',
    OperationQueueState.failed => 'Failed',
    OperationQueueState.cancelled => 'Cancelled',
    OperationQueueState.rejected => 'Rejected',
    OperationQueueState.deduped => 'Deduped',
  };
}

/// The status color for [state] on a surface whose warning orange is [orange].
///
/// The two queue surfaces disagree on orange (Yaru vs Material) and on where
/// the theme comes from (context vs param) — both survive as params, so each
/// caller keeps the exact colors it renders today.
Color operationStateColor(
  OperationQueueState state, {
  required Color orange,
  required ThemeData theme,
}) {
  return switch (state) {
    OperationQueueState.queued => orange,
    OperationQueueState.dispatching => theme.colorScheme.primary,
    OperationQueueState.running => Colors.green,
    OperationQueueState.cancelling => orange,
    OperationQueueState.succeeded => Colors.green,
    OperationQueueState.failed => theme.colorScheme.error,
    OperationQueueState.cancelled => orange,
    OperationQueueState.rejected => theme.colorScheme.error,
    OperationQueueState.deduped => theme.colorScheme.primary,
  };
}
