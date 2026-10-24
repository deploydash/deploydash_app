import 'package:ui/ui/server/management/server_docker_storage_logic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('buildServerDockerStorageView parses storage payload', () {
    final view = buildServerDockerStorageView({
      'images': {
        'size_bytes': '1250000000',
        'reclaimable_bytes': 700000000,
        'total_count': '14',
      },
      'build_cache': {
        'size_bytes': 450000000.2,
        'reclaimable_bytes': '450000000',
        'total_count': 28,
      },
      'checked_at': '2026-05-30T12:00:00Z',
    });

    expect(view.imagesBytes, 1250000000);
    expect(view.imagesReclaimableBytes, 700000000);
    expect(view.imagesCount, 14);
    expect(view.buildCacheBytes, 450000000);
    expect(view.buildCacheReclaimableBytes, 450000000);
    expect(view.buildCacheCount, 28);
    expect(view.totalReclaimableBytes, 1150000000);
    expect(view.checkedAt, DateTime.parse('2026-05-30T12:00:00Z'));
  });

  test('buildServerDockerStorageView falls back cleanly', () {
    final view = buildServerDockerStorageView(const <String, dynamic>{});

    expect(view.imagesBytes, isNull);
    expect(view.imagesReclaimableBytes, isNull);
    expect(view.imagesCount, isNull);
    expect(view.buildCacheBytes, isNull);
    expect(view.buildCacheReclaimableBytes, isNull);
    expect(view.buildCacheCount, isNull);
    expect(view.totalReclaimableBytes, isNull);
    expect(view.checkedAt, isNull);
  });

  test('Docker storage formatters expose stable output', () {
    expect(formatDockerStorageBytes(null), '--');
    expect(formatDockerStorageBytes(999), '999 B');
    expect(formatDockerStorageBytes(1250), '1.25 kB');
    expect(formatDockerStorageBytes(12500000), '12.5 MB');
    expect(formatDockerStorageBytes(1250000000), '1.25 GB');
    expect(formatDockerStorageCount(null), '--');
    expect(formatDockerStorageCount(14), '14');
  });
}
