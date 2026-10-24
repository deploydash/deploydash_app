import 'package:ui/services/concurrency_engine.dart';
import 'package:flutter_test/flutter_test.dart';

OperationDescriptor _descriptor({
  required String operationId,
  required String idempotencyKey,
  required List<OperationResourceClaim> claims,
  OperationPriority priority = OperationPriority.normal,
  OperationPreemptibleClass preemptibleClass =
      OperationPreemptibleClass.mutating,
}) {
  return OperationDescriptor(
    operationInstanceId: operationId,
    operationType: 'test/$operationId',
    idempotencyKey: idempotencyKey,
    priority: priority,
    preemptibleClass: preemptibleClass,
    claims: claims,
    metadata: const <String, dynamic>{},
  );
}

OperationResourceClaim _claim({required OperationLockMode mode}) {
  return OperationResourceClaim(
    resource: const OperationResourceRef(
      kind: 'stack',
      scope: 'host-1',
      id: 'postgres',
    ),
    mode: mode,
  );
}

void main() {
  test('defaults to FIFO scheduling with no preemption', () async {
    final engine = OperationConcurrencyEngine();
    expect(engine.policy.queueOrdering, OperationQueueOrdering.fifo);
    expect(engine.policy.preemptionMode, OperationPreemptionMode.none);
  });

  test('read/read claims can run concurrently', () async {
    final engine = OperationConcurrencyEngine();
    final first = await engine.schedule(
      _descriptor(
        operationId: 'read-1',
        idempotencyKey: 'read-1',
        claims: <OperationResourceClaim>[_claim(mode: OperationLockMode.read)],
      ),
    );
    await first.waitUntilDispatch;

    final secondConflict = engine.evaluateConflicts(
      _descriptor(
        operationId: 'read-2-preview',
        idempotencyKey: 'read-2',
        claims: <OperationResourceClaim>[_claim(mode: OperationLockMode.read)],
      ),
    );
    expect(secondConflict.isBlocked, isFalse);

    final second = await engine.schedule(
      _descriptor(
        operationId: 'read-2',
        idempotencyKey: 'read-2',
        claims: <OperationResourceClaim>[_claim(mode: OperationLockMode.read)],
      ),
    );
    await second.waitUntilDispatch;
    expect(second.decision.type, OperationScheduleDecisionType.accepted);

    first.release(OperationCompletionState.success);
    second.release(OperationCompletionState.success);
  });

  test(
    'write claim blocks behind active read claim with resource details',
    () async {
      final engine = OperationConcurrencyEngine();
      final reader = await engine.schedule(
        _descriptor(
          operationId: 'reader-1',
          idempotencyKey: 'reader-1',
          claims: <OperationResourceClaim>[
            _claim(mode: OperationLockMode.read),
          ],
        ),
      );
      await reader.waitUntilDispatch;

      final conflict = engine.evaluateConflicts(
        _descriptor(
          operationId: 'writer-preview',
          idempotencyKey: 'writer-1',
          claims: <OperationResourceClaim>[
            _claim(mode: OperationLockMode.write),
          ],
        ),
      );

      expect(conflict.isBlocked, isTrue);
      expect(conflict.blockingOperationIds, contains('reader-1'));
      expect(conflict.blockingResources, contains('stack:host-1:postgres'));

      final writer = await engine.schedule(
        _descriptor(
          operationId: 'writer-1',
          idempotencyKey: 'writer-1',
          claims: <OperationResourceClaim>[
            _claim(mode: OperationLockMode.write),
          ],
        ),
      );
      expect(writer.decision.type, OperationScheduleDecisionType.queued);
      expect(
        writer.decision.blockingResources,
        contains('stack:host-1:postgres'),
      );

      reader.release(OperationCompletionState.success);
      await writer.waitUntilDispatch;
      writer.release(OperationCompletionState.success);
    },
  );

  test(
    'recovered in-flight snapshots become failed with uncertain marker',
    () async {
      final engine = OperationConcurrencyEngine();
      engine.restoreRecoveredSnapshots(<OperationQueueSnapshot>[
        OperationQueueSnapshot(
          operationInstanceId: 'recovered-running-1',
          operationType: 'postgres/service_restart',
          state: OperationQueueState.running,
          submittedAt: DateTime.now().toUtc(),
          startedAt: DateTime.now().toUtc(),
          claims: <OperationResourceClaim>[
            OperationResourceClaim(
              resource: const OperationResourceRef(
                kind: 'stack',
                scope: 'host-1',
                id: 'postgres',
              ),
              mode: OperationLockMode.write,
            ),
          ],
          metadata: const <String, dynamic>{'source': 'test'},
          message: 'Running before restart.',
        ),
      ]);

      final snapshots = engine.queueSnapshot;
      expect(snapshots.length, 1);
      expect(snapshots.single.state, OperationQueueState.failed);
      expect(snapshots.single.metadata['recovery_uncertain'], isTrue);

      final permit = await engine.schedule(
        _descriptor(
          operationId: 'fresh-writer',
          idempotencyKey: 'fresh-writer',
          claims: <OperationResourceClaim>[
            _claim(mode: OperationLockMode.write),
          ],
        ),
      );
      expect(permit.decision.type, OperationScheduleDecisionType.accepted);
      permit.release(OperationCompletionState.success);
    },
  );

  test('conflict matrix blocks cross-service shared stack writes', () async {
    final engine = OperationConcurrencyEngine();
    final appDescriptor = OperationClaimRegistry.buildDescriptor(
      operationInstanceId: 'app-run-1',
      payload: <String, dynamic>{
        'action': 'run_workflow',
        'workflow_id': 'app',
        'operation_id': 'run',
        'connection': <String, dynamic>{'ip': '203.0.113.50'},
        'params': <String, dynamic>{'project_id': 'project-1'},
      },
      serializePerHost: true,
    );
    final httpDescriptor = OperationClaimRegistry.buildDescriptor(
      operationInstanceId: 'http-restart-preview',
      payload: <String, dynamic>{
        'action': 'run_workflow',
        'workflow_id': 'http',
        'operation_id': 'service_restart',
        'connection': <String, dynamic>{'ip': '203.0.113.50'},
      },
      serializePerHost: true,
    );

    final appPermit = await engine.schedule(appDescriptor);
    await appPermit.waitUntilDispatch;

    final httpConflict = engine.evaluateConflicts(httpDescriptor);
    expect(httpConflict.isBlocked, isTrue);
    expect(httpConflict.blockingResources, contains('stack:203.0.113.50:http'));

    appPermit.release(OperationCompletionState.success);
  });

  test(
    'app exec blocks behind active app deploy on same project and host',
    () async {
      final engine = OperationConcurrencyEngine();
      final runDescriptor = OperationClaimRegistry.buildDescriptor(
        operationInstanceId: 'app-run-1',
        payload: <String, dynamic>{
          'action': 'run_workflow',
          'workflow_id': 'app',
          'operation_id': 'run',
          'connection': <String, dynamic>{'ip': '203.0.113.50'},
          'params': <String, dynamic>{'project_id': 'project-1'},
        },
        serializePerHost: true,
      );
      final execDescriptor = OperationClaimRegistry.buildDescriptor(
        operationInstanceId: 'app-exec-preview',
        payload: <String, dynamic>{
          'action': 'run_workflow',
          'workflow_id': 'app',
          'operation_id': 'exec',
          'connection': <String, dynamic>{'ip': '203.0.113.50'},
          'params': <String, dynamic>{'project_id': 'project-1'},
        },
        serializePerHost: true,
      );

      final appPermit = await engine.schedule(runDescriptor);
      await appPermit.waitUntilDispatch;

      final execConflict = engine.evaluateConflicts(execDescriptor);
      expect(execConflict.isBlocked, isTrue);
      expect(execConflict.blockingResources, contains('project:project-1:app'));

      appPermit.release(OperationCompletionState.success);
    },
  );

  test(
    'app exec blocks behind active app disconnect on same project and host',
    () async {
      final engine = OperationConcurrencyEngine();
      final disconnectDescriptor = OperationClaimRegistry.buildDescriptor(
        operationInstanceId: 'app-disconnect-1',
        payload: <String, dynamic>{
          'action': 'run_workflow',
          'workflow_id': 'app',
          'operation_id': 'disconnect',
          'connection': <String, dynamic>{'ip': '203.0.113.50'},
          'params': <String, dynamic>{'project_id': 'project-1'},
        },
        serializePerHost: true,
      );
      final execDescriptor = OperationClaimRegistry.buildDescriptor(
        operationInstanceId: 'app-exec-preview-2',
        payload: <String, dynamic>{
          'action': 'run_workflow',
          'workflow_id': 'app',
          'operation_id': 'exec',
          'connection': <String, dynamic>{'ip': '203.0.113.50'},
          'params': <String, dynamic>{'project_id': 'project-1'},
        },
        serializePerHost: true,
      );

      final disconnectPermit = await engine.schedule(disconnectDescriptor);
      await disconnectPermit.waitUntilDispatch;

      final execConflict = engine.evaluateConflicts(execDescriptor);
      expect(execConflict.isBlocked, isTrue);
      expect(execConflict.blockingResources, contains('project:project-1:app'));

      disconnectPermit.release(OperationCompletionState.success);
    },
  );

  test(
    'second app exec blocks while another app exec is running for the same project',
    () async {
      final engine = OperationConcurrencyEngine();
      final firstExecDescriptor = OperationClaimRegistry.buildDescriptor(
        operationInstanceId: 'app-exec-1',
        payload: <String, dynamic>{
          'action': 'run_workflow',
          'workflow_id': 'app',
          'operation_id': 'exec',
          'connection': <String, dynamic>{'ip': '203.0.113.50'},
          'params': <String, dynamic>{'project_id': 'project-1'},
        },
        serializePerHost: true,
      );
      final secondExecDescriptor = OperationClaimRegistry.buildDescriptor(
        operationInstanceId: 'app-exec-2',
        payload: <String, dynamic>{
          'action': 'run_workflow',
          'workflow_id': 'app',
          'operation_id': 'exec',
          'connection': <String, dynamic>{'ip': '203.0.113.50'},
          'params': <String, dynamic>{'project_id': 'project-1'},
        },
        serializePerHost: true,
      );

      final firstPermit = await engine.schedule(firstExecDescriptor);
      await firstPermit.waitUntilDispatch;

      final secondConflict = engine.evaluateConflicts(secondExecDescriptor);
      expect(secondConflict.isBlocked, isTrue);

      firstPermit.release(OperationCompletionState.success);
    },
  );

  test('burst submissions preserve safe ordering under contention', () async {
    final engine = OperationConcurrencyEngine();
    final firstWriter = await engine.schedule(
      _descriptor(
        operationId: 'burst-w1',
        idempotencyKey: 'burst-w1',
        claims: <OperationResourceClaim>[_claim(mode: OperationLockMode.write)],
      ),
    );
    await firstWriter.waitUntilDispatch;

    final secondWriter = await engine.schedule(
      _descriptor(
        operationId: 'burst-w2',
        idempotencyKey: 'burst-w2',
        claims: <OperationResourceClaim>[_claim(mode: OperationLockMode.write)],
      ),
    );
    final reader = await engine.schedule(
      _descriptor(
        operationId: 'burst-r1',
        idempotencyKey: 'burst-r1',
        claims: <OperationResourceClaim>[_claim(mode: OperationLockMode.read)],
      ),
    );
    final thirdWriter = await engine.schedule(
      _descriptor(
        operationId: 'burst-w3',
        idempotencyKey: 'burst-w3',
        claims: <OperationResourceClaim>[_claim(mode: OperationLockMode.write)],
      ),
    );

    expect(secondWriter.decision.type, OperationScheduleDecisionType.queued);
    expect(reader.decision.type, OperationScheduleDecisionType.queued);
    expect(thirdWriter.decision.type, OperationScheduleDecisionType.queued);

    firstWriter.release(OperationCompletionState.success);
    await secondWriter.waitUntilDispatch;
    secondWriter.release(OperationCompletionState.success);

    await reader.waitUntilDispatch;
    reader.release(OperationCompletionState.success);

    await thirdWriter.waitUntilDispatch;
    thirdWriter.release(OperationCompletionState.success);
  });

  test(
    'audit stream emits queueing, dequeue, and completion transitions',
    () async {
      final engine = OperationConcurrencyEngine();
      final auditEvents = <OperationAuditEvent>[];
      final subscription = engine.watchAuditEvents().listen(auditEvents.add);
      addTearDown(subscription.cancel);

      final first = await engine.schedule(
        _descriptor(
          operationId: 'audit-1',
          idempotencyKey: 'audit-1',
          claims: <OperationResourceClaim>[
            _claim(mode: OperationLockMode.write),
          ],
        ),
      );
      await first.waitUntilDispatch;

      final second = await engine.schedule(
        _descriptor(
          operationId: 'audit-2',
          idempotencyKey: 'audit-2',
          claims: <OperationResourceClaim>[
            _claim(mode: OperationLockMode.write),
          ],
        ),
      );
      expect(second.decision.type, OperationScheduleDecisionType.queued);

      first.release(OperationCompletionState.success);
      await second.waitUntilDispatch;
      second.release(OperationCompletionState.failure);

      await Future<void>.delayed(const Duration(milliseconds: 10));

      final eventTypes = auditEvents.map((event) => event.eventType).toSet();
      expect(eventTypes, contains('operation_accepted'));
      expect(eventTypes, contains('operation_queued'));
      expect(eventTypes, contains('operation_dequeued'));
      expect(eventTypes, contains('operation_completed'));
    },
  );

  test(
    'FIFO policy ignores priority when dispatching queued operations',
    () async {
      final engine = OperationConcurrencyEngine(
        policy: const OperationSchedulerPolicy(
          queueOrdering: OperationQueueOrdering.fifo,
        ),
      );

      final running = await engine.schedule(
        _descriptor(
          operationId: 'fifo-running',
          idempotencyKey: 'fifo-running',
          claims: <OperationResourceClaim>[
            _claim(mode: OperationLockMode.write),
          ],
        ),
      );
      await running.waitUntilDispatch;

      final lowPriorityFirst = await engine.schedule(
        _descriptor(
          operationId: 'fifo-low',
          idempotencyKey: 'fifo-low',
          priority: OperationPriority.low,
          claims: <OperationResourceClaim>[
            _claim(mode: OperationLockMode.write),
          ],
        ),
      );
      final highPrioritySecond = await engine.schedule(
        _descriptor(
          operationId: 'fifo-high',
          idempotencyKey: 'fifo-high',
          priority: OperationPriority.high,
          claims: <OperationResourceClaim>[
            _claim(mode: OperationLockMode.write),
          ],
        ),
      );

      expect(
        lowPriorityFirst.decision.type,
        OperationScheduleDecisionType.queued,
      );
      expect(
        highPrioritySecond.decision.type,
        OperationScheduleDecisionType.queued,
      );

      running.release(OperationCompletionState.success);
      await lowPriorityFirst.waitUntilDispatch;
      lowPriorityFirst.release(OperationCompletionState.success);

      await highPrioritySecond.waitUntilDispatch;
      highPrioritySecond.release(OperationCompletionState.success);
    },
  );

  test('stale operations are marked and exposed in metrics', () async {
    final engine = OperationConcurrencyEngine(
      policy: const OperationSchedulerPolicy(
        staleTimeout: Duration(milliseconds: 1),
      ),
    );

    final permit = await engine.schedule(
      _descriptor(
        operationId: 'stale-running',
        idempotencyKey: 'stale-running',
        claims: <OperationResourceClaim>[_claim(mode: OperationLockMode.write)],
      ),
    );
    await permit.waitUntilDispatch;
    engine.markRunning('stale-running');

    await Future<void>.delayed(const Duration(milliseconds: 10));
    engine.runHousekeepingNow();

    final staleSnapshot = engine.queueSnapshot.firstWhere(
      (item) => item.operationInstanceId == 'stale-running',
    );
    expect(staleSnapshot.isStale, isTrue);
    expect(engine.metricsSnapshot.stale, 1);

    permit.release(OperationCompletionState.success);
  });

  test('queue depth and wait warnings are surfaced in metrics', () async {
    final engine = OperationConcurrencyEngine(
      policy: const OperationSchedulerPolicy(
        queueDepthWarningThreshold: 1,
        queueWaitWarningThreshold: Duration.zero,
      ),
    );

    final first = await engine.schedule(
      _descriptor(
        operationId: 'warn-1',
        idempotencyKey: 'warn-1',
        claims: <OperationResourceClaim>[_claim(mode: OperationLockMode.write)],
      ),
    );
    await first.waitUntilDispatch;

    final queued = await engine.schedule(
      _descriptor(
        operationId: 'warn-2',
        idempotencyKey: 'warn-2',
        claims: <OperationResourceClaim>[_claim(mode: OperationLockMode.write)],
      ),
    );
    expect(queued.decision.type, OperationScheduleDecisionType.queued);

    final metrics = engine.metricsSnapshot;
    expect(metrics.queueDepthWarning, isTrue);
    expect(metrics.queueWaitWarning, isTrue);
    expect(metrics.queueOrdering, OperationQueueOrdering.fifo.name);
    expect(metrics.preemptionMode, OperationPreemptionMode.none.name);

    first.release(OperationCompletionState.success);
    await queued.waitUntilDispatch;
    queued.release(OperationCompletionState.success);
  });

  test('claim registry classifies read-only operations as readOnly class', () {
    final descriptor = OperationClaimRegistry.buildDescriptor(
      operationInstanceId: 'describe-op',
      payload: <String, dynamic>{
        'action': 'run_workflow',
        'workflow_id': 'postgres',
        'operation_id': 'describe',
        'connection': <String, dynamic>{'ip': '203.0.113.70'},
      },
      serializePerHost: true,
    );
    expect(descriptor.preemptibleClass, OperationPreemptibleClass.readOnly);
  });

  test('claim registry classifies server/check as readOnly class '
      '(migrated from the legacy check_server action, T-1.5.2)', () {
    final descriptor = OperationClaimRegistry.buildDescriptor(
      operationInstanceId: 'check-op',
      payload: <String, dynamic>{
        'action': 'run_workflow',
        'workflow_id': 'server',
        'operation_id': 'check',
        'host': '203.0.113.70',
      },
      serializePerHost: true,
    );
    expect(descriptor.preemptibleClass, OperationPreemptibleClass.readOnly);
  });

  test('claim registry classifies setup/describe as readOnly class '
      '(migrated from the legacy describe_setup action, T-1.5.2)', () {
    final descriptor = OperationClaimRegistry.buildDescriptor(
      operationInstanceId: 'describe-setup-op',
      payload: <String, dynamic>{
        'action': 'run_workflow',
        'workflow_id': 'setup',
        'operation_id': 'describe',
      },
      serializePerHost: false,
    );
    expect(descriptor.preemptibleClass, OperationPreemptibleClass.readOnly);
  });

  test(
    'claim registry serializes any non-run_workflow action against its host',
    () {
      // Every current caller sends action: run_workflow (T-1.5.2), but
      // buildDescriptor is a general payload -> descriptor mapping, so an
      // unrecognized action must still serialize against its host rather
      // than silently dispatching with no claim at all.
      final descriptor = OperationClaimRegistry.buildDescriptor(
        operationInstanceId: 'unknown-action-op',
        payload: <String, dynamic>{
          'action': 'some_future_action',
          'host': '203.0.113.90',
        },
        serializePerHost: true,
      );
      expect(descriptor.claims, hasLength(1));
      expect(descriptor.claims.single.resource.kind, 'host');
      expect(descriptor.claims.single.resource.scope, '203.0.113.90');
      expect(descriptor.claims.single.resource.id, 'control');
      expect(descriptor.claims.single.mode, OperationLockMode.write);
    },
  );

  test('markProgress clears stale state for active operation', () async {
    final engine = OperationConcurrencyEngine(
      policy: const OperationSchedulerPolicy(
        staleTimeout: Duration(milliseconds: 1),
      ),
    );

    final permit = await engine.schedule(
      _descriptor(
        operationId: 'progress-clear-stale',
        idempotencyKey: 'progress-clear-stale',
        claims: <OperationResourceClaim>[_claim(mode: OperationLockMode.write)],
      ),
    );
    await permit.waitUntilDispatch;
    engine.markRunning('progress-clear-stale');

    await Future<void>.delayed(const Duration(milliseconds: 10));
    engine.runHousekeepingNow();
    expect(engine.metricsSnapshot.stale, 1);

    engine.markProgress('progress-clear-stale');
    expect(engine.metricsSnapshot.stale, 0);

    final snapshot = engine.queueSnapshot.firstWhere(
      (item) => item.operationInstanceId == 'progress-clear-stale',
    );
    expect(snapshot.isStale, isFalse);

    permit.release(OperationCompletionState.success);
  });

  test('queue warning flags clear after queue drains', () async {
    final engine = OperationConcurrencyEngine(
      policy: const OperationSchedulerPolicy(
        queueDepthWarningThreshold: 1,
        queueWaitWarningThreshold: Duration(milliseconds: 1),
      ),
    );

    final first = await engine.schedule(
      _descriptor(
        operationId: 'warn-clear-1',
        idempotencyKey: 'warn-clear-1',
        claims: <OperationResourceClaim>[_claim(mode: OperationLockMode.write)],
      ),
    );
    await first.waitUntilDispatch;

    final queued = await engine.schedule(
      _descriptor(
        operationId: 'warn-clear-2',
        idempotencyKey: 'warn-clear-2',
        claims: <OperationResourceClaim>[_claim(mode: OperationLockMode.write)],
      ),
    );
    expect(queued.decision.type, OperationScheduleDecisionType.queued);
    expect(engine.metricsSnapshot.queueDepthWarning, isTrue);

    first.release(OperationCompletionState.success);
    await queued.waitUntilDispatch;
    queued.release(OperationCompletionState.success);

    final clearedMetrics = engine.metricsSnapshot;
    expect(clearedMetrics.queueDepthWarning, isFalse);
  });

  test('priority ordering is honored when policy is priorityFifo', () async {
    final engine = OperationConcurrencyEngine(
      policy: const OperationSchedulerPolicy(
        queueOrdering: OperationQueueOrdering.priorityFifo,
      ),
    );

    final blocker = await engine.schedule(
      _descriptor(
        operationId: 'prio-blocker',
        idempotencyKey: 'prio-blocker',
        claims: <OperationResourceClaim>[_claim(mode: OperationLockMode.write)],
      ),
    );
    await blocker.waitUntilDispatch;

    final low = await engine.schedule(
      _descriptor(
        operationId: 'prio-low',
        idempotencyKey: 'prio-low',
        priority: OperationPriority.low,
        claims: <OperationResourceClaim>[_claim(mode: OperationLockMode.write)],
      ),
    );
    final high = await engine.schedule(
      _descriptor(
        operationId: 'prio-high',
        idempotencyKey: 'prio-high',
        priority: OperationPriority.high,
        claims: <OperationResourceClaim>[_claim(mode: OperationLockMode.write)],
      ),
    );
    expect(low.decision.type, OperationScheduleDecisionType.queued);
    expect(high.decision.type, OperationScheduleDecisionType.queued);

    blocker.release(OperationCompletionState.success);
    await high.waitUntilDispatch;
    high.release(OperationCompletionState.success);

    await low.waitUntilDispatch;
    low.release(OperationCompletionState.success);
  });

  group('idempotency key sanitization', () {
    // Why: the idempotency key is persisted in the Python task-history file
    // and travels in the engine payload, so a secret inside params would be
    // written to disk in plaintext. These guards pin the fix forward.
    Map<String, dynamic> postgresParamsWithSecrets() {
      return <String, dynamic>{
        'dry_run': false,
        'settings': <String, dynamic>{
          'project_slug': 'shop',
          'superuser_password': 'super-secret-pw-1',
          'password': 'user-secret-pw-2',
          'tls_dns_credentials': 'dns-credential-token-3',
          'backup_aws_secret_access_key': 'aws-secret-4',
          'deploy_private_key': 'private-key-material-5',
        },
      };
    }

    test('idempotency key carries no secret values', () {
      final descriptor = OperationClaimRegistry.buildDescriptor(
        operationInstanceId: 'pg-sanitize-1',
        payload: <String, dynamic>{
          'action': 'run_workflow',
          'workflow_id': 'postgres',
          'operation_id': 'project_list',
          'connection': <String, dynamic>{'ip': '203.0.113.70'},
          'params': postgresParamsWithSecrets(),
        },
        serializePerHost: true,
      );
      for (final secret in <String>[
        'super-secret-pw-1',
        'user-secret-pw-2',
        'dns-credential-token-3',
        'aws-secret-4',
        'private-key-material-5',
      ]) {
        expect(descriptor.idempotencyKey, isNot(contains(secret)));
      }
    });

    test('idempotency key keeps non-sensitive identity and key order', () {
      Map<String, dynamic> payloadWithOrder(List<String> settingKeys) {
        final settings = <String, dynamic>{};
        final values = <String, String>{
          'project_slug': 'shop',
          'superuser_password': 'super-secret-pw-1',
          'password': 'user-secret-pw-2',
        };
        for (final key in settingKeys) {
          settings[key] = values[key];
        }
        return <String, dynamic>{
          'action': 'run_workflow',
          'workflow_id': 'postgres',
          'operation_id': 'project_list',
          'connection': <String, dynamic>{'ip': '203.0.113.70'},
          'params': <String, dynamic>{'dry_run': false, 'settings': settings},
        };
      }

      final first = OperationClaimRegistry.buildDescriptor(
        operationInstanceId: 'pg-order-1',
        payload: payloadWithOrder(<String>[
          'project_slug',
          'superuser_password',
          'password',
        ]),
        serializePerHost: true,
      );
      final second = OperationClaimRegistry.buildDescriptor(
        operationInstanceId: 'pg-order-2',
        payload: payloadWithOrder(<String>[
          'password',
          'superuser_password',
          'project_slug',
        ]),
        serializePerHost: true,
      );
      expect(second.idempotencyKey, first.idempotencyKey);
      expect(first.idempotencyKey, contains('shop'));
    });
  });

  test(
    'claim registry classifies backup_backlog_report as readOnly with read locks',
    () {
      // Why: the report only lists storage, like backup_artifact_list, so
      // it must share read locks instead of serializing behind writers.
      final descriptor = OperationClaimRegistry.buildDescriptor(
        operationInstanceId: 'backlog-report-op',
        payload: <String, dynamic>{
          'action': 'run_workflow',
          'workflow_id': 'postgres',
          'operation_id': 'backup_backlog_report',
          'connection': <String, dynamic>{'ip': '203.0.113.70'},
        },
        serializePerHost: true,
      );
      expect(descriptor.preemptibleClass, OperationPreemptibleClass.readOnly);
      expect(descriptor.claims, isNotEmpty);
      expect(descriptor.claims.map((claim) => claim.mode).toSet(), {
        OperationLockMode.read,
      });
    },
  );

  test('claim registry classifies backup_backlog_cleanup as mutating', () {
    // Why: the cleanup deletes storage, so it must take write locks --
    // including the per-policy backup claim that serializes cleanups.
    final descriptor = OperationClaimRegistry.buildDescriptor(
      operationInstanceId: 'backlog-cleanup-op',
      payload: <String, dynamic>{
        'action': 'run_workflow',
        'workflow_id': 'postgres',
        'operation_id': 'backup_backlog_cleanup',
        'connection': <String, dynamic>{'ip': '203.0.113.70'},
        'params': <String, dynamic>{
          'settings': <String, dynamic>{'backup_policy_id': 'daily-main'},
        },
      },
      serializePerHost: true,
    );
    expect(descriptor.preemptibleClass, OperationPreemptibleClass.mutating);
    expect(
      descriptor.claims
          .where((claim) => claim.resource.kind == 'backup')
          .map((claim) => claim.mode)
          .toSet(),
      {OperationLockMode.write},
    );
  });
}
