import 'dart:math';

import 'package:ui/services/postgres_service_password.dart';
import 'package:ui/services/sensitive_data_sanitizer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('generated PostgreSQL service passwords are strong and redactable', () {
    final password = generatePostgresServicePassword(random: Random(42));

    expect(password, hasLength(48));
    expect(password, matches(RegExp(r'^[A-Za-z0-9_-]+$')));
    expect(
      sanitizeSensitivePayloadMap(<String, dynamic>{
        'superuser_password': password,
      }),
      <String, dynamic>{'superuser_password': '***'},
    );
  });
}
