class Project {
  static const Object noChange = Object();

  const Project({
    required this.id,
    this.serverId,
    required this.name,
    required this.type,
    required this.gitUrl,
    required this.primaryDomain,
    this.domainRoutingMode = 'single_host',
    this.repositoryFullName,
    this.appSubdirectory,
    this.deployBranch = 'main',
    this.appPort = 3000,
    this.publicHealthCheckEnabled = true,
    this.publicHealthCheckPath = '/',
    this.lastDeployCommit,
    this.lastDeployedAt,
    this.railpackBuildCommand = 'npm run build',
    this.railpackRunCommand = 'npm run start',
    this.railpackProvider,
    this.railpackNodeMode = 'auto',
    this.tlsChallengeMode = 'http',
    this.tlsDnsProvider,
    this.tlsDnsCredentials = const <String, String>{},
    this.appDisconnected = false,
    this.injectPostgresEnv = false,
    this.sqliteStorageEnabled = false,
    this.sqliteVolumeName,
    this.sqliteMountPath,
    this.sqliteFileName,
    this.isActive = false,
  });

  final String id;
  final String? serverId;
  final String name;
  final String type;
  final String gitUrl;
  final String primaryDomain;
  final String domainRoutingMode;
  final String? repositoryFullName;
  final String? appSubdirectory;
  final String deployBranch;
  final int appPort;
  final bool publicHealthCheckEnabled;
  final String publicHealthCheckPath;
  final String? lastDeployCommit;
  final DateTime? lastDeployedAt;
  final String railpackBuildCommand;
  final String railpackRunCommand;
  final String? railpackProvider;
  final String railpackNodeMode;
  final String tlsChallengeMode;
  final String? tlsDnsProvider;
  final Map<String, String> tlsDnsCredentials;
  final bool appDisconnected;
  final bool injectPostgresEnv;
  final bool sqliteStorageEnabled;
  final String? sqliteVolumeName;
  final String? sqliteMountPath;
  final String? sqliteFileName;
  final bool isActive;

  /// The build-command override, normalized for deployment.
  ///
  /// An empty value delegates to the selected Railpack provider default.
  String get effectiveBuildCommand => railpackBuildCommand.trim();

  Project copyWith({
    Object? serverId = noChange,
    String? primaryDomain,
    String? domainRoutingMode,
    String? repositoryFullName,
    Object? appSubdirectory = noChange,
    String? deployBranch,
    int? appPort,
    bool? publicHealthCheckEnabled,
    String? publicHealthCheckPath,
    String? lastDeployCommit,
    DateTime? lastDeployedAt,
    String? railpackBuildCommand,
    String? railpackRunCommand,
    Object? railpackProvider = noChange,
    String? railpackNodeMode,
    String? tlsChallengeMode,
    Object? tlsDnsProvider = noChange,
    Object? tlsDnsCredentials = noChange,
    bool? appDisconnected,
    bool? injectPostgresEnv,
    bool? sqliteStorageEnabled,
    Object? sqliteVolumeName = noChange,
    Object? sqliteMountPath = noChange,
    Object? sqliteFileName = noChange,
    bool? isActive,
  }) {
    return Project(
      id: id,
      serverId: identical(serverId, noChange)
          ? this.serverId
          : serverId as String?,
      name: name,
      type: type,
      gitUrl: gitUrl,
      primaryDomain: primaryDomain ?? this.primaryDomain,
      domainRoutingMode: domainRoutingMode ?? this.domainRoutingMode,
      repositoryFullName: repositoryFullName ?? this.repositoryFullName,
      appSubdirectory: identical(appSubdirectory, noChange)
          ? this.appSubdirectory
          : appSubdirectory as String?,
      deployBranch: deployBranch ?? this.deployBranch,
      appPort: appPort ?? this.appPort,
      publicHealthCheckEnabled:
          publicHealthCheckEnabled ?? this.publicHealthCheckEnabled,
      publicHealthCheckPath:
          publicHealthCheckPath ?? this.publicHealthCheckPath,
      lastDeployCommit: lastDeployCommit ?? this.lastDeployCommit,
      lastDeployedAt: lastDeployedAt ?? this.lastDeployedAt,
      railpackBuildCommand: railpackBuildCommand ?? this.railpackBuildCommand,
      railpackRunCommand: railpackRunCommand ?? this.railpackRunCommand,
      railpackProvider: identical(railpackProvider, noChange)
          ? this.railpackProvider
          : railpackProvider as String?,
      railpackNodeMode: railpackNodeMode ?? this.railpackNodeMode,
      tlsChallengeMode: tlsChallengeMode ?? this.tlsChallengeMode,
      tlsDnsProvider: identical(tlsDnsProvider, noChange)
          ? this.tlsDnsProvider
          : tlsDnsProvider as String?,
      tlsDnsCredentials: identical(tlsDnsCredentials, noChange)
          ? this.tlsDnsCredentials
          : Map<String, String>.from(tlsDnsCredentials as Map<String, String>),
      appDisconnected: appDisconnected ?? this.appDisconnected,
      injectPostgresEnv: injectPostgresEnv ?? this.injectPostgresEnv,
      sqliteStorageEnabled: sqliteStorageEnabled ?? this.sqliteStorageEnabled,
      sqliteVolumeName: identical(sqliteVolumeName, noChange)
          ? this.sqliteVolumeName
          : sqliteVolumeName as String?,
      sqliteMountPath: identical(sqliteMountPath, noChange)
          ? this.sqliteMountPath
          : sqliteMountPath as String?,
      sqliteFileName: identical(sqliteFileName, noChange)
          ? this.sqliteFileName
          : sqliteFileName as String?,
      isActive: isActive ?? this.isActive,
    );
  }
}
