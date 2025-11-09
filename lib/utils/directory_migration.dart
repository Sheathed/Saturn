import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:logging/logging.dart';

class DirectoryMigration {
  static final Logger _logger = Logger('DirectoryMigration');
  static bool _migrationCompleted = false;

  /// Files that need to be migrated
  static const List<String> _filesToMigrate = [
    'settings.json',
    'metacache.json',
    'homescreen.json',
    'playback.json',
    'saturn.log',
    'download.log',
  ];
  static Future<bool> migrate() async {
    if (_migrationCompleted) {
      return true;
    }

    try {
      final oldDir = await getApplicationDocumentsDirectory();
      final newDir = await getApplicationSupportDirectory();

      _logger.info('Starting directory migration...');
      _logger.info('Old directory: ${oldDir.path}');
      _logger.info('New directory: ${newDir.path}');

      // Ensure new directory exists
      if (!await newDir.exists()) {
        await newDir.create(recursive: true);
      }

      int migratedCount = 0;
      int skippedCount = 0;
      int errorCount = 0;

      for (final filename in _filesToMigrate) {
        try {
          final oldFile = File('${oldDir.path}/$filename');
          final newFile = File('${newDir.path}/$filename');

          // Check if file exists in old location
          if (await oldFile.exists()) {
            // Check if file already exists in new location
            if (await newFile.exists()) {
              _logger.info(
                '$filename already exists in new location, skipping migration',
              );
              skippedCount++;

              // Optionally delete old file after verifying new file exists
              try {
                await oldFile.delete();
                _logger.info('Deleted old $filename from documents directory');
              } catch (e) {
                _logger.warning('Could not delete old $filename: $e');
              }
            } else {
              // Copy file to new location
              await oldFile.copy(newFile.path);
              _logger.info('Migrated $filename to new location');

              // Verify the copy was successful
              if (await newFile.exists()) {
                migratedCount++;
                // Delete old file after successful migration
                try {
                  await oldFile.delete();
                  _logger.info(
                    'Deleted old $filename after successful migration',
                  );
                } catch (e) {
                  _logger.warning('Could not delete old $filename: $e');
                }
              } else {
                _logger.severe(
                  'Migration failed for $filename - new file not found',
                );
                errorCount++;
              }
            }
          } else {
            _logger.info(
              '$filename does not exist in old location, no migration needed',
            );
          }
        } catch (e, stack) {
          _logger.severe('Error migrating $filename: $e', e, stack);
          errorCount++;
        }
      }

      _logger.info(
        'Migration completed: $migratedCount migrated, $skippedCount skipped, $errorCount errors',
      );

      _migrationCompleted = true;
      return errorCount == 0;
    } catch (e, stack) {
      _logger.severe('Fatal error during migration: $e', e, stack);
      return false;
    }
  }

  static Future<Directory> getAppSupportDirectory() async {
    await migrate();
    return await getApplicationSupportDirectory();
  }

  static Future<String> getAppSupportFilePath(String filename) async {
    final dir = await getAppSupportDirectory();
    return '${dir.path}/$filename';
  }
}
