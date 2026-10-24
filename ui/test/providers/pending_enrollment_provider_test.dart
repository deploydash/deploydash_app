import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/data/local/server_repository.dart';
import 'package:ui/providers/pending_enrollment_provider.dart';

void main() {
  PendingEnrollment enrollment() {
    return PendingEnrollment(
      draft: const ServerDraft(
        name: 'Pending-01',
        host: '203.0.113.40',
        port: 22,
        sshUser: 'root',
        authMethod: ServerAuthMethod.password,
        sshPassword: 'bootstrap-secret',
      ),
      checkResult: const <String, dynamic>{'status': 'success'},
    );
  }

  test('pending enrollment defaults to nothing awaiting enrollment', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(pendingEnrollmentProvider), isNull);
  });

  test('a seeded scope opens with its pending enrollment', () {
    final pending = enrollment();
    final container = ProviderContainer(
      overrides: [
        pendingEnrollmentProvider.overrideWith(
          () => PendingEnrollmentNotifier(pending),
        ),
      ],
    );
    addTearDown(container.dispose);

    expect(container.read(pendingEnrollmentProvider), same(pending));
  });

  test('clear drops the pending enrollment exactly once', () {
    final container = ProviderContainer(
      overrides: [
        pendingEnrollmentProvider.overrideWith(
          () => PendingEnrollmentNotifier(enrollment()),
        ),
      ],
    );
    addTearDown(container.dispose);

    container.read(pendingEnrollmentProvider.notifier).clear();

    expect(container.read(pendingEnrollmentProvider), isNull);
  });
}
