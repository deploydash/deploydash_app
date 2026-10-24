import 'package:ui/utils/payload_codecs.dart';

class ServerDockerStorageViewModel {
  const ServerDockerStorageViewModel({
    required this.imagesBytes,
    required this.imagesReclaimableBytes,
    required this.imagesCount,
    required this.buildCacheBytes,
    required this.buildCacheReclaimableBytes,
    required this.buildCacheCount,
    required this.checkedAt,
  });

  final int? imagesBytes;
  final int? imagesReclaimableBytes;
  final int? imagesCount;
  final int? buildCacheBytes;
  final int? buildCacheReclaimableBytes;
  final int? buildCacheCount;
  final DateTime? checkedAt;

  int? get totalReclaimableBytes {
    final images = imagesReclaimableBytes;
    final cache = buildCacheReclaimableBytes;
    if (images == null && cache == null) {
      return null;
    }
    return (images ?? 0) + (cache ?? 0);
  }
}

ServerDockerStorageViewModel buildServerDockerStorageView(
  Map<String, dynamic> storage,
) {
  final images = mapFrom(storage['images']);
  final buildCache = mapFrom(storage['build_cache']);

  return ServerDockerStorageViewModel(
    imagesBytes: intFrom(images['size_bytes']),
    imagesReclaimableBytes: intFrom(images['reclaimable_bytes']),
    imagesCount: intFrom(images['total_count']),
    buildCacheBytes: intFrom(buildCache['size_bytes']),
    buildCacheReclaimableBytes: intFrom(buildCache['reclaimable_bytes']),
    buildCacheCount: intFrom(buildCache['total_count']),
    checkedAt: DateTime.tryParse(storage['checked_at']?.toString() ?? ''),
  );
}

String formatDockerStorageBytes(int? bytes, {String fallback = '--'}) {
  if (bytes == null) {
    return fallback;
  }
  if (bytes < 1000) {
    return '$bytes B';
  }

  const units = <String>['kB', 'MB', 'GB', 'TB', 'PB'];
  var value = bytes.toDouble();
  var unitIndex = -1;
  while (value >= 1000 && unitIndex < units.length - 1) {
    value /= 1000;
    unitIndex += 1;
  }

  final decimals = value >= 100
      ? 0
      : value >= 10
      ? 1
      : 2;
  return '${value.toStringAsFixed(decimals)} ${units[unitIndex]}';
}

String formatDockerStorageCount(int? count, {String fallback = '--'}) {
  if (count == null) {
    return fallback;
  }
  return '$count';
}
