import 'dart:io';

import 'package:ui/services/envelope_capture.dart';
import 'package:ui/services/sensitive_data_sanitizer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('envelope capture (temporary T-0.5 scaffolding)', () {
    test('is compiled out unless the dart-define is set', () {
      // The guard that matters. This file writes request payloads to disk;
      // if it were ever live in a shipped build it would drop server
      // payloads into the user's filesystem. The capture directory is a
      // const String.fromEnvironment, so with no define it folds to '' and
      // the writer returns before touching the disk.
      final directory = Directory.systemTemp.createTempSync('envelope-off-');
      addTearDown(() => directory.deleteSync(recursive: true));

      captureRequestEnvelope(<String, dynamic>{
        'action': 'run_workflow',
        'workflow_id': 'app',
        'operation_id': 'deploy',
        'password': 'hunter2',
      });

      expect(envelopeCaptureEnabled, isFalse);
      expect(directory.listSync(), isEmpty);
    });

    test('credentials are removed before an envelope reaches the disk', () {
      // The corpus is committed to qa/fixtures/envelopes/, so a redaction
      // failure would commit real credentials. Asserted against the same
      // sanitizer the writer uses, on the key names that actually appear in
      // engine payloads.
      final sanitized = sanitizeSensitivePayloadMap(<String, dynamic>{
        // The current wire shape. This named the setup_server alias until
        // 2026-09-04 -- deleted by T-1.5.2 and surviving inside a string
        // literal, which is exactly where T-1.5.8's two survivors hid. The
        // corpus this fixture stands for is replayed by T-1.5.5, so a fixture
        // teaching the retired shape is worse than a dead reference. Found by
        // the retired-surface check on its first run.
        'action': 'run_workflow',
        'workflow_id': 'setup',
        'operation_id': 'run',
        'host': '203.0.113.10',
        'username': 'ubuntu',
        'password': 'hunter2',
        'private_key': '-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n',
        'settings': <String, dynamic>{
          'superuser_password': 'postgres-root',
          'project_slug': 'demo',
        },
      });

      expect(sanitized['password'], isNot(contains('hunter2')));
      expect(sanitized['private_key'], isNot(contains('BEGIN OPENSSH')));
      final settings = sanitized['settings'] as Map<String, dynamic>;
      expect(settings['superuser_password'], isNot(contains('postgres-root')));
      // Non-secret intent must survive, or the corpus would be useless for
      // deriving params_schema shapes in T-1.5.3.
      expect(sanitized['host'], '203.0.113.10');
      expect(sanitized['username'], 'ubuntu');
      expect(settings['project_slug'], 'demo');
    });
  });
}
