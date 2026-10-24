import 'package:ui/ui/system/container_runtime_status.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('preserves an explicit unknown backend status', () {
    final status = ContainerRuntimeStatus.fromMap(const <String, dynamic>{
      'present': true,
      'docker_state': 'running',
      'running': true,
      'health': 'unknown',
      'effective_status': 'unknown',
    });

    expect(status.effectiveStatus, ContainerRuntimeEffectiveStatus.unknown);
    expect(status.label, 'Unknown');
  });

  test('parses normalized unhealthy status', () {
    final status = ContainerRuntimeStatus.fromMap(const <String, dynamic>{
      'present': true,
      'docker_state': 'running',
      'running': true,
      'health': 'unhealthy',
      'exit_code': 0,
      'image': 'deploydash/postgres-ext:17',
      'started_at': '2026-07-01T12:00:00Z',
      'effective_status': 'unhealthy',
      'readiness': <String, dynamic>{
        'status': 'unhealthy',
        'detail': 'pg_isready failed',
      },
    });

    expect(status.label, 'Unhealthy');
    expect(status.isProcessActive, isTrue);
    expect(status.isReady, isFalse);
    expect(status.readinessDetail, 'pg_isready failed');
  });

  test('maps legacy running and health values without container status', () {
    expect(
      ContainerRuntimeStatus.fromServiceStatus(const <String, dynamic>{
        'configured': true,
        'running': true,
        'health': 'healthy',
      }).label,
      'Ready',
    );
    expect(
      ContainerRuntimeStatus.fromServiceStatus(const <String, dynamic>{
        'configured': true,
        'running': true,
        'health': 'unhealthy',
      }).label,
      'Unhealthy',
    );
    expect(
      ContainerRuntimeStatus.fromServiceStatus(const <String, dynamic>{
        'configured': false,
        'running': false,
      }).label,
      'Not configured',
    );
  });

  test(
    'normalizes string booleans and derives status without effective value',
    () {
      final status = ContainerRuntimeStatus.fromServiceStatus(
        const <String, dynamic>{
          'configured': '1',
          'container_status': <String, dynamic>{
            'present': 'true',
            'docker_state': 'running',
            'running': 'true',
            'health': 'starting',
            'exit_code': '0',
          },
        },
      );

      expect(status.label, 'Starting');
      expect(status.present, isTrue);
      expect(status.running, isTrue);
      expect(status.exitCode, 0);
    },
  );

  test('maps string false configured values to not configured', () {
    final status = ContainerRuntimeStatus.fromServiceStatus(
      const <String, dynamic>{
        'configured': '0',
        'running': 'true',
        'health': 'healthy',
      },
    );

    expect(status.label, 'Not configured');
    expect(status.isReady, isFalse);
  });

  test('normalizes stored web app health strings to shared statuses', () {
    expect(
      ContainerRuntimeStatus.fromStoredHealthStatus(
        'healthy',
      ).effectiveStatusKey,
      'ready',
    );
    expect(
      ContainerRuntimeStatus.fromStoredHealthStatus(
        'warning',
      ).effectiveStatusKey,
      'unhealthy',
    );
    expect(
      ContainerRuntimeStatus.fromStoredHealthStatus(
        'checking',
      ).effectiveStatusKey,
      'starting',
    );
    expect(
      ContainerRuntimeStatus.fromStoredHealthStatus(
        'not configured',
      ).effectiveStatusKey,
      'not_configured',
    );
    expect(
      ContainerRuntimeStatus.fromStoredHealthStatus(
        'unexpected',
      ).effectiveStatusKey,
      'unknown',
    );
  });
}
