/// A token identifying one in-flight async run, and the scope it belongs to.
///
/// Captured before an `await` and re-checked after it, so a result that
/// arrives once the user has moved on -- switched server, switched project,
/// or simply asked again -- can be dropped instead of written into state that
/// now describes something else.
class ScopedRunContext {
  /// Creates a run token. Obtain one from [ScopedRunRegistry.capture] rather
  /// than constructing it directly; only the registry can allocate an [epoch]
  /// that means anything.
  const ScopedRunContext({
    required this.scopeKey,
    required this.kind,
    required this.epoch,
    required this.runId,
    this.metadata = const <String, Object?>{},
  });

  /// What the run is *about* -- typically a server or project id.
  final String scopeKey;

  /// Which operation within the scope, so two concurrent kinds of refresh on
  /// one server do not cancel each other.
  final String kind;

  /// Monotonic counter for this scope and kind. A run is stale as soon as a
  /// later one exists.
  final int epoch;

  /// Human-readable identity for logs, unique per run.
  final String runId;

  /// Caller-supplied detail carried alongside the run, untouched by the
  /// registry.
  final Map<String, Object?> metadata;

  /// Whether this run is the one described by the given scope, kind and epoch.
  ///
  /// Use it when the caller already knows the current epoch;
  /// [ScopedRunRegistry.isCurrent] is the usual check.
  bool matches({
    required String scopeKey,
    required String kind,
    required int epoch,
  }) {
    return this.scopeKey == scopeKey &&
        this.kind == kind &&
        this.epoch == epoch;
  }
}

/// Allocates run tokens and says which of them is still the current one.
///
/// One registry per widget or provider that fetches on behalf of a changing
/// selection. It holds only a counter per scope-and-kind, so it costs nothing
/// to keep for the lifetime of that owner.
class ScopedRunRegistry {
  final Map<String, int> _epochs = <String, int>{};

  /// Starts a run and returns its token, making every earlier run for the same
  /// scope and kind stale.
  ///
  /// [scopeKey] and [kind] are trimmed, so a caller passing a padded id does
  /// not get a scope of its own.
  ScopedRunContext capture({
    required String scopeKey,
    required String kind,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) {
    final normalizedScopeKey = scopeKey.trim();
    final normalizedKind = kind.trim();
    final key = _entryKey(normalizedScopeKey, normalizedKind);
    final nextEpoch = _nextEpoch(key);
    return ScopedRunContext(
      scopeKey: normalizedScopeKey,
      kind: normalizedKind,
      epoch: nextEpoch,
      runId:
          '$normalizedScopeKey::$normalizedKind::$nextEpoch::'
          '${DateTime.now().microsecondsSinceEpoch}',
      metadata: metadata,
    );
  }

  /// Invalidates every in-flight run for [scopeKey] and [kind] without
  /// starting one, and returns the new epoch.
  ///
  /// This is how a cancel or a scope change abandons results already on their
  /// way back.
  int advance({required String scopeKey, required String kind}) {
    final key = _entryKey(scopeKey.trim(), kind.trim());
    return _nextEpoch(key);
  }

  /// Bumps and returns the epoch for [key] (D-80: shared by capture/advance).
  int _nextEpoch(String key) {
    final nextEpoch = (_epochs[key] ?? 0) + 1;
    _epochs[key] = nextEpoch;
    return nextEpoch;
  }

  /// Whether [run] is still the latest run for its scope and kind.
  ///
  /// False once [capture] or [advance] has been called again, and false after
  /// [clearScope] or [clearAll] -- a forgotten scope has no current run.
  bool isCurrent(ScopedRunContext run) {
    return _epochs[_entryKey(run.scopeKey, run.kind)] == run.epoch;
  }

  /// Forgets every kind under [scopeKey], stranding its in-flight runs.
  void clearScope(String scopeKey) {
    final prefix = '${scopeKey.trim()}::';
    _epochs.removeWhere((key, _) => key.startsWith(prefix));
  }

  /// Forgets every scope, stranding every in-flight run.
  void clearAll() {
    _epochs.clear();
  }

  String _entryKey(String scopeKey, String kind) => '$scopeKey::$kind';
}

/// Tracks which individual items currently have an action running.
///
/// The companion to [ScopedRunRegistry]: that one answers "is this result
/// still wanted", this one answers "is this row already working", so a
/// per-row spinner and a disabled button read from one place instead of a
/// scatter of booleans.
class ScopedBusyRegistry {
  final Set<String> _keys = <String>{};

  /// Whether nothing at all is running.
  bool get isEmpty => _keys.isEmpty;

  /// Forgets every busy item, in every scope.
  void clear() => _keys.clear();

  /// The registry key for one item, with each part trimmed.
  ///
  /// Exposed so a caller can build the key for a widget key or a log line
  /// without duplicating the format.
  String key({
    required String scopeKey,
    required String kind,
    required String id,
  }) {
    return '${scopeKey.trim()}::${kind.trim()}::${id.trim()}';
  }

  /// Whether the identified item has an action running.
  ///
  /// A null or blank [scopeKey] is never busy: it means the scope has not
  /// resolved yet, which is the state a workspace is in before a selection
  /// exists.
  bool isBusy({
    required String? scopeKey,
    required String kind,
    required String id,
  }) {
    final normalizedScopeKey = scopeKey?.trim();
    if (normalizedScopeKey == null || normalizedScopeKey.isEmpty) {
      return false;
    }
    return _keys.contains(
      key(scopeKey: normalizedScopeKey, kind: kind, id: id),
    );
  }

  /// Marks the identified item busy and returns the key to pass to [remove].
  ///
  /// Return the key rather than rebuilding it in the `finally` block: the two
  /// must agree, and a rebuild is where they drift.
  String markBusy({
    required String scopeKey,
    required String kind,
    required String id,
  }) {
    final busyKey = key(scopeKey: scopeKey, kind: kind, id: id);
    _keys.add(busyKey);
    return busyKey;
  }

  /// Marks the item with [key] no longer busy. Safe to call twice.
  void remove(String key) {
    _keys.remove(key);
  }

  /// Marks every item under [scopeKey] no longer busy, across all kinds.
  void clearScope(String scopeKey) {
    final prefix = '${scopeKey.trim()}::';
    _keys.removeWhere((key) => key.startsWith(prefix));
  }

  /// Marks every item of one [kind] under [scopeKey] no longer busy.
  void clearKind({required String scopeKey, required String kind}) {
    final prefix = '${scopeKey.trim()}::${kind.trim()}::';
    _keys.removeWhere((key) => key.startsWith(prefix));
  }
}
