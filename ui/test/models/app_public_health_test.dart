import 'package:ui/models/app_public_health.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AppPublicHealthSnapshot', () {
    test('normalizes healthy and unhealthy backend payloads', () {
      final healthy = AppPublicHealthSnapshot.fromPayload({
        'enabled': true,
        'status': ' HEALTHY ',
        'path': '/ready',
        'http_status': '204',
        'checked_at': '2026-08-06T12:00:00Z',
        'error': ' ',
      });
      final unhealthy = AppPublicHealthSnapshot.fromPayload({
        'enabled': true,
        'status': 'unhealthy',
        'path': '/health',
        'http_status': 500,
        'error': 'The public URL returned HTTP 500.',
      });

      expect(healthy.status, AppPublicHealthStatus.healthy);
      expect(healthy.isHealthy, isTrue);
      expect(healthy.needsAttention, isFalse);
      expect(healthy.path, '/ready');
      expect(healthy.httpStatus, 204);
      expect(healthy.checkedAt, DateTime.utc(2026, 8, 6, 12));
      expect(healthy.error, isNull);
      expect(healthy.detail, 'Public URL check passed (HTTP 204)');

      expect(unhealthy.status, AppPublicHealthStatus.unhealthy);
      expect(unhealthy.isHealthy, isFalse);
      expect(unhealthy.needsAttention, isTrue);
      expect(unhealthy.httpStatus, 500);
      expect(unhealthy.error, 'The public URL returned HTTP 500.');
      expect(unhealthy.detail, 'Public URL check failed (HTTP 500)');
    });

    test('disabled checks are skipped regardless of payload status', () {
      final snapshot = AppPublicHealthSnapshot.fromPayload({
        'enabled': false,
        'status': 'healthy',
        'path': '/up',
        'http_status': 200,
      });

      expect(snapshot.status, AppPublicHealthStatus.skipped);
      expect(snapshot.detail, 'Public URL check disabled');
    });

    test('falls back safely for malformed or incomplete values', () {
      for (final encoded in <String?>[null, '', 'not-json', '[]']) {
        final snapshot = AppPublicHealthSnapshot.fromJson(encoded);
        expect(snapshot.status, AppPublicHealthStatus.unknown);
        expect(snapshot.path, '/');
        expect(snapshot.detail, 'Public URL not checked');
      }

      final snapshot = AppPublicHealthSnapshot.fromPayload({
        'enabled': 'not-a-bool',
        'status': 'unexpected',
        'path': 'not-absolute',
        'http_status': 999,
        'checked_at': 'invalid',
      });
      expect(snapshot.enabled, isTrue);
      expect(snapshot.status, AppPublicHealthStatus.unknown);
      expect(snapshot.path, '/');
      expect(snapshot.httpStatus, isNull);
      expect(snapshot.checkedAt, isNull);
      expect(snapshot.detail, 'Public URL not checked');
      expect(
        AppPublicHealthSnapshot.fromPayload(null).status,
        AppPublicHealthStatus.unknown,
      );
    });

    test('round trips persisted snapshots without response content', () {
      final source = AppPublicHealthSnapshot(
        enabled: true,
        status: AppPublicHealthStatus.unhealthy,
        path: '/',
        httpStatus: 503,
        checkedAt: DateTime.utc(2026, 8, 6, 13),
        error: 'The public URL returned HTTP 503.',
      );

      final restored = AppPublicHealthSnapshot.fromJson(source.encode());
      expect(restored.enabled, source.enabled);
      expect(restored.status, source.status);
      expect(restored.path, source.path);
      expect(restored.httpStatus, source.httpStatus);
      expect(restored.checkedAt, source.checkedAt);
      expect(restored.error, source.error);
      expect(restored.toJson(), source.toJson());
    });

    test('detail omits an unavailable HTTP status', () {
      const healthy = AppPublicHealthSnapshot(
        enabled: true,
        status: AppPublicHealthStatus.healthy,
        path: '/',
      );
      const unhealthy = AppPublicHealthSnapshot(
        enabled: true,
        status: AppPublicHealthStatus.unhealthy,
        path: '/',
      );

      expect(healthy.detail, 'Public URL check passed');
      expect(unhealthy.detail, 'Public URL check failed');
    });
  });
}
