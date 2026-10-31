import 'package:flutter/services.dart' show appFlavor;
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' show getDatabasesPath;

// Keep builds without a native flavor consistent with Android's product flavor.
const appBuildFlavor =
    appFlavor ??
    String.fromEnvironment('SATURN_FLAVOR', defaultValue: 'stable');

String get appTitle {
  switch (appBuildFlavor) {
    case 'canary':
      return 'Saturn Canary';
    case 'dev':
      return 'Saturn Dev';
    default:
      return 'Saturn';
  }
}

/// Returns Saturn's flavor-isolated app data directory.
///
/// Stable keeps the historical directory so existing installs continue to
/// use their current settings, database, and downloads. Canary and dev get
/// dedicated subdirectories on every desktop platform.
Future<Directory> getFlavorSupportDirectory() async {
  final base = await getApplicationSupportDirectory();
  final directory = appBuildFlavor == 'stable'
      ? base
      : Directory(p.join(base.path, 'flavors', appBuildFlavor));
  if (!await directory.exists()) {
    await directory.create(recursive: true);
  }
  return directory;
}

/// Flavor-specific database directory.
///
/// On desktop, sqflite_common_ffi defaults to a `.dart_tool` directory under
/// the process working directory. Installed applications can start with their
/// working directory inside a protected install folder, so keep the database
/// under Saturn's writable application-support directory instead. Copy any
/// existing desktop databases forward once so users retain offline content.
Future<String> getFlavorDatabaseDirectory() async {
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    final supportDirectory = await getFlavorSupportDirectory();
    final directory = Directory(p.join(supportDirectory.path, 'databases'));
    await directory.create(recursive: true);

    final legacyDirectories = <String>[supportDirectory.path];
    try {
      legacyDirectories.insert(0, p.absolute(await getDatabasesPath()));
    } catch (_) {
      // Continue with app-support and Documents locations if FFI cannot
      // resolve its working-directory database path.
    }
    // Older Windows stable builds may have stored their database in Documents.
    if (appBuildFlavor == 'stable') {
      try {
        legacyDirectories.add((await getApplicationDocumentsDirectory()).path);
      } catch (_) {
        // Documents is optional; the other legacy locations are still checked.
      }
    }

    for (final legacyPath in legacyDirectories) {
      if (p.equals(p.normalize(legacyPath), p.normalize(directory.path))) {
        continue;
      }
      for (final databaseName in ['offline2.db', 'offline.db']) {
        final legacyDatabase = File(p.join(legacyPath, databaseName));
        final newDatabase = File(p.join(directory.path, databaseName));
        final stagedFiles = <File>[];
        try {
          if (!await legacyDatabase.exists() || await newDatabase.exists()) {
            continue;
          }

          // Stage all SQLite files before exposing the new database path, so
          // an interrupted copy cannot leave a partial database behind.
          for (final suffix in ['', '-wal', '-shm']) {
            final source = File('${legacyDatabase.path}$suffix');
            if (!await source.exists()) continue;
            final staged = File('${newDatabase.path}.migration$suffix');
            if (await staged.exists()) await staged.delete();
            await source.copy(staged.path);
            stagedFiles.add(staged);
          }

          for (final staged in stagedFiles.where(
            (file) => !file.path.endsWith('.db.migration'),
          )) {
            final suffix = staged.path.endsWith('-wal') ? '-wal' : '-shm';
            await staged.rename('${newDatabase.path}$suffix');
          }
          final stagedDatabase = File('${newDatabase.path}.migration');
          await stagedDatabase.rename(newDatabase.path);
        } catch (_) {
          for (final staged in stagedFiles) {
            if (await staged.exists()) await staged.delete();
          }
          // An inaccessible old location should not block trying the other
          // legacy locations or opening a fresh database in app support.
        }
      }
    }

    return directory.path;
  }

  // Keep Android and iOS on their platform-provided database paths.
  final basePath = await getDatabasesPath();
  final directory = appBuildFlavor == 'stable'
      ? Directory(basePath)
      : Directory(p.join(basePath, 'flavors', appBuildFlavor));
  if (!await directory.exists()) {
    await directory.create(recursive: true);
  }
  return directory.path;
}
