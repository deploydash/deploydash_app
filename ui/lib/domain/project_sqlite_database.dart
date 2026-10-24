class ProjectSqliteDatabase {
  const ProjectSqliteDatabase({
    required this.id,
    required this.projectId,
    required this.name,
    required this.volumeName,
    required this.mountPath,
    required this.fileName,
    this.isPrimary = false,
    this.volumeExists,
    this.volumeMountpoint,
    this.volumeSizeBytes,
    this.lastCheckedAt,
  });

  static const Object noChange = Object();

  final String id;
  final String projectId;
  final String name;
  final String volumeName;
  final String mountPath;
  final String fileName;
  final bool isPrimary;
  final bool? volumeExists;
  final String? volumeMountpoint;
  final int? volumeSizeBytes;
  final DateTime? lastCheckedAt;

  String get databasePath => '$mountPath/$fileName';
  String get databaseUrl => 'sqlite:///$databasePath';

  ProjectSqliteDatabase copyWith({
    String? id,
    String? projectId,
    String? name,
    String? volumeName,
    String? mountPath,
    String? fileName,
    bool? isPrimary,
    bool? volumeExists,
    Object? volumeMountpoint = noChange,
    Object? volumeSizeBytes = noChange,
    Object? lastCheckedAt = noChange,
  }) {
    return ProjectSqliteDatabase(
      id: id ?? this.id,
      projectId: projectId ?? this.projectId,
      name: name ?? this.name,
      volumeName: volumeName ?? this.volumeName,
      mountPath: mountPath ?? this.mountPath,
      fileName: fileName ?? this.fileName,
      isPrimary: isPrimary ?? this.isPrimary,
      volumeExists: volumeExists ?? this.volumeExists,
      volumeMountpoint: identical(volumeMountpoint, noChange)
          ? this.volumeMountpoint
          : volumeMountpoint as String?,
      volumeSizeBytes: identical(volumeSizeBytes, noChange)
          ? this.volumeSizeBytes
          : volumeSizeBytes as int?,
      lastCheckedAt: identical(lastCheckedAt, noChange)
          ? this.lastCheckedAt
          : lastCheckedAt as DateTime?,
    );
  }
}
