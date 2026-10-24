import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import '../utils/payload_codecs.dart';
import 'sensitive_data_sanitizer.dart';

/// Lock mode applied to a resource claim.
enum OperationLockMode {
  /// Shared. Any number of readers may hold a resource at once; only a writer
  /// excludes them.
  read,

  /// Exclusive. Excludes every other holder, reader or writer.
  write,
}

/// Runtime state tracked by the operation scheduler.
///
/// The five terminal states are distinguished because each says something
/// different about the customer's server: [succeeded] and [failed] describe
/// work that ran, [cancelled] work that was stopped, and [rejected] and
/// [deduped] work that never started at all.
enum OperationQueueState {
  /// Waiting for a conflicting operation to finish.
  queued,

  /// Cleared to run; the engine task has not started yet.
  dispatching,

  /// Running on an engine task.
  running,

  /// Cancellation requested; still running until the task stops.
  cancelling,

  /// Finished successfully.
  succeeded,

  /// Finished with an error.
  failed,

  /// Stopped at the user's request.
  cancelled,

  /// Refused before scheduling, because the request itself was not valid.
  rejected,

  /// Recognised as identical to one already queued or running, so not run
  /// twice.
  deduped,
}

/// Admission decision returned by the scheduler.
enum OperationScheduleDecisionType {
  /// Cleared to run immediately.
  accepted,

  /// Held until conflicting resources free up.
  queued,

  /// Refused, and will not run.
  rejected,

  /// Already in flight as another operation; treated as a success, since the
  /// work the caller wanted is happening.
  deduped,
}

/// Terminal state used to close an operation permit.
enum OperationCompletionState {
  /// The operation did what it was asked to.
  success,

  /// It did not.
  failure,

  /// It stopped at the user's request. Never reported as a failure.
  cancelled,
}

/// Reserved for scheduler v2 extensions.
///
/// Read by the priority orderings below, but nothing currently submits an
/// operation as anything other than [normal], so the default FIFO policy makes
/// it inert today.
enum OperationPriority {
  /// Ahead of normal work under a priority ordering.
  high,

  /// The default.
  normal,

  /// Behind normal work under a priority ordering.
  low,
}

/// Queue ordering policy for pending operations.
enum OperationQueueOrdering {
  /// Strictly first in, first out. The shipped default: predictable, and it
  /// cannot starve anything.
  fifo,

  /// Higher priority first, FIFO within a priority.
  priorityFifo,

  /// Priority first, but a long-waiting operation climbs over time, so a low
  /// priority one cannot be starved indefinitely.
  priorityAging,
}

/// Operation class used by preemption policies.
enum OperationPreemptibleClass {
  /// Reads nothing but state; interrupting it changes nothing on the server.
  readOnly,

  /// Mutates, but can be stopped at a safe point.
  safeMutating,

  /// Mutates, and must not be interrupted. The default for anything
  /// unclassified -- assuming a half-finished operation is safe to abandon is
  /// the assumption that damages a customer's server.
  mutating,
}

/// Reserved for future preemption controls.
enum OperationPreemptionMode {
  /// Never preempt. The shipped setting: a queued operation waits.
  none,

  /// Ask a running operation to yield at its next safe point.
  cooperative,

  /// Stop a running operation immediately.
  hard,
}

/// How the scheduler orders, ages and warns about queued work.
///
/// One value with conservative defaults rather than a set of knobs: the
/// shipped configuration is FIFO with no preemption, and the other options
/// exist so the policy can change in one place when there is evidence it
/// should.
class OperationSchedulerPolicy {
  /// Creates a policy. The defaults are what ships.
  const OperationSchedulerPolicy({
    this.queueOrdering = OperationQueueOrdering.fifo,
    this.preemptionMode = OperationPreemptionMode.none,
    this.staleTimeout = const Duration(minutes: 20),
    this.queueDepthWarningThreshold = 8,
    this.queueWaitWarningThreshold = const Duration(minutes: 5),
    this.priorityAgingQuantum = const Duration(minutes: 2),
  });

  /// How pending operations are ordered.
  final OperationQueueOrdering queueOrdering;

  /// Whether a running operation can be displaced.
  final OperationPreemptionMode preemptionMode;

  /// How long without progress before an operation is flagged stale.
  ///
  /// Stale means "needs a human", not "failed": provisioning legitimately goes
  /// quiet for minutes, so the scheduler surfaces the silence rather than
  /// acting on it.
  final Duration staleTimeout;

  /// Queue length at which the depth warning is raised.
  final int queueDepthWarningThreshold;

  /// Wait time at which the queue-wait warning is raised.
  final Duration queueWaitWarningThreshold;

  /// How much waiting buys one step of priority under
  /// [OperationQueueOrdering.priorityAging].
  final Duration priorityAgingQuantum;
}

/// One thing an operation needs exclusive or shared use of.
///
/// Deliberately three parts rather than one string: `kind` says what sort of
/// thing (`host`, `stack`, `project`, `firewall`, `scheduler`, `backup`),
/// `scope` says which one, and `id` says which aspect of it. That is what
/// lets a Postgres read and an HTTP deploy on the same host proceed together
/// while two deploys do not.
class OperationResourceRef {
  /// Names one resource.
  const OperationResourceRef({
    required this.kind,
    required this.scope,
    required this.id,
  });

  /// What sort of resource this is.
  final String kind;

  /// Which one -- a host key, a project id, a policy id.
  final String scope;

  /// Which aspect of it.
  final String id;

  /// The three parts as the string locks are actually keyed by.
  String get key => '${kind.trim()}:${scope.trim()}:${id.trim()}';

  /// This reference as a map, for the persisted queue and the audit trail.
  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'kind': kind,
      'scope': scope,
      'id': id,
      'key': key,
    };
  }

  /// Reads a persisted reference, defaulting each missing part to `unknown`.
  ///
  /// A recovered claim with an unknown part still keys consistently, so it
  /// blocks nothing real -- which is the right outcome for a queue entry whose
  /// meaning did not survive a restart.
  static OperationResourceRef fromMap(Map<String, dynamic> value) {
    return OperationResourceRef(
      kind: value['kind']?.toString() ?? 'unknown',
      scope: value['scope']?.toString() ?? 'unknown',
      id: value['id']?.toString() ?? 'unknown',
    );
  }
}

/// A resource an operation intends to hold, and how.
class OperationResourceClaim {
  /// Creates a claim on [resource] in [mode].
  const OperationResourceClaim({
    required this.resource,
    required this.mode,
    this.reason,
  });

  /// What is being claimed.
  final OperationResourceRef resource;

  /// Shared or exclusive.
  final OperationLockMode mode;

  /// Why this operation needs it, in words. Carried into the audit trail so a
  /// blocked queue can be explained without reading this file.
  final String? reason;

  /// This claim as a map, for the persisted queue and the audit trail.
  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'resource': resource.toMap(),
      'mode': mode.name,
      if (reason != null) 'reason': reason,
    };
  }

  /// Reads a persisted claim.
  ///
  /// An unreadable mode is restored as [OperationLockMode.write], the
  /// stricter of the two: over-serializing costs a wait, under-serializing
  /// costs a concurrent write to a customer's server.
  static OperationResourceClaim fromMap(Map<String, dynamic> value) {
    final resourceValue = value['resource'];
    // D-58 (T-014): left — the Map<String, dynamic> fast-path aliases the
    // source instance where mapFrom would copy; same contract as _extractMap.
    final resourceMap = resourceValue is Map<String, dynamic>
        ? resourceValue
        : resourceValue is Map
        ? resourceValue.map((key, value) => MapEntry(key.toString(), value))
        : const <String, dynamic>{};
    final modeText = value['mode']?.toString() ?? OperationLockMode.write.name;
    return OperationResourceClaim(
      resource: OperationResourceRef.fromMap(resourceMap),
      mode: modeText == OperationLockMode.read.name
          ? OperationLockMode.read
          : OperationLockMode.write,
      reason: value['reason']?.toString(),
    );
  }
}

/// Everything the scheduler needs to know about one operation.
///
/// Derived from the request payload by [OperationClaimRegistry.buildDescriptor]
/// rather than supplied by callers, so what an operation conflicts with is
/// decided in one place from what it actually is -- not from what whoever
/// added the feature remembered to declare.
class OperationDescriptor {
  /// Creates a descriptor. Obtain one from
  /// [OperationClaimRegistry.buildDescriptor].
  const OperationDescriptor({
    required this.operationInstanceId,
    required this.operationType,
    required this.idempotencyKey,
    required this.claims,
    required this.metadata,
    this.workflowId,
    this.workflowOperationId,
    this.hostKey,
    this.priority = OperationPriority.normal,
    this.preemptibleClass = OperationPreemptibleClass.mutating,
    this.supportsCooperativeCancel = false,
    this.preconditionErrors = const <String>[],
  });

  /// This attempt's unique id. New for every submission, including a retry of
  /// identical work.
  final String operationInstanceId;

  /// What kind of operation this is, as `workflow/operation`. The key failure
  /// counts are grouped by.
  final String operationType;

  /// A canonical hash of what was asked for.
  ///
  /// Two submissions with the same key are the same request, which is what
  /// [OperationScheduleDecisionType.deduped] is decided on -- a double-clicked
  /// deploy button must not deploy twice.
  final String idempotencyKey;

  /// Which workflow, when this is a workflow request.
  final String? workflowId;

  /// Which operation within it.
  final String? workflowOperationId;

  /// The server this acts on, normalized. Null for operations that reach no
  /// server.
  final String? hostKey;

  /// Scheduling priority. Inert under the shipped FIFO ordering.
  final OperationPriority priority;

  /// Whether this operation could be displaced, if preemption were enabled.
  final OperationPreemptibleClass preemptibleClass;

  /// Whether the engine side can stop this at a safe point.
  final bool supportsCooperativeCancel;

  /// Every resource this operation needs, and how.
  final List<OperationResourceClaim> claims;

  /// Why this request cannot be scheduled at all. Empty when it can.
  ///
  /// Checked *before* anything else, so a malformed request is refused rather
  /// than queued -- a request missing its host key would otherwise serialize
  /// against nothing and run beside the operation it should have waited for.
  final List<String> preconditionErrors;

  /// Descriptive detail carried into snapshots and the audit trail.
  final Map<String, dynamic> metadata;

  /// Whether this request must be rejected outright.
  bool get hasPreconditionErrors => preconditionErrors.isNotEmpty;
}

/// What would happen if an operation were scheduled right now, without
/// scheduling it.
///
/// Lets a screen say "a deploy is already running on this server" before the
/// user commits, instead of after. Claims nothing, so calling it changes
/// nothing.
class OperationConflictEvaluation {
  /// Records one evaluation.
  const OperationConflictEvaluation({
    required this.isBlocked,
    required this.message,
    this.blockingOperationIds = const <String>[],
    this.blockingResources = const <String>[],
  });

  /// Whether it would have to wait, or be refused outright.
  final bool isBlocked;

  /// Why, in one sentence.
  final String message;

  /// Which operations are in the way.
  final List<String> blockingOperationIds;

  /// Which resource keys they hold.
  final List<String> blockingResources;

  /// This evaluation as a map, for callers that pass it across a boundary.
  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'is_blocked': isBlocked,
      'message': message,
      if (blockingOperationIds.isNotEmpty)
        'blocking_operation_ids': blockingOperationIds,
      if (blockingResources.isNotEmpty) 'blocking_resources': blockingResources,
    };
  }
}

/// What the scheduler did with a submitted operation.
///
/// Emitted as the first event of every operation stream, so a wait is visible
/// as a wait. Silently queueing is how a user concludes the app is broken and
/// clicks again.
class OperationScheduleDecision {
  /// Records one admission decision.
  const OperationScheduleDecision({
    required this.type,
    required this.message,
    this.queuePosition,
    this.blockingOperationIds = const <String>[],
    this.blockingResources = const <String>[],
    this.duplicateOfOperationId,
  });

  /// What was decided.
  final OperationScheduleDecisionType type;

  /// The decision in one sentence.
  final String message;

  /// Place in the queue, when queued. 1-based.
  final int? queuePosition;

  /// Which operations are in the way, when queued.
  final List<String> blockingOperationIds;

  /// Which resource keys they hold, when queued.
  final List<String> blockingResources;

  /// The operation this one duplicates, when deduped. What the caller should
  /// follow instead.
  final String? duplicateOfOperationId;

  /// This decision as a map, for the event stream and the audit trail.
  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'type': type.name,
      'message': message,
      if (queuePosition != null) 'queue_position': queuePosition,
      if (blockingOperationIds.isNotEmpty)
        'blocking_operation_ids': blockingOperationIds,
      if (blockingResources.isNotEmpty) 'blocking_resources': blockingResources,
      if (duplicateOfOperationId != null)
        'duplicate_of_operation_id': duplicateOfOperationId,
    };
  }
}

/// One scheduler decision, recorded in order.
///
/// The trail that explains why an operation waited, was refused, was
/// deduplicated, or went stale -- questions that are unanswerable after the
/// fact from state alone, because state only shows where things ended up.
class OperationAuditEvent {
  /// Records one scheduler event.
  const OperationAuditEvent({
    required this.sequence,
    required this.timestamp,
    required this.eventType,
    required this.operationInstanceId,
    required this.message,
    required this.data,
  });

  /// Monotonic counter, so events can be ordered even when timestamps tie.
  final int sequence;

  /// When it happened, in UTC.
  final DateTime timestamp;

  /// What happened, e.g. `operation_queued`, `operation_marked_stale`.
  final String eventType;

  /// Which operation it concerns, or `scheduler` for queue-wide warnings.
  final String operationInstanceId;

  /// The event in one sentence.
  final String message;

  /// Structured detail for this event type.
  final Map<String, dynamic> data;

  /// This event as a map.
  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'sequence': sequence,
      'timestamp': timestamp.toIso8601String(),
      'event_type': eventType,
      'operation_instance_id': operationInstanceId,
      'message': message,
      'data': data,
    };
  }
}

/// Counters and averages describing how the scheduler is behaving.
///
/// Cumulative for the life of the engine, not a window. Read by diagnostics
/// and by the queue-warning UI; nothing schedules on them.
class OperationSchedulerMetricsSnapshot {
  /// Records one set of readings.
  const OperationSchedulerMetricsSnapshot({
    required this.submitted,
    required this.accepted,
    required this.queued,
    required this.rejected,
    required this.deduped,
    required this.running,
    required this.cancelling,
    required this.completedSuccess,
    required this.completedFailure,
    required this.completedCancelled,
    required this.averageWaitMs,
    required this.averageRunMs,
    required this.averageCancelMs,
    required this.queueDepth,
    required this.stale,
    required this.oldestQueueWaitMs,
    required this.queueDepthWarning,
    required this.queueWaitWarning,
    required this.queueOrdering,
    required this.preemptionMode,
    required this.failureByOperationType,
  });

  /// All-zero readings, for a scheduler that has done nothing yet.
  factory OperationSchedulerMetricsSnapshot.empty() {
    return OperationSchedulerMetricsSnapshot(
      submitted: 0,
      accepted: 0,
      queued: 0,
      rejected: 0,
      deduped: 0,
      running: 0,
      cancelling: 0,
      completedSuccess: 0,
      completedFailure: 0,
      completedCancelled: 0,
      averageWaitMs: 0,
      averageRunMs: 0,
      averageCancelMs: 0,
      queueDepth: 0,
      stale: 0,
      oldestQueueWaitMs: 0,
      queueDepthWarning: false,
      queueWaitWarning: false,
      queueOrdering: OperationQueueOrdering.fifo.name,
      preemptionMode: OperationPreemptionMode.none.name,
      failureByOperationType: <String, int>{},
    );
  }

  /// Operations submitted, whatever became of them.
  final int submitted;

  /// Operations cleared to run. Counts a queued operation when it is finally
  /// dispatched, so [submitted] and [accepted] converge rather than matching.
  final int accepted;

  /// Times an operation had to wait.
  final int queued;

  /// Operations refused before scheduling.
  final int rejected;

  /// Operations recognised as duplicates.
  final int deduped;

  /// How many are running right now.
  final int running;

  /// How many are stopping right now.
  final int cancelling;

  /// Operations that finished successfully.
  final int completedSuccess;

  /// Operations that failed.
  final int completedFailure;

  /// Operations stopped at the user's request.
  final int completedCancelled;

  /// Mean time from submission to running.
  final int averageWaitMs;

  /// Mean time from running to finished.
  final int averageRunMs;

  /// Mean time from a cancellation request to the operation actually stopping.
  /// The measure of how cooperative cancellation really is.
  final int averageCancelMs;

  /// How many are waiting right now.
  final int queueDepth;

  /// How many have gone quiet past the policy's stale timeout.
  final int stale;

  /// How long the longest-waiting queued operation has been waiting.
  final int oldestQueueWaitMs;

  /// Whether the queue is longer than the policy's threshold.
  final bool queueDepthWarning;

  /// Whether something has waited longer than the policy's threshold.
  final bool queueWaitWarning;

  /// The active ordering policy, by name.
  final String queueOrdering;

  /// The active preemption mode, by name.
  final String preemptionMode;

  /// Failures counted by operation type, which is what identifies an operation
  /// that fails systematically rather than occasionally.
  final Map<String, int> failureByOperationType;

  /// These readings as a map.
  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'submitted': submitted,
      'accepted': accepted,
      'queued': queued,
      'rejected': rejected,
      'deduped': deduped,
      'running': running,
      'cancelling': cancelling,
      'completed_success': completedSuccess,
      'completed_failure': completedFailure,
      'completed_cancelled': completedCancelled,
      'average_wait_ms': averageWaitMs,
      'average_run_ms': averageRunMs,
      'average_cancel_ms': averageCancelMs,
      'queue_depth': queueDepth,
      'stale': stale,
      'oldest_queue_wait_ms': oldestQueueWaitMs,
      'queue_depth_warning': queueDepthWarning,
      'queue_wait_warning': queueWaitWarning,
      'queue_ordering': queueOrdering,
      'preemption_mode': preemptionMode,
      'failure_by_operation_type': failureByOperationType,
    };
  }
}

/// One operation as the UI and the recovery store see it.
///
/// The scheduler's internal state is mutable and private; this is the
/// immutable view of it. Snapshots are also what gets written to the encrypted
/// local database, so an operation in flight when the app dies is still
/// visible after a restart -- see
/// [OperationConcurrencyEngine.restoreRecoveredSnapshots] for what that
/// recovery may and may not claim.
class OperationQueueSnapshot {
  static const Object _unset = Object();

  /// Records one operation's state.
  const OperationQueueSnapshot({
    required this.operationInstanceId,
    required this.operationType,
    required this.state,
    required this.submittedAt,
    required this.claims,
    required this.metadata,
    required this.message,
    this.priority = OperationPriority.normal,
    this.workflowId,
    this.workflowOperationId,
    this.hostKey,
    this.queuePosition,
    this.taskId,
    this.startedAt,
    this.completedAt,
    this.blockingOperationIds = const <String>[],
    this.blockingResources = const <String>[],
    this.isStale = false,
    this.staleSince,
  });

  /// Which attempt this is.
  final String operationInstanceId;

  /// What kind of operation, as `workflow/operation`.
  final String operationType;

  /// Which workflow, when this is a workflow request.
  final String? workflowId;

  /// Which operation within it.
  final String? workflowOperationId;

  /// The server it acts on.
  final String? hostKey;

  /// Its scheduling priority.
  final OperationPriority priority;

  /// Where it is in its lifecycle.
  final OperationQueueState state;

  /// When it was submitted.
  final DateTime submittedAt;

  /// When it was cleared to run, or null while queued.
  final DateTime? startedAt;

  /// When it reached a terminal state, or null while live.
  final DateTime? completedAt;

  /// Its 1-based place in the queue, or null when not queued.
  final int? queuePosition;

  /// The engine task running it, once there is one.
  final int? taskId;

  /// What it claims.
  final List<OperationResourceClaim> claims;

  /// What is in its way, while queued.
  final List<String> blockingOperationIds;

  /// Which resource keys those hold.
  final List<String> blockingResources;

  /// Whether it has gone quiet past the policy's stale timeout.
  final bool isStale;

  /// When it went quiet.
  final DateTime? staleSince;

  /// The current one-line status.
  final String message;

  /// Descriptive detail from the descriptor, plus any recovery annotations.
  final Map<String, dynamic> metadata;

  /// A copy with the given fields replaced.
  ///
  /// The nullable fields use a sentinel rather than null-means-keep, because
  /// several of them genuinely need clearing: a dispatched operation has no
  /// queue position, and a recovered one has no task id.
  OperationQueueSnapshot copyWith({
    OperationQueueState? state,
    Object? startedAt = _unset,
    Object? completedAt = _unset,
    Object? queuePosition = _unset,
    Object? taskId = _unset,
    String? message,
    List<String>? blockingOperationIds,
    List<String>? blockingResources,
    OperationPriority? priority,
    bool? isStale,
    Object? staleSince = _unset,
    Map<String, dynamic>? metadata,
  }) {
    return OperationQueueSnapshot(
      operationInstanceId: operationInstanceId,
      operationType: operationType,
      workflowId: workflowId,
      workflowOperationId: workflowOperationId,
      hostKey: hostKey,
      priority: priority ?? this.priority,
      state: state ?? this.state,
      submittedAt: submittedAt,
      startedAt: startedAt == _unset ? this.startedAt : startedAt as DateTime?,
      completedAt: completedAt == _unset
          ? this.completedAt
          : completedAt as DateTime?,
      queuePosition: queuePosition == _unset
          ? this.queuePosition
          : queuePosition as int?,
      taskId: taskId == _unset ? this.taskId : taskId as int?,
      claims: claims,
      blockingOperationIds: blockingOperationIds ?? this.blockingOperationIds,
      blockingResources: blockingResources ?? this.blockingResources,
      isStale: isStale ?? this.isStale,
      staleSince: staleSince == _unset
          ? this.staleSince
          : staleSince as DateTime?,
      message: message ?? this.message,
      metadata: metadata ?? this.metadata,
    );
  }

  /// This snapshot as the map persisted in the local database.
  Map<String, dynamic> toMap() {
    // Named so the `!= null` checks promote them. Dart promotes only private
    // final fields, and these are part of the public shape.
    final startedAt = this.startedAt;
    final completedAt = this.completedAt;
    final staleSince = this.staleSince;
    return <String, dynamic>{
      'operation_instance_id': operationInstanceId,
      'operation_type': operationType,
      if (workflowId != null) 'workflow_id': workflowId,
      if (workflowOperationId != null)
        'workflow_operation_id': workflowOperationId,
      if (hostKey != null) 'host_key': hostKey,
      'priority': priority.name,
      'state': state.name,
      'submitted_at': submittedAt.toIso8601String(),
      if (startedAt != null) 'started_at': startedAt.toIso8601String(),
      if (completedAt != null) 'completed_at': completedAt.toIso8601String(),
      if (queuePosition != null) 'queue_position': queuePosition,
      if (taskId != null) 'task_id': taskId,
      'claims': claims.map((claim) => claim.toMap()).toList(growable: false),
      if (blockingOperationIds.isNotEmpty)
        'blocking_operation_ids': blockingOperationIds,
      if (blockingResources.isNotEmpty) 'blocking_resources': blockingResources,
      if (isStale) 'is_stale': true,
      if (staleSince != null) 'stale_since': staleSince.toIso8601String(),
      'message': message,
      'metadata': metadata,
    };
  }

  /// Reads a persisted snapshot back after a restart.
  ///
  /// Every field is defaulted rather than required, and an unrecognised state
  /// reads as [OperationQueueState.failed]. That direction is deliberate: a
  /// recovered entry whose state cannot be read must not appear to be running,
  /// because nothing is running -- the process that was doing it is gone.
  static OperationQueueSnapshot fromMap(Map<String, dynamic> value) {
    DateTime? parseDate(dynamic raw) {
      if (raw is! String || raw.trim().isEmpty) {
        return null;
      }
      return DateTime.tryParse(raw.trim())?.toUtc();
    }

    OperationQueueState parseState(String raw) {
      for (final candidate in OperationQueueState.values) {
        if (candidate.name == raw) {
          return candidate;
        }
      }
      return OperationQueueState.failed;
    }

    OperationPriority parsePriority(String raw) {
      for (final candidate in OperationPriority.values) {
        if (candidate.name == raw) {
          return candidate;
        }
      }
      return OperationPriority.normal;
    }

    final claimsValue = value['claims'];
    final claims = <OperationResourceClaim>[];
    if (claimsValue is List) {
      for (final item in claimsValue) {
        if (item is Map<String, dynamic>) {
          claims.add(OperationResourceClaim.fromMap(item));
          continue;
        }
        if (item is Map) {
          claims.add(OperationResourceClaim.fromMap(mapFrom(item)));
        }
      }
    }

    final metadataValue = value['metadata'];
    // D-58 (T-014): left — same aliasing fast-path as _extractMap/resourceMap.
    final metadata = metadataValue is Map<String, dynamic>
        ? metadataValue
        : metadataValue is Map
        ? metadataValue.map((key, value) => MapEntry(key.toString(), value))
        : const <String, dynamic>{};

    final blockingIdsValue = value['blocking_operation_ids'];
    final blockingIds = blockingIdsValue is List
        ? blockingIdsValue
              .map((item) => item.toString())
              .toList(growable: false)
        : const <String>[];
    final blockingResourcesValue = value['blocking_resources'];
    final blockingResources = blockingResourcesValue is List
        ? blockingResourcesValue
              .map((item) => item.toString())
              .toList(growable: false)
        : const <String>[];

    final queuePositionRaw = value['queue_position'];
    final taskIdRaw = value['task_id'];

    return OperationQueueSnapshot(
      operationInstanceId:
          value['operation_instance_id']?.toString() ?? 'recovered-unknown',
      operationType: value['operation_type']?.toString() ?? 'unknown',
      workflowId: value['workflow_id']?.toString(),
      workflowOperationId: value['workflow_operation_id']?.toString(),
      hostKey: value['host_key']?.toString(),
      priority: parsePriority(value['priority']?.toString() ?? ''),
      state: parseState(value['state']?.toString() ?? ''),
      submittedAt: parseDate(value['submitted_at']) ?? DateTime.now().toUtc(),
      startedAt: parseDate(value['started_at']),
      completedAt: parseDate(value['completed_at']),
      queuePosition: queuePositionRaw is int
          ? queuePositionRaw
          : int.tryParse(queuePositionRaw?.toString() ?? ''),
      taskId: taskIdRaw is int
          ? taskIdRaw
          : int.tryParse(taskIdRaw?.toString() ?? ''),
      claims: claims,
      blockingOperationIds: blockingIds,
      blockingResources: blockingResources,
      isStale: value['is_stale'] == true,
      staleSince: parseDate(value['stale_since']),
      message: value['message']?.toString() ?? '',
      metadata: metadata,
    );
  }
}

/// A queued operation was cancelled before it ever dispatched.
///
/// Thrown from [OperationPermit.waitUntilDispatch], and the reason `SSHService`
/// can turn a pre-dispatch cancel into [CancelledFailure] rather than an
/// error: nothing ran, so nothing failed.
class OperationQueueCancelledException implements Exception {
  /// Creates the exception with the reason given for the cancellation.
  OperationQueueCancelledException(this.message);

  /// Why it was cancelled.
  final String message;

  @override
  String toString() => message;
}

/// Permission to run one operation, and the obligation to report back.
///
/// The contract is: await [waitUntilDispatch], run the work, then call
/// [release] exactly once, on every path including a thrown one. A permit that
/// is never released holds its resource locks for the rest of the session, and
/// every later operation touching that server queues behind a ghost.
class OperationPermit {
  /// Issues a permit. Only the scheduler creates these.
  const OperationPermit({
    required this.operationInstanceId,
    required this.decision,
    required this.waitUntilDispatch,
    required this.release,
    this.noExecutionRequired = false,
  });

  /// The operation this permit is for.
  final String operationInstanceId;

  /// What the scheduler decided, including why it queued or refused.
  final OperationScheduleDecision decision;

  /// Completes when the operation may start.
  ///
  /// Already complete for an accepted operation. Completes with
  /// [OperationQueueCancelledException] if the operation is cancelled while
  /// still queued.
  final Future<void> waitUntilDispatch;

  /// Reports the outcome and frees the claims. Call exactly once.
  final void Function(OperationCompletionState state, {String? message})
  release;

  /// Whether this permit represents work that will not run at all -- a
  /// rejection or a dedup. Its [release] is a no-op, and there is nothing to
  /// await.
  final bool noExecutionRequired;
}

/// Decides what may run, what must wait, and what must not run twice.
///
/// Deploy Dash operates other people's servers, and two operations touching
/// one server at once is how a machine ends up half-configured. So every
/// request declares the resources it needs, and this engine grants them as
/// read or write locks: concurrent reads of one host are fine, a deploy and a
/// firewall change on that host are not.
///
/// Four properties are worth knowing before changing anything here:
///
/// - **Claims are acquired in a fixed order.** Every claim list is sorted by
///   resource key before locks are taken, so two operations wanting the same
///   pair cannot deadlock by taking them in opposite orders.
/// - **Identical requests deduplicate.** A second submission with the same
///   idempotency key is answered with the first's id rather than run again.
/// - **Nothing is preempted.** A queued operation waits for the running one to
///   finish, however long that is.
/// - **Silence is surfaced, not acted on.** An operation with no progress past
///   the policy's stale timeout is flagged for a human; the engine never
///   cancels or reassigns on its own.
class OperationConcurrencyEngine {
  /// Creates a scheduler.
  ///
  /// [housekeepingInterval] enables the periodic stale and warning sweep;
  /// without it those are only recomputed when something else happens, which
  /// is what a test wants.
  OperationConcurrencyEngine({
    int maxCompletedSnapshots = 80,
    OperationSchedulerPolicy policy = const OperationSchedulerPolicy(),
    Duration? housekeepingInterval,
  }) : _maxCompletedSnapshots = maxCompletedSnapshots,
       _policy = policy,
       _housekeepingInterval = housekeepingInterval {
    if (_housekeepingInterval != null &&
        _housekeepingInterval > Duration.zero) {
      _housekeepingTimer = Timer.periodic(_housekeepingInterval, (_) {
        _runHousekeepingTick();
      });
    }
  }

  final int _maxCompletedSnapshots;
  final OperationSchedulerPolicy _policy;
  final Duration? _housekeepingInterval;
  Timer? _housekeepingTimer;

  final Queue<_PendingOperation> _pending = ListQueue<_PendingOperation>();
  final Map<String, _TrackedOperation> _tracked = <String, _TrackedOperation>{};
  final Map<String, _ResourceLockState> _resourceLocks =
      <String, _ResourceLockState>{};
  final Map<String, String> _idempotencyIndex = <String, String>{};

  final StreamController<List<OperationQueueSnapshot>> _queueController =
      StreamController<List<OperationQueueSnapshot>>.broadcast();
  final StreamController<OperationSchedulerMetricsSnapshot> _metricsController =
      StreamController<OperationSchedulerMetricsSnapshot>.broadcast();
  final StreamController<OperationAuditEvent> _auditController =
      StreamController<OperationAuditEvent>.broadcast();

  int _auditSequence = 0;
  int _submitted = 0;
  int _accepted = 0;
  int _queued = 0;
  int _rejected = 0;
  int _deduped = 0;
  int _completedSuccess = 0;
  int _completedFailure = 0;
  int _completedCancelled = 0;
  int _waitSamples = 0;
  int _waitSumMs = 0;
  int _runSamples = 0;
  int _runSumMs = 0;
  int _cancelSamples = 0;
  int _cancelSumMs = 0;
  final Map<String, int> _failureByOperationType = <String, int>{};
  bool _queueDepthWarningActive = false;
  bool _queueWaitWarningActive = false;

  /// Every operation the scheduler still knows about, live and recent.
  ///
  /// Ordered by what needs attention: running first, then queued, then
  /// finished. Recomputes stale flags first, so reading it never returns a
  /// stale staleness.
  List<OperationQueueSnapshot> get queueSnapshot {
    _updateStaleFlags(DateTime.now().toUtc());
    return _buildSnapshot();
  }

  /// Scheduler counters and averages as they stand.
  OperationSchedulerMetricsSnapshot get metricsSnapshot {
    _updateStaleFlags(DateTime.now().toUtc());
    return _buildMetrics();
  }

  /// Streams the queue on every change. Also what persists it for recovery.
  Stream<List<OperationQueueSnapshot>> watchQueue() => _queueController.stream;

  /// Streams metrics on every change.
  Stream<OperationSchedulerMetricsSnapshot> watchMetrics() =>
      _metricsController.stream;

  /// Streams scheduler decisions as they are made.
  Stream<OperationAuditEvent> watchAuditEvents() => _auditController.stream;

  /// The policy in force.
  OperationSchedulerPolicy get policy => _policy;

  /// Runs the stale and warning sweep immediately.
  ///
  /// Lets a test advance that logic without waiting on a timer, and lets a
  /// caller refresh warnings on demand.
  void runHousekeepingNow() {
    _runHousekeepingTick();
  }

  /// Stops the sweep and closes the streams.
  ///
  /// Does not cancel anything running: the engine tasks are the engine's, and
  /// disposing a scheduler is not a reason to abandon a half-provisioned
  /// server.
  void dispose() {
    _housekeepingTimer?.cancel();
    _queueController.close();
    _metricsController.close();
    _auditController.close();
  }

  /// Admits an operation, returning the permit that governs it.
  ///
  /// Four outcomes, checked in this order:
  ///
  /// 1. **Rejected** -- the descriptor carries precondition errors, so the
  ///    request is not schedulable at all. Checked first, before it can claim
  ///    anything.
  /// 2. **Deduped** -- an operation with the same idempotency key is already
  ///    queued or running. Answered with that operation's id; nothing new runs.
  /// 3. **Accepted** -- every claim is free, so they are taken and the permit
  ///    is already dispatchable.
  /// 4. **Queued** -- something conflicts. The permit completes when the
  ///    blocking operations release.
  ///
  /// The returned permit must be released exactly once; see [OperationPermit].
  Future<OperationPermit> schedule(OperationDescriptor descriptor) async {
    _submitted += 1;
    final now = DateTime.now().toUtc();
    final tracked = _TrackedOperation(
      descriptor: descriptor,
      submittedAt: now,
      state: OperationQueueState.queued,
      message: 'Queued for scheduling.',
    );
    _tracked[descriptor.operationInstanceId] = tracked;

    if (descriptor.hasPreconditionErrors) {
      _rejected += 1;
      tracked
        ..state = OperationQueueState.rejected
        ..completedAt = now
        ..isStale = false
        ..staleSince = null
        ..lastProgressAt = now
        ..message = descriptor.preconditionErrors.join(' ');
      _recordAudit(
        operationInstanceId: descriptor.operationInstanceId,
        eventType: 'operation_rejected',
        message: tracked.message,
        data: <String, dynamic>{
          'operation_type': descriptor.operationType,
          'precondition_errors': descriptor.preconditionErrors,
        },
      );
      _emitState();
      return OperationPermit(
        operationInstanceId: descriptor.operationInstanceId,
        decision: OperationScheduleDecision(
          type: OperationScheduleDecisionType.rejected,
          message: tracked.message,
        ),
        waitUntilDispatch: Future<void>.value(),
        release: (_, {String? message}) {},
        noExecutionRequired: true,
      );
    }

    final duplicateOperationId = _idempotencyIndex[descriptor.idempotencyKey];
    if (duplicateOperationId != null) {
      _deduped += 1;
      tracked
        ..state = OperationQueueState.deduped
        ..completedAt = now
        ..isStale = false
        ..staleSince = null
        ..lastProgressAt = now
        ..message =
            'Duplicate operation request ignored (already queued/running).';
      _recordAudit(
        operationInstanceId: descriptor.operationInstanceId,
        eventType: 'operation_deduped',
        message: tracked.message,
        data: <String, dynamic>{
          'operation_type': descriptor.operationType,
          'duplicate_of': duplicateOperationId,
        },
      );
      _emitState();
      return OperationPermit(
        operationInstanceId: descriptor.operationInstanceId,
        decision: OperationScheduleDecision(
          type: OperationScheduleDecisionType.deduped,
          message: tracked.message,
          duplicateOfOperationId: duplicateOperationId,
        ),
        waitUntilDispatch: Future<void>.value(),
        release: (_, {String? message}) {},
        noExecutionRequired: true,
      );
    }

    _idempotencyIndex[descriptor.idempotencyKey] =
        descriptor.operationInstanceId;
    final waitingPermit = Completer<void>();
    final pending = _PendingOperation(
      descriptor: descriptor,
      permitCompleter: waitingPermit,
    );

    final blockingAnalysis = _blockingAnalysis(descriptor.claims);
    final canRunNow = _canAcquireClaims(
      descriptor.operationInstanceId,
      descriptor.claims,
    );

    OperationScheduleDecision decision;
    if (canRunNow) {
      _accepted += 1;
      _acquireClaims(descriptor.operationInstanceId, descriptor.claims);
      tracked
        ..state = OperationQueueState.dispatching
        ..startedAt = now
        ..isStale = false
        ..staleSince = null
        ..lastProgressAt = now
        ..blockingOperationIds = const <String>[]
        ..blockingResources = const <String>[]
        ..message = 'Scheduling accepted. Dispatching to engine.';
      waitingPermit.complete();
      decision = const OperationScheduleDecision(
        type: OperationScheduleDecisionType.accepted,
        message: 'Operation accepted.',
      );
      _recordAudit(
        operationInstanceId: descriptor.operationInstanceId,
        eventType: 'operation_accepted',
        message: 'Operation accepted by scheduler.',
        data: <String, dynamic>{
          'operation_type': descriptor.operationType,
          'queue_ordering': _policy.queueOrdering.name,
          'preemption_mode': _policy.preemptionMode.name,
          'preemptible_class': descriptor.preemptibleClass.name,
          'claims': descriptor.claims
              .map((claim) => claim.toMap())
              .toList(growable: false),
        },
      );
    } else {
      _queued += 1;
      final preemptionDeferred = _wouldPreemptIfEnabled(
        descriptor,
        blockingAnalysis,
      );
      tracked
        ..state = OperationQueueState.queued
        ..lastProgressAt = now
        ..message = preemptionDeferred
            ? 'Queued behind conflicting operation (preemption disabled).'
            : 'Queued behind active/conflicting operations.'
        ..blockingOperationIds = blockingAnalysis.blockingOperationIds
        ..blockingResources = blockingAnalysis.blockingResources;
      _pending.addLast(pending);
      _recalculateQueuePositions();
      final queuePosition = tracked.queuePosition;
      decision = OperationScheduleDecision(
        type: OperationScheduleDecisionType.queued,
        message: 'Operation queued due to conflicting resources.',
        queuePosition: queuePosition,
        blockingOperationIds: blockingAnalysis.blockingOperationIds,
        blockingResources: blockingAnalysis.blockingResources,
      );
      _recordAudit(
        operationInstanceId: descriptor.operationInstanceId,
        eventType: 'operation_queued',
        message: 'Operation queued by scheduler.',
        data: <String, dynamic>{
          'operation_type': descriptor.operationType,
          'queue_ordering': _policy.queueOrdering.name,
          'preemption_mode': _policy.preemptionMode.name,
          'preemptible_class': descriptor.preemptibleClass.name,
          'preemption_deferred': preemptionDeferred,
          'queue_position': queuePosition,
          'blocking_operation_ids': blockingAnalysis.blockingOperationIds,
          'blocking_resources': blockingAnalysis.blockingResources,
        },
      );
    }

    _emitState();

    return OperationPermit(
      operationInstanceId: descriptor.operationInstanceId,
      decision: decision,
      waitUntilDispatch: waitingPermit.future,
      release: (state, {String? message}) {
        complete(descriptor.operationInstanceId, state, message: message);
      },
    );
  }

  /// Cancels an operation that has not dispatched yet.
  ///
  /// False when there is nothing queued under that id -- it has already
  /// started, and cancelling it means asking the engine, not the scheduler.
  /// Frees its idempotency key so an equivalent request can be submitted
  /// again, and drains the queue in case it was blocking something.
  bool cancelQueuedOperation(String operationInstanceId, {String? reason}) {
    for (final pending in _pending.toList(growable: false)) {
      if (pending.descriptor.operationInstanceId != operationInstanceId) {
        continue;
      }
      _pending.remove(pending);
      _recalculateQueuePositions();
      final tracked = _tracked[operationInstanceId];
      final now = DateTime.now().toUtc();
      if (tracked != null) {
        tracked
          ..state = OperationQueueState.cancelled
          ..completedAt = now
          ..isStale = false
          ..staleSince = null
          ..lastProgressAt = now
          ..message = reason ?? 'Queued operation cancelled by user.'
          ..queuePosition = null;
      }
      _idempotencyIndex.remove(pending.descriptor.idempotencyKey);
      if (!pending.permitCompleter.isCompleted) {
        pending.permitCompleter.completeError(
          OperationQueueCancelledException(
            reason ?? 'Queued operation cancelled before dispatch.',
          ),
        );
      }
      _completedCancelled += 1;
      _recordAudit(
        operationInstanceId: operationInstanceId,
        eventType: 'operation_cancelled_queued',
        message: reason ?? 'Queued operation cancelled before dispatch.',
        data: <String, dynamic>{
          'operation_type': pending.descriptor.operationType,
        },
      );
      _emitState();
      _drainQueue();
      return true;
    }
    return false;
  }

  /// Records that the engine task for this operation has started.
  ///
  /// Where the wait time sample is taken -- the gap between submission and
  /// actually running, which is the number that says whether the queue is
  /// hurting anyone.
  void markRunning(String operationInstanceId, {int? taskId, String? message}) {
    final tracked = _tracked[operationInstanceId];
    if (tracked == null) {
      return;
    }
    final now = DateTime.now().toUtc();
    tracked
      ..state = OperationQueueState.running
      ..taskId = taskId
      ..startedAt = tracked.startedAt ?? now
      ..isStale = false
      ..staleSince = null
      ..lastProgressAt = now
      ..message = message ?? 'Running.'
      ..queuePosition = null;

    final waitDuration = now.difference(tracked.submittedAt);
    _waitSamples += 1;
    _waitSumMs += waitDuration.inMilliseconds;

    _recordAudit(
      operationInstanceId: operationInstanceId,
      eventType: 'operation_running',
      message: tracked.message,
      data: <String, dynamic>{
        'task_id': taskId,
        'wait_ms': waitDuration.inMilliseconds,
      },
    );
    _emitState();
  }

  /// Records that the operation is still alive, resetting its stale clock.
  ///
  /// Called for every engine event. An operation that emits nothing for the
  /// policy's stale timeout is flagged, so this is what distinguishes a long
  /// step from a hung one.
  void markProgress(String operationInstanceId, {String? message}) {
    final tracked = _tracked[operationInstanceId];
    if (tracked == null || _isTerminalState(tracked.state)) {
      return;
    }
    final now = DateTime.now().toUtc();
    tracked
      ..lastProgressAt = now
      ..isStale = false
      ..staleSince = null;
    if (message != null && message.trim().isNotEmpty) {
      tracked.message = message.trim();
    }
  }

  /// Records that cancellation was requested.
  ///
  /// Not a terminal state: the operation is still running until it stops on
  /// its own terms. Ignored once the operation has already finished, so a
  /// cancel that loses the race does not reopen a closed entry.
  void markCancelling(String operationInstanceId, {String? message}) {
    final tracked = _tracked[operationInstanceId];
    if (tracked == null) {
      return;
    }
    if (tracked.state == OperationQueueState.cancelled ||
        tracked.state == OperationQueueState.failed ||
        tracked.state == OperationQueueState.succeeded) {
      return;
    }
    final now = DateTime.now().toUtc();
    tracked
      ..state = OperationQueueState.cancelling
      ..cancelRequestedAt = now
      ..isStale = false
      ..staleSince = null
      ..lastProgressAt = now
      ..message = message ?? 'Cancellation requested.';
    _recordAudit(
      operationInstanceId: operationInstanceId,
      eventType: 'operation_cancelling',
      message: tracked.message,
      data: const <String, dynamic>{},
    );
    _emitState();
  }

  /// Closes an operation, frees its claims, and dispatches whatever was
  /// waiting.
  ///
  /// Idempotent: a second call on an already-completed operation does nothing,
  /// so a release in a `finally` after an explicit completion is harmless.
  /// Releasing claims is the important half -- it is what lets the next
  /// operation on that server run.
  void complete(
    String operationInstanceId,
    OperationCompletionState completion, {
    String? message,
  }) {
    final tracked = _tracked[operationInstanceId];
    if (tracked == null || tracked.completedAt != null) {
      return;
    }

    _releaseClaims(operationInstanceId, tracked.descriptor.claims);
    _idempotencyIndex.remove(tracked.descriptor.idempotencyKey);

    final now = DateTime.now().toUtc();
    tracked
      ..completedAt = now
      ..queuePosition = null
      ..isStale = false
      ..staleSince = null
      ..lastProgressAt = now
      ..message = message ?? _defaultCompletionMessage(completion: completion);

    final startedAt = tracked.startedAt;
    if (startedAt != null) {
      final runDuration = now.difference(startedAt);
      _runSamples += 1;
      _runSumMs += runDuration.inMilliseconds;
    }

    final cancelRequestedAt = tracked.cancelRequestedAt;
    if (cancelRequestedAt != null) {
      final cancelDuration = now.difference(cancelRequestedAt);
      _cancelSamples += 1;
      _cancelSumMs += cancelDuration.inMilliseconds;
    }

    switch (completion) {
      case OperationCompletionState.success:
        tracked.state = OperationQueueState.succeeded;
        _completedSuccess += 1;
      case OperationCompletionState.failure:
        tracked.state = OperationQueueState.failed;
        _completedFailure += 1;
        final currentFailures =
            _failureByOperationType[tracked.descriptor.operationType] ?? 0;
        _failureByOperationType[tracked.descriptor.operationType] =
            currentFailures + 1;
      case OperationCompletionState.cancelled:
        tracked.state = OperationQueueState.cancelled;
        _completedCancelled += 1;
    }

    _trimCompletedSnapshots();

    _recordAudit(
      operationInstanceId: operationInstanceId,
      eventType: 'operation_completed',
      message: tracked.message,
      data: <String, dynamic>{
        'completion_state': completion.name,
        'operation_type': tracked.descriptor.operationType,
      },
    );

    _drainQueue();
    _emitState();
  }

  /// The queue, narrowed to one server. A null or blank [hostKey] returns
  /// everything.
  List<OperationQueueSnapshot> snapshotsForHost(String? hostKey) {
    _updateStaleFlags(DateTime.now().toUtc());
    final normalizedHost = _normalizeHost(hostKey);
    if (normalizedHost == null) {
      return _buildSnapshot();
    }
    return _buildSnapshot()
        .where((snapshot) {
          final snapshotHost = _normalizeHost(snapshot.hostKey);
          return snapshotHost == normalizedHost;
        })
        .toList(growable: false);
  }

  /// Whether the operation is still in a state that can be cancelled.
  ///
  /// True while cancelling, too: a cancel that is taking a while may
  /// legitimately be asked for again.
  bool canCancelOperation(String operationInstanceId) {
    final tracked = _tracked[operationInstanceId];
    if (tracked == null) {
      return false;
    }
    return tracked.state == OperationQueueState.queued ||
        tracked.state == OperationQueueState.running ||
        tracked.state == OperationQueueState.dispatching ||
        tracked.state == OperationQueueState.cancelling;
  }

  /// Says what would happen to [descriptor] if scheduled now, without
  /// scheduling it.
  ///
  /// Claims nothing and records nothing, so a screen may call it freely.
  /// Checks the same three things [schedule] does, in the same order.
  OperationConflictEvaluation evaluateConflicts(
    OperationDescriptor descriptor,
  ) {
    if (descriptor.hasPreconditionErrors) {
      return OperationConflictEvaluation(
        isBlocked: true,
        message: descriptor.preconditionErrors.join(' '),
      );
    }

    final duplicateOperationId = _idempotencyIndex[descriptor.idempotencyKey];
    if (duplicateOperationId != null) {
      return OperationConflictEvaluation(
        isBlocked: true,
        message: 'Duplicate operation already queued or running.',
        blockingOperationIds: <String>[duplicateOperationId],
      );
    }

    final blockingAnalysis = _blockingAnalysis(descriptor.claims);
    if (blockingAnalysis.blockingOperationIds.isNotEmpty) {
      return OperationConflictEvaluation(
        isBlocked: true,
        message: 'Blocked by active conflicting operation.',
        blockingOperationIds: blockingAnalysis.blockingOperationIds,
        blockingResources: blockingAnalysis.blockingResources,
      );
    }

    return const OperationConflictEvaluation(
      isBlocked: false,
      message: 'No resource conflicts detected.',
    );
  }

  /// Reinstates queue entries persisted before an app restart.
  ///
  /// Anything that was mid-flight is restored as **failed**, annotated
  /// `recovery_uncertain`, and says so in its message. This is the honest
  /// answer and the only safe one: the process that was running it is gone,
  /// this app cannot know whether the server-side work finished, and showing
  /// it as still running would invite the user to wait for something that will
  /// never complete. Entries already terminal are restored as they were.
  ///
  /// Restored entries claim no locks -- they are history, not work.
  void restoreRecoveredSnapshots(List<OperationQueueSnapshot> snapshots) {
    for (final snapshot in snapshots) {
      final normalizedSnapshot = _normalizeRecoveredSnapshot(snapshot);
      if (_tracked.containsKey(normalizedSnapshot.operationInstanceId)) {
        continue;
      }
      final descriptor = OperationDescriptor(
        operationInstanceId: normalizedSnapshot.operationInstanceId,
        operationType: normalizedSnapshot.operationType,
        workflowId: normalizedSnapshot.workflowId,
        workflowOperationId: normalizedSnapshot.workflowOperationId,
        hostKey: normalizedSnapshot.hostKey,
        idempotencyKey:
            normalizedSnapshot.metadata['idempotency_key']?.toString() ??
            normalizedSnapshot.operationInstanceId,
        priority: normalizedSnapshot.priority,
        preemptibleClass: _parsePreemptibleClass(
          normalizedSnapshot.metadata['preemptible_class']?.toString(),
        ),
        supportsCooperativeCancel:
            normalizedSnapshot.metadata['supports_cooperative_cancel'] == true,
        claims: normalizedSnapshot.claims,
        metadata: normalizedSnapshot.metadata,
      );
      _tracked[normalizedSnapshot.operationInstanceId] =
          _TrackedOperation(
              descriptor: descriptor,
              submittedAt: normalizedSnapshot.submittedAt,
              state: normalizedSnapshot.state,
              message: normalizedSnapshot.message,
            )
            ..startedAt = normalizedSnapshot.startedAt
            ..completedAt = normalizedSnapshot.completedAt
            ..queuePosition = normalizedSnapshot.queuePosition
            ..taskId = normalizedSnapshot.taskId
            ..isStale = normalizedSnapshot.isStale
            ..staleSince = normalizedSnapshot.staleSince
            ..lastProgressAt =
                normalizedSnapshot.staleSince ??
                normalizedSnapshot.startedAt ??
                normalizedSnapshot.submittedAt
            ..blockingOperationIds = normalizedSnapshot.blockingOperationIds
            ..blockingResources = normalizedSnapshot.blockingResources;
    }
    _trimCompletedSnapshots();
    _emitState();
  }

  _BlockingAnalysis _blockingAnalysis(List<OperationResourceClaim> claims) {
    if (claims.isEmpty) {
      return const _BlockingAnalysis();
    }
    final blockingByOperation = <String, Set<String>>{};
    for (final claim in claims) {
      final lockState = _resourceLocks[claim.resource.key];
      if (lockState == null) {
        continue;
      }
      final writer = lockState.writer;
      if (claim.mode == OperationLockMode.read) {
        if (writer != null) {
          blockingByOperation
              .putIfAbsent(writer, () => <String>{})
              .add(claim.resource.key);
        }
        continue;
      }
      if (writer != null) {
        blockingByOperation
            .putIfAbsent(writer, () => <String>{})
            .add(claim.resource.key);
      }
      for (final reader in lockState.readers) {
        blockingByOperation
            .putIfAbsent(reader, () => <String>{})
            .add(claim.resource.key);
      }
    }
    if (blockingByOperation.isEmpty) {
      return const _BlockingAnalysis();
    }
    final blockingOperationIds = blockingByOperation.keys.toList(
      growable: false,
    )..sort();
    final blockingResources =
        blockingByOperation.values
            .expand((resources) => resources)
            .toSet()
            .toList(growable: false)
          ..sort();
    return _BlockingAnalysis(
      blockingOperationIds: blockingOperationIds,
      blockingResources: blockingResources,
    );
  }

  bool _wouldPreemptIfEnabled(
    OperationDescriptor incoming,
    _BlockingAnalysis blockingAnalysis,
  ) {
    if (blockingAnalysis.blockingOperationIds.isEmpty) {
      return false;
    }
    if (incoming.preemptibleClass != OperationPreemptibleClass.readOnly) {
      return false;
    }
    return _policy.preemptionMode == OperationPreemptionMode.none;
  }

  bool _canAcquireClaims(
    String operationInstanceId,
    List<OperationResourceClaim> claims,
  ) {
    for (final claim in _sortedClaims(claims)) {
      final lockState = _resourceLocks[claim.resource.key];
      if (lockState == null) {
        continue;
      }
      if (claim.mode == OperationLockMode.read) {
        final writer = lockState.writer;
        if (writer != null && writer != operationInstanceId) {
          return false;
        }
        continue;
      }

      final writer = lockState.writer;
      if (writer != null && writer != operationInstanceId) {
        return false;
      }
      if (lockState.readers.any((reader) => reader != operationInstanceId)) {
        return false;
      }
    }
    return true;
  }

  void _acquireClaims(
    String operationInstanceId,
    List<OperationResourceClaim> claims,
  ) {
    for (final claim in _sortedClaims(claims)) {
      final lockState = _resourceLocks.putIfAbsent(
        claim.resource.key,
        () => _ResourceLockState(),
      );
      if (claim.mode == OperationLockMode.read) {
        lockState.readers.add(operationInstanceId);
      } else {
        lockState.writer = operationInstanceId;
      }
    }
  }

  void _releaseClaims(
    String operationInstanceId,
    List<OperationResourceClaim> claims,
  ) {
    for (final claim in _sortedClaims(claims)) {
      final lockState = _resourceLocks[claim.resource.key];
      if (lockState == null) {
        continue;
      }
      if (lockState.writer == operationInstanceId) {
        lockState.writer = null;
      }
      lockState.readers.remove(operationInstanceId);
      if (lockState.writer == null && lockState.readers.isEmpty) {
        _resourceLocks.remove(claim.resource.key);
      }
    }
  }

  List<OperationResourceClaim> _sortedClaims(
    List<OperationResourceClaim> claims,
  ) {
    final ordered = List<OperationResourceClaim>.from(claims, growable: false);
    ordered.sort((left, right) {
      final compareResource = left.resource.key.compareTo(right.resource.key);
      if (compareResource != 0) {
        return compareResource;
      }
      final leftModeWeight = left.mode == OperationLockMode.read ? 0 : 1;
      final rightModeWeight = right.mode == OperationLockMode.read ? 0 : 1;
      return leftModeWeight.compareTo(rightModeWeight);
    });
    return ordered;
  }

  void _drainQueue() {
    while (_pending.isNotEmpty) {
      final now = DateTime.now().toUtc();
      final next = _selectDispatchCandidate(now);
      if (next == null) {
        break;
      }
      final descriptor = next.descriptor;
      final canDispatch = _canAcquireClaims(
        descriptor.operationInstanceId,
        descriptor.claims,
      );
      if (!canDispatch) {
        break;
      }

      _pending.remove(next);
      _acquireClaims(descriptor.operationInstanceId, descriptor.claims);

      final tracked = _tracked[descriptor.operationInstanceId];
      if (tracked != null) {
        tracked
          ..state = OperationQueueState.dispatching
          ..startedAt = now
          ..isStale = false
          ..staleSince = null
          ..lastProgressAt = now
          ..queuePosition = null
          ..blockingOperationIds = const <String>[]
          ..blockingResources = const <String>[]
          ..message = 'Dequeued and dispatching to engine.';
      }

      if (!next.permitCompleter.isCompleted) {
        next.permitCompleter.complete();
      }
      _accepted += 1;

      _recordAudit(
        operationInstanceId: descriptor.operationInstanceId,
        eventType: 'operation_dequeued',
        message: 'Operation dequeued and ready to run.',
        data: <String, dynamic>{'operation_type': descriptor.operationType},
      );
      _recalculateQueuePositions(now: now);
    }
  }

  void _recalculateQueuePositions({DateTime? now}) {
    final cursor = now ?? DateTime.now().toUtc();
    final inOrder = _pendingInSchedulingOrder(cursor);
    var index = 1;
    for (final pending in inOrder) {
      final tracked = _tracked[pending.descriptor.operationInstanceId];
      if (tracked == null) {
        continue;
      }
      final blocking = _blockingAnalysis(pending.descriptor.claims);
      tracked
        ..queuePosition = index
        ..lastProgressAt = cursor
        ..blockingOperationIds = blocking.blockingOperationIds
        ..blockingResources = blocking.blockingResources;
      index += 1;
    }
  }

  _PendingOperation? _selectDispatchCandidate(DateTime now) {
    if (_pending.isEmpty) {
      return null;
    }
    if (_policy.queueOrdering == OperationQueueOrdering.fifo) {
      final first = _pending.first;
      final descriptor = first.descriptor;
      final canDispatch = _canAcquireClaims(
        descriptor.operationInstanceId,
        descriptor.claims,
      );
      return canDispatch ? first : null;
    }
    for (final pending in _pendingInSchedulingOrder(now)) {
      final descriptor = pending.descriptor;
      if (_canAcquireClaims(
        descriptor.operationInstanceId,
        descriptor.claims,
      )) {
        return pending;
      }
    }
    return null;
  }

  List<_PendingOperation> _pendingInSchedulingOrder(DateTime now) {
    final ordered = _pending.toList(growable: false);
    if (_policy.queueOrdering == OperationQueueOrdering.fifo) {
      return ordered;
    }

    ordered.sort((left, right) {
      final comparePriority = _priorityWeight(
        right.descriptor.priority,
      ).compareTo(_priorityWeight(left.descriptor.priority));
      if (_policy.queueOrdering == OperationQueueOrdering.priorityFifo &&
          comparePriority != 0) {
        return comparePriority;
      }

      if (_policy.queueOrdering == OperationQueueOrdering.priorityAging) {
        final leftScore = _priorityAgingScore(left, now);
        final rightScore = _priorityAgingScore(right, now);
        final compareScore = rightScore.compareTo(leftScore);
        if (compareScore != 0) {
          return compareScore;
        }
      } else if (comparePriority != 0) {
        return comparePriority;
      }

      final leftSubmitted =
          _tracked[left.descriptor.operationInstanceId]?.submittedAt;
      final rightSubmitted =
          _tracked[right.descriptor.operationInstanceId]?.submittedAt;
      final submittedCompare = (leftSubmitted ?? now).compareTo(
        rightSubmitted ?? now,
      );
      if (submittedCompare != 0) {
        return submittedCompare;
      }
      return left.descriptor.operationInstanceId.compareTo(
        right.descriptor.operationInstanceId,
      );
    });
    return ordered;
  }

  int _priorityAgingScore(_PendingOperation pending, DateTime now) {
    final tracked = _tracked[pending.descriptor.operationInstanceId];
    final submittedAt = tracked?.submittedAt ?? now;
    final waitedFor = now.difference(submittedAt);
    final bucketMs = _policy.priorityAgingQuantum.inMilliseconds;
    final ageScore = bucketMs <= 0 ? 0 : waitedFor.inMilliseconds ~/ bucketMs;
    return (_priorityWeight(pending.descriptor.priority) * 1000) + ageScore;
  }

  int _priorityWeight(OperationPriority priority) {
    return switch (priority) {
      OperationPriority.high => 3,
      OperationPriority.normal => 2,
      OperationPriority.low => 1,
    };
  }

  OperationQueueSnapshot _normalizeRecoveredSnapshot(
    OperationQueueSnapshot snapshot,
  ) {
    if (_isTerminalState(snapshot.state)) {
      return snapshot;
    }
    final recoveredAt = DateTime.now().toUtc();
    final updatedMetadata = <String, dynamic>{
      ...snapshot.metadata,
      'recovery_uncertain': true,
      'recovered_from_state': snapshot.state.name,
      'recovered_at': recoveredAt.toIso8601String(),
    };
    return snapshot.copyWith(
      state: OperationQueueState.failed,
      completedAt: recoveredAt,
      queuePosition: null,
      taskId: null,
      isStale: false,
      staleSince: null,
      message:
          'Recovered after app restart. Previous in-flight state is unknown.',
      blockingOperationIds: const <String>[],
      blockingResources: const <String>[],
      metadata: updatedMetadata,
    );
  }

  bool _isTerminalState(OperationQueueState state) {
    return switch (state) {
      OperationQueueState.succeeded => true,
      OperationQueueState.failed => true,
      OperationQueueState.cancelled => true,
      OperationQueueState.rejected => true,
      OperationQueueState.deduped => true,
      OperationQueueState.queued => false,
      OperationQueueState.dispatching => false,
      OperationQueueState.running => false,
      OperationQueueState.cancelling => false,
    };
  }

  void _trimCompletedSnapshots() {
    // Carry the completion time the filter just established, so the sort
    // reads a value rather than asserting on a mutable field again. The
    // terminal-state test is `_isTerminalState`'s, not a second copy of its
    // five states.
    final completed = <({DateTime completedAt, _TrackedOperation operation})>[];
    for (final operation in _tracked.values) {
      final completedAt = operation.completedAt;
      if (completedAt == null || !_isTerminalState(operation.state)) {
        continue;
      }
      completed.add((completedAt: completedAt, operation: operation));
    }
    completed.sort(
      (left, right) => left.completedAt.compareTo(right.completedAt),
    );

    if (completed.length <= _maxCompletedSnapshots) {
      return;
    }

    final removeCount = completed.length - _maxCompletedSnapshots;
    for (var index = 0; index < removeCount; index += 1) {
      _tracked.remove(
        completed[index].operation.descriptor.operationInstanceId,
      );
    }
  }

  List<OperationQueueSnapshot> _buildSnapshot() {
    final snapshots =
        _tracked.values
            .map(
              (tracked) => OperationQueueSnapshot(
                operationInstanceId: tracked.descriptor.operationInstanceId,
                operationType: tracked.descriptor.operationType,
                workflowId: tracked.descriptor.workflowId,
                workflowOperationId: tracked.descriptor.workflowOperationId,
                hostKey: tracked.descriptor.hostKey,
                priority: tracked.descriptor.priority,
                state: tracked.state,
                submittedAt: tracked.submittedAt,
                startedAt: tracked.startedAt,
                completedAt: tracked.completedAt,
                queuePosition: tracked.queuePosition,
                taskId: tracked.taskId,
                claims: tracked.descriptor.claims,
                blockingOperationIds: tracked.blockingOperationIds,
                blockingResources: tracked.blockingResources,
                isStale: tracked.isStale,
                staleSince: tracked.staleSince,
                message: tracked.message,
                metadata: tracked.descriptor.metadata,
              ),
            )
            .toList(growable: false)
          ..sort((left, right) {
            final leftWeight = _queueStateWeight(left.state);
            final rightWeight = _queueStateWeight(right.state);
            final weightCompare = leftWeight.compareTo(rightWeight);
            if (weightCompare != 0) {
              return weightCompare;
            }
            final leftQueuePosition = left.queuePosition;
            final rightQueuePosition = right.queuePosition;
            if (leftQueuePosition != null && rightQueuePosition != null) {
              final queueCompare = leftQueuePosition.compareTo(
                rightQueuePosition,
              );
              if (queueCompare != 0) {
                return queueCompare;
              }
            }
            return right.submittedAt.compareTo(left.submittedAt);
          });

    return snapshots;
  }

  int _queueStateWeight(OperationQueueState state) {
    return switch (state) {
      OperationQueueState.running => 0,
      OperationQueueState.dispatching => 1,
      OperationQueueState.cancelling => 2,
      OperationQueueState.queued => 3,
      OperationQueueState.failed => 4,
      OperationQueueState.cancelled => 5,
      OperationQueueState.succeeded => 6,
      OperationQueueState.rejected => 7,
      OperationQueueState.deduped => 8,
    };
  }

  OperationSchedulerMetricsSnapshot _buildMetrics() {
    final now = DateTime.now().toUtc();
    final running = _tracked.values
        .where((tracked) => tracked.state == OperationQueueState.running)
        .length;
    final cancelling = _tracked.values
        .where((tracked) => tracked.state == OperationQueueState.cancelling)
        .length;
    final stale = _tracked.values.where((tracked) => tracked.isStale).length;
    final oldestQueueWaitMs = _oldestQueueWaitMs(now);
    final queueDepthWarning =
        _pending.length >= _policy.queueDepthWarningThreshold;
    final queueWaitWarning =
        oldestQueueWaitMs >= _policy.queueWaitWarningThreshold.inMilliseconds;

    final averageWait = _waitSamples == 0 ? 0 : _waitSumMs ~/ _waitSamples;
    final averageRun = _runSamples == 0 ? 0 : _runSumMs ~/ _runSamples;
    final averageCancel = _cancelSamples == 0
        ? 0
        : _cancelSumMs ~/ _cancelSamples;

    return OperationSchedulerMetricsSnapshot(
      submitted: _submitted,
      accepted: _accepted,
      queued: _queued,
      rejected: _rejected,
      deduped: _deduped,
      running: running,
      cancelling: cancelling,
      completedSuccess: _completedSuccess,
      completedFailure: _completedFailure,
      completedCancelled: _completedCancelled,
      averageWaitMs: averageWait,
      averageRunMs: averageRun,
      averageCancelMs: averageCancel,
      queueDepth: _pending.length,
      stale: stale,
      oldestQueueWaitMs: oldestQueueWaitMs,
      queueDepthWarning: queueDepthWarning,
      queueWaitWarning: queueWaitWarning,
      queueOrdering: _policy.queueOrdering.name,
      preemptionMode: _policy.preemptionMode.name,
      failureByOperationType: Map<String, int>.unmodifiable(
        Map<String, int>.from(_failureByOperationType),
      ),
    );
  }

  String _defaultCompletionMessage({
    required OperationCompletionState completion,
  }) {
    return switch (completion) {
      OperationCompletionState.success => 'Operation completed successfully.',
      OperationCompletionState.failure => 'Operation failed.',
      OperationCompletionState.cancelled => 'Operation cancelled.',
    };
  }

  void _recordAudit({
    required String operationInstanceId,
    required String eventType,
    required String message,
    required Map<String, dynamic> data,
  }) {
    if (_auditController.isClosed) {
      return;
    }
    final event = OperationAuditEvent(
      sequence: ++_auditSequence,
      timestamp: DateTime.now().toUtc(),
      eventType: eventType,
      operationInstanceId: operationInstanceId,
      message: message,
      data: data,
    );
    _auditController.add(event);
  }

  void _emitState() {
    if (_queueController.isClosed || _metricsController.isClosed) {
      return;
    }
    final now = DateTime.now().toUtc();
    _updateStaleFlags(now);
    _updateQueueWarningFlags(now);
    _queueController.add(_buildSnapshot());
    _metricsController.add(_buildMetrics());
  }

  void _runHousekeepingTick() {
    final now = DateTime.now().toUtc();
    final staleChanged = _updateStaleFlags(now);
    final warningChanged = _updateQueueWarningFlags(now);
    if (staleChanged || warningChanged) {
      _emitState();
    }
  }

  bool _updateStaleFlags(DateTime now) {
    var changed = false;
    for (final tracked in _tracked.values) {
      if (_isTerminalState(tracked.state)) {
        if (tracked.isStale) {
          tracked
            ..isStale = false
            ..staleSince = null;
          changed = true;
        }
        continue;
      }
      final age = now.difference(tracked.lastProgressAt);
      final shouldBeStale = age >= _policy.staleTimeout;
      if (shouldBeStale == tracked.isStale) {
        continue;
      }
      tracked.isStale = shouldBeStale;
      if (shouldBeStale) {
        tracked.staleSince = now;
        _recordAudit(
          operationInstanceId: tracked.descriptor.operationInstanceId,
          eventType: 'operation_marked_stale',
          message: 'Operation appears stale and needs manual intervention.',
          data: <String, dynamic>{
            'operation_type': tracked.descriptor.operationType,
            'stale_timeout_ms': _policy.staleTimeout.inMilliseconds,
          },
        );
      } else {
        tracked.staleSince = null;
        _recordAudit(
          operationInstanceId: tracked.descriptor.operationInstanceId,
          eventType: 'operation_stale_cleared',
          message: 'Operation no longer considered stale.',
          data: <String, dynamic>{
            'operation_type': tracked.descriptor.operationType,
          },
        );
      }
      changed = true;
    }
    return changed;
  }

  bool _updateQueueWarningFlags(DateTime now) {
    final queueDepthWarning =
        _pending.length >= _policy.queueDepthWarningThreshold;
    final queueWaitWarning =
        _oldestQueueWaitMs(now) >=
        _policy.queueWaitWarningThreshold.inMilliseconds;
    final depthChanged = queueDepthWarning != _queueDepthWarningActive;
    final waitChanged = queueWaitWarning != _queueWaitWarningActive;
    final changed = depthChanged || waitChanged;
    if (depthChanged) {
      _recordAudit(
        operationInstanceId: 'scheduler',
        eventType: queueDepthWarning
            ? 'scheduler_queue_depth_warning_on'
            : 'scheduler_queue_depth_warning_off',
        message: queueDepthWarning
            ? 'Queue depth warning threshold exceeded.'
            : 'Queue depth warning threshold cleared.',
        data: <String, dynamic>{
          'queue_depth': _pending.length,
          'threshold': _policy.queueDepthWarningThreshold,
        },
      );
    }
    if (waitChanged) {
      _recordAudit(
        operationInstanceId: 'scheduler',
        eventType: queueWaitWarning
            ? 'scheduler_queue_wait_warning_on'
            : 'scheduler_queue_wait_warning_off',
        message: queueWaitWarning
            ? 'Queue wait warning threshold exceeded.'
            : 'Queue wait warning threshold cleared.',
        data: <String, dynamic>{
          'oldest_queue_wait_ms': _oldestQueueWaitMs(now),
          'threshold_ms': _policy.queueWaitWarningThreshold.inMilliseconds,
        },
      );
    }
    _queueDepthWarningActive = queueDepthWarning;
    _queueWaitWarningActive = queueWaitWarning;
    return changed;
  }

  int _oldestQueueWaitMs(DateTime now) {
    if (_pending.isEmpty) {
      return 0;
    }
    DateTime? oldest;
    for (final pending in _pending) {
      final tracked = _tracked[pending.descriptor.operationInstanceId];
      final submittedAt = tracked?.submittedAt;
      if (submittedAt == null) {
        continue;
      }
      if (oldest == null || submittedAt.isBefore(oldest)) {
        oldest = submittedAt;
      }
    }
    if (oldest == null) {
      return 0;
    }
    return now.difference(oldest).inMilliseconds;
  }

  OperationPreemptibleClass _parsePreemptibleClass(String? raw) {
    for (final candidate in OperationPreemptibleClass.values) {
      if (candidate.name == raw) {
        return candidate;
      }
    }
    return OperationPreemptibleClass.mutating;
  }

  String? _normalizeHost(String? host) {
    final text = host?.trim().toLowerCase();
    if (text == null || text.isEmpty) {
      return null;
    }
    return text;
  }
}

/// Works out what an operation touches, from the request itself.
///
/// The single owner of "which operations conflict". It reads the payload --
/// workflow, operation, host, project, task and policy ids -- and derives the
/// claims, the idempotency key, and whether the operation is read-only.
///
/// Deriving rather than declaring is the whole point. If each feature declared
/// its own claims, a new operation would default to claiming nothing and would
/// silently run beside a deploy; here an unrecognised workflow falls through to
/// an exclusive host claim, so the unknown case over-serializes instead of
/// under-serializing.
class OperationClaimRegistry {
  const OperationClaimRegistry._();

  /// Postgres operations that never mutate server state.
  ///
  /// One set for both lock claims and preemption classification: listing the
  /// same operations in two `||` chains let them drift apart silently.
  static const _postgresReadOnlyOperations = <String>{
    'describe',
    'service_status',
    'project_list',
    'backup_artifact_list',
    'backup_backlog_report',
  };

  /// Builds the scheduler's view of one request.
  ///
  /// Read-only operations claim their resources shared, so several can run at
  /// once; everything else claims exclusive. Some claims are wider than they
  /// look on purpose -- an app deploy also takes a write lock on the host's
  /// HTTP stack, because publishing a release rewrites the gateway
  /// configuration a concurrent HTTP operation would be editing.
  ///
  /// The idempotency key is canonical JSON over the action, workflow,
  /// operation, host and sanitized params, with map keys sorted, so two
  /// requests that differ only in key order deduplicate against each other.
  ///
  /// Params are sanitized (not raw): the key is persisted in the Python
  /// task-history file and travels in the engine payload, so a secret inside
  /// settings must never enter it. Sanitizing keeps non-sensitive identity
  /// (project, policy and task ids) intact for dedup purposes.
  ///
  /// [serializePerHost] false is for operations that reach no server, such as
  /// computing a setup plan; with it true, a request that carries no host key
  /// is rejected rather than run unserialized.
  static OperationDescriptor buildDescriptor({
    required String operationInstanceId,
    required Map<String, dynamic> payload,
    required bool serializePerHost,
  }) {
    final action = _normalized(payload['action']);
    final workflowId = _normalized(payload['workflow_id']);
    final workflowOperationId = _normalized(payload['operation_id']);
    final params = _extractMap(payload['params']);
    final hostKey = _extractHostKey(payload);
    final projectId = _extractProjectId(params);
    final schedulerTaskId = _extractTextByKeys(params, const <String>[
      'task_id',
      'taskId',
      'managed_task_id',
      'managedTaskId',
    ]);
    final policyId = _extractTextByKeys(params, const <String>[
      'policy_id',
      'policyId',
      'backup_policy_id',
    ]);

    final operationType = action == 'run_workflow'
        ? '${workflowId ?? 'unknown'}/${workflowOperationId ?? 'unknown'}'
        : (action ?? 'unknown');
    final priority = _extractPriority(payload, params);

    final claims = <OperationResourceClaim>[];
    final preconditionErrors = <String>[];

    if (action == 'run_workflow') {
      if (workflowId == null || workflowOperationId == null) {
        preconditionErrors.add(
          'Workflow operation request missing workflow_id/operation_id.',
        );
      }
      if (serializePerHost && hostKey == null) {
        preconditionErrors.add(
          'Workflow operation missing connection host key.',
        );
      }
      _addWorkflowClaims(
        claims,
        hostKey: hostKey,
        workflowId: workflowId,
        workflowOperationId: workflowOperationId,
        projectId: projectId,
        schedulerTaskId: schedulerTaskId,
        policyId: policyId,
      );
    } else {
      if (serializePerHost && hostKey != null) {
        claims.add(
          _claim(
            kind: 'host',
            scope: hostKey,
            id: 'control',
            mode: OperationLockMode.write,
            reason: 'Serialize host control actions.',
          ),
        );
      }
    }

    if (claims.isEmpty && serializePerHost && hostKey != null) {
      claims.add(
        _claim(
          kind: 'host',
          scope: hostKey,
          id: 'default',
          mode: OperationLockMode.write,
          reason: 'Fallback host serialization.',
        ),
      );
    }

    final preemptibleClass = _classifyPreemptibleClass(
      action: action,
      workflowId: workflowId,
      workflowOperationId: workflowOperationId,
    );
    final supportsCooperativeCancel =
        _extractBoolByKeys(payload, const <String>[
          'supports_cooperative_cancel',
          'supportsCooperativeCancel',
          'cooperative_cancel_supported',
        ]) ??
        _extractBoolByKeys(params, const <String>[
          'supports_cooperative_cancel',
          'supportsCooperativeCancel',
        ]) ??
        false;

    final idempotencyPayload = <String, dynamic>{
      'action': action,
      'workflow_id': workflowId,
      'operation_id': workflowOperationId,
      'host_key': hostKey,
      // Sanitized, never raw: this key is persisted in the Python
      // task-history file and echoed in the engine payload, so any secret
      // inside params (passwords, keys, credentials) must not enter it.
      // sanitizeSensitiveData is the single owner of redaction shapes.
      'params': sanitizeSensitiveData(params),
      'serialize_per_host': serializePerHost,
    };

    final idempotencyKey = _canonicalJson(idempotencyPayload);
    return OperationDescriptor(
      operationInstanceId: operationInstanceId,
      operationType: operationType,
      idempotencyKey: idempotencyKey,
      workflowId: workflowId,
      workflowOperationId: workflowOperationId,
      hostKey: hostKey,
      priority: priority,
      preemptibleClass: preemptibleClass,
      supportsCooperativeCancel: supportsCooperativeCancel,
      claims: List<OperationResourceClaim>.unmodifiable(claims),
      preconditionErrors: List<String>.unmodifiable(preconditionErrors),
      metadata: <String, dynamic>{
        'action': action,
        'workflow_id': workflowId,
        'operation_id': workflowOperationId,
        'project_id': projectId,
        'priority': priority.name,
        'preemptible_class': preemptibleClass.name,
        'supports_cooperative_cancel': supportsCooperativeCancel,
        ...?schedulerTaskId == null
            ? null
            : <String, dynamic>{'scheduler_task_id': schedulerTaskId},
        ...?policyId == null
            ? null
            : <String, dynamic>{'backup_policy_id': policyId},
      },
    );
  }

  static void _addWorkflowClaims(
    List<OperationResourceClaim> claims, {
    required String? hostKey,
    required String? workflowId,
    required String? workflowOperationId,
    required String? projectId,
    required String? schedulerTaskId,
    required String? policyId,
  }) {
    if (workflowId == null || workflowOperationId == null) {
      if (hostKey != null) {
        claims.add(
          _claim(
            kind: 'host',
            scope: hostKey,
            id: 'workflow',
            mode: OperationLockMode.write,
            reason: 'Serialize unknown workflow operations.',
          ),
        );
      }
      return;
    }

    switch (workflowId) {
      case 'server':
        final read =
            workflowOperationId == 'overview_metrics' ||
            workflowOperationId == 'system_status';
        if (hostKey != null) {
          claims.add(
            _claim(
              kind: 'host',
              scope: hostKey,
              id: 'server',
              mode: read ? OperationLockMode.read : OperationLockMode.write,
              reason: 'Server workflow resource.',
            ),
          );
        }
      case 'http':
        final readOnly =
            workflowOperationId == 'describe' ||
            workflowOperationId == 'service_status';
        if (hostKey != null) {
          claims.add(
            _claim(
              kind: 'host',
              scope: hostKey,
              id: 'http',
              mode: readOnly ? OperationLockMode.read : OperationLockMode.write,
              reason: 'HTTP workflow host coordination.',
            ),
          );
          claims.add(
            _claim(
              kind: 'stack',
              scope: hostKey,
              id: 'http',
              mode: readOnly ? OperationLockMode.read : OperationLockMode.write,
              reason: 'HTTP stack access.',
            ),
          );
        }
      case 'postgres':
        final readOnly = _postgresReadOnlyOperations.contains(
          workflowOperationId,
        );
        final mode = readOnly
            ? OperationLockMode.read
            : OperationLockMode.write;
        if (hostKey != null) {
          claims.add(
            _claim(
              kind: 'host',
              scope: hostKey,
              id: 'postgres',
              mode: mode,
              reason: 'Postgres workflow host coordination.',
            ),
          );
          claims.add(
            _claim(
              kind: 'stack',
              scope: hostKey,
              id: 'postgres',
              mode: mode,
              reason: 'Postgres stack access.',
            ),
          );
        }
        if (projectId != null) {
          claims.add(
            _claim(
              kind: 'project',
              scope: projectId,
              id: 'db',
              mode: mode,
              reason: 'Project database coordination.',
            ),
          );
        }
        if (workflowOperationId.startsWith('backup_') ||
            workflowOperationId == 'restore_run_now') {
          final backupId = policyId ?? projectId ?? 'global';
          claims.add(
            _claim(
              kind: 'backup',
              scope: backupId,
              id: 'policy',
              mode: mode,
              reason: 'Backup policy coordination.',
            ),
          );
        }
      case 'app':
        final readOnly =
            workflowOperationId == 'describe' ||
            workflowOperationId == 'resource_usage' ||
            workflowOperationId == 'runtime_logs' ||
            workflowOperationId == 'workers_status';
        final mode = readOnly
            ? OperationLockMode.read
            : OperationLockMode.write;
        final appScope = projectId ?? 'global';
        claims.add(
          _claim(
            kind: 'project',
            scope: appScope,
            id: 'app',
            mode: mode,
            reason: 'Application project coordination.',
          ),
        );
        if (hostKey != null) {
          claims.add(
            _claim(
              kind: 'host',
              scope: hostKey,
              id: 'app',
              mode: mode,
              reason: 'Application host coordination.',
            ),
          );
          if (workflowOperationId == 'run' ||
              workflowOperationId == 'disconnect' ||
              workflowOperationId == 'prepare_key' ||
              workflowOperationId == 'workers_apply') {
            claims.add(
              _claim(
                kind: 'stack',
                scope: hostKey,
                id: 'http',
                mode: OperationLockMode.write,
                reason: 'App deployment touches HTTP stack.',
              ),
            );
          }
        }
      case 'firewall':
        final readOnly =
            workflowOperationId == 'describe' ||
            workflowOperationId == 'status' ||
            workflowOperationId == 'scan_open_ports';
        if (hostKey != null) {
          claims.add(
            _claim(
              kind: 'firewall',
              scope: hostKey,
              id: 'rules',
              mode: readOnly ? OperationLockMode.read : OperationLockMode.write,
              reason: 'Firewall operations on host ruleset.',
            ),
          );
        }
      case 'scheduler':
        final readOnly =
            workflowOperationId == 'describe' ||
            workflowOperationId == 'task_status';
        final mode = readOnly
            ? OperationLockMode.read
            : OperationLockMode.write;
        final schedulerScope = projectId ?? 'global';
        claims.add(
          _claim(
            kind: 'scheduler',
            scope: schedulerScope,
            id: 'project',
            mode: mode,
            reason: 'Scheduler project coordination.',
          ),
        );
        if (schedulerTaskId != null) {
          claims.add(
            _claim(
              kind: 'scheduler',
              scope: schedulerScope,
              id: 'task:$schedulerTaskId',
              mode: mode,
              reason: 'Scheduler task-level coordination.',
            ),
          );
        }
        if (hostKey != null) {
          claims.add(
            _claim(
              kind: 'host',
              scope: hostKey,
              id: 'scheduler',
              mode: mode,
              reason: 'Scheduler host coordination.',
            ),
          );
        }
      case 'dns':
        final readOnly = workflowOperationId == 'describe';
        if (hostKey != null) {
          claims.add(
            _claim(
              kind: 'host',
              scope: hostKey,
              id: 'dns',
              mode: readOnly ? OperationLockMode.read : OperationLockMode.write,
              reason: 'DNS workflow host coordination.',
            ),
          );
          claims.add(
            _claim(
              kind: 'stack',
              scope: hostKey,
              id: 'dns',
              mode: readOnly ? OperationLockMode.read : OperationLockMode.write,
              reason: 'DNS stack access.',
            ),
          );
        }
      default:
        if (hostKey != null) {
          claims.add(
            _claim(
              kind: 'host',
              scope: hostKey,
              id: workflowId,
              mode: OperationLockMode.write,
              reason: 'Workflow fallback host coordination.',
            ),
          );
        }
    }
  }

  static OperationResourceClaim _claim({
    required String kind,
    required String scope,
    required String id,
    required OperationLockMode mode,
    required String reason,
  }) {
    return OperationResourceClaim(
      resource: OperationResourceRef(kind: kind, scope: scope, id: id),
      mode: mode,
      reason: reason,
    );
  }

  static String? _extractHostKey(Map<String, dynamic> payload) {
    final connection = _extractMap(payload['connection']);
    final rootServer = _extractMap(payload['server']);
    return _firstNonEmpty(<String?>[
      _normalized(connection['ip'] ?? connection['host']),
      _normalized(payload['ip'] ?? payload['host']),
      _normalized(rootServer['ip'] ?? rootServer['host']),
    ]);
  }

  static String? _extractProjectId(Map<String, dynamic> params) {
    // Before the desktop-wide project/bucket rename (T-1.2), this list also
    // checked bucket_id/bucketId/project_bucket_id/projectBucketId. Those
    // renamed onto the same project_id/projectId text already present here,
    // producing duplicate entries; removed rather than kept duplicated.
    return _extractTextByKeys(params, const <String>[
      'project_id',
      'projectId',
    ]);
  }

  static String? _extractTextByKeys(
    Map<String, dynamic> source,
    List<String> keys,
  ) {
    for (final key in keys) {
      final value = source[key];
      final text = _normalized(value);
      if (text != null) {
        return text;
      }
    }

    for (final entry in source.entries) {
      final value = entry.value;
      if (value is Map) {
        final nested = _extractTextByKeys(mapFrom(value), keys);
        if (nested != null) {
          return nested;
        }
      }
    }
    return null;
  }

  static bool? _extractBoolByKeys(
    Map<String, dynamic> source,
    List<String> keys,
  ) {
    for (final key in keys) {
      final value = source[key];
      if (value is bool) {
        return value;
      }
      final text = _normalized(value)?.toLowerCase();
      if (text == 'true') {
        return true;
      }
      if (text == 'false') {
        return false;
      }
    }
    return null;
  }

  static OperationPriority _extractPriority(
    Map<String, dynamic> payload,
    Map<String, dynamic> params,
  ) {
    final rawPriority =
        _extractTextByKeys(payload, const <String>[
          'priority',
          'operation_priority',
          'operationPriority',
        ]) ??
        _extractTextByKeys(params, const <String>[
          'priority',
          'operation_priority',
          'operationPriority',
        ]);
    if (rawPriority == null) {
      return OperationPriority.normal;
    }
    final normalized = rawPriority.toLowerCase();
    for (final candidate in OperationPriority.values) {
      if (candidate.name == normalized) {
        return candidate;
      }
    }
    return OperationPriority.normal;
  }

  static OperationPreemptibleClass _classifyPreemptibleClass({
    required String? action,
    required String? workflowId,
    required String? workflowOperationId,
  }) {
    if (action != 'run_workflow') {
      return OperationPreemptibleClass.mutating;
    }
    if (_isReadOnlyWorkflowOperation(workflowId, workflowOperationId)) {
      return OperationPreemptibleClass.readOnly;
    }
    return OperationPreemptibleClass.mutating;
  }

  static bool _isReadOnlyWorkflowOperation(
    String? workflowId,
    String? operationId,
  ) {
    if (workflowId == null || operationId == null) {
      return false;
    }
    switch (workflowId) {
      case 'server':
        return operationId == 'overview_metrics' ||
            operationId == 'system_status' ||
            operationId == 'check';
      case 'setup':
        return operationId == 'describe';
      case 'http':
        return operationId == 'describe' || operationId == 'service_status';
      case 'postgres':
        return _postgresReadOnlyOperations.contains(operationId);
      case 'app':
        return operationId == 'describe' ||
            operationId == 'resource_usage' ||
            operationId == 'runtime_logs' ||
            operationId == 'workers_precheck' ||
            operationId == 'worker_logs' ||
            operationId == 'workers_status';
      case 'firewall':
        return operationId == 'describe' ||
            operationId == 'status' ||
            operationId == 'scan_open_ports';
      case 'scheduler':
        return operationId == 'describe' || operationId == 'task_status';
      case 'dns':
        return operationId == 'describe';
      default:
        return false;
    }
  }

  // D-58 (T-014): left — the Map<String, dynamic> fast-path returns the
  // SAME instance (callers are read-only today, but the aliasing contract
  // differs from mapFrom's always-copy); route only if the fast-path goes.
  static Map<String, dynamic> _extractMap(dynamic value) {
    if (value is Map<String, dynamic>) {
      return value;
    }
    if (value is Map) {
      return value.map((key, value) => MapEntry(key.toString(), value));
    }
    return const <String, dynamic>{};
  }

  static String? _normalized(dynamic value) {
    final text = value?.toString().trim();
    if (text == null || text.isEmpty) {
      return null;
    }
    return text;
  }

  static String? _firstNonEmpty(List<String?> values) {
    for (final value in values) {
      if (value != null && value.isNotEmpty) {
        return value.toLowerCase();
      }
    }
    return null;
  }

  static String _canonicalJson(dynamic value) {
    final canonical = _canonicalize(value);
    return jsonEncode(canonical);
  }

  static dynamic _canonicalize(dynamic value) {
    if (value is Map) {
      final map = mapFrom(value);
      final keys = map.keys.toList(growable: false)..sort();
      final result = <String, dynamic>{};
      for (final key in keys) {
        result[key] = _canonicalize(map[key]);
      }
      return result;
    }
    if (value is List) {
      return value.map(_canonicalize).toList(growable: false);
    }
    return value;
  }
}

class _PendingOperation {
  const _PendingOperation({
    required this.descriptor,
    required this.permitCompleter,
  });

  final OperationDescriptor descriptor;
  final Completer<void> permitCompleter;
}

class _TrackedOperation {
  _TrackedOperation({
    required this.descriptor,
    required this.submittedAt,
    required this.state,
    required this.message,
  }) : lastProgressAt = submittedAt;

  final OperationDescriptor descriptor;
  final DateTime submittedAt;
  OperationQueueState state;
  String message;
  DateTime? startedAt;
  DateTime? completedAt;
  DateTime? cancelRequestedAt;
  DateTime lastProgressAt;
  bool isStale = false;
  DateTime? staleSince;
  int? queuePosition;
  int? taskId;
  List<String> blockingOperationIds = const <String>[];
  List<String> blockingResources = const <String>[];
}

class _ResourceLockState {
  String? writer;
  final Set<String> readers = <String>{};
}

class _BlockingAnalysis {
  const _BlockingAnalysis({
    this.blockingOperationIds = const <String>[],
    this.blockingResources = const <String>[],
  });

  final List<String> blockingOperationIds;
  final List<String> blockingResources;
}
