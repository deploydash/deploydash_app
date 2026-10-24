import 'package:ui/services/sensitive_data_sanitizer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('sanitizeSensitiveData', () {
    test('redacts environment descendants and credential text shapes', () {
      const canary = 'DD_TEST_SECRET_DO_NOT_LOG_7f4c';
      final sanitized = sanitizeSensitiveData(<String, Object?>{
        'runtime_env': <String, Object?>{
          'FEATURE_FLAG': canary,
          'NESTED': <String, Object?>{'SAFE_NAME': canary},
          'LIST': <Object?>[
            canary,
            <String, Object?>{'PORT': 3000},
          ],
        },
        'wrapper': <String, Object?>{
          'env': <String, Object?>{'ARBITRARY': canary},
          'env_vars': <String, Object?>{'OTHER': canary},
          'environment': <String, Object?>{'THIRD': canary},
        },
        'message':
            'Authorization: Bearer $canary\n'
            '-----BEGIN PRIVATE KEY-----\n$canary\n-----END PRIVATE KEY-----\n'
            r'-----BEGIN OPENSSH PRIVATE KEY-----\n'
            '$canary'
            r'\n-----END OPENSSH PRIVATE KEY-----',
        'compiler': '/workspace/lib/main.dart ERR_BUILD_42 abcdef1234567890',
      });

      expect(sanitized.toString(), isNot(contains(canary)));
      expect(
        (sanitized as Map<String, Object?>)['runtime_env'],
        <String, Object?>{
          'FEATURE_FLAG': '***',
          'NESTED': <String, Object?>{'SAFE_NAME': '***'},
          'LIST': <Object?>[
            '***',
            <String, Object?>{'PORT': '***'},
          ],
        },
      );
      expect(sanitized['message'], contains('Authorization: Bearer ***'));
      expect(sanitized['message'], isNot(contains('BEGIN PRIVATE KEY')));
      expect(
        sanitized['message'],
        isNot(contains('BEGIN OPENSSH PRIVATE KEY')),
      );
      expect(
        sanitized['compiler'],
        '/workspace/lib/main.dart ERR_BUILD_42 abcdef1234567890',
      );
    });

    test('redacts the managed user password (#62)', () {
      // Green on arrival: the generic `password` pattern already covers the
      // setup-result key and the setup command's `MANAGED_PASSWORD=`
      // assignment. This pins that coverage so a future pattern narrowing
      // cannot silently start leaking the managed password.
      expect(
        sanitizeSensitiveData(<String, Object?>{
          'status': 'success',
          'managed_user_password':
              'C1nL0wlFXAbfMIXpr0LKaez51aai2qXW6kI_c3Qhq3Y',
        }),
        <String, Object?>{'status': 'success', 'managed_user_password': '***'},
      );
      final redacted = sanitizeSensitiveText(
        'set -eu; MANAGED_PASSWORD=secret-value; adduser x',
      );
      expect(redacted, isNot(contains('secret-value')));
      expect(redacted, contains('MANAGED_PASSWORD=***'));
    });

    test('redacts the server credential storage payload shape', () {
      expect(
        sanitizeSensitiveData(<String, Object?>{
          'server_id': 'server-1',
          'ssh_password': 'correct horse battery staple',
          'private_key': '-----BEGIN OPENSSH PRIVATE KEY-----',
          'key_path': '/home/user/.ssh/id_ed25519',
          'public_key': 'ssh-ed25519 AAAA public@example.test',
        }),
        <String, Object?>{
          'server_id': 'server-1',
          'ssh_password': '***',
          'private_key': '***',
          'key_path': '***',
          'public_key': 'ssh-ed25519 AAAA public@example.test',
        },
      );
    });

    test(
      'covers every supported text transport without erasing diagnostics',
      () {
        const canary = 'DD_TEST_SECRET_DO_NOT_LOG_7f4c';
        final sanitized = sanitizeSensitiveText(
          '\u001b[31m'
          '"api_token": "$canary"\n'
          'FEATURE_FLAG\t$canary\n'
          '"APP_NAME":"$canary"\n'
          'PORT=3000 DATABASE_URL=postgres://user:$canary@example/db\n'
          'artifact=/workspace/build/app code=ERR_BUILD_42',
        );

        expect(sanitized, isNot(contains(canary)));
        expect(sanitized, contains('"api_token": "***"'));
        expect(sanitized, contains('FEATURE_FLAG\t***'));
        expect(sanitized, contains('"APP_NAME":"***"'));
        expect(sanitized, contains('PORT=***'));
        expect(sanitized, contains('DATABASE_URL=***'));
        expect(sanitized, contains('/workspace/build/app'));
        expect(sanitized, contains('ERR_BUILD_42'));
        expect(sanitized, isNot(contains('\u001b[31m')));
        expect(
          sanitizeSensitiveText('connect=postgres://user:$canary@example/db'),
          'connect=postgres://user:***@example/db',
        );
        expect(
          sanitizeSensitiveData(<Object?>['password=$canary', 42]),
          <Object?>['password=***', 42],
        );
      },
    );

    test(
      'accepts every JSON object boundary shape and rejects non-objects',
      () {
        const canary = 'DD_TEST_SECRET_DO_NOT_LOG_7f4c';
        expect(
          sanitizeSensitivePayloadMap(<String, dynamic>{'password': canary}),
          <String, dynamic>{'password': '***'},
        );
        expect(
          sanitizeJsonObjectFromUnknown(<String, dynamic>{'token': canary}),
          <String, dynamic>{'token': '***'},
        );
        expect(
          sanitizeJsonObjectFromUnknown(<Object?, Object?>{1: canary}),
          <String, dynamic>{'1': canary},
        );
        expect(
          sanitizeJsonObjectFromUnknown('{"runtime_env":{"PORT":"3000"}}'),
          <String, dynamic>{
            'runtime_env': <String, dynamic>{'PORT': '***'},
          },
        );
        expect(
          () => sanitizeJsonObjectFromUnknown(null),
          throwsFormatException,
        );
        expect(
          () => sanitizeJsonObjectFromUnknown('   '),
          throwsFormatException,
        );
        expect(
          () => sanitizeJsonObjectFromUnknown('[]'),
          throwsFormatException,
        );
      },
    );
  });
}
