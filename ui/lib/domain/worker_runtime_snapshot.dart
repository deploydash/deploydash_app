import '../utils/payload_codecs.dart';

class WorkerRuntimeSnapshot {
  const WorkerRuntimeSnapshot({
    required this.configured,
    required this.orphans,
  });

  final List<Map<String, dynamic>> configured;
  final List<Map<String, dynamic>> orphans;

  static const empty = WorkerRuntimeSnapshot(
    configured: <Map<String, dynamic>>[],
    orphans: <Map<String, dynamic>>[],
  );

  factory WorkerRuntimeSnapshot.fromResponse(Map<String, dynamic> response) {
    final payload = response['workers'];
    if (payload is! Map) {
      return empty;
    }

    // D-58 (T-014): left — String-map items are aliased in (not copied)
    // and non-maps are dropped; mapListFrom copies every entry instead.
    List<Map<String, dynamic>> normalizeList(dynamic value) {
      if (value is! List) {
        return const <Map<String, dynamic>>[];
      }
      final rows = <Map<String, dynamic>>[];
      for (final item in value) {
        if (item is Map<String, dynamic>) {
          rows.add(item);
          continue;
        }
        if (item is Map) {
          rows.add(mapFrom(item));
        }
      }
      return rows;
    }

    final normalizedPayload = mapFrom(payload);

    return WorkerRuntimeSnapshot(
      configured: normalizeList(normalizedPayload['configured']),
      orphans: normalizeList(normalizedPayload['orphans']),
    );
  }
}
