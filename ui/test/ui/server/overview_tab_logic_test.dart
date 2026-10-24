import 'package:ui/ui/server/management/overview_tab_logic.dart';
import 'package:ui/utils/payload_codecs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yaru/yaru.dart';

void main() {
  test(
    'buildOverviewUiState shows initial loading only when fetch can run',
    () {
      final loading = buildOverviewUiState(
        canRequestMetrics: true,
        metrics: const <String, dynamic>{},
        errorMessage: null,
        lastUpdatedAt: null,
      );
      expect(loading.showInitialLoading, isTrue);
      expect(loading.visibleErrorMessage, isNull);
      expect(loading.lastUpdatedLabel, 'Not yet');

      final blocked = buildOverviewUiState(
        canRequestMetrics: false,
        metrics: const <String, dynamic>{},
        errorMessage: null,
        lastUpdatedAt: null,
      );
      expect(blocked.showInitialLoading, isFalse);
    },
  );

  test('buildOverviewUiState hides loading after metrics or errors exist', () {
    final timestamp = DateTime.utc(2026, 4, 18, 12, 30, 45);
    final withMetrics = buildOverviewUiState(
      canRequestMetrics: true,
      metrics: const <String, dynamic>{'cpu': <String, dynamic>{}},
      errorMessage: null,
      lastUpdatedAt: timestamp,
    );
    expect(withMetrics.showInitialLoading, isFalse);
    expect(withMetrics.visibleErrorMessage, isNull);
    expect(
      withMetrics.lastUpdatedLabel,
      formatOverviewTimestamp(timestamp, fallback: 'Not yet'),
    );

    final withError = buildOverviewUiState(
      canRequestMetrics: true,
      metrics: const <String, dynamic>{},
      errorMessage: ' Failed to load metrics. ',
      lastUpdatedAt: null,
    );
    expect(withError.showInitialLoading, isFalse);
    expect(withError.visibleErrorMessage, 'Failed to load metrics.');
  });

  test('buildOverviewMetricsView parses and sorts metrics', () {
    final view = buildOverviewMetricsView({
      'system': {
        'uptime_seconds': '93784',
        'booted_at': '2026-04-17T12:56:16Z',
      },
      'cpu': {'usage_percent': '31.5', 'load_1m': 0.44},
      'memory': {
        'used_mb': '1024',
        'total_mb': 4096.0,
        'used_percent': 25,
        'swap_used_percent': '0.0',
      },
      'disk': {
        'root_used_percent': '42.0',
        'root_free_gb': 88.2,
        'root_total_gb': '128.0',
        'root_inode_used_percent': 12,
      },
      'network': {
        'total_rx_kbps': '12.5',
        'total_tx_kbps': 8,
        'interfaces': [
          {'name': 'eth1', 'rx_kbps': 3, 'tx_kbps': 1},
          {'name': 'eth0', 'rx_kbps': 12.5, 'tx_kbps': 8.0},
          'skip',
        ],
        'top_interface': {'name': 'eth0', 'rx_kbps': 12.5, 'tx_kbps': 8.0},
      },
      'io': {
        'total_read_kbps': 4.0,
        'total_write_kbps': '2.0',
        'devices': [
          {
            'name': 'sdb',
            'read_kbps': 1.0,
            'write_kbps': 1.0,
            'util_percent': 5,
          },
          {
            'name': 'nvme0n1',
            'read_kbps': 4.0,
            'write_kbps': 2.0,
            'util_percent': 9.0,
          },
        ],
        'top_device': {'name': 'nvme0n1', 'util_percent': 9.0},
      },
      'collection': {
        'retention_days': '60',
        'sysstat_file_count': 4,
        'oldest_file': 'oldest',
        'newest_file': 'newest',
      },
      'collected_at': '2026-04-18T15:00:00Z',
    });

    expect(view.uptimeSeconds, 93784);
    expect(view.bootedAt, DateTime.parse('2026-04-17T12:56:16Z'));
    expect(view.cpuUsagePercent, 31.5);
    expect(view.memoryUsedPercent, 25.0);
    expect(view.diskUsedPercent, 42.0);
    expect(view.memoryUsedMb, 1024);
    expect(view.memoryTotalMb, 4096);
    expect(view.interfaces.map((entry) => entry.name).toList(), [
      'eth0',
      'eth1',
    ]);
    expect(view.topInterfaceName, 'eth0');
    expect(view.maxInterfaceThroughput, 20.5);
    expect(view.devices.map((entry) => entry.name).toList(), [
      'nvme0n1',
      'sdb',
    ]);
    expect(view.topDeviceName, 'nvme0n1');
    expect(view.retentionDays, 60);
    expect(view.sysstatFileCount, 4);
    expect(view.oldestFile, 'oldest');
    expect(view.newestFile, 'newest');
    expect(view.collectedAt, DateTime.parse('2026-04-18T15:00:00Z'));
  });

  test('buildOverviewMetricsView falls back safely for missing data', () {
    final view = buildOverviewMetricsView(const <String, dynamic>{});
    expect(view.uptimeSeconds, isNull);
    expect(view.bootedAt, isNull);
    expect(view.cpuUsagePercent, isNull);
    expect(view.memoryUsedPercent, isNull);
    expect(view.diskUsedPercent, isNull);
    expect(view.interfaces, isEmpty);
    expect(view.devices, isEmpty);
    expect(view.maxInterfaceThroughput, 1.0);
    expect(view.retentionDays, 90);
    expect(view.sysstatFileCount, 0);
    expect(view.topInterfaceName, 'Unavailable');
    expect(view.topDeviceName, 'Unavailable');
    expect(view.collectedAt, isNull);
  });

  test('mapping and numeric readers handle unsupported inputs', () {
    expect(mapFrom(null), isEmpty);
    expect(mapListFrom(null), isEmpty);
    expect(
      mapListFrom([
        'skip',
        {'a': 1},
      ]),
      [
        {'a': 1},
      ],
    );
    expect(doubleFrom(4), 4.0);
    expect(doubleFrom(' 4.5 '), 4.5);
    expect(doubleFrom(Object()), isNull);
    expect(intFrom(4.2), 4);
    expect(intFrom(' 7 '), 7);
    expect(intFrom(Object()), isNull);
  });

  test('formatters expose stable fallback strings', () {
    expect(formatOverviewUnit(null, '%'), 'Unavailable');
    expect(formatOverviewUnit(12.34, '%'), '12.3%');
    expect(formatOverviewUnit(null, ' GB'), 'Unavailable');
    expect(formatOverviewUnit(3.26, ' GB'), '3.3 GB');
    expect(formatOverviewUnit(null, ' GB', divisor: 1024), 'Unavailable');
    expect(formatOverviewUnit(2048, ' GB', divisor: 1024), '2.0 GB');
    expect(formatOverviewUptime(null), 'Unavailable');
    expect(formatOverviewUptime(59), '59s');
    expect(formatOverviewUptime(125), '2m');
    expect(formatOverviewUptime(3660), '1h 1m');
    expect(formatOverviewUptime(93784), '1d 2h');
    expect(formatOverviewUnit(null, ' kB/s'), 'Unavailable');
    expect(formatOverviewUnit(4.44, ' kB/s'), '4.4 kB/s');
    expect(formatOverviewTimestamp(null), 'Unavailable');
    expect(formatOverviewTimestamp(null, fallback: 'Not yet'), 'Not yet');
  });

  test('overviewGaugeColor uses threshold bands', () {
    expect(overviewGaugeColor(90), YaruColors.red);
    expect(overviewGaugeColor(70), YaruColors.orange);
    expect(overviewGaugeColor(20), Colors.green);
    expect(overviewGaugeColor(null), Colors.grey);
  });
}
