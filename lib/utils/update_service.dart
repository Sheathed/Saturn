import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

class UpdateService extends ChangeNotifier {
  UpdateService._();

  static final UpdateService instance = UpdateService._();
  static const _releaseUrl =
      'https://api.github.com/repos/Sheathed/Saturn/releases/latest';
  static const _notificationChannelId = 'saturn_updates';
  static const _notificationChannelName = 'Updates';
  static const _notificationId = 7401;

  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();
  Future<void>? _checkInProgress;
  bool _notificationSetup = false;
  bool _notifyWhenReady = false;

  bool isChecking = false;
  String? currentVersion;
  String? latestVersion;
  String? changelog;
  String? releasePageUrl;
  String? errorMessage;

  bool get updateAvailable =>
      latestVersion != null &&
      currentVersion != null &&
      compareVersions(latestVersion!, currentVersion!) > 0;

  Future<void> checkForUpdates({bool notifyIfAvailable = false}) {
    _notifyWhenReady = _notifyWhenReady || notifyIfAvailable;
    final existing = _checkInProgress;
    if (existing != null) return existing;
    isChecking = true;
    errorMessage = null;
    notifyListeners();
    final check = _performCheck();
    _checkInProgress = check.whenComplete(() {
      isChecking = false;
      _checkInProgress = null;
      notifyListeners();
    });
    return _checkInProgress!;
  }

  Future<void> _performCheck() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final response = await http
          .get(
            Uri.parse(_releaseUrl),
            headers: const {'Accept': 'application/vnd.github+json'},
          )
          .timeout(const Duration(seconds: 12));
      if (response.statusCode != 200) {
        throw HttpException('GitHub returned HTTP ${response.statusCode}');
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final tag = data['tag_name'] as String?;
      if (tag == null || tag.trim().isEmpty) {
        throw const FormatException('Release response had no version tag.');
      }
      currentVersion = info.version;
      latestVersion = tag.replaceFirst(RegExp(r'^v'), '');
      changelog = data['body'] as String?;
      releasePageUrl = data['html_url'] as String?;
      errorMessage = null;

      if (_notifyWhenReady && updateAvailable) {
        await _notifyNewVersion(latestVersion!);
      }
    } catch (error, stackTrace) {
      errorMessage = error.toString();
      Logger.root.warning(
        'Could not check for updates: $error',
        error,
        stackTrace,
      );
    } finally {
      _notifyWhenReady = false;
    }
  }

  int compareVersions(String left, String right) {
    final leftParts = RegExp(
      r'\d+',
    ).allMatches(left.split('+').first).map((match) => int.parse(match[0]!));
    final rightParts = RegExp(
      r'\d+',
    ).allMatches(right.split('+').first).map((match) => int.parse(match[0]!));
    final a = leftParts.toList();
    final b = rightParts.toList();
    final length = a.length > b.length ? a.length : b.length;
    for (var index = 0; index < length; index++) {
      final comparison = (index < a.length ? a[index] : 0).compareTo(
        index < b.length ? b[index] : 0,
      );
      if (comparison != 0) return comparison;
    }
    return 0;
  }

  Future<void> _initializeNotifications() async {
    if (_notificationSetup) return;
    final initialization = InitializationSettings(
      android: const AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: const DarwinInitializationSettings(),
      macOS: const DarwinInitializationSettings(),
      linux: const LinuxInitializationSettings(defaultActionName: 'Open'),
      windows: const WindowsInitializationSettings(
        appName: 'Saturn',
        appUserModelId: 's.s.saturn.SaturnApp',
        guid: 'a4c71c7a-7785-4f87-a9b6-46c817fd2d12',
      ),
    );
    await _notifications.initialize(
      settings: initialization,
      onDidReceiveNotificationResponse: (response) {
        final url = response.payload ?? releasePageUrl;
        if (url == null) return;
        final uri = Uri.tryParse(url);
        if (uri != null) {
          unawaited(launchUrl(uri, mode: LaunchMode.externalApplication));
        }
      },
    );
    if (Platform.isAndroid) {
      await _notifications
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.createNotificationChannel(
            const AndroidNotificationChannel(
              _notificationChannelId,
              _notificationChannelName,
              description: 'Notifications about Saturn updates',
              importance: Importance.high,
            ),
          );
    } else if (Platform.isIOS) {
      await _notifications
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >()
          ?.requestPermissions(alert: true, badge: false, sound: false);
    } else if (Platform.isMacOS) {
      await _notifications
          .resolvePlatformSpecificImplementation<
            MacOSFlutterLocalNotificationsPlugin
          >()
          ?.requestPermissions(alert: true, badge: false, sound: false);
    }
    _notificationSetup = true;
  }

  Future<void> _notifyNewVersion(String version) async {
    try {
      final supportDirectory = await getApplicationSupportDirectory();
      final marker = File(
        '${supportDirectory.path}${Platform.pathSeparator}update-notified-version.txt',
      );
      if (await marker.exists() &&
          (await marker.readAsString()).trim() == version) {
        return;
      }
      await _initializeNotifications();
      await _notifications.show(
        id: _notificationId,
        title: 'Saturn update available',
        body: 'Version $version is ready. Tap to view the release notes.',
        payload: releasePageUrl,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            _notificationChannelId,
            _notificationChannelName,
            channelDescription: 'Notifications about Saturn updates',
            importance: Importance.high,
            priority: Priority.high,
            icon: 'ic_logo',
          ),
          iOS: DarwinNotificationDetails(),
          macOS: DarwinNotificationDetails(),
          linux: LinuxNotificationDetails(defaultActionName: 'Open'),
          windows: WindowsNotificationDetails(),
        ),
      );
      await marker.writeAsString(version, flush: true);
    } catch (error, stackTrace) {
      Logger.root.warning(
        'Could not show update notification: $error',
        error,
        stackTrace,
      );
    }
  }
}
