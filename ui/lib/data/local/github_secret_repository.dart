import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_database.dart';

/// The deploy key Deploy Dash generated for one GitHub repository.
///
/// Per repository, not per account: a key that can read one repo is a much
/// smaller thing to lose than one that can read all of them.
class GitHubDeployKeyRecord {
  /// Pairs a repository with the key installed on it.
  const GitHubDeployKeyRecord({
    required this.repositoryFullName,
    required this.publicKey,
    required this.privateKey,
  });

  /// The repository, as `owner/name`.
  final String repositoryFullName;

  /// The public half, which is what gets added to the repository on GitHub.
  final String publicKey;

  /// The private half, sent inline with a clone so the server never keeps a
  /// copy of its own.
  final String privateKey;
}

/// The one boundary for GitHub credentials in the local database.
///
/// An interface so the OAuth and deploy flows can be tested without SQLCipher,
/// and so there is one named place to look for "where do we keep the GitHub
/// token".
abstract class GitHubSecretRepository {
  /// The stored OAuth access token, or null when not connected.
  Future<String?> readAuthToken();

  /// Stores the OAuth access token, replacing any previous one.
  Future<void> saveAuthToken(String accessToken);

  /// Removes the stored token. What disconnecting GitHub does locally.
  Future<void> clearAuthToken();

  /// The deploy key for a repository, or null when none was generated.
  Future<GitHubDeployKeyRecord?> readDeployKey(String repositoryFullName);

  /// Removes a repository's deploy key.
  Future<void> deleteDeployKey(String repositoryFullName);

  /// Stores a repository's deploy key, replacing any previous one.
  Future<void> saveDeployKey({
    required String repositoryFullName,
    required String publicKey,
    required String privateKey,
  });
}

/// The shipped implementation, backed by the encrypted local database.
///
/// Exactly one auth token is stored, at a fixed row id -- there is one signed-in
/// GitHub account, and pinning the row makes that structural rather than a
/// convention every writer has to keep. Every write drops blank input rather
/// than storing it, so a cleared field never becomes an empty credential that
/// later fails at clone time.
class DriftGitHubSecretRepository implements GitHubSecretRepository {
  /// Creates the repository over the app database.
  const DriftGitHubSecretRepository(this._database);

  static const _authTokenRowId = 1;
  final AppDatabase _database;

  @override
  Future<String?> readAuthToken() async {
    final row =
        await (_database.select(_database.gitHubAuthTokens)
              ..where((table) => table.id.equals(_authTokenRowId))
              ..limit(1))
            .getSingleOrNull();
    return row?.accessToken;
  }

  @override
  Future<void> saveAuthToken(String accessToken) async {
    final normalized = accessToken.trim();
    if (normalized.isEmpty) {
      return;
    }
    final now = DateTime.now();
    await _database
        .into(_database.gitHubAuthTokens)
        .insertOnConflictUpdate(
          GitHubAuthTokensCompanion.insert(
            id: const Value(_authTokenRowId),
            accessToken: normalized,
            createdAt: Value(now),
            updatedAt: Value(now),
          ),
        );
  }

  @override
  Future<void> clearAuthToken() async {
    await (_database.delete(
      _database.gitHubAuthTokens,
    )..where((table) => table.id.equals(_authTokenRowId))).go();
  }

  @override
  Future<GitHubDeployKeyRecord?> readDeployKey(
    String repositoryFullName,
  ) async {
    final normalizedRepo = repositoryFullName.trim();
    if (normalizedRepo.isEmpty) {
      return null;
    }
    final row =
        await (_database.select(_database.gitHubDeployKeys)
              ..where(
                (table) => table.repositoryFullName.equals(normalizedRepo),
              )
              ..limit(1))
            .getSingleOrNull();
    if (row == null) {
      return null;
    }
    return GitHubDeployKeyRecord(
      repositoryFullName: row.repositoryFullName,
      publicKey: row.publicKey,
      privateKey: row.privateKey,
    );
  }

  @override
  Future<void> deleteDeployKey(String repositoryFullName) async {
    final normalizedRepo = repositoryFullName.trim();
    if (normalizedRepo.isEmpty) {
      return;
    }
    await (_database.delete(
      _database.gitHubDeployKeys,
    )..where((table) => table.repositoryFullName.equals(normalizedRepo))).go();
  }

  @override
  Future<void> saveDeployKey({
    required String repositoryFullName,
    required String publicKey,
    required String privateKey,
  }) async {
    final normalizedRepo = repositoryFullName.trim();
    final normalizedPublic = publicKey.trim();
    final normalizedPrivate = privateKey.trim();
    if (normalizedRepo.isEmpty ||
        normalizedPublic.isEmpty ||
        normalizedPrivate.isEmpty) {
      return;
    }

    final now = DateTime.now();
    await _database
        .into(_database.gitHubDeployKeys)
        .insertOnConflictUpdate(
          GitHubDeployKeysCompanion.insert(
            repositoryFullName: normalizedRepo,
            publicKey: normalizedPublic,
            privateKey: normalizedPrivate,
            createdAt: Value(now),
            updatedAt: Value(now),
          ),
        );
  }
}

/// The app-wide GitHub secret repository.
final gitHubSecretRepositoryProvider = Provider<GitHubSecretRepository>((ref) {
  final database = ref.watch(appDatabaseProvider);
  return DriftGitHubSecretRepository(database);
});
