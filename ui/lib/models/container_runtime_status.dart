import '../utils/payload_codecs.dart';

/// What a managed container is actually doing, as one value.
///
/// Docker reports a container's state, its healthcheck and its restart
/// behaviour separately, and Deploy Dash adds its own readiness probe on top.
/// Rendering four independent fields is how a stopped container ends up
/// showing a stale "healthy" badge, so they are collapsed here once and the
/// UI reads only the result.
///
/// The four negative-looking values are deliberately distinct, because the
/// next action differs for each: [unhealthy] means look at the logs,
/// [stopped] means start it, [missing] means it was removed outside Deploy
/// Dash, and [notConfigured] means the feature was never set up.
enum ContainerRuntimeEffectiveStatus {
  /// Running, and every check that ran passed.
  ready,

  /// Up, but still inside its startup or health-check grace period.
  starting,

  /// Docker is cycling it, usually because it keeps exiting.
  restarting,

  /// Running, but a health or readiness check is failing.
  unhealthy,

  /// The container exists but no process is running in it.
  stopped,

  /// No container by that name exists on the server.
  missing,

  /// The service was never set up for this server or project.
  notConfigured,

  /// Nothing has been read yet, or what was read could not be interpreted.
  unknown,

  /// Deploy Dash is creating it right now; absence is expected, not a fault.
  provisioning,
}

/// The persisted and protocol-level state of a managed container.
///
/// Presentation colors are deliberately supplied by the UI layer.
class ContainerRuntimeStatus {
  /// Creates a status from already-interpreted fields.
  ///
  /// The defaults describe a container that is not there. Prefer the named
  /// constructors for the common states and the factories for anything that
  /// arrived from the engine or the database.
  const ContainerRuntimeStatus({
    required this.effectiveStatus,
    this.present = false,
    this.dockerState = '',
    this.running = false,
    this.health = 'unknown',
    this.exitCode,
    this.image = '',
    this.startedAt = '',
    this.readinessStatus = 'not_checked',
    this.readinessDetail = '',
  });

  /// A running, healthy container.
  const ContainerRuntimeStatus.ready()
    : this(
        effectiveStatus: ContainerRuntimeEffectiveStatus.ready,
        present: true,
        dockerState: 'running',
        running: true,
        health: 'healthy',
      );

  /// A container that exists with nothing running in it.
  const ContainerRuntimeStatus.stopped()
    : this(effectiveStatus: ContainerRuntimeEffectiveStatus.stopped);

  /// A service that was never set up, so there is no container to describe.
  const ContainerRuntimeStatus.notConfigured()
    : this(effectiveStatus: ContainerRuntimeEffectiveStatus.notConfigured);

  /// Nothing is known yet. The fallback for every unreadable payload here,
  /// so a malformed response shows "unknown" rather than a wrong state.
  const ContainerRuntimeStatus.unknown()
    : this(effectiveStatus: ContainerRuntimeEffectiveStatus.unknown);

  /// A container Deploy Dash is in the middle of creating.
  ///
  /// [present] is true even though the container may not exist yet: the point
  /// is to stop the UI reporting it as missing while we are making it.
  const ContainerRuntimeStatus.provisioning()
    : this(
        effectiveStatus: ContainerRuntimeEffectiveStatus.provisioning,
        present: true,
      );

  /// The single collapsed answer. This is what the UI renders.
  final ContainerRuntimeEffectiveStatus effectiveStatus;

  /// Whether a container of that name exists on the server at all.
  final bool present;

  /// Docker's own state word -- `running`, `exited`, `restarting`, and so on.
  /// Raw and unmapped, for the technical-details reveal.
  final String dockerState;

  /// Whether a process is running inside the container.
  final bool running;

  /// Docker's healthcheck verdict, or `unknown` when the image defines none.
  final String health;

  /// The exit code of the last run, when the container has stopped.
  final int? exitCode;

  /// The image reference the container was created from.
  final String image;

  /// When the current run started, as the engine reported it.
  final String startedAt;

  /// Deploy Dash's own readiness probe result, independent of Docker's
  /// healthcheck. `not_checked` when no probe ran.
  final String readinessStatus;

  /// Why the readiness probe reached its verdict, for technical details.
  final String readinessDetail;

  /// Whether the container is running and passing its checks.
  bool get isReady => effectiveStatus == ContainerRuntimeEffectiveStatus.ready;

  /// The status as its persisted and wire-level string.
  ///
  /// Not [Enum.name]: `notConfigured` is written `not_configured`, which is
  /// the spelling the engine sends and the local database stores. Keeping the
  /// mapping here means the enum can be renamed without rewriting stored
  /// rows.
  String get effectiveStatusKey {
    return switch (effectiveStatus) {
      ContainerRuntimeEffectiveStatus.ready => 'ready',
      ContainerRuntimeEffectiveStatus.starting => 'starting',
      ContainerRuntimeEffectiveStatus.restarting => 'restarting',
      ContainerRuntimeEffectiveStatus.unhealthy => 'unhealthy',
      ContainerRuntimeEffectiveStatus.stopped => 'stopped',
      ContainerRuntimeEffectiveStatus.missing => 'missing',
      ContainerRuntimeEffectiveStatus.notConfigured => 'not_configured',
      ContainerRuntimeEffectiveStatus.unknown => 'unknown',
      ContainerRuntimeEffectiveStatus.provisioning => 'provisioning',
    };
  }

  /// Whether something is running inside the container.
  ///
  /// True for [ContainerRuntimeEffectiveStatus.unhealthy] as well as
  /// [ContainerRuntimeEffectiveStatus.ready]: a failing healthcheck is a
  /// running process. Callers use it to decide whether "stop" is the sensible
  /// action, not whether the service works.
  bool get isProcessActive =>
      running ||
      effectiveStatus == ContainerRuntimeEffectiveStatus.ready ||
      effectiveStatus == ContainerRuntimeEffectiveStatus.starting ||
      effectiveStatus == ContainerRuntimeEffectiveStatus.restarting ||
      effectiveStatus == ContainerRuntimeEffectiveStatus.unhealthy;

  /// Whether the container is mid-transition, so its state will change on its
  /// own shortly. The cue to keep polling and to disable start and stop.
  bool get isBusy =>
      effectiveStatus == ContainerRuntimeEffectiveStatus.starting ||
      effectiveStatus == ContainerRuntimeEffectiveStatus.restarting ||
      effectiveStatus == ContainerRuntimeEffectiveStatus.provisioning;

  /// Whether nothing is running, for whichever of the three reasons.
  ///
  /// Groups [ContainerRuntimeEffectiveStatus.stopped],
  /// [ContainerRuntimeEffectiveStatus.missing] and
  /// [ContainerRuntimeEffectiveStatus.notConfigured] for the one decision
  /// where they agree -- there is nothing to talk to. The three stay separate
  /// everywhere the recovery differs.
  bool get isStoppedLike =>
      effectiveStatus == ContainerRuntimeEffectiveStatus.stopped ||
      effectiveStatus == ContainerRuntimeEffectiveStatus.missing ||
      effectiveStatus == ContainerRuntimeEffectiveStatus.notConfigured;

  /// The status in sentence case, as shown on a badge.
  ///
  /// Reworded rather than mechanical: `missing` reads "Not found", because a
  /// container Deploy Dash cannot see is not necessarily one that is gone.
  String get label {
    return switch (effectiveStatus) {
      ContainerRuntimeEffectiveStatus.ready => 'Ready',
      ContainerRuntimeEffectiveStatus.starting => 'Starting',
      ContainerRuntimeEffectiveStatus.restarting => 'Restarting',
      ContainerRuntimeEffectiveStatus.unhealthy => 'Unhealthy',
      ContainerRuntimeEffectiveStatus.stopped => 'Stopped',
      ContainerRuntimeEffectiveStatus.missing => 'Not found',
      ContainerRuntimeEffectiveStatus.notConfigured => 'Not configured',
      ContainerRuntimeEffectiveStatus.unknown => 'Unknown',
      ContainerRuntimeEffectiveStatus.provisioning => 'Provisioning',
    };
  }

  /// Reads a server-services payload, which wraps a container status inside a
  /// service's own record.
  ///
  /// `configured: false` short-circuits to
  /// [ContainerRuntimeStatus.notConfigured] before anything else is read: a
  /// service that was never set up has no container state worth interpreting.
  /// A nested `container_status` map is read by [ContainerRuntimeStatus.fromMap];
  /// its absence falls back to
  /// [ContainerRuntimeStatus.fromLegacy]. Anything that is not a map at all
  /// yields [ContainerRuntimeStatus.unknown].
  factory ContainerRuntimeStatus.fromServiceStatus(Object? raw) {
    if (raw is! Map) return const ContainerRuntimeStatus.unknown();
    final map = mapFrom(raw);
    final configured = _boolFromValue(map['configured'], defaultValue: true);
    if (!configured) return const ContainerRuntimeStatus.notConfigured();
    final containerStatus = map['container_status'];
    if (containerStatus is Map) {
      return ContainerRuntimeStatus.fromMap(containerStatus);
    }
    return ContainerRuntimeStatus.fromLegacy(
      running: _boolFromValue(map['running']),
      health: map['health']?.toString(),
      configured: configured,
    );
  }

  /// Reads a container-status payload from the engine.
  ///
  /// The engine's own `effective_status` wins when it is a value this build
  /// recognises. When it is absent or unrecognised, the status is *derived*
  /// from the raw Docker fields instead, so a payload from a newer or older
  /// engine still resolves to something true rather than to unknown.
  ///
  /// A literal `"unknown"` is the exception: it is honoured as sent, because
  /// there the engine is telling us it looked and could not say, which is not
  /// the same as not having told us.
  factory ContainerRuntimeStatus.fromMap(Object? raw) {
    if (raw is! Map) return const ContainerRuntimeStatus.unknown();
    final map = mapFrom(raw);
    final effectiveStatusValue = map['effective_status']?.toString();
    final effective = _effectiveStatusFromString(effectiveStatusValue);
    final hasExplicitUnknownStatus =
        effectiveStatusValue?.trim().toLowerCase() == 'unknown';
    final readiness = map['readiness'];
    final readinessMap = mapFrom(readiness);
    final present = _boolFromValue(map['present']);
    final running = _boolFromValue(map['running']);
    final dockerState = map['docker_state']?.toString() ?? '';
    final health = map['health']?.toString() ?? 'unknown';
    return ContainerRuntimeStatus(
      effectiveStatus:
          effective == ContainerRuntimeEffectiveStatus.unknown &&
              !hasExplicitUnknownStatus
          ? _deriveEffectiveStatus(
              present: present,
              running: running,
              dockerState: dockerState,
              health: health,
              readinessStatus: readinessMap['status']?.toString(),
            )
          : effective,
      present: present,
      dockerState: dockerState,
      running: running,
      health: health,
      exitCode: map['exit_code'] is int
          ? map['exit_code'] as int
          : int.tryParse(map['exit_code']?.toString() ?? ''),
      image: map['image']?.toString() ?? '',
      startedAt: map['started_at']?.toString() ?? '',
      readinessStatus: readinessMap['status']?.toString() ?? 'not_checked',
      readinessDetail: readinessMap['detail']?.toString() ?? '',
    );
  }

  /// Rebuilds a status from the single word cached in the local database.
  ///
  /// Only [effectiveStatus] survives that round trip, so the Docker fields
  /// are filled with the values that state implies -- enough for a badge and
  /// for [isProcessActive], and deliberately not presented as a fresh
  /// reading. Callers wanting live detail must re-query the server.
  factory ContainerRuntimeStatus.fromStoredHealthStatus(String? raw) {
    final effective = _effectiveStatusFromString(raw);
    return switch (effective) {
      ContainerRuntimeEffectiveStatus.ready =>
        const ContainerRuntimeStatus.ready(),
      ContainerRuntimeEffectiveStatus.starting => const ContainerRuntimeStatus(
        effectiveStatus: ContainerRuntimeEffectiveStatus.starting,
        present: true,
        dockerState: 'running',
        running: true,
        health: 'starting',
      ),
      ContainerRuntimeEffectiveStatus.restarting =>
        const ContainerRuntimeStatus(
          effectiveStatus: ContainerRuntimeEffectiveStatus.restarting,
          present: true,
          dockerState: 'restarting',
          running: true,
        ),
      ContainerRuntimeEffectiveStatus.unhealthy => const ContainerRuntimeStatus(
        effectiveStatus: ContainerRuntimeEffectiveStatus.unhealthy,
        present: true,
        dockerState: 'running',
        running: true,
        health: 'unhealthy',
      ),
      ContainerRuntimeEffectiveStatus.stopped =>
        const ContainerRuntimeStatus.stopped(),
      ContainerRuntimeEffectiveStatus.missing => const ContainerRuntimeStatus(
        effectiveStatus: ContainerRuntimeEffectiveStatus.missing,
      ),
      ContainerRuntimeEffectiveStatus.notConfigured =>
        const ContainerRuntimeStatus.notConfigured(),
      ContainerRuntimeEffectiveStatus.provisioning =>
        const ContainerRuntimeStatus.provisioning(),
      ContainerRuntimeEffectiveStatus.unknown =>
        const ContainerRuntimeStatus.unknown(),
    };
  }

  /// Reads the older `running` plus `health` pair, for payloads that predate
  /// `effective_status`.
  ///
  /// An unrecognised health value on a running container reads as
  /// [ContainerRuntimeEffectiveStatus.ready]: in this older shape, only
  /// `starting` and `unhealthy` carried meaning, and every other word --
  /// including an image with no healthcheck at all -- meant nothing was
  /// wrong.
  factory ContainerRuntimeStatus.fromLegacy({
    required bool running,
    String? health,
    bool configured = true,
  }) {
    if (!configured) return const ContainerRuntimeStatus.notConfigured();
    final normalizedHealth = (health ?? 'unknown').trim().toLowerCase();
    if (!running) {
      return ContainerRuntimeStatus(
        effectiveStatus: ContainerRuntimeEffectiveStatus.stopped,
        health: normalizedHealth,
      );
    }
    final effective = switch (normalizedHealth) {
      'starting' => ContainerRuntimeEffectiveStatus.starting,
      'unhealthy' => ContainerRuntimeEffectiveStatus.unhealthy,
      _ => ContainerRuntimeEffectiveStatus.ready,
    };
    return ContainerRuntimeStatus(
      effectiveStatus: effective,
      present: true,
      dockerState: 'running',
      running: true,
      health: normalizedHealth,
    );
  }

  /// A copy with the given fields replaced.
  ///
  /// [exitCode] cannot be cleared this way -- passing null keeps the existing
  /// value. Build a fresh status for a container that has restarted rather
  /// than trying to unset it.
  ContainerRuntimeStatus copyWith({
    ContainerRuntimeEffectiveStatus? effectiveStatus,
    bool? present,
    String? dockerState,
    bool? running,
    String? health,
    int? exitCode,
    String? image,
    String? startedAt,
    String? readinessStatus,
    String? readinessDetail,
  }) {
    return ContainerRuntimeStatus(
      effectiveStatus: effectiveStatus ?? this.effectiveStatus,
      present: present ?? this.present,
      dockerState: dockerState ?? this.dockerState,
      running: running ?? this.running,
      health: health ?? this.health,
      exitCode: exitCode ?? this.exitCode,
      image: image ?? this.image,
      startedAt: startedAt ?? this.startedAt,
      readinessStatus: readinessStatus ?? this.readinessStatus,
      readinessDetail: readinessDetail ?? this.readinessDetail,
    );
  }
}

ContainerRuntimeEffectiveStatus _effectiveStatusFromString(String? raw) {
  return switch (raw?.trim().toLowerCase()) {
    'ready' ||
    'running' ||
    'healthy' ||
    'success' ||
    'live' => ContainerRuntimeEffectiveStatus.ready,
    'starting' ||
    'checking' ||
    'updating' => ContainerRuntimeEffectiveStatus.starting,
    'restarting' => ContainerRuntimeEffectiveStatus.restarting,
    'unhealthy' ||
    'degraded' ||
    'warning' ||
    'failed' ||
    'error' => ContainerRuntimeEffectiveStatus.unhealthy,
    'down' || 'stopped' => ContainerRuntimeEffectiveStatus.stopped,
    'missing' => ContainerRuntimeEffectiveStatus.missing,
    'not_configured' ||
    'not configured' ||
    'notconfigured' => ContainerRuntimeEffectiveStatus.notConfigured,
    'provisioning' => ContainerRuntimeEffectiveStatus.provisioning,
    _ => ContainerRuntimeEffectiveStatus.unknown,
  };
}

bool _boolFromValue(Object? value, {bool defaultValue = false}) {
  if (value is bool) return value;
  if (value == null) return defaultValue;
  final text = value.toString().trim().toLowerCase();
  if (text == '1' || text == 'true' || text == 'yes' || text == 'on') {
    return true;
  }
  if (text == '0' || text == 'false' || text == 'no' || text == 'off') {
    return false;
  }
  return defaultValue;
}

ContainerRuntimeEffectiveStatus _deriveEffectiveStatus({
  required bool present,
  required bool running,
  required String dockerState,
  required String health,
  String? readinessStatus,
}) {
  final normalizedState = dockerState.trim().toLowerCase();
  final normalizedHealth = health.trim().toLowerCase();
  final normalizedReadiness = readinessStatus?.trim().toLowerCase();
  if (!present) return ContainerRuntimeEffectiveStatus.missing;
  if (normalizedState == 'restarting') {
    return ContainerRuntimeEffectiveStatus.restarting;
  }
  if (!running ||
      normalizedState == 'created' ||
      normalizedState == 'exited' ||
      normalizedState == 'dead' ||
      normalizedState == 'removing') {
    return ContainerRuntimeEffectiveStatus.stopped;
  }
  if (normalizedHealth == 'starting' || normalizedReadiness == 'starting') {
    return ContainerRuntimeEffectiveStatus.starting;
  }
  if (normalizedHealth == 'unhealthy' || normalizedReadiness == 'unhealthy') {
    return ContainerRuntimeEffectiveStatus.unhealthy;
  }
  return ContainerRuntimeEffectiveStatus.ready;
}
