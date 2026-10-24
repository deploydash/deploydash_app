// Payload codecs + overview unit formatter (D-58).
//
// The single home for whole-map/list/scalar decoding and overview unit
// formatting for the desktop app. The defs moved here verbatim from
// `ui/server/management/overview_tab_logic.dart` (+ the docker-storage
// `_mapFrom`/`_intFrom` twins): data-layer repositories hand-rolled their own
// copies because they cannot import from `ui/` — an everywhere-importable
// `utils/` home unblocks them legally.

// --- Whole-map/list codecs --------------------------------------------------

/// String-keyed view of [raw], or `const {}` when it is not a map.
///
/// Keys stringify with `key.toString()` — a null key yields `'null'`
/// (Dart's `Null.toString()`), the same value T-013's `stringifyJsonKeys`
/// produces; the two owners differ in arity (whole-map here, entry-lambda
/// there), not in null behavior.
Map<String, dynamic> mapFrom(dynamic raw) {
  if (raw is! Map) {
    return const <String, dynamic>{};
  }
  return raw.map((key, value) => MapEntry(key.toString(), value));
}

/// String-keyed views of the maps in [raw], or `const []` when not a list.
///
/// Non-map items are dropped silently (`whereType`); the result is fixed
/// length (`growable: false`).
List<Map<String, dynamic>> mapListFrom(dynamic raw) {
  if (raw is! List) {
    return const <Map<String, dynamic>>[];
  }
  return raw
      .whereType<Map<dynamic, dynamic>>()
      .map((entry) => entry.map((k, v) => MapEntry(k.toString(), v)))
      .toList(growable: false);
}

/// Shared num-or-parse engine behind [intFrom] and [doubleFrom] (D-58).
///
/// Why one engine with two parser params instead of two bodies: the shapes
/// are identical (num → parse, String → trim-then-parse, else null) and only
/// the parsers differ (int fast-paths + rounds; double widens). The public
/// names stay separate — callers read `intFrom`/`doubleFrom`, never this.
T? _numFrom<T extends Object>(
  dynamic raw,
  T Function(num) parseNum,
  T? Function(String) parseString,
) {
  if (raw is num) {
    return parseNum(raw);
  }
  if (raw is String) {
    return parseString(raw);
  }
  return null;
}

/// An int read from [raw]: ints pass through, other nums round, strings
/// trim-then-parse, everything else is null.
int? intFrom(dynamic raw) => _numFrom<int>(
  raw,
  (n) => n is int ? n : n.round(),
  (s) => int.tryParse(s.trim()),
);

/// A double read from [raw]: nums widen (no rounding), strings
/// trim-then-parse, everything else is null.
double? doubleFrom(dynamic raw) => _numFrom<double>(
  raw,
  (n) => n.toDouble(),
  (s) => double.tryParse(s.trim()),
);

// --- Overview unit formatting -----------------------------------------------

/// `<scaled value to 1 decimal><suffix>`, or 'Unavailable' when null (D-58).
///
/// [suffix] carries its own leading space where the shipped copy has one
/// (`'%'` has none; `' GB'` and `' kB/s'` do) — the four members this folds
/// disagree on spacing, so the owner takes bytes, not a spacing rule.
/// [divisor] divides before formatting (Gb-from-Mb passes 1024); division —
/// not multiplication by a reciprocal — so the routed expression is literally
/// the expression it replaces.
String formatOverviewUnit(num? value, String suffix, {num divisor = 1}) {
  if (value == null) {
    return 'Unavailable';
  }
  return '${(value / divisor).toStringAsFixed(1)}$suffix';
}
