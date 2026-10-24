import 'package:ui/domain/project_sqlite_database.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ProjectSqliteDatabase derives its canonical SQLite paths', () {
    const sqliteDatabase = ProjectSqliteDatabase(
      id: 'sqlite-1',
      projectId: 'project-1',
      name: 'Primary',
      volumeName: 'deploydash_project_1',
      mountPath: '/var/lib/app',
      fileName: 'main.db',
    );

    expect(sqliteDatabase.databasePath, '/var/lib/app/main.db');
    expect(sqliteDatabase.databaseUrl, 'sqlite:////var/lib/app/main.db');
  });
}
