import 'package:flutter_discord_rpc/flutter_discord_rpc.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:saturn/settings.dart';

class DiscordRPCService {
  static DiscordRPCService? _instance;
  bool _isInitialized = false;

  DiscordRPCService._();

  static Future<DiscordRPCService> getInstance() async {
    _instance ??= DiscordRPCService._();
    return _instance!;
  }

  void discordRPCController() {
    initialize();
    FlutterDiscordRPC.instance.isConnectedStream.listen((isConnected) {
      if (!isConnected) {
        FlutterDiscordRPC.instance.reconnect();
      }
    });
  }

  void initialize() {
    FlutterDiscordRPC.initialize('882672432144592957');
    FlutterDiscordRPC.instance.connect(autoRetry: true);
    FlutterDiscordRPC.instance.isConnectedStream.listen((isConnected) {
      if (isConnected) {
        _isInitialized = true;
      }
    });
  }

  Future<void> updateRPC(
    String songName,
    String artist,
    String albumArt,
    String album, {
    RPCTimestamps? timestamps,
  }) async {
    if (!_isInitialized) return;
    final discordRPC = settings.enableDiscordRPC;
    if (!discordRPC) {
      clearRPC();
      return;
    }
    final packageInfo = await PackageInfo.fromPlatform();
    while (!FlutterDiscordRPC.instance.isConnected) {
      await Future.delayed(const Duration(seconds: 1));
    }
    FlutterDiscordRPC.instance.setActivity(
      activity: RPCActivity(
        state: artist,
        details: songName,
        timestamps: timestamps,
        assets: RPCAssets(
          largeImage: albumArt,
          largeText: album,
          smallImage: 'small',
          smallText: 'Saturn v${packageInfo.version}',
        ),
        buttons: [
          RPCButton(label: 'Download Saturn', url: 'https://saturn.kim/'),
        ],
        activityType: ActivityType.listening,
      ),
    );
  }

  void clearRPC() {
    FlutterDiscordRPC.instance.clearActivity();
  }

  void disconnect() {
    FlutterDiscordRPC.instance.disconnect();
  }

  void dispose() {
    FlutterDiscordRPC.instance.dispose();
    _isInitialized = false;
  }
}
