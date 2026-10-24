part of '../../project_workspace.dart';

// Postgres form-validation patterns. One home for each regex (also avoids
// recompiling per keystroke); `final`, not `const` -- RegExp has no const
// constructor, so the validator takes both as required parameters.
final _postgresIdentifierPattern = RegExp(r'^[a-z][a-z0-9_]*$');
final _postgresDatabaseNamePattern = RegExp(r'^[a-z0-9_]+$');

extension _DatabaseTabLogic on _DatabaseTabViewState {
  _ProjectDatabaseEngine _resolveEngineForServer(Server server) {
    return _ProjectDatabaseEngine.postgres;
  }

  _ProjectDatabaseEngine? _engineForSection(_DatabaseTabSection section) {
    return switch (section) {
      _DatabaseTabSection.sqlite => null,
      _DatabaseTabSection.postgres => _ProjectDatabaseEngine.postgres,
    };
  }

  _DatabaseTabSection _resolveSectionForServer(Server server) {
    return server.serviceDatabaseEnabled
        ? _DatabaseTabSection.postgres
        : _DatabaseTabSection.sqlite;
  }

  int _defaultPortForEngine({
    required _ProjectDatabaseEngine engine,
    required Server? server,
  }) {
    return 5432;
  }

  String _databaseAccessLabel(String accessMode) {
    return accessMode == 'read_only'
        ? 'Can read data only'
        : 'Can read data and manage tables';
  }

  String _postgresPermissionHelpText(String accessMode) {
    return accessMode == 'read_only'
        ? 'Can read data only. This user cannot create or change tables.'
        : 'Can read data and manage tables includes create, edit, and '
              'delete table structure.';
  }

  String _defaultSqliteVolumeName({
    required Project project,
    required String sqliteName,
  }) {
    final projectSlug = slugifyProjectName(
      project.name,
      fallback: 'project-db',
    );
    final sqliteSlug = slugifyProjectName(sqliteName, fallback: 'db');
    return 'deploydash_sqlite_${projectSlug}_$sqliteSlug';
  }

  String _defaultSqliteFileName(String sqliteName) {
    final sqliteSlug = slugifyProjectName(sqliteName, fallback: 'db');
    if (sqliteSlug == 'primary') {
      return _DatabaseTabViewState._sqliteDefaultFileName;
    }
    return '$sqliteSlug.db';
  }

  String? _validateSqliteConfigName(String rawValue) {
    final value = rawValue.trim();
    if (value.isEmpty) {
      return 'Name is required.';
    }
    if (value.length > 64) {
      return 'Name must be 64 characters or fewer.';
    }
    if (!RegExp(r'^[A-Za-z0-9]+$').hasMatch(value)) {
      return 'Name can only use letters and numbers.';
    }
    return null;
  }

  Map<String, dynamic> _buildSqliteOperationSettings({
    required Project project,
    required ProjectSqliteDatabase sqliteDatabase,
  }) {
    final fallbackRepository = 'deploydash/local-app';
    final repositoryFullName = project.repositoryFullName?.trim();
    return <String, dynamic>{
      'project_slug': slugifyProjectName(project.name, fallback: 'project-db'),
      'repository_full_name':
          repositoryFullName != null && repositoryFullName.isNotEmpty
          ? repositoryFullName
          : fallbackRepository,
      'branch': project.deployBranch.trim().isNotEmpty
          ? project.deployBranch.trim()
          : 'main',
      'primary_domain': project.primaryDomain.trim() == 'Not configured'
          ? null
          : project.primaryDomain.trim(),
      'app_port': project.appPort,
      'sqlite_storage': <String, dynamic>{
        'enabled': true,
        'volume_name': sqliteDatabase.volumeName,
        'mount_path': sqliteDatabase.mountPath,
        'file_name': sqliteDatabase.fileName,
      },
    };
  }

  String? _validatePostgresDatabaseName(String rawValue) =>
      _validatePostgresIdentifier(
        rawValue,
        fieldLabel: 'Database name',
        requiredField: true,
        identifierPattern: _postgresDatabaseNamePattern,
        patternHelp: 'may only use lowercase letters, numbers, or underscores.',
      );

  /// Validates a postgres identifier for a form, returning an error or null.
  ///
  /// Why: database-name and identifier validation share trim + bounds +
  /// regex-guard and differ only in pattern, label, and required-ness; one
  /// owner keeps the bounds (63/3) and check order in one place. The
  /// pattern stays a parameter because names allow leading digits and
  /// identifiers require a leading letter -- unifying them would reject
  /// legal names.
  String? _validatePostgresIdentifier(
    String rawValue, {
    required String fieldLabel,
    required bool requiredField,
    required RegExp identifierPattern,
    required String patternHelp,
  }) {
    final value = rawValue.trim();
    if (value.isEmpty) {
      return requiredField ? '$fieldLabel is required.' : null;
    }
    if (value.length > 63) {
      return '$fieldLabel must be 63 characters or fewer.';
    }
    if (value.length < 3) {
      return '$fieldLabel must be at least 3 characters.';
    }
    if (!identifierPattern.hasMatch(value)) {
      return '$fieldLabel $patternHelp';
    }
    return null;
  }

  Map<String, dynamic> _buildPostgresSettings({
    required Server server,
    required Project project,
    Map<String, dynamic>? overrides,
  }) {
    return buildManagedPostgresProjectSettings(
      projectName: project.name,
      config: server.postgresConfig,
      overrides: <String, dynamic>{
        'known_project_slugs': knownProjectSlugsOnServer(
          projects: ref.read(projectListProvider),
          serverId: server.id,
        ),
        ...?overrides,
      },
    );
  }

  String _workflowIdForEngine(_ProjectDatabaseEngine engine) {
    return 'postgres';
  }

  Map<String, dynamic> _buildSettingsForEngine({
    required _ProjectDatabaseEngine engine,
    required Server server,
    required Project project,
    Map<String, dynamic>? settingsOverrides,
  }) {
    return switch (engine) {
      _ProjectDatabaseEngine.postgres => _buildPostgresSettings(
        server: server,
        project: project,
        overrides: settingsOverrides,
      ),
    };
  }

  String? _resolveSelectedDatabase({
    required List<String> availableDatabases,
    String? preferredDatabase,
  }) {
    if (availableDatabases.isEmpty) {
      return null;
    }
    if (preferredDatabase != null &&
        availableDatabases.contains(preferredDatabase)) {
      return preferredDatabase;
    }
    return availableDatabases.first;
  }

  String? _resolveSelectedUsername({
    required List<_ProjectDatabaseUserRecord> users,
    required String? selectedDatabase,
    String? preferredUsername,
  }) {
    if (selectedDatabase == null) {
      return null;
    }
    final scopedUsers = users
        .where((user) => user.database == selectedDatabase)
        .toList(growable: false);
    if (scopedUsers.isEmpty) {
      return null;
    }
    if (preferredUsername != null &&
        scopedUsers.any((user) => user.username == preferredUsername)) {
      return preferredUsername;
    }
    return scopedUsers.first.username;
  }

  _ProjectDatabaseUserRecord? _userForSelection({
    required List<_ProjectDatabaseUserRecord> users,
    required String? selectedDatabase,
    required String? selectedUsername,
  }) {
    if (selectedDatabase == null || selectedUsername == null) {
      return null;
    }
    for (final user in users) {
      if (user.database == selectedDatabase &&
          user.username == selectedUsername) {
        return user;
      }
    }
    return null;
  }

  String _credentialLookupKey({
    required _ProjectDatabaseEngine engine,
    required String? projectId,
    required String? serverId,
    required String username,
    String? databaseName,
  }) {
    final normalizedDatabase = databaseName?.trim() ?? '';
    return '${serverId?.trim() ?? ''}|${projectId?.trim() ?? ''}|'
        '${engine.name}|$normalizedDatabase|${username.trim()}';
  }

  ({String? username, String? password, String? databaseName})
  _parseConnectionUriCredentials(String? connectionUri) {
    final raw = connectionUri?.trim();
    if (raw == null || raw.isEmpty) {
      return (username: null, password: null, databaseName: null);
    }

    final parsed = Uri.tryParse(raw);
    if (parsed == null) {
      return (username: null, password: null, databaseName: null);
    }

    final userInfo = parsed.userInfo;
    final separator = userInfo.indexOf(':');
    final username = separator >= 0
        ? userInfo.substring(0, separator).trim()
        : userInfo.trim();
    final password = separator >= 0
        ? userInfo.substring(separator + 1).trim()
        : null;
    final path = parsed.path.trim();
    final databaseName = path.startsWith('/') ? path.substring(1).trim() : path;

    return (
      username: username.isEmpty ? null : username,
      password: password == null || password.isEmpty ? null : password,
      databaseName: databaseName.isEmpty ? null : databaseName,
    );
  }

  String _webAppHostForEngine({
    required _ProjectDatabaseEngine engine,
    required String host,
  }) {
    if (engine == _ProjectDatabaseEngine.postgres) {
      return 'host.docker.internal';
    }
    return formatHostForDisplay(host);
  }

  String? _webAppConnectionUriForEngine({
    required _ProjectDatabaseEngine engine,
    String? connectionUri,
  }) {
    final raw = connectionUri?.trim();
    if (raw == null || raw.isEmpty) {
      return null;
    }
    if (engine != _ProjectDatabaseEngine.postgres) {
      return raw;
    }

    final parsed = Uri.tryParse(raw);
    if (parsed == null) {
      return raw;
    }

    return parsed.replace(host: 'host.docker.internal').toString();
  }

  Project? _projectById(List<Project> projects, String projectId) {
    for (final project in projects) {
      if (project.id == projectId) {
        return project;
      }
    }
    return null;
  }

  String _formatTimestamp(DateTime? value) {
    if (value == null) {
      return 'Unavailable';
    }
    final local = value.toLocal();
    String twoDigits(int part) => part.toString().padLeft(2, '0');
    return '${local.year}-${twoDigits(local.month)}-${twoDigits(local.day)} '
        '${twoDigits(local.hour)}:${twoDigits(local.minute)}';
  }

  bool _isSqliteCheckStale(DateTime? value) {
    if (value == null) {
      return true;
    }
    return DateTime.now().difference(value.toLocal()) >
        const Duration(minutes: 15);
  }

  String _formatSqliteCheckAge(DateTime? value) {
    if (value == null) {
      return 'Not checked yet';
    }
    final age = DateTime.now().difference(value.toLocal());
    if (age.isNegative || age < const Duration(minutes: 1)) {
      return 'Checked just now';
    }
    if (age < const Duration(hours: 1)) {
      return 'Checked ${age.inMinutes} min ago';
    }
    if (age < const Duration(days: 1)) {
      return 'Checked ${age.inHours} hr ago';
    }
    return 'Checked ${age.inDays} days ago';
  }

  String _formatByteSize(int? bytes) {
    if (bytes == null) {
      return 'Unavailable';
    }
    if (bytes < 1024) {
      return '$bytes B';
    }
    final kib = bytes / 1024;
    if (kib < 1024) {
      return '${kib.toStringAsFixed(1)} KiB';
    }
    final mib = kib / 1024;
    if (mib < 1024) {
      return '${mib.toStringAsFixed(1)} MiB';
    }
    final gib = mib / 1024;
    return '${gib.toStringAsFixed(2)} GiB';
  }
}
