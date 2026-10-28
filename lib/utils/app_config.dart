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

/// Flavor-specific database directory while preserving stable's old path.
Future<String> getFlavorDatabaseDirectory() async {
  final basePath = await getDatabasesPath();
  final directory = appBuildFlavor == 'stable'
      ? Directory(basePath)
      : Directory(p.join(basePath, 'flavors', appBuildFlavor));
  if (!await directory.exists()) {
    await directory.create(recursive: true);
  }
  return directory.path;
}
