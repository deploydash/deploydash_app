import 'dart:math';

import 'package:flutter/material.dart';
import 'package:ui/utils/payload_codecs.dart';
import 'package:yaru/yaru.dart';

class OverviewUiState {
  const OverviewUiState({
    required this.showInitialLoading,
    required this.visibleErrorMessage,
    required this.lastUpdatedLabel,
  });

  final bool showInitialLoading;
  final String? visibleErrorMessage;
  final String lastUpdatedLabel;
}

class OverviewInterfaceView {
  const OverviewInterfaceView({
    required this.name,
    required this.rxKbps,
    required this.txKbps,
  });

  final String name;
  final double rxKbps;
  final double txKbps;
}

class OverviewDeviceView {
  const OverviewDeviceView({
    required this.name,
    required this.readKbps,
    required this.writeKbps,
    required this.utilPercent,
  });

  final String name;
  final double readKbps;
  final double writeKbps;
  final double utilPercent;
}

class OverviewMetricsViewModel {
  const OverviewMetricsViewModel({
    required this.uptimeSeconds,
    required this.bootedAt,
    required this.cpuUsagePercent,
    required this.memoryUsedPercent,
    required this.diskUsedPercent,
    required this.load1m,
    required this.memoryUsedMb,
    required this.memoryTotalMb,
    required this.swapUsedPercent,
    required this.diskFreeGb,
    required this.diskTotalGb,
    required this.diskInodeUsedPercent,
    required this.interfaces,
    required this.topInterfaceName,
    required this.topInterfaceRx,
    required this.topInterfaceTx,
    required this.maxInterfaceThroughput,
    required this.devices,
    required this.topDeviceName,
    required this.topDeviceUtil,
    required this.totalRxKbps,
    required this.totalTxKbps,
    required this.totalReadKbps,
    required this.totalWriteKbps,
    required this.retentionDays,
    required this.sysstatFileCount,
    required this.oldestFile,
    required this.newestFile,
    required this.collectedAt,
  });

  final int? uptimeSeconds;
  final DateTime? bootedAt;
  final double? cpuUsagePercent;
  final double? memoryUsedPercent;
  final double? diskUsedPercent;
  final double? load1m;
  final int? memoryUsedMb;
  final int? memoryTotalMb;
  final double? swapUsedPercent;
  final double? diskFreeGb;
  final double? diskTotalGb;
  final double? diskInodeUsedPercent;
  final List<OverviewInterfaceView> interfaces;
  final String topInterfaceName;
  final double topInterfaceRx;
  final double topInterfaceTx;
  final double maxInterfaceThroughput;
  final List<OverviewDeviceView> devices;
  final String topDeviceName;
  final double topDeviceUtil;
  final double? totalRxKbps;
  final double? totalTxKbps;
  final double? totalReadKbps;
  final double? totalWriteKbps;
  final int retentionDays;
  final int sysstatFileCount;
  final String? oldestFile;
  final String? newestFile;
  final DateTime? collectedAt;
}

OverviewUiState buildOverviewUiState({
  required bool canRequestMetrics,
  required Map<String, dynamic> metrics,
  required String? errorMessage,
  required DateTime? lastUpdatedAt,
}) {
  final trimmedError = errorMessage?.trim();
  final hasError = trimmedError != null && trimmedError.isNotEmpty;
  final hasMetrics = metrics.isNotEmpty;
  final showInitialLoading =
      canRequestMetrics && !hasMetrics && !hasError && lastUpdatedAt == null;

  return OverviewUiState(
    showInitialLoading: showInitialLoading,
    visibleErrorMessage: hasError ? trimmedError : null,
    lastUpdatedLabel: formatOverviewTimestamp(
      lastUpdatedAt,
      fallback: 'Not yet',
    ),
  );
}

OverviewMetricsViewModel buildOverviewMetricsView(
  Map<String, dynamic> metrics,
) {
  final cpu = mapFrom(metrics['cpu']);
  final memory = mapFrom(metrics['memory']);
  final disk = mapFrom(metrics['disk']);
  final system = mapFrom(metrics['system']);
  final network = mapFrom(metrics['network']);
  final io = mapFrom(metrics['io']);
  final collection = mapFrom(metrics['collection']);

  final interfaces =
      mapListFrom(network['interfaces'])
          .map(
            (entry) => OverviewInterfaceView(
              name: entry['name']?.toString() ?? '--',
              rxKbps: doubleFrom(entry['rx_kbps']) ?? 0,
              txKbps: doubleFrom(entry['tx_kbps']) ?? 0,
            ),
          )
          .toList(growable: false)
        ..sort((a, b) => (b.rxKbps + b.txKbps).compareTo(a.rxKbps + a.txKbps));

  final topInterface = mapFrom(network['top_interface']);
  final devices =
      mapListFrom(io['devices'])
          .map(
            (entry) => OverviewDeviceView(
              name: entry['name']?.toString() ?? '--',
              readKbps: doubleFrom(entry['read_kbps']) ?? 0,
              writeKbps: doubleFrom(entry['write_kbps']) ?? 0,
              utilPercent: (doubleFrom(entry['util_percent']) ?? 0)
                  .clamp(0, 100)
                  .toDouble(),
            ),
          )
          .toList(growable: false)
        ..sort((a, b) => b.utilPercent.compareTo(a.utilPercent));

  final topDevice = mapFrom(io['top_device']);
  final maxInterfaceThroughput = interfaces.isEmpty
      ? 1.0
      : interfaces
            .map((entry) => entry.rxKbps + entry.txKbps)
            .fold<double>(0.0, max)
            .clamp(1.0, double.infinity);

  return OverviewMetricsViewModel(
    uptimeSeconds: intFrom(system['uptime_seconds']),
    bootedAt: DateTime.tryParse(system['booted_at']?.toString() ?? ''),
    cpuUsagePercent: doubleFrom(
      cpu['usage_percent'],
    )?.clamp(0.0, 100.0).toDouble(),
    memoryUsedPercent: doubleFrom(
      memory['used_percent'],
    )?.clamp(0.0, 100.0).toDouble(),
    diskUsedPercent: doubleFrom(
      disk['root_used_percent'],
    )?.clamp(0.0, 100.0).toDouble(),
    load1m: doubleFrom(cpu['load_1m']),
    memoryUsedMb: intFrom(memory['used_mb']),
    memoryTotalMb: intFrom(memory['total_mb']),
    swapUsedPercent: doubleFrom(memory['swap_used_percent']),
    diskFreeGb: doubleFrom(disk['root_free_gb']),
    diskTotalGb: doubleFrom(disk['root_total_gb']),
    diskInodeUsedPercent: doubleFrom(disk['root_inode_used_percent']),
    interfaces: interfaces,
    topInterfaceName: _availableText(topInterface['name']),
    topInterfaceRx: doubleFrom(topInterface['rx_kbps']) ?? 0,
    topInterfaceTx: doubleFrom(topInterface['tx_kbps']) ?? 0,
    maxInterfaceThroughput: maxInterfaceThroughput,
    devices: devices,
    topDeviceName: _availableText(topDevice['name']),
    topDeviceUtil: doubleFrom(topDevice['util_percent']) ?? 0,
    totalRxKbps: doubleFrom(network['total_rx_kbps']),
    totalTxKbps: doubleFrom(network['total_tx_kbps']),
    totalReadKbps: doubleFrom(io['total_read_kbps']),
    totalWriteKbps: doubleFrom(io['total_write_kbps']),
    retentionDays: intFrom(collection['retention_days']) ?? 90,
    sysstatFileCount: intFrom(collection['sysstat_file_count']) ?? 0,
    oldestFile: collection['oldest_file']?.toString(),
    newestFile: collection['newest_file']?.toString(),
    collectedAt: DateTime.tryParse(metrics['collected_at']?.toString() ?? ''),
  );
}

String formatOverviewUptime(int? value) {
  if (value == null) {
    return 'Unavailable';
  }
  if (value < 60) {
    return '${value}s';
  }

  final days = value ~/ 86400;
  final hours = (value % 86400) ~/ 3600;
  final minutes = (value % 3600) ~/ 60;

  if (days > 0) {
    return hours > 0 ? '${days}d ${hours}h' : '${days}d';
  }
  if (hours > 0) {
    return minutes > 0 ? '${hours}h ${minutes}m' : '${hours}h';
  }
  return '${minutes}m';
}

String formatOverviewTimestamp(
  DateTime? value, {
  String fallback = 'Unavailable',
}) {
  if (value == null) {
    return fallback;
  }
  final local = value.toLocal();
  String two(int raw) => raw.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
}

Color overviewGaugeColor(double? utilizationPercent) {
  if (utilizationPercent == null) {
    return Colors.grey;
  }
  if (utilizationPercent >= 85) {
    return YaruColors.red;
  }
  if (utilizationPercent >= 65) {
    return YaruColors.orange;
  }
  return Colors.green;
}

String _availableText(Object? raw) {
  final value = raw?.toString().trim() ?? '';
  return value.isEmpty || value == '--' ? 'Unavailable' : value;
}
