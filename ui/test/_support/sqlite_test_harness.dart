import 'package:sqlite3/sqlite3.dart' as sqlite;

bool ensureSqliteRuntimeAvailable() {
  try {
    final _ = sqlite.sqlite3.version;
    return true;
  } catch (_) {
    return false;
  }
}

bool ensureEncryptedSqliteRuntimeAvailable() {
  try {
    final db = sqlite.sqlite3.openInMemory();
    try {
      final rows = db.select('PRAGMA cipher;');
      if (rows.isEmpty) {
        return false;
      }
      return (rows.first.columnAt(0)?.toString().trim() ?? '').isNotEmpty;
    } finally {
      db.close();
    }
  } catch (_) {
    return false;
  }
}
