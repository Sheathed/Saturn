// lib/env/env.dart
import 'package:envied/envied.dart';

part 'env.g.dart';

@Envied(path: 'lib/.env')
abstract class Env {
  @EnviedField(varName: 'deezerClientId', obfuscate: true)
  static final String deezerClientId = _Env.deezerClientId;
  @EnviedField(varName: 'deezerClientSecret', obfuscate: true)
  static final String deezerClientSecret = _Env.deezerClientSecret;
}
