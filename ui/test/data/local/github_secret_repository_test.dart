import 'package:ui/data/local/app_database.dart';
import 'package:ui/data/local/github_secret_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../_support/sqlite_test_harness.dart';

void main() {
  final sqliteAvailable = ensureSqliteRuntimeAvailable();

  group('DriftGitHubSecretRepository', () {
    late AppDatabase database;
    late DriftGitHubSecretRepository repository;

    setUp(() {
      database = AppDatabase.forTesting(NativeDatabase.memory());
      repository = DriftGitHubSecretRepository(database);
    });

    tearDown(() async {
      await database.close();
    });

    test('saves and reads auth token', () async {
      await repository.saveAuthToken('token-123');
      final token = await repository.readAuthToken();

      expect(token, 'token-123');
    }, skip: !sqliteAvailable);

    test('saves and reads deploy key by repository', () async {
      await repository.saveDeployKey(
        repositoryFullName: 'me/my-blog',
        publicKey: 'ssh-ed25519 AAAATEST',
        privateKey: '-----BEGIN PRIVATE KEY-----test',
      );

      final stored = await repository.readDeployKey('me/my-blog');
      expect(stored, isNotNull);
      expect(stored!.repositoryFullName, 'me/my-blog');
      expect(stored.publicKey, 'ssh-ed25519 AAAATEST');
      expect(stored.privateKey, '-----BEGIN PRIVATE KEY-----test');
    }, skip: !sqliteAvailable);

    test(
      'deleteDeployKey trims repository name and removes stored key',
      () async {
        await repository.saveDeployKey(
          repositoryFullName: 'me/my-blog',
          publicKey: 'ssh-ed25519 AAAATEST',
          privateKey: '-----BEGIN PRIVATE KEY-----test',
        );

        await repository.deleteDeployKey('  me/my-blog  ');

        expect(await repository.readDeployKey('me/my-blog'), isNull);
      },
      skip: !sqliteAvailable,
    );

    test('deleteDeployKey ignores blank repository names', () async {
      await repository.saveDeployKey(
        repositoryFullName: 'me/my-blog',
        publicKey: 'ssh-ed25519 AAAATEST',
        privateKey: '-----BEGIN PRIVATE KEY-----test',
      );

      await repository.deleteDeployKey('   ');

      expect(await repository.readDeployKey('me/my-blog'), isNotNull);
    }, skip: !sqliteAvailable);
  });
}
